#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-records-test.sh で実行する。
# pick が答えの記録を読み、待つか人間を呼ぶかを決めることを確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- pick が答えの記録を読む。待つか人間を呼ぶかのときだけ読み、使う 1 件で「待つ」の判断と期限のあとの数え直しをする。
# 記録は、スクワッドのリーダー（orchestrator）が書いた行で、別のタスク（task-old、識別子 DEMO-1）に置く。

# 「待つ」が効いていれば、リセットが 24 時間より先でも 24 時間の判定をせず、終了 3。起こしは、再開の時刻と期限の早い方に置く。
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
[[ $(wakeup_count) == 1 ]]
expect_wake_at $((now + 5000))
# 期限より再開の時刻が早ければ、再開の時刻に置く。
wait_setup 3000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 3000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
expect_wake_at $((now + 3000))
# 待ち始めは引き継ぎ、24 時間を超えていても判定しない（記録がなければ終了 4 になる待ち）。
start=$((now - 72000))
wait_setup 18000
add_comment agent orchestrator c1 $((now - 70000)) "$(wait_line planner $((now - 70000)) "$start")"
run planner
expect_status 4
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$start" $((now + 5000)) DEMO-1 "$claude90")"
expect_wake_at $((now + 5000))
echo 'PASS usage-wait pick: 「待つ」の記録が効いていれば、24 時間の判定をせず、再開の時刻と期限の早い方に起こしを置き、行に答えのタスクを書く'

# 同じタスクの記録、別の工程（Codex の designer）でも同じ。
wait_setup 100000
set_marked test-issue:DEMO-4
add_comment agent orchestrator rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-4 "$claude90")"
reset
set_roster designer
usage 10 $((now + 100000)) 10 $((now + 100000)) 90 $((now + 100000)) true
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
run designer
expect_status 3
expect_out "$(wait_answer_line designer $((now + 5000)) "$now" $((now + 5000)) DEMO-1 '上限に近い枠: Codex 週 90%')"
expect_wake_at $((now + 5000))
echo 'PASS usage-wait pick: 「待つ」は同じタスクの記録でも別のタスクの記録でも、別の工程でも効く'

# 空いているとき（使用率が 80% 未満）は、記録を読まずに今のとおり役を選ぶ。一覧を読めなくても失敗しない。
reset
set_roster planner
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
touch "$test_dir/issue-list-fail"
run planner
expect_status 0
grep -qxF '役: planner' "$test_dir/out"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 使用率が 80% 未満なら、記録を読まず（一覧を読めなくても）、今のとおり役を選ぶ'

# 期限を過ぎた記録（答えは何でも）は効かない。期限より前の待ちの行と人間を呼ぶ行は、待ち始めの引き継ぎに使わず、数え直す。
start=$((now - 72000))
for verdict in 待つ 進める; do
	wait_setup 18000
	add_comment agent orchestrator c1 $((now - 70000)) "$(wait_line planner $((now - 70000)) "$start")"
	add_comment agent orchestrator c2 $((now - 3000)) "$(exceeded_line "$start" $((now + 18000)))"
	run planner
	expect_status 4
	put_record rec1 $((now - 2000)) "$(answer_line "$verdict" $((now - 5000)) $((now - 100)))"
	run planner
	expect_status 3
	expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。$claude90"
	[[ $(wakeup_count) == 1 ]]
	# 期限のあとの待ちの行は、そのまま引き継ぐ。
	add_comment agent orchestrator c3 $((now - 50)) "$(wait_line planner $((now + 18000)) $((now - 50)))"
	run planner
	expect_status 3
	expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso $((now - 50)))。$claude90"
	# 数え直したあとも、リセットが 24 時間より先なら終了 4 で人間を呼ぶ。
	wait_setup 100000
	put_record rec1 $((now - 2000)) "$(answer_line "$verdict" $((now - 5000)) $((now - 100)))"
	run planner
	expect_status 4
	expect_out "$(exceeded_line "$now" $((now + 100000)))"
	[[ $(wakeup_count) == 0 ]]
done
echo 'PASS usage-wait pick: 期限を過ぎた記録では今の判定に戻り、期限より前の待ちの行と人間を呼ぶ行は数えず、期限のあとの待ちの行は引き継ぐ'

# 記録と読まないもの: リーダーでない作者、人間、別のスクワッド、2 行目、形に合わない行。判定は記録がないときのまま。
for kind in not-leader human other-squad second-line bad-format empty-rest bad-time; do
	wait_setup 100000
	set_marked task-old:DEMO-1
	line=$(answer_line 待つ $((now - 600)) $((now + 5000)))
	case $kind in
	not-leader) add_task_comment comments-task-old.json agent other-codex-fixer f1 $((now - 500)) "$line" ;;
	human) add_task_comment comments-task-old.json member member-test f1 $((now - 500)) "$line" ;;
	other-squad) add_task_comment comments-task-old.json agent orchestrator f1 $((now - 500)) "${line/スクワッド: squad-test/スクワッド: squad-other}" ;;
	second-line) add_task_comment comments-task-old.json agent orchestrator f1 $((now - 500)) "$(printf '引用です。\n%s' "$line")" ;;
	bad-format) add_task_comment comments-task-old.json agent orchestrator f1 $((now - 500)) "${line/。期限:/。期限は:}" ;;
	empty-rest) add_task_comment comments-task-old.json agent orchestrator f1 $((now - 500)) "${line%"$claude90"}" ;;
	bad-time) add_task_comment comments-task-old.json agent orchestrator f1 $((now - 500)) "${line/Z。期限/+09:00。期限}" ;;
	esac
	run planner
	expect_status 4
	[[ $(wakeup_count) == 0 ]]
