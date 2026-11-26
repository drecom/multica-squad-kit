#!/usr/bin/env bash
# squad-task-post を、CLI を差し替えて確認する。実際のタスクには触れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/task-post-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export TASK_POST_TEST_DIR=$test_dir
stub_dir=$test_dir/stub
mkdir -p "$test_dir/bin" "$stub_dir"
script=$root/common/monitor/squad-task-post

cat >"$test_dir/bin/multica" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$TASK_POST_TEST_DIR/stub
printf 'multica %s\n' "$*" >>"$dir/calls.log"
flag() { [[ -f $dir/$1 ]]; }
case "${1-} ${2-} ${3-}" in
"issue get"*)
	flag issue-fail && { echo 'multica: タスクが読めません' >&2; exit 1; }
	cat "$dir/issue.json" ;;
"issue comment add")
	flag post-fail && { echo 'multica: 投稿できません' >&2; exit 1; }
	[[ -f $4 || $* == *"--content-file "* ]] || exit 99
	if flag id-unreadable; then echo '{"ok":true}'; else echo '{"id":"c-new"}'; fi ;;
"issue status "*)
	if flag status-fail; then echo 'multica: 状態を変えられません' >&2; exit 1; fi ;;
*)
	echo "予期しない呼び出し: $*" >&2
	exit 99 ;;
esac
MOCK
chmod +x "$test_dir/bin/multica"
export PATH="$test_dir/bin:$PATH"

fail() { echo "失敗: $*" >&2; exit 1; }
TASK=TASK-1
body=$test_dir/body.md
printf '人間の返事を待ちます。\n' >"$body"

reset() {
	rm -rf "$stub_dir"
	mkdir -p "$stub_dir"
	: >"$stub_dir/calls.log"
	jq -n '{id: "i-1", identifier: "TASK-1", title: "使用量を減らす", status: "in_progress", status_category: "started",
		labels: [], metadata: {}, assignee_type: "squad", assignee_id: "squad-1"}' >"$stub_dir/issue.json"
}
run() {
	status=0
	"$script" "$@" >"$test_dir/out" 2>"$test_dir/err" || status=$?
	out=$(<"$test_dir/out")
	err=$(<"$test_dir/err")
}
expect_status() { [[ $status == "$1" ]] || fail "$2: 終了コード ${status}（期待 ${1}）。出力: $out / $err"; }
calls() { cat "$stub_dir/calls.log"; }
expect_calls() { # 呼び出しの行に、期待する文字列が含まれる（$1）か、含まれない（$2 が not）ことを確認する。
	if [[ ${3-} == not ]]; then
		! calls | grep -qF -- "$1" || fail "$2: 呼ばれないはずの ${1} が呼ばれました。呼び出し: $(calls)"
	else
		calls | grep -qF -- "$1" || fail "$2: ${1} が呼ばれていません。呼び出し: $(calls)"
	fi
}

# ---- 両方できる: 投稿のあとに状態を変える ----
reset
run "$TASK" --status in_review --content-file "$body"
expect_status 0 '両方できる'
[[ $out == $'投稿: c-new\n状態: in_progress -> in_review' ]] || fail "両方できる: 出力が違います: $out"
[[ -z $err ]] || fail "両方できる: 標準エラーに出ています: $err"
post_line=$(calls | grep -n 'issue comment add' | head -n 1 | cut -d: -f1)
status_line=$(calls | grep -n 'issue status' | head -n 1 | cut -d: -f1)
[[ -n $post_line && -n $status_line && $post_line -lt $status_line ]] || fail '両方できる: 投稿より先に状態を変えています'
expect_calls "multica issue comment add $TASK --content-file $body --output json" '両方できる: 親なしの投稿'
expect_calls "multica issue status $TASK in_review" '両方できる: 状態の変更'
[[ $(calls | grep -c 'issue comment add') == 1 && $(calls | grep -c 'issue status') == 1 ]] || fail '両方できる: 投稿と状態の変更は 1 回ずつです'

# ---- 親を渡すと、そのスレッドに投稿する ----
reset
run "$TASK" --status blocked --content-file "$body" --parent c-parent
expect_status 0 '親あり'
expect_calls "--parent c-parent" '親あり: 親の指定'
[[ $out == $'投稿: c-new\n状態: in_progress -> blocked' ]] || fail "親あり: 出力が違います: $out"

# ---- 引数の順が違っても同じ ----
reset
run --parent c-parent --content-file "$body" --status todo "$TASK"
expect_status 0 '引数の順'
[[ $out == $'投稿: c-new\n状態: in_progress -> todo' ]] || fail "引数の順: 出力が違います: $out"

