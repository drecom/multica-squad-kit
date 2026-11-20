#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-proceed-test.sh で実行する。
# pick が「進める」の記録を読み、上限に近いままでも系統を回すことを確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- pick の「進める」。効いている「進める」の記録があれば、上限に近いままでも、上限に達していない系統へ回す。

# 両方上限に近くても、「進める」が効いていれば、dispatch-pick に --allow-near を足して呼び直し、選んだ役に答えの 1 文を足す。待たない。
proceed_dual 0 "$near_out"
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) "$both_near")"
run implement 小さい
expect_status 0
expect_out "役: codex-implementer
振り分け: Codex（Claude は週の使用率が 80% 以上、Claude は 5 時間の枠が 80% 以上、Codex は週の使用率が 80% 以上。両方の系統が上限に近いので、人間の答えで選んだ）。Claude 週 85%・5 時間 90%、Codex 週 82%。$(proceed_note_line $((now + 5000)) DEMO-1)。工程: implement"
[[ $(dispatch_calls) == 'implement 小さい|implement 小さい --allow-near' && $(wakeup_count) == 0 ]]
# 修正も同じ。人間は呼ばず、起こしも置かない。
proceed_dual 0 $'役: claude-fixer\n振り分け: Claude（両方の系統が上限に近いので、人間の答えで選んだ）。Claude 週 85%・5 時間 90%、Codex 週 82%\n'
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) "$both_near")"
run fix
expect_status 0
grep -qxF "役: claude-fixer" "$test_dir/out"
grep -qF "。$(proceed_note_line $((now + 5000)) DEMO-1)。工程: fix" "$test_dir/out"
[[ $(dispatch_calls) == 'fix|fix --allow-near' && $(wakeup_count) == 0 ]]
# 同じタスクの記録でも効く。
proceed_dual 0 "$near_out"
set_marked test-issue:DEMO-4
add_comment agent orchestrator rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) "$both_near")"
run implement 小さい
expect_status 0
grep -qF "。$(proceed_note_line $((now + 5000)) DEMO-4)。工程: implement" "$test_dir/out"
echo 'PASS usage-wait pick: 両系統が上限に近くても「進める」が効いていれば、--allow-near で呼び直した役を選び、答えの 1 文を足す。待たず、起こしを置かない'

# どの系統も上限に達していれば（dispatch-pick が --allow-near でも終了 2）、「待つ」と同じに待つ。24 時間の判定はせず、起こしは再開の時刻と期限の早い方。
proceed_dual 2 ''
usage 100 $((now + 18000)) 90 $((now + 3600)) 100 $((now + 10800)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 100%・5 時間 90%、Codex 週 100%')"
run implement 小さい
expect_status 3
expect_out "$(proceed_wait_line implement $((now + 5000)) "$now" $((now + 5000)) DEMO-1 '上限に近い枠: Claude 週 100%・5 時間 90%、Codex 週 100%')"
[[ $(dispatch_calls) == 'implement 小さい|implement 小さい --allow-near' && $(wakeup_count) == 1 ]]
expect_wake_at $((now + 5000))
# 再開の時刻が期限より早ければ、再開の時刻に置く。リセットが 24 時間より先でも終了 4 にならない。
proceed_dual 2 ''
usage 100 $((now + 3000)) 90 $((now + 1000)) 100 $((now + 2000)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 100%・5 時間 90%、Codex 週 100%')"
run implement 小さい
expect_status 3
expect_wake_at $((now + 2000))
proceed_dual 2 ''
usage 100 $((now + 100000)) 90 $((now + 3600)) 100 $((now + 100000)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 100%・5 時間 90%、Codex 週 100%')"
run implement 小さい
expect_status 3
expect_wake_at $((now + 5000))
echo 'PASS usage-wait pick: 「進める」が効いていても、どの系統も上限に達していれば「待つ」と同じに待ち、末尾に頼める系統がない文を出し、人間を呼ばない'

# 「進める」でも、期限を過ぎていれば効かない。--allow-near で呼び直さず、期限より前の待ちを数えない今の判定に戻る。
proceed_dual 0 "$near_out"
usage 85 $((now + 100000)) 90 $((now + 3600)) 82 $((now + 100000)) true
put_record rec1 $((now - 2000)) "$(answer_line 進める $((now - 5000)) $((now - 100)) "$both_near")"
run implement 小さい
expect_status 4
[[ $(dispatch_calls) == 'implement 小さい' && $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 期限を過ぎた「進める」の記録は効かず、--allow-near で呼び直さない'

# 「待つ」と「進める」の切り替えは、答えた時刻が新しい記録が勝つ。
switch_records() { # 古い記録の判断 新しい記録の判断
	proceed_dual 0 "$near_out"
	set_marked task-old:DEMO-1 task-new:DEMO-2
	add_task_comment comments-task-old.json agent orchestrator old1 $((now - 800)) "$(answer_line "$1" $((now - 1000)) $((now + 5000)) "$both_near")"
	add_task_comment comments-task-new.json agent orchestrator new1 $((now - 300)) "$(answer_line "$2" $((now - 500)) $((now + 4000)) "$both_near")"
}
switch_records 待つ 進める
run implement 小さい
expect_status 0
grep -qF "。$(proceed_note_line $((now + 4000)) DEMO-2)。工程: implement" "$test_dir/out"
[[ $(wakeup_count) == 0 ]]
switch_records 進める 待つ
run implement 小さい
expect_status 3
expect_out "$(wait_answer_line implement $((now + 4000)) "$now" $((now + 4000)) DEMO-2 "$both_near")"
[[ $(dispatch_calls) == 'implement 小さい' ]]
echo 'PASS usage-wait pick: 「待つ」と「進める」は、答えた時刻が新しい記録に切り替わる'

# 空いているとき（使用率が 80% 未満）は、記録を読まず（一覧を読めなくても）、--allow-near も足さずに今のとおり選ぶ。
reset
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)))"
touch "$test_dir/issue-list-fail"
run implement 小さい
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%。工程: implement'
[[ $(dispatch_calls) == 'implement 小さい' ]]
echo 'PASS usage-wait pick: 使用率が 80% 未満なら、「進める」の記録を読まず、今のとおり選ぶ'

# 片系統の構成と planner・designer: その系統が上限に近くても、達していなければ選ぶ。達していれば「待つ」と同じに待つ。
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)))"
run planner
expect_status 0
expect_out "役: planner
振り分け: Claude（片系統の構成）。Claude 週 90%・5 時間 10%。$(proceed_note_line $((now + 5000)) DEMO-1)。工程: planner"
[[ $(wakeup_count) == 0 ]]
# Claude の 5 時間の枠が 100% なら、週が 100% 未満でも達している。
reset
set_roster planner
usage 90 $((now + 100000)) 100 $((now + 3600)) 10 $((now + 100000)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 90%・5 時間 100%')"
run planner
expect_status 3
expect_out "$(proceed_wait_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-1 '上限に近い枠: Claude 週 90%・5 時間 100%')"
expect_wake_at $((now + 5000))
# 片系統の Codex の designer。週 90% は選ぶ。利用不可なら達しているので待つ。
reset
set_roster designer
usage 10 $((now + 100000)) 10 $((now + 100000)) 90 $((now + 100000)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) '上限に近い枠: Codex 週 90%')"
run designer
expect_status 0
expect_out "役: designer
振り分け: Codex（片系統の構成）。Codex 週 90%。$(proceed_note_line $((now + 5000)) DEMO-1)。工程: designer"
usage 10 $((now + 100000)) 10 $((now + 100000)) 82 $((now + 100000)) false
run designer
expect_status 3
expect_out "$(proceed_wait_line designer $((now + 5000)) "$now" $((now + 5000)) DEMO-1 '上限に近い枠: Codex 週 82%・利用不可')"
# 片系統の implement も同じ。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)))"
run implement 小さい
expect_status 0
grep -qF "。$(proceed_note_line $((now + 5000)) DEMO-1)。工程: implement" "$test_dir/out"
# 期限を過ぎていれば選ばず、待つ判定に戻る。
reset
set_roster planner
usage 90 $((now + 18000)) 10 $((now + 100000)) 10 $((now + 100000)) true
put_record rec1 $((now - 2000)) "$(answer_line 進める $((now - 5000)) $((now - 100)))"
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。$claude90"
echo 'PASS usage-wait pick: 片系統の構成と planner・designer は、「進める」が効いていて上限に達していなければ選び、達していれば「待つ」と同じに待つ'

