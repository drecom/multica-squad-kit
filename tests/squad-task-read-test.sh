#!/usr/bin/env bash
# squad-task-read を、CLI を差し替えて確認する。実際のタスクと GitHub には触れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/task-read-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export TASK_READ_TEST_DIR=$test_dir
stub_dir=$test_dir/stub
mkdir -p "$test_dir/bin" "$stub_dir"
script=$root/common/monitor/squad-task-read

cat >"$test_dir/bin/multica" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$TASK_READ_TEST_DIR/stub
printf 'multica %s\n' "$*" >>"$dir/calls.log"
flag() { [[ -f $dir/$1 ]]; }
case "${1-} ${2-} ${3-}" in
"issue get"*)
	flag issue-fail && exit 1
	cat "$dir/issue.json" ;;
"issue comment list")
	flag comments-fail && exit 1
	cat "$dir/comments.json" ;;
"issue runs"*)
	flag runs-fail && exit 1
	cat "$dir/runs.json" ;;
"squad list"*)
	flag roster-fail && exit 1
	cat "$dir/squads.json" ;;
"squad member"*)
	cat "$dir/members.json" ;;
"agent get"*)
	cat "$dir/agent-$3.json" ;;
*)
	echo "予期しない呼び出し: $*" >&2
	exit 99 ;;
esac
MOCK
cat >"$test_dir/bin/gh" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$TASK_READ_TEST_DIR/stub
printf 'gh %s\n' "$*" >>"$dir/calls.log"
[[ ${1-} == pr && ${2-} == view ]] || { echo "予期しない呼び出し: $*" >&2; exit 99; }
if [[ $* == *isDraft* ]]; then
	[[ ! -f $dir/pr-fail ]] || { echo 'gh: pull request が読めません' >&2; exit 1; }
	cat "$dir/pr.json"
else
	[[ ! -f $dir/ci-fail ]] || { echo 'gh: チェックが読めません' >&2; exit 1; }
	cat "$dir/ci.json"
fi
MOCK
chmod +x "$test_dir/bin/multica" "$test_dir/bin/gh"
export PATH="$test_dir/bin:$PATH"

fail() { echo "失敗: $*" >&2; exit 1; }

IMPL=agent-impl
FIXER=agent-fixer
DESIGNER=agent-designer
LEADER=agent-leader
TASK=TASK-1
PR_URL=https://github.com/drecom/multica-squad-kit/pull/25

reset() { # スタブの状態を初めに戻す。
	rm -rf "$stub_dir"
	mkdir -p "$stub_dir"
	: >"$stub_dir/calls.log"
	echo '[]' >"$stub_dir/comments.json"
	echo '[]' >"$stub_dir/runs.json"
	issue_fixture "$PR_URL"
	roster_fixture
	pr_fixture
}

# タスクを 1 件作る。引数: pr_url（空なら metadata に入れない）
issue_fixture() {
	jq -n --arg pr "$1" '
		{id: "i-1", identifier: "TASK-1", title: "使用量を減らす", status: "in_progress", status_category: "started",
		 labels: [{id: "l-1", name: "重要"}, {id: "l-2", name: "設計"}],
		 metadata: ({repository: "drecom/multica-squad-kit", branch: "agent/x"} + (if $pr == "" then {} else {pr_url: $pr} end)),
		 assignee_type: "squad", assignee_id: "squad-1"}' >"$stub_dir/issue.json"
}

agent_record() { jq -n --arg id "$1" --arg name "$2" '{id: $id, name: $name, archived_at: null, model: "m"}'; }
roster_fixture() { # squad-run-cut state が読む名簿。
	echo "[{\"id\":\"squad-1\",\"name\":\"squadkit-and00\",\"leader_id\":\"$LEADER\",\"creator_id\":\"u-1\",\"archived_at\":null}]" >"$stub_dir/squads.json"
	local pair id
	for pair in "$LEADER:squadkit-orchestrator-and00" "$IMPL:squadkit-claude-implementer-and00" "$FIXER:squadkit-claude-fixer-and00" \
		"$DESIGNER:squadkit-designer-and00"; do
		id=${pair%%:*}
		agent_record "$id" "${pair#*:}" >"$stub_dir/agent-$id.json"
	done
	echo "[{\"member_type\":\"agent\",\"member_id\":\"$LEADER\"},{\"member_type\":\"agent\",\"member_id\":\"$IMPL\"},{\"member_type\":\"agent\",\"member_id\":\"$FIXER\"},{\"member_type\":\"agent\",\"member_id\":\"$DESIGNER\"}]" >"$stub_dir/members.json"
}

