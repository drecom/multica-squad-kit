#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-cancel-test.sh で実行する。
# 記録の取り消し、8 日の条件、起こしの置き直し、起こしを 1 件に保つことを確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- 取り消し、8 日の条件、起こしの置き直し（pick）。
cancel_line() { # 取り消す記録のコメントの ID 新しい答えのタスク
	printf '使用率の答えの取り消し: %s。新しい答えのタスク: %s' "$1" "$2"
}
# 取り消された記録は、期限の前でも、ない記録と同じに扱う。リーダーが書き、行の ID が同じタスクの記録のコメントを指すものだけ。
for verdict in 待つ 進める; do
	wait_setup 100000
	put_record rec1 $((now - 500)) "$(answer_line "$verdict" $((now - 600)) $((now + 5000)))"
	add_task_comment comments-task-old.json agent orchestrator cancel1 $((now - 400)) "$(cancel_line rec1 DEMO-9)"
	run planner
	expect_status 4
	expect_out "$(exceeded_line "$now" $((now + 100000)))"
	[[ $(wakeup_count) == 0 ]]
done
# 取り消しは返信の親でなく行の ID で決める。ほかの記録の ID を指す取り消しは、この記録を取り消さない。
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
add_task_comment comments-task-old.json agent orchestrator cancel1 $((now - 400)) "$(cancel_line other-record DEMO-9)"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
# リーダーでない作者・人間・形に合わない行・2 行目の取り消しは、取り消しと読まない。
for kind in not-leader human bad-format second-line; do
	wait_setup 100000
	put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
	cancel=$(cancel_line rec1 DEMO-9)
	case $kind in
	not-leader) add_task_comment comments-task-old.json agent other-codex-fixer cancel1 $((now - 400)) "$cancel" ;;
	human) add_task_comment comments-task-old.json member member-test cancel1 $((now - 400)) "$cancel" ;;
	bad-format) add_task_comment comments-task-old.json agent orchestrator cancel1 $((now - 400)) "${cancel/。新しい答えのタスク:/。新しい答えは:}" ;;
	second-line) add_task_comment comments-task-old.json agent orchestrator cancel1 $((now - 400)) "$(printf '引用です。\n%s' "$cancel")" ;;
	esac
	run planner
	expect_status 3
	expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
done
# 取り消した記録のほかに、取り消されていない古い記録があれば、そちらを使う。
wait_setup 100000
set_marked task-old:DEMO-1 task-new:DEMO-2
add_task_comment comments-task-old.json agent orchestrator old1 $((now - 800)) "$(answer_line 待つ $((now - 1000)) $((now + 4000)))"
add_task_comment comments-task-new.json agent orchestrator new1 $((now - 300)) "$(answer_line 待つ $((now - 500)) $((now + 5000)))"
add_task_comment comments-task-new.json agent orchestrator cancel1 $((now - 200)) "$(cancel_line new1 DEMO-9)"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 4000)) "$now" $((now + 4000)) DEMO-1 "$claude90")"
expect_wake_at $((now + 4000))
# 取り消しは、別のタスクの記録には効かない。
wait_setup 100000
set_marked task-old:DEMO-1 task-new:DEMO-2
add_task_comment comments-task-old.json agent orchestrator rec1 $((now - 800)) "$(answer_line 待つ $((now - 1000)) $((now + 4000)))"
add_task_comment comments-task-new.json agent orchestrator cancel1 $((now - 200)) "$(cancel_line rec1 DEMO-9)"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 4000)) "$now" $((now + 4000)) DEMO-1 "$claude90")"
echo 'PASS usage-wait pick: 取り消された記録は期限の前でも使わず、取り消しは行の ID で同じタスクの記録に効き、リーダーが書いた形に合う行だけが取り消しになる'

