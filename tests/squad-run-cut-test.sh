#!/usr/bin/env bash
# squad-run-cut の check と post を、CLI を差し替えて確かめる。実際のタスクには触れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/run-cut-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export RUN_CUT_TEST_DIR=$test_dir
stub_dir=$test_dir/stub
monitor=$test_dir/monitor
work=$test_dir/work
mkdir -p "$test_dir/bin" "$stub_dir" "$monitor" "$work"

# 値のファイルを書き換えて確かめるので、スクリプトと値を、テストの場所へ写す。
cp common/monitor/squad-run-cut common/monitor/squad-cli-lib common/monitor/squad-run-cut-values "$monitor/"
script=$monitor/squad-run-cut

cat >"$test_dir/bin/multica" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$RUN_CUT_TEST_DIR/stub
printf '%s\n' "$*" >>"$dir/calls.log"
next() { # 呼んだ回数を数える。第 1 引数は種類。
	local n=0
	[[ -f $dir/count-$1 ]] && n=$(<"$dir/count-$1")
	n=$((n + 1))
	printf '%s\n' "$n" >"$dir/count-$1"
	printf '%s\n' "$n"
}
flag() { [[ -f $dir/$1 ]]; }
case "${1-} ${2-} ${3-}" in
"issue run-messages"*)
	flag run-messages-fail && exit 1
	cat "$dir/run-messages.json" ;;
"issue comment list")
	flag comment-list-fail && exit 1
	cat "$dir/comments.json" ;;
