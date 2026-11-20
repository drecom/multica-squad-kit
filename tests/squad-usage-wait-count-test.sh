#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-count-test.sh で実行する。
# 答えの記録を使わない pick の 24 時間の数え方、名簿の読み方、リセットを過ぎたときと使い方の誤りを確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- 24 時間の数え方。planner の片系統で、リセットまでの時間を変えて確認する。

# 初めての待ちは、今から数える。24 時間ちょうどまでは待ち、超えれば待たずに終了 4 にする。
wait_setup 86400
run planner
expect_status 3
# 24 時間以内の待ちは、人間を呼ぶ行を出さない。
if grep -qF '通算 24 時間を超える' "$test_dir/out"; then echo '24 時間以内の待ちで人間を呼ぶ行を出した' >&2; exit 1; fi
[[ $(wakeup_count) == 1 ]]
wait_setup 86401
run planner
expect_status 4
expect_out "$(exceeded_line "$now" $((now + 86401)))"
[[ $(wakeup_count) == 0 ]]

# 待ち始めは、同じ工程の待ちの行が続くあいだ引き継ぐ。
start=$((now - 72000))
wait_setup 10800
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 10800))) まで待つ。待ち始め: $(iso "$start")。上限に近い枠: Claude 週 90%"
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
run planner
expect_status 4
expect_out "$(exceeded_line "$start" $((now + 18000)))"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: 待ち始めを同じ工程の待ちの行から引き継ぎ、通算 24 時間を超えたら起こしを置かず終了 4 にする'

# 人間の質問やほかの工程の待ち・ほかの役の結果が間にあっても、待ち始めは変わらない。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment member human q1 $((now - 3000)) '進捗は？'
add_comment agent orchestrator c2 $((now - 2000)) "$(wait_line designer $((now + 3000)) $((now - 2000)))"
add_comment agent designer r1 $((now - 1000)) '設計の結果です。'
run planner
expect_status 4
expect_out "$(exceeded_line "$start" $((now + 18000)))"
# 24 時間を超えたあとの質問でも、数え直さない。
add_comment agent orchestrator c3 $((now - 900)) "$(exceeded_line "$start" $((now + 18000)))"
add_comment member human q2 $((now - 800)) '今どうなっていますか。待ちますか？'
run planner
expect_status 4
expect_out "$(exceeded_line "$start" $((now + 18000)))"
echo 'PASS usage-wait: 質問・ほかの工程の待ち・ほかの役の結果、24 時間を超えたあとの質問では、待ち始めを数え直さない'

# 工程の再開（その工程の振り分けの行）で数え直す。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) $'役: planner\n振り分け: Claude（片系統の構成）。Claude 週 10%。工程: planner'
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
# ほかの工程の振り分けの行では数え直さない。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) $'役: designer\n振り分け: Codex（片系統の構成）。Codex 週 10%。工程: designer'
run planner
expect_status 4
echo 'PASS usage-wait: その工程の振り分けの行のあとは数え直し、ほかの工程のものでは数え直さない'