# 答えの記録を読めなければ、「進める」の判断でも終了 1。役を選ばず、待つにも進めるにも倒さない。
proceed_dual 0 "$near_out"
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) "$both_near")"
touch "$test_dir/comments-fail-task-old"
run implement 小さい
expect_status 1
grep -qF '使用率の答えの記録を読めない' "$test_dir/err"
[[ ! -s $test_dir/out && $(wakeup_count) == 0 && $(dispatch_calls) == 'implement 小さい' ]]
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)))"
touch "$test_dir/issue-list-fail"
run planner
expect_status 1
[[ ! -s $test_dir/out && $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 答えの記録を読めなければ、「進める」の判断でも終了 1。役を選ばず、起こしも置かない'

# 互換: decide が人間を呼んだ回（前の回: の行を持つ人間を呼ぶコメント）で答えを記録したあと、--round なしの pick でも、「進める」は終了 0 で選び、「待つ」は終了 3 で待つ。待ちの起こしに回と decide の流し直しを書かない。
decide_call_comment() { # decide が人間を呼んだコメント（前の回: の行と、24 時間を超える待ちの行）を、リーダーのコメントとして置く
	add_comment agent orchestrator call1 $((now - 900)) "$(printf '人間の判断が要ります。\n前の回: round-7\n使用率の待ち: implement は %s まで待つと通算 24 時間を超える。待ち始め: %s。%s' "$(iso $((now + 100000)))" "$(iso $((now - 900)))" "$both_near")"
}
proceed_dual 0 "$near_out"
decide_call_comment
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) "$both_near")"
run implement 小さい
expect_status 0
if grep -q '^回: ' "$test_dir/out"; then fail '出力に回の行がある'; fi
[[ $(wakeup_count) == 0 ]]
proceed_dual 0 "$near_out"
decide_call_comment
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)) "$both_near")"
run implement 小さい
expect_status 3
expect_out "$(wait_answer_line implement $((now + 5000)) "$now" $((now + 5000)) DEMO-1 "$both_near")"
assert_jq '(.instruction | contains("回:") | not) and (.instruction | contains("squad-review-next decide") | not)' "$test_dir/wakeups.jsonl"
echo 'PASS usage-wait pick: --round なしの pick は、「進める」なら終了 0、「待つ」なら終了 3 で、待ちの起こしに回と decide の流し直しを書かない'
