#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-answer-tidy-test.sh で実行する。
# answer が終える前にマークと記録を整えること（期限を過ぎた記録のマークを含む）を確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- answer が終える前に、マークと記録を整える。書いたコメントが次に読むときに現れるよう、apply-writes を置く。
# 重なった 2 件の記録（task-old の old1 と task-new の new1。new1 が新しい）。task-new にマークはなく、task-none は記録のないマーク。
tidy_setup() {
	answer_setup near 7200
	touch "$test_dir/apply-writes"
	set_marked task-old:DEMO-1 task-none:DEMO-3
	set_all task-old:DEMO-1:$now task-new:DEMO-2:$now task-none:DEMO-3:$now
	add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 2000)) "$(answer_line 待つ $((answer_t - 2000)) $((now + 5000)))"
	add_task_comment comments-task-new.json agent orchestrator new1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 4000)))"
	add_task_comment comments-task-none.json member member-test c1 $((answer_t - 1000)) 'コメント'
}
# 取り消されておらず期限が今より後の記録が 2 件あれば、新しい方のタスクにマークがなくても、古い方を取り消す。同じ答えで書かずに終える回でも整える。
tidy_setup
run_answer planner 待つ ans1
expect_none_line
[[ $(posted_count) == 1 ]]
assert_jq -s '.[0] == {issue: "task-old", parent: "old1", content: "使用率の答えの取り消し: old1。新しい答えのタスク: DEMO-2\n"}' "$test_dir/posted-comments.jsonl"
# 使う記録のタスクにマークがなければ置き直す。効いている記録のなくなった古いタスクのマークは外す。記録のないタスクのマークは残す。
[[ $(metadata_count) == 2 ]]
assert_jq -s '[.[] | .[2:4]] == [["set", "task-new"], ["delete", "task-old"]]' "$test_dir/metadata-calls.jsonl"
assert_jq -s '.[0] == ["issue", "metadata", "set", "task-new", "--key", "usage_answer_squad", "--value", "squad-test", "--type", "string", "--output", "json"]' "$test_dir/metadata-calls.jsonl"
# マークを外したあとに、そのタスクの有効な記録が見つかれば、マークを置き直す。
answer_setup near 7200
touch "$test_dir/apply-writes"
set_marked task-x:DEMO-5
add_task_comment comments-task-x.json agent orchestrator exp1 $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now - 10)))"
cp "$test_dir/comments-task-x.json" "$test_dir/reveal-on-delete-task-x"
add_task_comment reveal-on-delete-task-x agent orchestrator live-x $((answer_t - 500)) "$(answer_line 待つ $((answer_t - 500)) $((now + 3000)))"
run_answer planner 待つ ans1
expect_status 0
assert_jq -s '[.[] | .[2:4]] == [["set", "test-issue"], ["delete", "task-x"], ["set", "task-x"]]' "$test_dir/metadata-calls.jsonl"
# 外したあとにそのタスクを読み直せなければ、記録があるものとしてマークを置き直し、警告して終了 0。置き直せなければ終了 1。
answer_setup near 7200
touch "$test_dir/apply-writes"
set_marked task-x:DEMO-5
add_task_comment comments-task-x.json agent orchestrator exp1 $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now - 10)))"
touch "$test_dir/fail-comments-on-delete-task-x"
run_answer planner 待つ ans1
expect_status 0
assert_jq -s '[.[] | .[2:4]] == [["set", "test-issue"], ["delete", "task-x"], ["set", "task-x"]]' "$test_dir/metadata-calls.jsonl"
grep -qF 'マークを外したあとにタスクを読み直せなかったため、記録があるものとしてマークを置き直した: task-x' "$test_dir/err"
answer_setup near 7200
touch "$test_dir/apply-writes"
set_marked task-x:DEMO-5
add_task_comment comments-task-x.json agent orchestrator exp1 $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now - 10)))"
touch "$test_dir/fail-comments-on-delete-task-x" "$test_dir/fail-set-on-delete"
run_answer planner 待つ ans1
expect_status 1
grep -qF 'マークを外したあとにタスクを読み直せず、マークも置き直せなかった: task-x' "$test_dir/err"
# 重なった記録の取り消しを書けなければ、何も書かずに終了 1。
tidy_setup
touch "$test_dir/comment-add-fail-task-old"
run_answer planner 待つ ans1
expect_status 1
grep -qF '重なった記録の取り消しを書けなかった' "$test_dir/err"
grep -qF 'もう一度返事すれば' "$test_dir/err"
[[ $(<"$test_dir/out") == '' ]]
expect_no_write
# 使う記録のタスクにマークを置き直せなければ、終了 1。置いたのに一覧に出なければ、終了 1。
tidy_setup
touch "$test_dir/metadata-set-fail"
run_answer planner 待つ ans1
expect_status 1
grep -qF '置き直せなかった: task-new' "$test_dir/err"
tidy_setup
touch "$test_dir/metadata-set-noop"
run_answer planner 待つ ans1
expect_status 1
grep -qF 'マークのあるタスクの一覧に出ない: task-new' "$test_dir/err"
# 古いマークを外せなくても、記録は整っているので、警告にとどめて終了 0。
tidy_setup
touch "$test_dir/metadata-delete-fail"
run_answer planner 待つ ans1
expect_none_line
grep -qF '古いマークを外せなかった: task-old' "$test_dir/err"
echo 'PASS usage-wait answer: 終える前に、重なった記録を古い方から取り消し、使う記録のタスクのマークを置き直し、効いている記録のないタスクのマークを外す。外したあとに有効な記録が見つかれば置き直し、書けなければ終了 1（マークを外せないときは警告）'

