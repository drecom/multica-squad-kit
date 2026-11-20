#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-answer-cancel-test.sh で実行する。
# answer が答えを変えたときに古い記録を取り消すことと、マークに頼らずに記録を探すことを確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# 答えを変えると、古い記録と同じタスクの同じ返信先に取り消しを書いてから、新しい記録を書く。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
set_parent comments-task-old.json old1 old-answer
run_answer planner 進める ans1
expect_status 0
new_line=$(answer_line 進める "$answer_t" $((now + 7200)))
expect_out "$new_line"
[[ $(posted_count) == 2 ]]
assert_jq -s --arg cancel "$(cancel_body old1)" --arg line "$new_line" \
	'.[0] == {issue: "task-old", parent: "old-answer", content: ($cancel + "\n")} and .[1] == {issue: "test-issue", parent: "ans1", content: ($line + "\n")}' "$test_dir/posted-comments.jsonl"
# 取り消しの行は、1 行目だけで、人間を呼ぶ行にも記録の行にも読まれない形をしている。
[[ $(jq -s -j '.[0].content' "$test_dir/posted-comments.jsonl" | wc -l | tr -d ' ') == 1 ]]
if jq -s -r '.[0].content' "$test_dir/posted-comments.jsonl" | grep -qE '^使用率の答え: |mention://'; then fail '取り消しの行が記録の行かメンションの形をしている'; fi
# 返信先が空の記録は、その記録のコメントへの返信で取り消す。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
run_answer planner 進める ans1
expect_status 0
assert_jq -s '.[0].issue == "task-old" and .[0].parent == "old1"' "$test_dir/posted-comments.jsonl"
# 効いている記録が複数あれば、取り消されておらず期限が今より後のものをすべて取り消す。期限を過ぎた記録と、取り消し済みの記録は取り消さない。
answer_setup near 7200
set_marked task-old:DEMO-1 task-new:DEMO-2
add_task_comment comments-task-old.json agent orchestrator exp1 $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now - 10)))"
add_task_comment comments-task-old.json agent orchestrator live1 $((answer_t - 2000)) "$(answer_line 待つ $((answer_t - 2000)) $((now + 5000)))"
add_task_comment comments-task-new.json agent orchestrator done1 $((answer_t - 1500)) "$(answer_line 待つ $((answer_t - 1500)) $((now + 5000)))"
add_task_comment comments-task-new.json agent orchestrator c-done1 $((answer_t - 1400)) "$(cancel_body done1)"
add_task_comment comments-task-new.json agent orchestrator live2 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 4000)))"
run_answer planner 進める ans1
expect_status 0
[[ $(posted_count) == 3 ]]
assert_jq -s --arg c1 "$(cancel_body live1)" --arg c2 "$(cancel_body live2)" \
	'(map(select(.issue != "test-issue")) | map({issue, content}) | sort_by(.issue)) == [{issue: "task-new", content: ($c2 + "\n")}, {issue: "task-old", content: ($c1 + "\n")}] and (.[-1].issue == "test-issue" and .[-1].parent == "ans1")' "$test_dir/posted-comments.jsonl"
# リーダー以外が書いた取り消しの行では、記録は取り消されない（なお取り消す相手になる）。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator live1 $((answer_t - 2000)) "$(answer_line 待つ $((answer_t - 2000)) $((now + 5000)))"
add_task_comment comments-task-old.json agent other-codex-fixer forged-cancel $((answer_t - 1500)) "$(cancel_body live1)"
add_task_comment comments-task-old.json member member-test human-cancel $((answer_t - 1400)) "$(cancel_body live1)"
run_answer planner 進める ans1
expect_status 0
[[ $(posted_count) == 2 ]]
assert_jq -s --arg c1 "$(cancel_body live1)" '.[0] == {issue: "task-old", parent: "live1", content: ($c1 + "\n")}' "$test_dir/posted-comments.jsonl"
echo 'PASS usage-wait answer: 答えを変えると、効いている記録のすべてを古い記録と同じタスクの同じ返信先で取り消してから、新しい記録を書く。期限切れと取り消し済みの記録は取り消さない'

# 取り消しを書けなければ、新しい記録もマークも書かずに終了 1。同じ引数で流し直すと、残りの取り消しと新しい記録を書く。
answer_setup near 7200
set_marked task-old:DEMO-1 task-new:DEMO-2
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 2000)) "$(answer_line 待つ $((answer_t - 2000)) $((now + 5000)))"
add_task_comment comments-task-new.json agent orchestrator old2 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 4000)))"
touch "$test_dir/comment-add-fail-task-old"
run_answer planner 進める ans1
expect_status 1
grep -qF '古い記録の取り消しを書けない' "$test_dir/err"
grep -qF 'もう一度返事すれば' "$test_dir/err"
[[ $(<"$test_dir/out") == '' ]]
[[ $(posted_count) == 1 && $(metadata_count) == 0 ]]
assert_jq -s --arg c2 "$(cancel_body old2)" '.[0] == {issue: "task-new", parent: "old2", content: ($c2 + "\n")}' "$test_dir/posted-comments.jsonl"
# 書けた取り消しが一覧に現れたあと、同じ引数で流し直す。残りの取り消しと新しい記録が書かれる。
rm -f "$test_dir/comment-add-fail-task-old"
add_task_comment comments-task-new.json agent orchestrator c-old2 $((now - 100)) "$(cancel_body old2)"
run_answer planner 進める ans1
expect_status 0
expect_out "$(answer_line 進める "$answer_t" $((now + 7200)))"
[[ $(posted_count) == 2 ]]
assert_jq -s --arg c1 "$(cancel_body old1)" '.[0] == {issue: "task-old", parent: "old1", content: ($c1 + "\n")} and .[1].issue == "test-issue" and .[1].parent == "ans1"' "$test_dir/posted-comments.jsonl"
# 最初の取り消しを書けないときも、新しい記録を書かない。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
touch "$test_dir/comment-add-fail-task-old"
run_answer planner 進める ans1
expect_status 1
expect_no_write
echo 'PASS usage-wait answer: 取り消しを書けなければ、新しい記録もマークも書かずに終了 1。流し直すと、残りの取り消しと新しい記録を書く'