# ---- 投稿できない: 状態は変えない ----
reset
touch "$stub_dir/post-fail"
run "$TASK" --status in_review --content-file "$body"
expect_status 1 '投稿の失敗'
[[ $out != *投稿:* ]] || fail "投稿の失敗: 投稿の行が出ています: $out"
[[ $err == *'状態は変えていません'* ]] || fail "投稿の失敗: 理由が標準エラーにありません: $err"
expect_calls 'issue status' '投稿の失敗: 状態は変えない' not
reset
touch "$stub_dir/post-fail"
run "$TASK" --status in_review --content-file "$body" --parent c-parent
expect_status 1 '親ありの投稿の失敗'
expect_calls 'issue status' '親ありの投稿の失敗: 状態は変えない' not

# ---- 状態を読めない: 投稿も状態の変更もしない ----
reset
touch "$stub_dir/issue-fail"
run "$TASK" --status in_review --content-file "$body"
expect_status 1 '状態を読めない'
expect_calls 'issue comment add' '状態を読めない: 投稿しない' not
expect_calls 'issue status' '状態を読めない: 状態は変えない' not

# ---- 投稿のあとに状態を変えられない: 3、投稿の行は出す ----
reset
touch "$stub_dir/status-fail"
run "$TASK" --status in_review --content-file "$body"
expect_status 3 '状態の失敗'
[[ $out == '投稿: c-new' ]] || fail "状態の失敗: 投稿の行だけが出るはずです: $out"
[[ $err == *'multica issue status だけを流し直して'* ]] || fail "状態の失敗: 流し直しの案内が標準エラーにありません: $err"
[[ $(calls | grep -c 'issue comment add') == 1 ]] || fail '状態の失敗: 投稿は 1 回だけです'

# ---- 投稿はできたが ID を読めない: 状態は変える ----
reset
touch "$stub_dir/id-unreadable"
run "$TASK" --status in_review --content-file "$body"
expect_status 0 'ID を読めない'
[[ $out == $'投稿: 未確認\n状態: in_progress -> in_review' ]] || fail "ID を読めない: 出力が違います: $out"
[[ $err == *'コメントの ID を読めません'* ]] || fail "ID を読めない: 理由が標準エラーにありません: $err"
expect_calls "multica issue status $TASK in_review" 'ID を読めない: 状態の変更'
[[ $(calls | grep -c 'issue comment add') == 1 ]] || fail 'ID を読めない: 投稿は 1 回だけです'
reset
touch "$stub_dir/id-unreadable"
run "$TASK" --status in_review --content-file "$body" --parent c-parent
expect_status 0 '親ありで ID を読めない'
[[ $out == $'投稿: 未確認\n状態: in_progress -> in_review' ]] || fail "親ありで ID を読めない: 出力が違います: $out"
expect_calls "multica issue status $TASK in_review" '親ありで ID を読めない: 状態の変更'
[[ $(calls | grep -c 'issue comment add') == 1 ]] || fail '親ありで ID を読めない: 投稿は 1 回だけです'
reset
touch "$stub_dir/id-unreadable" "$stub_dir/status-fail"
run "$TASK" --status in_review --content-file "$body"
expect_status 3 'ID を読めず状態も変えられない'
[[ $out == '投稿: 未確認' ]] || fail "ID を読めず状態も変えられない: 出力が違います: $out"
[[ $err == *'multica issue status だけを流し直して'* ]] || fail "ID を読めず状態も変えられない: 流し直しの案内がありません: $err"

# ---- 使い方の誤り: 2、CLI は呼ばない ----
usage_error() { # 引数: 名前 引数...
	local name=$1
	shift
	reset
	run "$@"
	expect_status 2 "$name"
	[[ $err == *'使い方'* ]] || fail "${name}: 標準エラーに使い方がありません: $err"
	[[ ! -s $stub_dir/calls.log ]] || fail "${name}: CLI を呼んでいます: $(calls)"
}
usage_error '引数なし'
usage_error 'タスクなし' --status in_review --content-file "$body"
usage_error '状態なし' "$TASK" --content-file "$body"
usage_error 'ファイルなし' "$TASK" --status in_review
usage_error '状態が空' "$TASK" --status '' --content-file "$body"
usage_error '状態が不明' "$TASK" --status finished --content-file "$body"
usage_error '値のない --status' "$TASK" --content-file "$body" --status
usage_error '親が空' "$TASK" --status in_review --content-file "$body" --parent ''
usage_error '同じ指定の繰り返し' "$TASK" --status in_review --status done --content-file "$body"
usage_error '知らない指定' "$TASK" --status in_review --content-file "$body" --force
usage_error 'タスクが 2 つ' "$TASK" TASK-2 --status in_review --content-file "$body"
usage_error 'ファイルがない' "$TASK" --status in_review --content-file "$test_dir/none.md"
: >"$test_dir/empty.md"
usage_error '空のファイル' "$TASK" --status in_review --content-file "$test_dir/empty.md"

echo 'PASS squad-task-post: 投稿のあとに状態を変え、投稿できなければ状態を変えず、状態の失敗は 3 で返す'