# 期限が記録のコメントの時刻から 8 日（691200 秒）を超える行は、記録と読まない。8 日ちょうどは読む。
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now - 500 + 691201)))"
run planner
expect_status 4
[[ $(wakeup_count) == 0 ]]
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now - 500 + 691200)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 100000)) "$now" $((now - 500 + 691200)) DEMO-1 "$claude90")"
# 8 日を超える新しい記録は、古い有効な記録を隠さない。
wait_setup 100000
set_marked task-old:DEMO-1 task-new:DEMO-2
add_task_comment comments-task-old.json agent orchestrator old1 $((now - 800)) "$(answer_line 待つ $((now - 1000)) $((now + 4000)))"
add_task_comment comments-task-new.json agent orchestrator new1 $((now - 300)) "$(answer_line 待つ $((now - 500)) $((now - 300 + 691201)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 4000)) "$now" $((now + 4000)) DEMO-1 "$claude90")"
echo 'PASS usage-wait pick: 期限が記録のコメントの時刻から 8 日を超える行は記録と読まず、8 日ちょうどは読む'

# 起こしの置き直し。記録が効いていて、置いてある起こしが期限より遅ければ、期限の時刻に新しい起こしを置く。
mark='使用率の待ちの起こしで起きました。'
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
add_rule late true "$mark"$'\n工程: planner\n再開の時刻: '"$(iso $((now + 90000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
[[ $(wakeup_count) == 1 ]]
expect_wake_at $((now + 5000))
# 起こしが期限と同じか早ければ、置き直さず、置いてある時刻を使う。
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
add_rule early true "$mark"$'\n工程: planner\n再開の時刻: '"$(iso $((now + 3000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 3000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
[[ $(wakeup_count) == 0 ]]
# 遅い起こしと期限に合う起こしがあれば（置き直したあとの 2 回目）、早い方を使い、増やさない。
wait_setup 100000
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)))"
add_rule late true "$mark"$'\n工程: planner\n再開の時刻: '"$(iso $((now + 90000)))"
add_rule fit true "$mark"$'\n工程: planner\n再開の時刻: '"$(iso $((now + 5000)))"
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 5000)) "$now" $((now + 5000)) DEMO-1 "$claude90")"
[[ $(wakeup_count) == 0 ]]
# 記録がなければ、置いてある遅い起こしをそのまま使う。
wait_setup 10000
add_rule late true "$mark"$'\n工程: planner\n再開の時刻: '"$(iso $((now + 9000)))"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 9000)) "$now")"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 記録が効いていて起こしが期限より遅ければ期限の時刻に置き直し、期限に合う起こしがあれば増やさず、記録がなければ置いてある起こしを使う'

# 頼める系統がないときの待つ行は、「進める」の文で出す。「待つ」の記録は、「人間の答えで待つ」のまま。
proceed_dual 2 ''
usage 100 $((now + 18000)) 90 $((now + 3600)) 100 $((now + 10800)) true
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 100%・5 時間 90%、Codex 週 100%')"
run implement 小さい
expect_status 3
grep -qF '。人間の答えで進めるが、頼める系統がないので待つ（期限 ' "$test_dir/out"
if grep -qF '人間の答えで待つ（' "$test_dir/out"; then fail '進めるの記録の待ちが「待つ」の文になっている'; fi
proceed_dual 2 ''
usage 100 $((now + 18000)) 90 $((now + 3600)) 100 $((now + 10800)) true
put_record rec1 $((now - 500)) "$(answer_line 待つ $((now - 600)) $((now + 5000)) '上限に近い枠: Claude 週 100%・5 時間 90%、Codex 週 100%')"
run implement 小さい
expect_status 3
grep -qF '。人間の答えで待つ（期限 ' "$test_dir/out"
if grep -qF '頼める系統がない' "$test_dir/out"; then fail '待つの記録の待ちに頼める系統がない文が入っている'; fi
echo 'PASS usage-wait pick: 頼める系統がないときの待つ行は、「進める」の記録なら頼める系統がない文、「待つ」の記録なら人間の答えで待つ文で出す'