# answer はマークに頼らずに記録を探す。マークのないタスクの記録も取り消す。絞り込みのない一覧を has_more が偽になるまで読み、8 日前より後のタスクと、時刻を読めないタスクだけを読む。
answer_setup near 7200
set_all task-old:DEMO-1:$now
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
[[ $(jq -s length "$test_dir/metadata-calls.jsonl") == 0 ]]
run_answer planner 進める ans1
expect_status 0
assert_jq -s --arg c1 "$(cancel_body old1)" '.[0] == {issue: "task-old", parent: "old1", content: ($c1 + "\n")} and (length == 2)' "$test_dir/posted-comments.jsonl"
# 記録を探す一覧は、絞り込みなし（マーク・担当・プロジェクトを渡さない）で、最初に読む。マークのある一覧は、終える前の整えだけが読む。
assert_jq -s 'map(select(.[0] == "issue" and .[1] == "list")) | length > 0 and (.[0] | index("--metadata") | not) and all(.[]; (index("--assignee") | not) and (index("--project") | not))' "$test_dir/calls.jsonl"
# マークがあっても、一覧にないタスクの記録は読まない（読む範囲を決めるのは一覧）。
answer_setup near 7200
set_marked task-old:DEMO-1
set_all
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
run_answer planner 進める ans1
expect_status 0
[[ $(posted_count) == 1 ]]
assert_jq -s '.[0].issue == "test-issue"' "$test_dir/posted-comments.jsonl"
# 8 日前より前に動いたタスクは読まない。ちょうど 8 日前も読まない。時刻が空のタスクと、読めない時刻のタスクは読む。
answer_setup near 7200
set_all task-old:DEMO-1:$((now - 700000)) task-edge:DEMO-2:$((now - 691200)) task-none:DEMO-3:none task-bad:DEMO-6:bad task-in:DEMO-5:$((now - 691199))
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
add_task_comment comments-task-edge.json agent orchestrator edge1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
add_task_comment comments-task-none.json agent orchestrator none1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
add_task_comment comments-task-bad.json agent orchestrator bad1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
add_task_comment comments-task-in.json agent orchestrator in1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
run_answer planner 進める ans1
expect_status 0
assert_jq -s '(map(select(.issue != "test-issue") | .issue) | sort) == ["task-bad", "task-in", "task-none"]' "$test_dir/posted-comments.jsonl"
# 一覧が複数のページにまたがれば、1 件重ねて進めて、続きがなくなるまで読む。
answer_setup near 7200
list_total=3
set_all_page 0 true task-old:DEMO-1:$now task-new:DEMO-2:$now
set_all_page 1 false task-new:DEMO-2:$now task-third:DEMO-3:$now
unset list_total
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now + 5000)))"
add_task_comment comments-task-new.json agent orchestrator old2 $((answer_t - 2000)) "$(answer_line 待つ $((answer_t - 2000)) $((now + 4000)))"
add_task_comment comments-task-third.json agent orchestrator old3 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 3000)))"
run_answer planner 進める ans1
expect_status 0
assert_jq -s '[.[] | select(.issue != "test-issue") | .issue] | sort == ["task-new", "task-old", "task-third"]' "$test_dir/posted-comments.jsonl"
# 最初の読みと、書いたあとの読み直しで、2 回ずつ読む。
assert_jq -s '[.[] | select(.[0] == "issue" and .[1] == "list" and index("--limit") and (index("--metadata") | not)) | .[index("--offset") + 1]] == ["0", "1", "0", "1"]' "$test_dir/calls.jsonl"
# 続きがあるのに空のページは、無限に読まず、何も書かずに終了 1。
answer_setup near 7200
set_all_page 0 true
run_answer planner 進める ans1
expect_status 1
expect_no_write
# 一覧を読めない、取り消す相手の候補のコメントを読めないときも、何も書かずに終了 1。
answer_setup near 7200
set_all task-old:DEMO-1:$now
touch "$test_dir/issue-list-fail"
run_answer planner 進める ans1
expect_status 1
expect_no_write
answer_setup near 7200
set_all task-old:DEMO-1:$now
touch "$test_dir/comments-fail-task-old"
run_answer planner 進める ans1
expect_status 1
expect_no_write
echo 'PASS usage-wait answer: マークに頼らず、絞り込みのない一覧を続きがなくなるまで読み、8 日前より後と時刻を読めないタスクのコメントから、記録と取り消しを探す。読めなければ書かずに終了 1'
