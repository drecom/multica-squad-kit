#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-jq-fail-test.sh で実行する。
# squad-usage-wait の中の jq が 1 回失敗したとき、0 回の繰り返しや空の値として読み流さず、終了 1 で止まり、そのあとの書き込みをしないことを確認する。
# 失敗は、tests/arg-limit-lib.sh の jq の包みに、環境変数 JQ_FAIL_ON（引数を空白でつないだ文字列に当てる glob）で入れる。
# 対象は、docs/usage-answer.md の「jq への渡し方」の、繰り返しの切り出しと配列の読み取り。共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

wake_text() { # 工程 再開の時刻（秒）
	printf '%s\n工程: %s\n再開の時刻: %s\n' "$mark" "$1" "$(iso "$2")"
}
injected() { grep -qF 'jq: injected failure' "$test_dir/err" || { printf '注入した失敗が起きなかった。標準エラー:\n%s\n' "$(<"$test_dir/err")" >&2; exit 1; }; }
no_delete_call() { ! grep -q '"delete"' "$test_dir/metadata-calls.jsonl"; }
tidy_two() { # 重なった 2 件の記録（old1 と new1）。同じ答えで終える回でも整える
	answer_setup near 7200
	touch "$test_dir/apply-writes"
	set_marked task-old:DEMO-1
	set_all task-old:DEMO-1:$now task-new:DEMO-2:$now
	add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 2000)) "$(answer_line 待つ $((answer_t - 2000)) $((now + 5000)))"
	add_task_comment comments-task-new.json agent orchestrator new1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 4000)))"
}
two_targets() { # 工程
	add_rule t1 true "$(wake_text "$1" $((now + 4000)))"
	add_rule t2 true "$(wake_text "$1" $((now + 8000)))"
}
one_system() {
	reset
	set_roster claude-implementer
	two_targets implement
}

# 行 1（answer_tidy のマークのタスクの ID）: マークのあるタスクを記録のないものと読み違え、マークを外さずに答えを書いて終了 0 にしない。
answer_setup near 7200
touch "$test_dir/apply-writes"
set_marked task-x:DEMO-5
set_all task-x:DEMO-5:$((now - 9 * 86400))
add_task_comment comments-task-x.json agent orchestrator exp1 $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now - 10)))"
JQ_FAIL_ON='*select(.id as $i | $r | any(.[]; .task == $i) | not) | .id' run_answer planner 待つ ans1
expect_status 1
injected
no_delete_call
echo 'PASS usage-wait jq 失敗 1: answer_tidy でマークのタスクの ID を読めなければ、終了 1 で、マークを外さない'

# 行 3（answer_cancel_records の取り消す記録の切り出し）: 切り出せなければ、取り消しを 0 件として答えを書かない。
answer_setup near 7200
touch "$test_dir/apply-writes"
add_task_comment comments-task-act.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
set_all task-act:DEMO-2:$now
JQ_FAIL_ON='* .\[\] | select((.cancelled | not) and .expiry > $now)' run_answer planner 進める ans1
expect_status 1
injected
expect_no_write
echo 'PASS usage-wait jq 失敗 3: answer_cancel_records で取り消す記録を切り出せなければ、終了 1 で、何も書かない'

# 行 4（answer_records のタスクの行の切り出し）: 切り出せなければ、タスクを 0 件として答えを書かない。
JQ_FAIL_ON='*@tsv*' run_answer planner 進める ans1
expect_status 1
injected
expect_no_write
echo 'PASS usage-wait jq 失敗 4: answer_records でタスクの行を切り出せなければ、終了 1 で、何も書かない'

# 行 5（答えを書いたあとの、マークのあるタスクの ID の切り出し）: 切り出せなければ、マークを整えずに終了 1。
answer_setup near 7200
touch "$test_dir/apply-writes"
set_marked task-new:DEMO-2 task-b:DEMO-3
set_all task-new:DEMO-2:$now task-b:DEMO-3:$now
add_task_comment comments-task-new.json agent orchestrator new1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 4000)))"
add_task_comment comments-task-b.json agent orchestrator rb $((answer_t - 3000)) "$(answer_line 待つ $((answer_t - 3000)) $((now - 10)))"
JQ_FAIL_ON='-r .\[\].id' run_answer planner 待つ ans1
expect_status 1
injected
no_delete_call
echo 'PASS usage-wait jq 失敗 5: answer_tidy でマークのあるタスクの ID を切り出せなければ、終了 1 で、マークを外さない'

# 行 8（answer_tidy の残す記録のタスクの識別子）: 読めなければ、取り消しを書かずに終了 1。
tidy_two
JQ_FAIL_ON='-r .identifier' run_answer planner 待つ ans1
expect_status 1
injected
[[ $(posted_count) == 0 ]]
echo 'PASS usage-wait jq 失敗 8: answer_tidy で残す記録の識別子を読めなければ、終了 1 で、取り消しを書かない'

# 行 2（delete_wakeups の ID の切り出し）と行 6（clear_wakeups の ID の配列）: 起こしを消さず、役も出さずに終了 1。
one_system
JQ_FAIL_ON='-r .\[\]' run implement 小さい
expect_status 1
injected
[[ ! -s $test_dir/wakeup-deletes && $(<"$test_dir/out") == '' ]]
one_system
JQ_FAIL_ON='-c \[.\[\].id\]' run implement 小さい
expect_status 1
injected
[[ ! -s $test_dir/wakeup-deletes && $(<"$test_dir/out") == '' ]]
echo 'PASS usage-wait jq 失敗 2・6: 消す起こしの ID を切り出せなければ、起こしを消さず、役も出さずに終了 1'

# 行 6（wait_or_exceed の消す ID の配列）: 作れなければ、起こしを消さずに終了 1。
wait_setup 10000
add_rule a true "$(wake_text planner $((now + 9000)))"
add_rule b true "$(wake_text planner $((now + 5000)))"
JQ_FAIL_ON='*select(.id != $keep) | .id]' run planner
expect_status 1
injected
[[ ! -s $test_dir/wakeup-deletes ]]
echo 'PASS usage-wait jq 失敗 6: wait_or_exceed で消す ID の配列を作れなければ、終了 1 で、起こしを消さない'

# 行 7（pick の回から決めたスクワッドの ID）: 読めなければ、役を出さずに終了 1。
reset
set_roster claude-implementer
add_comment agent orchestrator round-7 $((now - 600)) '観点: qa（テスト）'
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
JQ_FAIL_ON='-r .id' run implement 小さい --round round-7
expect_status 1
injected
[[ $(<"$test_dir/out") == '' ]]
echo 'PASS usage-wait jq 失敗 7: pick で回から決めたスクワッドの ID を読めなければ、終了 1 で、役を出さない'