# マークの差し替えを拒む。期限内の「進める」を task-old に記録し、あとから task-new で「待つ」に変えると、answer が古い記録を取り消す。
# 新しい記録のタスクのマークを消し、古い記録のタスクのマークだけを残しても、pick は終了 0 にならず、効いている記録がないときの判定になる。
swap_setup() { # マークを付けるタスク（<id>:<識別子> ...）
	wait_setup 100000
	add_task_comment comments-task-old.json agent orchestrator old1 $((now - 2000)) "$(answer_line 進める $((now - 2100)) $((now + 5000)))"
	add_task_comment comments-task-old.json agent orchestrator c-old1 $((now - 900)) "$(cancel_body old1)"
	add_task_comment comments-task-new.json agent orchestrator new1 $((now - 800)) "$(answer_line 待つ $((now - 900)) $((now + 4000)))"
	set_marked "$@"
}
swap_setup task-old:DEMO-1
run planner
[[ $status == 3 || $status == 4 ]] || { printf '終了 3 か 4 を期待したが %s\n出力:\n%s\n' "$status" "$(<"$test_dir/out")" >&2; exit 1; }
expect_out "$(exceeded_line "$now" $((now + 100000)))"
[[ $(wakeup_count) == 0 ]]
# 両方にマークがあれば、「待つ」に従う。
swap_setup task-old:DEMO-1 task-new:DEMO-2
run planner
expect_status 3
expect_out "$(wait_answer_line planner $((now + 4000)) "$now" $((now + 4000)) DEMO-2 "$claude90")"
# マークをすべて消すと、今の判定になる。
swap_setup
run planner
expect_status 4
expect_out "$(exceeded_line "$now" $((now + 100000)))"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 古い記録のタスクのマークだけを残しても、終了 0 にならず今の判定になる。両方にマークがあれば「待つ」に従い、マークをすべて消すと今の判定になる'

# ---- 起こしを、工程と回ごとに 1 件に保ち、工程が再開すると消す（pick）。起こしの一覧は 1 回だけ読み、置いてから消す。
wake_text() { # 工程 再開の時刻（秒。空なら、再開の時刻の行を書かない） [回]
	printf '%s\n工程: %s\n' "$mark" "$1"
	[[ -z ${3:-} ]] || printf '回: %s\n' "$3"
	[[ -z $2 ]] || printf '再開の時刻: %s\n' "$(iso "$2")"
}
wakeup_list_reads() { jq -s '[.[] | select(.[0] == "issue" and .[1] == "wakeup" and .[2] == "list")] | length' "$test_dir/calls.jsonl"; }
expect_ids() { [[ $(wakeup_ids) == "$1" ]] || { printf '起こしの ID は %s のはずが %s\n' "$1" "$(wakeup_ids)" >&2; exit 1; }; }
expect_empty_out() { [[ $(<"$test_dir/out") == '' ]] || { printf '出力は空のはずが:\n%s\n' "$(<"$test_dir/out")" >&2; exit 1; }; }