# 24 時間を超えたあとの、リーダーが書いた延長の行で数え直す。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) "$(old_exceeded_line "$start")"
add_comment agent orchestrator c3 $((now - 2000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
[[ $(wakeup_count) == 1 ]]
# 延長のあとの待ちの行からは、その待ち始めを引き継ぐ。
add_comment agent orchestrator c4 $((now - 1000)) "$(wait_line planner $((now + 18000)) "$now")"
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
echo 'PASS usage-wait: 24 時間を超えたあとのリーダーの延長の行で数え直し、その後の待ちの行は新しい待ち始めを引き継ぐ'

# 新しい形の人間を呼ぶ行のあとの延長の行も、同じように数え直す。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) "$(exceeded_line "$start" $((now + 18000)))"
add_comment agent orchestrator c3 $((now - 2000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
[[ $(wakeup_count) == 1 ]]
echo 'PASS usage-wait: 新しい形の人間を呼ぶ行のあとの延長の行でも数え直す'

# 古い形・新しい形の人間を呼ぶ行だけが残るタスクでは、待ち始めを人間を呼ぶ行から読まず、終了 1 にもしない。今の 24 時間の判定になる。
for line_kind in old_exceeded_line exceeded_line; do
	wait_setup 18000
	add_comment agent orchestrator c1 $((now - 3000)) "$("$line_kind" "$start" $((now + 18000)))"
	run planner
	expect_status 3
	expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
	[[ $(wakeup_count) == 1 ]]
	wait_setup 86401
	add_comment agent orchestrator c1 $((now - 3000)) "$("$line_kind" "$start" $((now + 18000)))"
	run planner
	expect_status 4
	expect_out "$(exceeded_line "$now" $((now + 86401)))"
	[[ $(wakeup_count) == 0 ]]
done
echo 'PASS usage-wait: 古い形・新しい形の人間を呼ぶ行だけが残るタスクで、待ち始めをその行から読まず、終了 1 にならず、今の判定になる'

# 24 時間を超える前の延長の行、リーダーでない作者の行、ほかの工程の行は数えない。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 5000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
add_comment agent orchestrator c3 $((now - 3000)) "$(exceeded_line "$start" $((now + 18000)))"
run planner
expect_status 4
expect_out "$(exceeded_line "$start" $((now + 18000)))"
add_comment agent designer c4 $((now - 2000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 4
add_comment agent orchestrator c5 $((now - 1000)) $'使用率の待ちの延長: designer。決めた人: 利用者'
run planner
expect_status 4
add_comment member human c6 $((now - 500)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 4
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: 24 時間を超える前の延長の行、リーダー以外の行、ほかの工程の行、人間のコメントの行では数え直さない'

# ---- 名簿の読み方。
reset
set_roster claude-implementer archived-codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 95 $((now + 7200)) false
run implement 小さい
expect_status 0
grep -qxF '役: claude-implementer' "$test_dir/out"
[[ -z $(dispatch_calls) ]]
reset
set_roster claude-fixer other-codex-fixer
run fix
expect_status 0
[[ -z $(dispatch_calls) ]]
grep -qxF '役: claude-fixer' "$test_dir/out"
echo 'PASS usage-wait: アーカイブ済みのエージェントとキーが合わない名前は、名簿に数えない'

reset
set_roster claude-fixer
run implement 小さい
expect_status 1
grep -qF '名簿に工程の役がない: implement' "$test_dir/err"
reset
set_roster claude-implementer
run planner
expect_status 1
grep -qF '名簿に工程の役がない: planner' "$test_dir/err"
reset
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
cp "$test_dir/issue.json" "$test_dir/issue.saved.json"
cp "$test_dir/issue-member.json" "$test_dir/issue.json"
run implement 小さい
expect_status 1
grep -qF 'タスクの担当がスクワッドではない' "$test_dir/err"
cp "$test_dir/issue.saved.json" "$test_dir/issue.json"
echo 'PASS usage-wait: 工程の役が名簿になければ、担当がスクワッドでなければ、終了 1'

# ---- リセットを過ぎたのに使用率がまだ上限に近いとき。過去の時刻に起こしを置かず、60 分後の再確認にする。
wait_setup -100
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 3600)) "$now")"
[[ $(wakeup_count) == 1 ]]
assert_jq --arg at "$(iso $((now + 3600)))" '(.args | index("--at") as $k | .[$k + 1]) == $at' "$test_dir/wakeups.jsonl"
# 24 時間の判定は、再確認の時刻までの経過を含む。待ち始めから 24 時間までなら待ち、超えれば待たずに終了 4 にする。
start=$((now - 82800))
wait_setup -100
add_comment agent orchestrator c1 "$start" "$(wait_line planner $((now - 100)) "$start")"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 3600)) "$start")"
start=$((now - 82900))
wait_setup -100
add_comment agent orchestrator c1 "$start" "$(wait_line planner $((now - 100)) "$start")"
run planner
expect_status 4
expect_out "$(exceeded_line "$start" $((now + 3600)))"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: リセットを過ぎても上限に近ければ、60 分後の再確認の時刻に起こしを置き、経過を 24 時間の判定に含める'

# ---- 使い方の誤り。
reset
# 旧い見積もりの値（U+5C0F U+3055 U+306A）は使い方のエラーにする。
old_small=$'\xe5\xb0\x8f\xe3\x81\x95\xe3\x81\xaa'
for bad in '' 'review' 'implement 中くらい' "implement $old_small" 'principal 小さい' 'principal Gemini' 'fix 小さい' 'planner Claude' 'implement 小さい 余分'; do
	# shellcheck disable=SC2086
	run $bad
	expect_status 1
done
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait) >/dev/null 2>"$test_dir/err" || status=$?
expect_status 1
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue) >/dev/null 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF '使い方: squad-usage-wait pick' "$test_dir/err"
[[ ! -s $test_dir/calls.jsonl ]]
echo 'PASS usage-wait: 工程や引数が不正なら、CLI を呼ばずに終了 1'