# ---- 期限を過ぎた記録のマーク。答えを書かずに終える回でも、使う記録のタスクのマークは外さない。
# 待ち始めが 48 時間前のタスクの待ちの行（タスク A。モックのタスクは 1 件なので、answer を流すタスク C と同じタスクに置く）。
expired_setup() { # マークのタスク B の記録の期限は 60 秒前。使用率は、答えを流すときは低く、pick を流すときに上げる
	answer_setup free
	touch "$test_dir/apply-writes"
	set_marked task-b:DEMO-2
	set_all task-b:DEMO-2:$now
	add_task_comment comments-task-b.json agent orchestrator rb $((now - 3600)) "$(answer_line 待つ $((now - 3600)) $((now - 60)))"
	add_comment agent orchestrator wa $((now - 172000)) "$(wait_line planner $((now - 172000 + 7200)) $((now - 172800)))"
}
expired_pick() { # 使用率 90%、リセットまで 2 時間。期限のあとなので数え直し、待ち始めは今になる
	usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
	run planner
	expect_status 3
	expect_out "使用率の待ち: planner を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。$claude90"
}
# (a) 期限を過ぎた記録のマークのタスクがあり、別のタスクで答えると、記録は書かず、そのマークを残す。
expired_setup
run_answer planner 待つ ans1
expect_none_line
expect_no_write
echo 'PASS usage-wait answer: 期限を過ぎた記録のマーク: 空きがあるときに答えても、記録は書かず、期限を過ぎた記録のタスクのマークを残す'
# (b) そのあとの pick は、期限で数え直して終了 3。待ち始めは今になる。
expired_pick
echo 'PASS usage-wait answer: 期限を過ぎた記録のマーク: マークを残したので、そのあとの pick は期限で数え直し、終了 3 で待ち始めは今になる'
# (c) 新しい記録が別のタスクにあれば、期限を過ぎた記録のタスクのマークを外し、新しい記録のタスクにマークを置く。
expired_setup
set_all task-b:DEMO-2:$now task-new:DEMO-4:$now
add_task_comment comments-task-new.json agent orchestrator rn $((now - 1000)) "$(answer_line 待つ $((now - 1000)) $((now + 4000)))"
run_answer planner 待つ ans1
expect_none_line
assert_jq -s '[.[] | .[2:4]] == [["set", "task-new"], ["delete", "task-b"]]' "$test_dir/metadata-calls.jsonl"
echo 'PASS usage-wait answer: 期限を過ぎた記録のマーク: 新しい記録が別のタスクにあれば、期限を過ぎた記録のタスクのマークを外す'
# (d) 最後の動きが 8 日より前でも、マークがあれば、その記録を使う記録として読み、マークを残す。pick も期限で数え直す。
expired_setup
set_all task-b:DEMO-2:$((now - 10 * 86400))
run_answer planner 待つ ans1
expect_none_line
expect_no_write
expired_pick
echo 'PASS usage-wait answer: 期限を過ぎた記録のマーク: 最後の動きが 8 日より前でも、マークのあるタスクの記録を使う記録として読み、マークを残し、pick は期限で数え直す'