# 終了 3 で、同じ工程の対象の起こしが 2 件以上あれば、再開の時刻の最も早い 1 件だけを残し、置かない。一覧は 1 回だけ読む。
wait_setup 10000
add_rule a true "$(wake_text planner $((now + 9000)))"
add_rule b true "$(wake_text planner $((now + 5000)))"
add_rule c true "$(wake_text planner $((now + 7000)))"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 5000)) "$now")"
[[ $(wakeup_count) == 0 && $(wakeup_list_reads) == 1 ]]
expect_ids 'ci b '
# 同じ時刻なら、一覧で先のものを残す。
wait_setup 10000
add_rule a true "$(wake_text planner $((now + 5000)))"
add_rule b true "$(wake_text planner $((now + 5000)))"
run planner
expect_status 3
expect_ids 'ci a '
# 再開の時刻を読めない起こしは、候補にしない。読める起こしがあればそちらを残し、読めないものを消す。
wait_setup 10000
add_rule u1 true "$(wake_text planner '')"
add_rule u2 true "$mark"$'\n工程: planner\n再開の時刻: 日付ではない'
add_rule ok true "$(wake_text planner $((now + 6000)))"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 6000)) "$now")"
[[ $(wakeup_count) == 0 ]]
expect_ids 'ci ok '
# 読めない起こしだけなら、新しく置き、置いたあとに読めない起こしを消す。
wait_setup 10000
add_rule u1 true "$(wake_text planner '')"
add_rule u2 true "$mark"$'\n工程: planner\n再開の時刻: 日付ではない'
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 10000)) "$now")"
[[ $(wakeup_count) == 1 && $(wakeup_list_reads) == 1 ]]
expect_ids 'ci created-1 '
assert_jq -s 'map(select(.[0] == "issue" and .[1] == "wakeup") | .[2]) as $c | ($c | index("create")) < ($c | index("delete"))' "$test_dir/calls.jsonl"
# 回ごとに 1 件。--round を付けた pick は、同じ回の起こしだけを数え、ほかの回・回のない起こし・ほかの工程・リーダーでない宛先・無効な起こしには触れない。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_comment agent orchestrator round-7 $((now - 600)) '観点: qa（テスト）'
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
add_rule r7a true "$(wake_text implement $((now + 6000)) round-7)"
add_rule r7b true "$(wake_text implement $((now + 3000)) round-7)"
add_rule r9 true "$(wake_text implement $((now + 3000)) round-9)"
add_rule noround true "$(wake_text implement $((now + 3000)))"
add_rule fix true "$(wake_text fix $((now + 3000)) round-7)"
add_rule other-agent true "$(wake_text implement $((now + 3000)) round-7)" other-codex-fixer
add_rule off false "$(wake_text implement $((now + 3000)) round-7)"
run implement 小さい --round round-7
expect_status 3
expect_ids 'ci r7b r9 noround fix other-agent off '
# 回のない pick は、回のある起こしに触れない。
wait_setup 10000
add_rule plain true "$(wake_text planner $((now + 4000)))"
add_rule plain2 true "$(wake_text planner $((now + 8000)))"
add_rule withround true "$(wake_text planner $((now + 4000)) round-7)"
run planner
expect_status 3
expect_ids 'ci plain withround '
echo 'PASS usage-wait pick: 終了 3 は、工程と回ごとに再開の時刻の最も早い起こし 1 件を残し、ほかを消す。読めない時刻の起こしは候補にせず、一覧は 1 回だけ読む'

# 工程が再開するとき（終了 0 の 5 つの経路と、終了 4）は、対象の起こしをすべて消す。ほかの工程・無効な起こしは消さない。
two_targets() { # 工程
	add_rule t1 true "$(wake_text "$1" $((now + 4000)))"
	add_rule t2 true "$(wake_text "$1" $((now + 8000)))"
	add_rule other-process true "$(wake_text other $((now + 4000)))"
	add_rule off false "$(wake_text "$1" $((now + 4000)))"
}
# 1. 両系統の構成で dispatch-pick が決めたとき。
reset
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
two_targets implement
run implement 小さい
expect_status 0
grep -qxF '役: claude-implementer' "$test_dir/out"
expect_ids 'ci other-process off '
[[ $(wakeup_list_reads) == 1 ]]
# 2. 片系統の構成で、使用率が 80% 未満のとき。
reset
set_roster claude-implementer
two_targets implement
run implement 小さい
expect_status 0
expect_ids 'ci other-process off '
# 3. 両方上限に近くても、「進める」が効いていて、頼める系統があるとき。
proceed_dual 0 "$near_out"
put_record rec1 $((now - 500)) "$(answer_line 進める $((now - 600)) $((now + 5000)) "$both_near")"
two_targets implement
run implement 小さい
expect_status 0
expect_ids 'ci other-process off '
# 4. 片系統の構成で、使用率を読めないとき。
reset
set_roster claude-implementer
echo 'not json' >"$test_dir/usage.json"
two_targets implement
run implement 小さい
expect_status 0
expect_ids 'ci other-process off '
# 5. 回つきの終了 0 は、同じ回の起こしだけを消す。
reset
set_roster claude-implementer
add_comment agent orchestrator round-7 $((now - 600)) '観点: qa（テスト）'
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
add_rule r7 true "$(wake_text implement $((now + 4000)) round-7)"
add_rule r9 true "$(wake_text implement $((now + 4000)) round-9)"
add_rule noround true "$(wake_text implement $((now + 4000)))"
run implement 小さい --round round-7
expect_status 0
expect_ids 'ci r9 noround '
# 6. 終了 4（通算 24 時間を超える）。
wait_setup 100000
two_targets planner
run planner
expect_status 4
expect_out "$(exceeded_line "$now" $((now + 100000)))"
expect_ids 'ci other-process off '
[[ $(wakeup_list_reads) == 1 && $(wakeup_count) == 0 ]]
echo 'PASS usage-wait pick: 工程が再開する終了 0（5 つの経路）と終了 4 は、対象の起こしをすべて消し、ほかの工程と無効な起こしには触れない'