# PR と CI を作る。CI は CheckRun 2 件と StatusContext 1 件。
pr_fixture() {
	jq -n '{number: 25, title: "feat", author: {is_bot: false, login: "someone"}, state: "OPEN", isDraft: true,
		baseRefName: "main", headRefOid: "0123456789abcdef0123456789abcdef01234567", headRefName: "agent/x",
		mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}' >"$stub_dir/pr.json"
	jq -n '{state: "OPEN", headRefOid: "0123456789abcdef0123456789abcdef01234567", statusCheckRollup: [
		{__typename: "CheckRun", name: "lint", status: "COMPLETED", workflowName: "ci", conclusion: "SUCCESS"},
		{__typename: "CheckRun", name: "test", status: "IN_PROGRESS", workflowName: "ci", conclusion: null},
		{__typename: "StatusContext", context: "external", state: "PENDING"}]}' >"$stub_dir/ci.json"
}

# コメントを 1 件作る。引数: id 種類 作者 時刻 親 本文
comment() {
	jq -n --arg id "$1" --arg type "$2" --arg author "$3" --arg at "$4" --arg parent "$5" --arg content "$6" '
		{id: $id, author_type: $type, author_id: $author, created_at: $at,
		 parent_id: (if $parent == "" then null else $parent end), content: $content}
		+ (if $type == "member" then {} else {source_task_id: "task-1"} end)'
}
comments() { jq -s '.' "$@"; }
state_cut() { comment "$1" agent "$2" "$3" '' $'区切り: 1\n済んだこと: a\n残り: b\n次に読む場所: c'; }
# 今から秒数だけ前の時刻
ago() { jq -nr --argjson s "$1" '(now - $s) | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
run_record() {
	jq -n --arg id "$1" --arg agent "$2" --arg status "$3" --arg at "$4" '
		{id: $id, agent_id: $agent, kind: "direct", status: $status, created_at: $at, delivered_comment_ids: [], error: null}'
}

run() {
	status=0
	MULTICA_AGENT_ID=${CALLER-$LEADER} MULTICA_TASK_ID=run-1 "$script" "$@" >"$test_dir/out" 2>"$test_dir/err" || status=$?
	out=$(<"$test_dir/out")
	err=$(<"$test_dir/err")
}
expect_status() { [[ $status == "$1" ]] || fail "$2: 終了コード ${status}（期待 ${1}）。出力: $out / $err"; }
# JSON の式が真になることを確かめる。
expect_json() { jq -e "$1" >/dev/null <<<"$out" || fail "$2: 式 ${1} が真になりません。出力: $out"; }

# ---- 欄がそろう ----
reset
comments <(comment c1 member u-1 2026-11-01T01:00:00Z '' '依頼です') <(comment c2 agent "$IMPL" 2026-11-01T02:00:00Z c1 '返事です') >"$stub_dir/comments.json"
echo "[$(run_record r1 "$IMPL" completed 2026-11-01T01:30:00Z)]" >"$stub_dir/runs.json"
run $TASK
expect_status 0 '欄がそろう'
[[ $(jq -c 'keys' <<<"$out") == '["ci","comments","cuts","errors","pr","runs","schema_version","task"]' ]] || fail "欄が違います: $out"
[[ $(jq -s length <<<"$out") == 1 ]] || fail "JSON が 1 つではありません: $out"
expect_json '.schema_version == 1' 'schema_version'
expect_json '.task == {id: "i-1", identifier: "TASK-1", title: "使用量を減らす", status: "in_progress", labels: ["重要", "設計"],
	metadata: {repository: "drecom/multica-squad-kit", branch: "agent/x", pr_url: "'"$PR_URL"'"}, assignee_type: "squad", assignee_id: "squad-1"}' 'task'
expect_json '.comments == [
	{id: "c1", parent_id: null, author_type: "member", author_id: "u-1", created_at: "2026-11-01T01:00:00Z", content: "依頼です"},
	{id: "c2", parent_id: "c1", author_type: "agent", author_id: "'"$IMPL"'", created_at: "2026-11-01T02:00:00Z", content: "返事です"}]' 'comments'
expect_json '.pr == {url: "'"$PR_URL"'", state: "OPEN", draft: true, head_sha: "0123456789abcdef0123456789abcdef01234567", mergeable: "MERGEABLE"}' 'pr'
expect_json '.ci == {head_sha: "0123456789abcdef0123456789abcdef01234567", checks: [
	{name: "lint", status: "COMPLETED", conclusion: "SUCCESS"},
	{name: "test", status: "IN_PROGRESS", conclusion: null},
	{name: "external", status: "PENDING", conclusion: "PENDING"}]}' 'ci'