done
echo 'PASS usage-wait pick: リーダー以外の作者・人間・別のスクワッド・2 行目・形に合わない行は、記録と読まず、判定が変わらない'

# 使う記録は、答えた時刻が最も新しい 1 件。答えた時刻が同じなら、記録のコメントが新しい方。
two_records() { # 古い記録の「答えた時刻 コメントの時刻 期限」、新しい記録の「同」
	wait_setup 100000
	set_marked task-old:DEMO-1 task-new:DEMO-2
	add_task_comment comments-task-old.json agent orchestrator old1 "$2" "$(answer_line 待つ "$1" "$3")"
	add_task_comment comments-task-new.json agent orchestrator new1 "$5" "$(answer_line 待つ "$4" "$6")"
}
# 答えた時刻の新しい方（task-new）に従う。
two_records $((now - 1000)) $((now - 800)) $((now + 5000)) $((now - 500)) $((now - 300)) $((now + 4000))
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 4000)) "$now" $((now + 4000)) DEMO-2 "$claude90")"
expect_wake_at $((now + 4000))
# 記録のコメントの時刻でなく、答えた時刻で並べる（古い答えをあとで記録しても、新しくならない）。
two_records $((now - 500)) $((now - 400)) $((now + 4000)) $((now - 2000)) $((now - 300)) $((now + 5000))
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 4000)) "$now" $((now + 4000)) DEMO-1 "$claude90")"
# 答えた時刻が同じなら、記録のコメントが新しい方に従う。
two_records $((now - 500)) $((now - 300)) $((now + 4000)) $((now - 500)) $((now - 200)) $((now + 5000))
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-2 "$claude90")"
# 使う記録が期限を過ぎていれば、期限が残っている古い記録は使わない（1 件だけを見る）。
two_records $((now - 1000)) $((now - 800)) $((now + 5000)) $((now - 500)) $((now - 300)) $((now - 100))
run planner
expect_status 4
expect_out "$(exceeded_line "$now" $((now + 100000)))"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 答えた時刻の新しい記録 1 件に従い、同じ時刻ならコメントの新しい方に従い、その期限が過ぎていれば古い記録は使わない'

# 記録がないときは、今の判定のまま。マークがあって記録のないタスク、マークのないタスク、古い形の行だけが残るタスクでも、終了 1 にならない。
for line_kind in none old_exceeded_line exceeded_line; do
	wait_setup 18000
	set_marked task-none:DEMO-2 test-issue:DEMO-4
	add_task_comment comments-task-none.json member member-test c1 $((now - 3000)) 'コメント'
	if [[ $line_kind != none ]]; then
		add_comment agent orchestrator c2 $((now - 3000)) "$("$line_kind" "$start" $((now + 18000)))"
	fi
	run planner
	expect_status 3
	expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。$claude90"
	[[ $(wakeup_count) == 1 ]]
	wait_setup 100000
	set_marked task-none:DEMO-2 test-issue:DEMO-4
	run planner
	expect_status 4
	expect_out "$(exceeded_line "$now" $((now + 100000)))"
	[[ $(wakeup_count) == 0 ]]
done
echo 'PASS usage-wait pick: マークがあって記録のないタスクと古い形の行だけのタスクでは、終了 1 にならず、今の 24 時間の判定になる'

# 一覧かコメントを読めなければ、終了 1。標準エラーに理由を出し、起こしは置かない（待つにも人間を呼ぶにも倒さない）。
wait_setup 18000
set_marked task-old:DEMO-1
touch "$test_dir/issue-list-fail"
run planner
expect_status 1
grep -qF '使用率の答えのマークのあるタスクを読めない' "$test_dir/err"
[[ ! -s $test_dir/out && $(wakeup_count) == 0 ]]
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
touch "$test_dir/comments-fail-task-old"
run planner
expect_status 1
grep -qF '使用率の答えの記録を読めない' "$test_dir/err"
[[ ! -s $test_dir/out && $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 答えの記録を読めなければ、理由を標準エラーに出して終了 1。起こしは置かず、待つにも人間を呼ぶにも倒さない'

# 両系統の構成で、dispatch-pick が両方上限に近いと返したときも、同じ記録で待つ。
reset
echo 2 >"$test_dir/dispatch-status"
: >"$test_dir/dispatch-out"
# Claude は週 85%（リセット 5 時間後）と 5 時間 90%（1 時間後）、Codex は週 82%（3 時間後）。再開の時刻は 3 時間後で、期限はそれより早い。
usage 85 $((now + 18000)) 90 $((now + 3600)) 82 $((now + 10800)) true
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 85%・5 時間 90%、Codex 週 82%')"
run implement 小さい
expect_status 3
expect_out "$(wait_answer_line implement $((now + 5000)) "$now" $((now + 5000)) DEMO-1 '上限に近い枠: Claude 週 85%・5 時間 90%、Codex 週 82%')"
expect_wake_at $((now + 5000))
echo 'PASS usage-wait pick: 両系統の構成でも、両方上限に近ければ「待つ」の記録で待つ'