"issue comment add")
	flag comment-add-fail && exit 1
	n=$(next comment)
	body=
	for ((i = 1; i <= $#; i++)); do
		if [[ ${!i} == --content-file ]]; then j=$((i + 1)); body=${!j}; fi
	done
	cp "$body" "$dir/posted-$n.md"
	printf '{"id":"posted-%s"}\n' "$n" ;;
"issue wakeup create")
	n=$(next wakeup)
	file=
	for ((i = 1; i <= $#; i++)); do
		if [[ ${!i} == --instruction-file ]]; then j=$((i + 1)); file=${!j}; fi
	done
	cp "$file" "$dir/wake-$n.txt"
	flag "wakeup-fail-$n" && exit 1
	printf '{"id":"wake-%s"}\n' "$n" ;;
"issue wakeup delete")
	flag wakeup-delete-fail && exit 1
	printf '{}\n' ;;
*)
	echo "予期しない呼び出し: $*" >&2
	exit 99 ;;
esac
MOCK
chmod +x "$test_dir/bin/multica"
export PATH="$test_dir/bin:$PATH"

fail() { echo "失敗: $*" >&2; exit 1; }

reset() { # スタブの状態と値のファイルを初めに戻す。
	rm -rf "$stub_dir"
	mkdir -p "$stub_dir" "$work/tmp"
	rm -f "$work"/tmp/*
	: >"$stub_dir/calls.log"
	cp common/monitor/squad-run-cut-values "$monitor/"
	echo '[]' >"$stub_dir/run-messages.json"
	echo '[]' >"$stub_dir/comments.json"
}

# 終了コードと標準出力・標準エラーを残して、スクリプトを呼ぶ。
run() {
	status=0
	(cd "$work" && MULTICA_TASK_ID=${RUN_ID-run-1} "$script" "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
	out=$(<"$test_dir/out")
	err=$(<"$test_dir/err")
}
expect_status() {
	[[ $status == "$1" ]] || fail "$2: 終了コード ${status}（期待 ${1}）。出力: $out / $err"
}
expect_out() {
	[[ $out == *"$1"* ]] || fail "$2: 標準出力に「${1}」がありません。出力: $out"
}
calls() { cat "$stub_dir/calls.log"; }
no_calls() { [[ ! -s $stub_dir/calls.log ]] || fail "$1: CLI を呼んでいます: $(calls)"; }

# tool_use を n 個と、数えてはいけない種類を混ぜた記録を作る。
messages() {
	jq -n --argjson n "$1" '
		[{type: "text", content: "考え中"}]
		+ [range($n) | {type: "tool_use", tool: "Bash", seq: .}]
		+ [range($n) | {type: "tool_result", output: "出力"}]'
}

# コメントを 1 件作る。引数: id 種類 作者 時刻 親 本文
comment() {
	jq -n --arg id "$1" --arg type "$2" --arg author "$3" --arg at "$4" --arg parent "$5" --arg content "$6" '
		{id: $id, author_type: $type, author_id: $author, created_at: $at,
		 parent_id: (if $parent == "" then null else $parent end), content: $content}
		+ (if $type == "member" then {} else {source_task_id: "task-1"} end)'
}
comments() { jq -s '.' "$@"; }

SELF=agent-self
LEADER=agent-leader
TASK=TASK-1
handoff=$test_dir/handoff.md
write_handoff() {
	cat >"$handoff" <<'EOF'
区切り: 2 回目
済んだこと: 設計と実装の 3 つ目まで
残り: 4 つ目の実装とテスト
次に読む場所: docs の「区切り」の節
EOF
}

# ---- check ----
reset
echo "$(messages 3)" >"$stub_dir/run-messages.json"
run check $TASK $SELF 0
expect_status 0 'check 少ない呼び出し'
[[ $out == '区切り: 要らない 呼び出し=3 圧縮=0' ]] || fail "check の出力が違います: $out"
grep -q '^issue run-messages run-1 --issue TASK-1 --output json$' "$stub_dir/calls.log" || fail "run-messages の呼び出しが違います: $(calls)"

reset
echo "$(messages 99)" >"$stub_dir/run-messages.json"
run check $TASK $SELF 0
expect_status 0 'check 99 回'
expect_out '区切り: 要らない 呼び出し=99' 'check 99 回'
echo "$(messages 100)" >"$stub_dir/run-messages.json"
run check $TASK $SELF 0
expect_status 0 'check 100 回'
expect_out '区切り: 要る 呼び出し=100' 'check 100 回'

reset
run check $TASK $SELF 2
expect_out '区切り: 要らない 呼び出し=0 圧縮=2' 'check 圧縮 2 回'
run check $TASK $SELF 3
expect_status 0 'check 圧縮 3 回'
expect_out '区切り: 要る 呼び出し=0 圧縮=3' 'check 圧縮 3 回'

# 値のファイルを書き換えると、判定が変わる。
reset
echo "$(messages 10)" >"$stub_dir/run-messages.json"
run check $TASK $SELF 1
expect_out '区切り: 要らない' 'check 既定の値'
sed -i.bak -e 's/^CALLS=.*/CALLS=5/' "$monitor/squad-run-cut-values"
run check $TASK $SELF 0
expect_out '区切り: 要る 呼び出し=10' 'check CALLS を 5 にした'
cp common/monitor/squad-run-cut-values "$monitor/"
sed -i.bak -e 's/^COMPACTIONS=.*/COMPACTIONS=1/' "$monitor/squad-run-cut-values"
run check $TASK $SELF 1
expect_out '区切り: 要る' 'check COMPACTIONS を 1 にした'

# 実行の ID がない・記録を読めないときは、呼び出しを未確認にし、圧縮の数だけで決める。
reset
status=0
(cd "$work" && env -u MULTICA_TASK_ID "$script" check $TASK $SELF 3) >"$test_dir/out" 2>"$test_dir/err" || status=$?
out=$(<"$test_dir/out")
expect_status 0 'check 実行の ID なし'
[[ $out == '区切り: 要る 呼び出し=未確認 圧縮=3' ]] || fail "実行の ID なしの出力が違います: $out"
[[ ! -s $stub_dir/calls.log ]] || fail "実行の ID がないのに run-messages を呼んでいます"
status=0
(cd "$work" && env -u MULTICA_TASK_ID "$script" check $TASK $SELF 0) >"$test_dir/out" 2>"$test_dir/err" || status=$?
out=$(<"$test_dir/out")
[[ $out == '区切り: 要らない 呼び出し=未確認 圧縮=0' ]] || fail "実行の ID なしで圧縮 0 の出力が違います: $out"

touch "$stub_dir/run-messages-fail"
run check $TASK $SELF 1
expect_status 0 'check 記録を読めない'
expect_out '区切り: 要らない 呼び出し=未確認 圧縮=1' 'check 記録を読めない'
rm "$stub_dir/run-messages-fail"
echo 'not json' >"$stub_dir/run-messages.json"
run check $TASK $SELF 3
expect_status 0 'check 記録が JSON でない'
expect_out '区切り: 要る 呼び出し=未確認 圧縮=3' 'check 記録が JSON でない'
echo '{"type":"tool_use"}' >"$stub_dir/run-messages.json"
run check $TASK $SELF 0
expect_out '呼び出し=未確認' 'check 記録が配列でない'

# 使い方の誤りは 2 で止まり、CLI を呼ばない。
reset
for bad in "" "check" "check $TASK $SELF" "check $TASK $SELF x" "check $TASK $SELF 1 extra" "check '' $SELF 1" "resume $TASK" "state $TASK" "unknown"; do
	# shellcheck disable=SC2086
	eval "run ${bad}"
	expect_status 2 "使い方の誤り「${bad}」"
done
no_calls '使い方の誤り'

# 値のファイルの項目が正の整数でなければ、1 で止まる。
reset
sed -i.bak -e 's/^CALLS=.*/CALLS=abc/' "$monitor/squad-run-cut-values"
run check $TASK $SELF 0
expect_status 1 '値が数でない'
[[ $err == *CALLS* ]] || fail "値の誤りの項目名が出ていません: $err"
cp common/monitor/squad-run-cut-values "$monitor/"
sed -i.bak -e 's/^START_WAIT=.*/START_WAIT=0/' "$monitor/squad-run-cut-values"
write_handoff
run post $TASK "$handoff" $SELF $LEADER
expect_status 1 '値が 0'
no_calls '値が 0'

# ---- post ----
# 4 つの行のどれかがない・空なら、2 で止まり、CLI を呼ばない。
reset
for key in '区切り:' '済んだこと:' '残り:' '次に読む場所:'; do
	write_handoff
	grep -v "^${key}" "$handoff" >"$handoff.new"
	run post $TASK "$handoff.new" $SELF $LEADER
	expect_status 2 "行がない「${key}」"
	sed "s/^${key}.*/${key}/" "$handoff" >"$handoff.new"
	run post $TASK "$handoff.new" $SELF $LEADER
	expect_status 2 "行が空「${key}」"
done
run post $TASK "$test_dir/none.md" $SELF $LEADER
expect_status 2 'ファイルがない'
run post $TASK "$handoff" $SELF
expect_status 2 '引数が足りない'
no_calls '行の誤り'

# 起点がなければ、タスクの始めから数え、最上位に投稿する。
reset
write_handoff
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post 起点なし'
[[ $out == $'投稿: posted-1\n見張り: wake-1\n起こし: wake-2' ]] || fail "post の出力が違います: $out"
grep -q '^issue comment add TASK-1 --content-file .* --output json$' "$stub_dir/calls.log" || fail "最上位の投稿の呼び出しが違います: $(calls)"
! grep -q -- '--parent' <(grep '^issue comment add' "$stub_dir/calls.log") || fail "起点がないのに --parent を付けています"
cmp -s "$handoff" "$stub_dir/posted-1.md" || fail "投稿した本文が引き継ぎのファイルと違います"
! grep -q 'mention://' "$stub_dir/posted-1.md" || fail "投稿にメンションが入っています"

# 見張りが続きより先に作られ、値と指示が合う。
[[ $(grep -c '^issue wakeup create' "$stub_dir/calls.log") == 2 ]] || fail "起こしが 2 件ではありません: $(calls)"
first=$(grep '^issue wakeup create' "$stub_dir/calls.log" | sed -n 1p)
second=$(grep '^issue wakeup create' "$stub_dir/calls.log" | sed -n 2p)
[[ $first == *"--kind at"* && $first == *"--after 30m"* && $first == *"--agent-id $LEADER"* ]] || fail "見張りの引数が違います: $first"
[[ $second == *"--kind at"* && $second == *"--after 1m"* && $second == *"--agent-id $SELF"* ]] || fail "続きの引数が違います: $second"
[[ $(<"$stub_dir/wake-1.txt") == '区切りの続きの確認: posted-1' ]] || fail "見張りの指示が違います: $(<"$stub_dir/wake-1.txt")"
[[ $(<"$stub_dir/wake-2.txt") == '区切りの続きで起きました。 posted-1' ]] || fail "続きの指示が違います: $(<"$stub_dir/wake-2.txt")"
[[ -z $(ls "$work/tmp" 2>/dev/null) ]] || fail "指示の一時ファイルが残っています: $(ls "$work/tmp")"

# 値のファイルの START_WAIT を変えると、見張りの待ちが変わる。
reset
write_handoff
sed -i.bak -e 's/^START_WAIT=.*/START_WAIT=10/' "$monitor/squad-run-cut-values"
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post START_WAIT を 10 にした'
grep '^issue wakeup create' "$stub_dir/calls.log" | sed -n 1p | grep -q -- '--after 10m' || fail "START_WAIT が見張りに届いていません: $(calls)"

# 起点（自分のメンションを含む最も新しいコメント）が最上位なら、そのコメントのスレッドへ投稿する。
reset
write_handoff
comments \
	<(comment c1 member user-1 2026-11-01T00:00:00Z '' 'はじめ') \
	<(comment c2 agent leader 2026-11-01T01:00:00Z '' "[@自分](mention://agent/$SELF) 頼みます") \
	>"$stub_dir/comments.json"
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post 起点が最上位'
grep '^issue comment add' "$stub_dir/calls.log" | grep -q -- '--parent c2 ' || fail "起点のスレッドへ投稿していません: $(calls)"

# 起点が返信なら、スレッドの最上位へ投稿する。
reset
write_handoff
comments \
	<(comment c1 member user-1 2026-11-01T00:00:00Z '' 'はじめ') \
	<(comment c2 agent leader 2026-11-01T01:00:00Z c1 "[@自分](mention://agent/$SELF) 頼みます") \
	>"$stub_dir/comments.json"
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post 起点が返信'
grep '^issue comment add' "$stub_dir/calls.log" | grep -q -- '--parent c1 ' || fail "スレッドの最上位へ投稿していません: $(calls)"

# 起点は、メンションを含む最も新しいコメントにする。古い起点の前後の区切りは数えない。
reset
write_handoff
comments \
	<(comment c1 agent leader 2026-11-01T00:00:00Z '' "[@自分](mention://agent/$SELF) 1 回目") \
	<(comment c2 agent "$SELF" 2026-11-01T01:00:00Z c1 $'区切り: 1\n済んだこと: a') \
	<(comment c3 agent "$SELF" 2026-11-01T02:00:00Z c1 $'区切り: 2\n済んだこと: b') \
	<(comment c4 agent "$SELF" 2026-11-01T03:00:00Z c1 $'区切り: 3\n済んだこと: c') \
	<(comment c5 agent "$SELF" 2026-11-01T04:00:00Z c1 $'区切り: 4\n済んだこと: d') \
	<(comment c6 agent "$SELF" 2026-11-01T05:00:00Z c1 $'区切り: 5\n済んだこと: e') \
	<(comment c7 agent leader 2026-11-01T06:00:00Z '' "[@自分](mention://agent/$SELF) 2 回目") \
	>"$stub_dir/comments.json"
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post 新しい起点で数え直す'
grep '^issue comment add' "$stub_dir/calls.log" | grep -q -- '--parent c7 ' || fail "新しい起点のスレッドへ投稿していません: $(calls)"

# 起点のあとに、自分の区切りが 4 件あれば 5 回目として投稿でき、5 件あれば 6 回目として止まる。
# 他の作者の区切りの行と、区切りでない自分のコメントは数えない。
reset
write_handoff
{
	comment c1 agent leader 2026-11-01T00:00:00Z '' "[@自分](mention://agent/$SELF) 頼みます"
	for n in 2 3 4 5; do
		comment "c$n" agent "$SELF" "2026-11-01T0$n:00:00Z" c1 $'区切り: x\n済んだこと: y'
	done
	comment o1 agent other-agent 2026-11-01T06:00:00Z c1 $'区切り: x\n済んだこと: y'
	comment o2 agent "$SELF" 2026-11-01T07:00:00Z c1 '通常の報告です'
} | jq -s '.' >"$stub_dir/comments.json"
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post 5 回目'
[[ $(grep -c '^issue wakeup create' "$stub_dir/calls.log") == 2 ]] || fail "5 回目で起こしが作られていません"

reset
write_handoff
{
	comment c1 agent leader 2026-11-01T00:00:00Z '' "[@自分](mention://agent/$SELF) 頼みます"
	for n in 2 3 4 5 6; do
		comment "c$n" agent "$SELF" "2026-11-01T0$n:00:00Z" c1 $'区切り: x\n済んだこと: y'
	done
} | jq -s '.' >"$stub_dir/comments.json"
run post $TASK "$handoff" $SELF $LEADER
expect_status 4 'post 6 回目'
[[ $err == *'続けて区切れる回数'* ]] || fail "超過の理由が出ていません: $err"
! grep -q '^issue comment add\|^issue wakeup' "$stub_dir/calls.log" || fail "超過なのに投稿か起こしを作っています: $(calls)"

# 値のファイルの MAX_CONSECUTIVE を変えると、超過の判定が変わる。
sed -i.bak -e 's/^MAX_CONSECUTIVE=.*/MAX_CONSECUTIVE=6/' "$monitor/squad-run-cut-values"
run post $TASK "$handoff" $SELF $LEADER
expect_status 0 'post MAX_CONSECUTIVE を 6 にした'
sed -i.bak -e 's/^MAX_CONSECUTIVE=.*/MAX_CONSECUTIVE=1/' "$monitor/squad-run-cut-values"
run post $TASK "$handoff" $SELF $LEADER
expect_status 4 'post MAX_CONSECUTIVE を 1 にした'

# 起点がなく、区切りが 1 件ある（2 回目）。MAX_CONSECUTIVE が 1 なら止まる。
reset
write_handoff
sed -i.bak -e 's/^MAX_CONSECUTIVE=.*/MAX_CONSECUTIVE=1/' "$monitor/squad-run-cut-values"
comments <(comment c1 agent "$SELF" 2026-11-01T00:00:00Z '' $'区切り: x\n済んだこと: y') >"$stub_dir/comments.json"
run post $TASK "$handoff" $SELF $LEADER
expect_status 4 'post 起点なしの 2 回目'

# 見張りを作れなければ、3 で止まり、続きを作らない。投稿済みのコメントは消さない。
reset
write_handoff
touch "$stub_dir/wakeup-fail-1"
run post $TASK "$handoff" $SELF $LEADER
expect_status 3 'post 見張りを作れない'
[[ $(grep -c '^issue wakeup create' "$stub_dir/calls.log") == 1 ]] || fail "見張りが作れないのに続きを作っています: $(calls)"
! grep -q '^issue wakeup delete' "$stub_dir/calls.log" || fail "作れていない見張りを消そうとしています"
[[ $err == *posted-1* ]] || fail "投稿済みのコメントの ID が出ていません: $err"

# 続きを作れなければ、3 で止まり、作った見張りを消す。
reset
write_handoff
touch "$stub_dir/wakeup-fail-2"
run post $TASK "$handoff" $SELF $LEADER
expect_status 3 'post 続きを作れない'
grep -q '^issue wakeup delete TASK-1 wake-1 ' "$stub_dir/calls.log" || fail "見張りを消していません: $(calls)"
# 見張りを消せなくても、3 のまま止まる。
touch "$stub_dir/wakeup-delete-fail"
rm -f "$stub_dir/count-wakeup" "$stub_dir/count-comment"
run post $TASK "$handoff" $SELF $LEADER
expect_status 3 'post 見張りを消せない'

# コメントを読めない・投稿できないときは、1 で止まり、起こしを作らない。
reset
write_handoff
touch "$stub_dir/comment-list-fail"
run post $TASK "$handoff" $SELF $LEADER
expect_status 1 'post コメントを読めない'
! grep -q '^issue comment add\|^issue wakeup' "$stub_dir/calls.log" || fail "読めないのに書いています: $(calls)"
reset
write_handoff
touch "$stub_dir/comment-add-fail"
run post $TASK "$handoff" $SELF $LEADER
expect_status 1 'post 投稿できない'
! grep -q '^issue wakeup' "$stub_dir/calls.log" || fail "投稿できないのに起こしを作っています: $(calls)"

echo 'squad-run-cut-test: ok'