expect_json '.runs == [{id: "r1", agent_id: "'"$IMPL"'", status: "completed", created_at: "2026-11-01T01:30:00Z"}]' 'runs'
expect_json '.cuts == [] and .errors == []' '区切りも読めない欄もない'
grep -q "^gh pr view 25 --repo drecom/multica-squad-kit " "$stub_dir/calls.log" || fail "PR の番号とリポジトリで読んでいません: $(cat "$stub_dir/calls.log")"
grep -q "^gh pr view $PR_URL " "$stub_dir/calls.log" || fail "CI を PR の URL で読んでいません: $(cat "$stub_dir/calls.log")"
! grep -qE '^(multica (issue comment add|issue status|issue update)|gh pr (edit|comment|merge))' "$stub_dir/calls.log" || fail "読み取り以外の呼び出しがあります"

# ---- --since ----
reset
comments <(comment c1 member u-1 2026-11-01T01:00:00Z '' '古い') <(comment c2 agent "$IMPL" 2026-11-01T02:00:00.123456Z '' '境目より後') \
	<(comment c3 agent "$IMPL" 2026-11-01T03:00:00+00:00 '' '新しい') >"$stub_dir/comments.json"
run $TASK --since 2026-11-01T01:30:00Z
expect_status 0 '--since'
expect_json '[.comments[].id] == ["c2", "c3"]' '--since より後だけ'
run $TASK --since 2026-11-01T02:00:00Z
expect_json '[.comments[].id] == ["c3"]' '--since と同じ時刻は含めない'
run $TASK --since 2026-11-01T10:30:00+09:00
expect_json '[.comments[].id] == ["c2", "c3"]' '--since の時差'
run $TASK --since 2026-11-01T11:00:00+09:00
expect_json '[.comments[].id] == ["c3"]' '--since の時差の境目'
run $TASK --since 2026-11-01T03:00:00Z
expect_json '.comments == []' '--since のあとにコメントがない'
run --since 2026-11-01T01:30:00Z $TASK
expect_status 0 '--since を先に書く'
expect_json '[.comments[].id] == ["c2", "c3"]' '--since を先に書く'
run $TASK
expect_json '[.comments[].id] == ["c1", "c2", "c3"]' '--since なしは全件'

# ---- PR のないタスク ----
reset
issue_fixture ''
run $TASK
expect_status 0 'PR なし'
expect_json '.pr == null and .ci == null and .errors == []' 'PR のないタスクで pr と ci が null'
expect_json '.task.identifier == "TASK-1" and (.comments | type == "array") and (.runs | type == "array") and (.cuts | type == "array")' 'PR なしでも、ほかの欄は読む'
! grep -q '^gh ' "$stub_dir/calls.log" || fail "PR がないのに gh を呼んでいます: $(cat "$stub_dir/calls.log")"
jq '.metadata.pr_url = ""' "$stub_dir/issue.json" >"$stub_dir/issue2.json" && mv "$stub_dir/issue2.json" "$stub_dir/issue.json"
run $TASK
expect_json '.pr == null and .ci == null and .errors == []' 'pr_url が空'

# ---- 区切りの途中が cuts に出る ----
reset
comments <(state_cut k1 "$IMPL" "$(ago 600)") <(state_cut k2 "$FIXER" "$(ago 2400)") <(state_cut k3 "$DESIGNER" "$(ago 2000)") >"$stub_dir/comments.json"
echo "[$(run_record r1 "$DESIGNER" running "$(ago 1000)")]" >"$stub_dir/runs.json"
run $TASK
expect_status 0 'cuts'
expect_json '.cuts | sort_by(.agent_id) == [
	{agent_id: "'"$DESIGNER"'", state: "動いている", comment_id: "k3"},
	{agent_id: "'"$FIXER"'", state: "始まらない", comment_id: "k2"},
	{agent_id: "'"$IMPL"'", state: "待ち", comment_id: "k1"}]' '区切りの途中が役・状態・コメントの ID で出る'
expect_json '.errors == []' 'cuts を読めた'
echo "[$(run_record r1 "$DESIGNER" completed "$(ago 1000)"), $(run_record r2 "$IMPL" failed "$(ago 300)")]" >"$stub_dir/runs.json"
run $TASK
expect_json '[.cuts[] | select(.agent_id == "'"$DESIGNER"'") | .state] == ["終わった"] and [.cuts[] | select(.agent_id == "'"$IMPL"'") | .state] == ["失敗した"]' '終わった・失敗した'