# 起こしの一覧を読めなければ、役も待ちの行も人間を呼ぶ行も出さずに終了 1（終了 0 の経路も、終了 3 の経路も）。
reset
set_roster claude-implementer
add_rule t1 true "$(wake_text implement $((now + 4000)))"
touch "$test_dir/wakeup-list-fail"
run implement 小さい
expect_status 1
expect_empty_out
expect_ids 'ci t1 '
wait_setup 10000
touch "$test_dir/wakeup-list-fail"
run planner
expect_status 1
expect_empty_out
[[ $(wakeup_count) == 0 ]]
wait_setup 100000
add_rule t1 true "$(wake_text planner $((now + 4000)))"
touch "$test_dir/wakeup-list-fail"
run planner
expect_status 1
expect_empty_out
expect_ids 'ci t1 '
# 消せなければ、行を出さずに終了 1。消せなかった起こしを読み直して、残っていれば失敗、なくなっているか無効なら続ける。
wait_setup 10000
add_rule t1 true "$(wake_text planner $((now + 4000)))"
add_rule t2 true "$(wake_text planner $((now + 8000)))"
touch "$test_dir/wakeup-delete-fail-t2"
run planner
expect_status 1
expect_empty_out
expect_ids 'ci t1 t2 '
# 同じ引数で流し直すと、1 件になって終了 3。
rm -f "$test_dir/wakeup-delete-fail-t2"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 4000)) "$now")"
expect_ids 'ci t1 '
# 消せなかったが、読み直すと一覧になかった（別の pick が先に消した）なら、続ける。
wait_setup 10000
add_rule t1 true "$(wake_text planner $((now + 4000)))"
add_rule t2 true "$(wake_text planner $((now + 8000)))"
echo gone >"$test_dir/wakeup-delete-fail-t2"
run planner
expect_status 3
expect_ids 'ci t1 '
[[ $(wakeup_list_reads) == 2 ]]
# 消せなかったが、読み直すと無効だった（消す直前に発火した）なら、続ける。
wait_setup 10000
add_rule t1 true "$(wake_text planner $((now + 4000)))"
add_rule t2 true "$(wake_text planner $((now + 8000)))"
echo disabled >"$test_dir/wakeup-delete-fail-t2"
run planner
expect_status 3
expect_ids 'ci t1 t2 '
# 工程が再開する経路の消せない失敗も、行を出さずに終了 1。
reset
set_roster claude-implementer
add_rule t1 true "$(wake_text implement $((now + 4000)))"
touch "$test_dir/wakeup-delete-fail"
run implement 小さい
expect_status 1
expect_empty_out
expect_ids 'ci t1 '
# 置けなければ、起こしを消さずに終了 1（先に消すと、置けなかったときに 0 件になる）。
wait_setup 10000
add_rule u1 true "$(wake_text planner '')"
touch "$test_dir/wakeup-create-fail"
run planner
expect_status 1
expect_empty_out
expect_ids 'ci u1 '
# 置いたあとに消せなければ、置いた起こしと読めない起こしが残る。流し直すと、置いた起こしを残して 1 件になり、終了 3。
wait_setup 10000
add_rule u1 true "$(wake_text planner '')"
touch "$test_dir/wakeup-delete-fail-u1"
run planner
expect_status 1
expect_empty_out
expect_ids 'ci u1 created-1 '
rm -f "$test_dir/wakeup-delete-fail-u1"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 10000)) "$now")"
expect_ids 'ci created-1 '
[[ $(wakeup_count) == 1 ]]
echo 'PASS usage-wait pick: 起こしの一覧を読めない・消せない・置けないときは行を出さずに終了 1 にし、消せなかった起こしが一覧になければ続ける。置いたあとに消せなければ、流し直して 1 件にする'