# ---- 読めない欄は null にして errors に理由を足す。終了コードは 0 ----
reset
touch "$stub_dir/pr-fail"
run $TASK
expect_status 0 'PR を読めない'
expect_json '.pr == null and .ci != null and (.errors | length == 1) and .errors[0].field == "pr" and (.errors[0].reason | contains("pull request が読めません"))' 'PR を読めない'
rm "$stub_dir/pr-fail"
touch "$stub_dir/ci-fail"
run $TASK
expect_status 0 'CI を読めない'
expect_json '.ci == null and .pr != null and (.errors | length == 1) and .errors[0].field == "ci" and (.errors[0].reason | contains("チェックが読めません"))' 'CI を読めない'
rm "$stub_dir/ci-fail"
touch "$stub_dir/runs-fail"
run $TASK
expect_status 0 '実行を読めない'
expect_json '.runs == null and .task != null and ([.errors[].field] | index("runs") != null)' '実行を読めない'
# 区切りの途中は実行の一覧も読むので、実行を読めないと cuts も null になる。
expect_json '.cuts == null and ([.errors[].field] | sort) == ["cuts", "runs"]' '実行を読めないと cuts も null'
rm "$stub_dir/runs-fail"
touch "$stub_dir/roster-fail"
run $TASK
expect_status 0 '区切りを読めない'
expect_json '.cuts == null and ([.errors[].field] == ["cuts"]) and .runs != null and .pr != null' '区切りを読めない'
rm "$stub_dir/roster-fail"
echo '{"state":"OPEN"}' >"$stub_dir/pr.json"
run $TASK
expect_status 0 'PR の応答が約束と違う'
expect_json '.pr == null and ([.errors[].field] == ["pr"])' 'PR の応答が約束と違う'
reset
issue_fixture 'https://example.com/not-a-pr'
run $TASK
expect_status 0 'pr_url の形が違う'
expect_json '.pr == null and .ci == null and ([.errors[].field] | sort) == ["ci", "pr"]' 'pr_url の形が違う'
! grep -q '^gh ' "$stub_dir/calls.log" || fail "pr_url の形が違うのに gh を呼んでいます"
# 読めない欄があっても、ほかの欄は出る。
reset
touch "$stub_dir/pr-fail" "$stub_dir/ci-fail" "$stub_dir/runs-fail" "$stub_dir/roster-fail"
comments <(comment c1 member u-1 2026-11-01T01:00:00Z '' '依頼です') >"$stub_dir/comments.json"
run $TASK
expect_status 0 '4 欄を読めない'
expect_json '.pr == null and .ci == null and .runs == null and .cuts == null and ([.errors[].field] | sort) == ["ci", "cuts", "pr", "runs"] and (.comments | length == 1) and .task.id == "i-1"' '4 欄を読めない'
[[ $(jq '[.errors[] | select(.reason == "")] | length' <<<"$out") == 0 ]] || fail "理由が空の errors があります: $out"

# ---- タスクを読めなければ 1 ----
reset
touch "$stub_dir/issue-fail"
run $TASK
expect_status 1 'タスクを読めない'
[[ -z $out ]] || fail "タスクを読めないのに標準出力があります: $out"
[[ $err == *'タスクを読めません'* ]] || fail "理由が標準エラーにありません: $err"
reset
echo 'not json' >"$stub_dir/issue.json"
run $TASK
expect_status 1 'タスクが JSON でない'
reset
jq 'del(.identifier)' "$stub_dir/issue.json" >"$stub_dir/issue2.json" && mv "$stub_dir/issue2.json" "$stub_dir/issue.json"
run $TASK
expect_status 1 'タスクが約束の欄を欠く'
reset
touch "$stub_dir/comments-fail"
run $TASK
expect_status 1 'コメントを読めない'
[[ -z $out ]] || fail "コメントを読めないのに標準出力があります: $out"

# ---- 使い方の誤りは 2 で、CLI を呼ばない ----
reset
for args in "" "--since" "--since ''" "$TASK --since" "$TASK --since not-a-time" "$TASK --since 2026-11-01" "$TASK --since 2026-13-45T25:61:61Z" \
	"$TASK extra" "$TASK --unknown" "$TASK --since 2026-11-01T01:00:00Z --since 2026-11-01T02:00:00Z" "''"; do
	eval "run $args"
	expect_status 2 "使い方の誤り（${args}）"
	[[ -z $out ]] || fail "使い方の誤りで標準出力があります（${args}）: $out"
	[[ $err == *'使い方: squad-task-read'* ]] || fail "使い方が標準エラーにありません（${args}）: $err"
done
[[ ! -s $stub_dir/calls.log ]] || fail "使い方の誤りで CLI を呼んでいます: $(cat "$stub_dir/calls.log")"

echo 'squad-task-read-test: ok'
