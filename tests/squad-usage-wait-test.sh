#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-test.sh で実行する。
# 答えの記録を使わない pick（両系統・片系統・工程ごとの系統・使用率を読めないとき・起こしの重複の防止）を確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- 両系統の構成: squad-dispatch-pick へ回す。
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
run implement 小さい
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%。工程: implement'
[[ $(dispatch_calls) == 'implement 小さい' && ! -s $test_dir/usage-reads && $(wakeup_count) == 0 ]]
run implement 大きい
expect_status 0
[[ $(dispatch_calls) == 'implement 大きい' ]]
run fix
expect_status 0
[[ $(dispatch_calls) == 'fix' ]]
grep -qxF '振り分け: Claude（理由）。Claude 週 20%。工程: fix' "$test_dir/out"
run principal Codex
expect_status 0
[[ $(dispatch_calls) == 'principal Codex' ]]
run principal Claude
[[ $(dispatch_calls) == 'principal Claude' ]]
run principal
[[ $(dispatch_calls) == 'principal' ]]
echo 'PASS usage-wait: 両系統の構成では squad-dispatch-pick の選んだ役と振り分けを、工程のマークを足して返す。principal の系統の引数もそのまま渡す'

# 回を渡さない直接の呼び出しは、タスクの担当がメンバーでも、呼び出したリーダー（MULTICA_AGENT_ID）のスクワッドの名簿で選ぶ。
# リーダーを決められないときだけ、タスクの担当のスクワッドへ戻る。担当もスクワッドでなければ失敗する。
reset
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
cp "$test_dir/issue.json" "$test_dir/issue.saved.json"
cp "$test_dir/issue-member.json" "$test_dir/issue.json"
status=0
(cd "$test_dir" && MULTICA_AGENT_ID=orchestrator bash monitor/squad-usage-wait pick test-issue implement 小さい) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%。工程: implement'
[[ $(dispatch_calls) == 'implement 小さい' ]]
status=0
(cd "$test_dir" && MULTICA_AGENT_ID=someone-else bash monitor/squad-usage-wait pick test-issue implement 小さい) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF 'タスクの担当がスクワッドではない' "$test_dir/err"
status=0
(cd "$test_dir" && env -u MULTICA_AGENT_ID bash monitor/squad-usage-wait pick test-issue implement 小さい) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF 'タスクの担当がスクワッドではない' "$test_dir/err"
# 担当がスクワッドなら、呼び出したリーダーがいなくても、担当のスクワッドで選ぶ。
cp "$test_dir/issue.saved.json" "$test_dir/issue.json"
reset
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
run implement 小さい
expect_status 0
echo 'PASS usage-wait: 担当がメンバーのタスクでも、呼び出したリーダーのスクワッドの名簿で選び、リーダーを決められなければ担当のスクワッドへ戻る'

# ---- 両系統の構成で、dispatch-pick が両方上限に近いと返したときだけ待つ。
echo 2 >"$test_dir/dispatch-status"
: >"$test_dir/dispatch-out"
# Claude は週 85%（リセット 5 時間後）と 5 時間 90%（1 時間後）、Codex は週 82%（3 時間後）。
usage 85 $((now + 18000)) 90 $((now + 3600)) 82 $((now + 10800)) true
run implement 小さい
expect_status 3
resume=$((now + 10800))
expect_out "使用率の待ち: implement を $(iso "$resume") まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 85%・5 時間 90%、Codex 週 82%"
[[ $(wakeup_count) == 1 ]]
assert_jq --arg at "$(iso "$resume")" --arg mark "$mark" '
	.args[0:4] == ["issue", "wakeup", "create", "test-issue"] and
	(.args | index("--kind") as $k | .[$k + 1]) == "at" and
	(.args | index("--at") as $k | .[$k + 1]) == $at and
	(.args | index("--agent-id") as $k | .[$k + 1]) == "orchestrator" and
	(.instruction | startswith($mark + "\n")) and (.instruction | split("\n") | any(. == "工程: implement"))
	and (.instruction | contains("回:") | not)' "$test_dir/wakeups.jsonl"
echo 'PASS usage-wait: 両系統が上限に近いときだけ待ち、系統ごとの再開の時刻の早い方を使う。起こしはリーダーへ、工程つきの指示で置く'

# 週の 80% 以上の枠が複数あれば、遅い方のリセット時刻を使う（Claude だけ近い片系統の構成）。
reset
set_roster claude-implementer
usage 85 $((now + 3600)) 90 $((now + 7200)) 10 $((now + 100000)) true
run implement 小さい
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 85%・5 時間 90%"
[[ -z $(dispatch_calls) ]]
reset
set_roster claude-implementer
usage 85 $((now + 9000)) 90 $((now + 7200)) 10 $((now + 100000)) true
run implement 小さい
expect_out "使用率の待ち: implement を $(iso $((now + 9000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 85%・5 時間 90%"
echo 'PASS usage-wait: 複数の枠が上限に近ければ、遅い方のリセット時刻まで待つ'

# Codex が利用不可で週が 80% 未満のときは、60 分後と週のリセット時刻の早い方にする。
reset
set_roster codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 50 $((now + 36000)) false
run implement 小さい
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 3600))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex は利用不可（週 50%）"
reset
set_roster codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 50 $((now + 1200)) false
run implement 小さい
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 1200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex は利用不可（週 50%）"
# Codex の週が 80% 以上なら、利用不可でも週のリセット時刻まで待つ。
reset
set_roster codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 90 $((now + 36000)) false
run implement 小さい
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 36000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex 週 90%・利用不可"
echo 'PASS usage-wait: Codex が利用不可で週が 80% 未満なら 60 分後と週のリセットの早い方、週が 80% 以上なら週のリセットまで待つ'

# 両系統が上限に近いと返されたあと、使用率を読み直せなければ 60 分後に読み直す。
reset
echo 2 >"$test_dir/dispatch-status"
echo 1 >"$test_dir/usage-status"
: >"$test_dir/usage.json"
run fix
expect_status 3
expect_out "使用率の待ち: fix を $(iso $((now + 3600))) まで待つ。待ち始め: $(iso "$now")。両系統が上限に近いと読んだが、読み直した使用率が揃わなかったため、60 分後に読み直す"
echo 'PASS usage-wait: 読み直しに失敗したときは、60 分後に読み直す'

# dispatch-pick の失敗は、待たずに終了 1 にする。
reset
echo 1 >"$test_dir/dispatch-status"
run implement 小さい
expect_status 1
[[ $(wakeup_count) == 0 ]]
grep -qF 'squad-dispatch-pick が失敗した（終了 1）' "$test_dir/err"
echo 'PASS usage-wait: squad-dispatch-pick が失敗したら、待たずに終了 1'

# ---- 片系統の構成。
reset
set_roster claude-implementer
run implement 小さい
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（片系統の構成）。Claude 週 10%・5 時間 10%。工程: implement'
[[ -z $(dispatch_calls) && $(wakeup_count) == 0 ]]
reset
set_roster codex-fixer
run fix
expect_status 0
expect_out $'役: codex-fixer\n振り分け: Codex（片系統の構成）。Codex 週 10%。工程: fix'
# もう一方の系統が上限に近くても、見ない。
usage 90 $((now + 3600)) 90 $((now + 3600)) 10 $((now + 100000)) true
run fix
expect_status 0
reset
set_roster claude-principal
usage 10 $((now + 100000)) 10 $((now + 10000)) 95 $((now + 3600)) false
run principal Codex
expect_status 0
expect_out $'役: claude-principal\n振り分け: Claude（片系統の構成）。Claude 週 10%・5 時間 10%。工程: principal'
[[ -z $(dispatch_calls) ]]
echo 'PASS usage-wait: 片系統の構成では、その系統の使用率だけを見て、上限に近くなければその役を選ぶ'

# 片系統で上限に近ければ待つ。
reset
set_roster codex-principal
usage 10 $((now + 100000)) 10 $((now + 10000)) 90 $((now + 7200)) true
run principal
expect_status 3
expect_out "使用率の待ち: principal を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex 週 90%"
[[ $(wakeup_count) == 1 && -z $(dispatch_calls) ]]
echo 'PASS usage-wait: 片系統の構成で上限に近ければ待つ'

# ---- planner と designer。系統は役のモデルで決める。
reset
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
run designer
expect_status 0
expect_out $'役: designer\n振り分け: Codex（片系統の構成）。Codex 週 10%。工程: designer'
reset
usage 10 $((now + 100000)) 10 $((now + 100000)) 90 $((now + 5400)) true
run planner
expect_status 0
expect_out $'役: planner\n振り分け: Claude（片系統の構成）。Claude 週 10%・5 時間 10%。工程: planner'
run designer
expect_status 3
expect_out "使用率の待ち: designer を $(iso $((now + 5400))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex 週 90%"
[[ -z $(dispatch_calls) ]]
echo 'PASS usage-wait: planner と designer は、名簿の役のモデルの系統が上限に近いときだけ待つ。dispatch-pick は使わない'

# ---- 使用率を読めないときは、待たずにその系統に固定する。
reset
set_roster claude-implementer
echo 1 >"$test_dir/usage-status"
echo 'not json' >"$test_dir/usage.json"
run implement 小さい
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（使用率を読めないため、片系統の構成のその系統に固定した。使用率の出力を JSON として読めなかった）。工程: implement'
[[ $(wakeup_count) == 0 ]]
reset
set_roster codex-implementer
jq -n --arg read "$(iso "$now")" '{read_at: $read, claude: {error: "no claude"}, codex: {error: "no codex"}}' >"$test_dir/usage.json"
run implement 小さい
expect_status 0
grep -qF '振り分け: Codex（使用率を読めないため、片系統の構成のその系統に固定した。Codex: no codex）。工程: implement' "$test_dir/out"
# 読めたのがもう一方の系統だけでも、固定する。
set_roster claude-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 10 $((now + 100000)) true
jq --arg read "$(iso "$now")" '.claude = {error: "no claude"}' "$test_dir/usage.json" >"$test_dir/usage.tmp"
mv "$test_dir/usage.tmp" "$test_dir/usage.json"
run implement 小さい
expect_status 0
grep -qF 'Claude: no claude' "$test_dir/out"
# 30 分より古い使用率も、読めないものとして扱う。
reset
set_roster claude-implementer
usage 95 $((now + 7200)) 95 $((now + 7200)) 10 $((now + 100000)) true
jq --arg read "$(iso $((now - 2000)))" '.read_at = $read' "$test_dir/usage.json" >"$test_dir/usage.tmp"
mv "$test_dir/usage.tmp" "$test_dir/usage.json"
run implement 小さい
expect_status 0
grep -qF '使用率が 30 分より古い' "$test_dir/out"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: 使用率を読めないとき、片系統の構成はその系統に固定して理由を書き、待たない'

# ---- 起こしの重複の防止。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_rule other-process true "$mark"$'\n工程: fix\n再開の時刻: 2026-01-01T00:00:00Z'
add_rule disabled false "$mark"$'\n工程: implement\n再開の時刻: 2026-01-01T00:00:00Z'
add_rule same-process true "$mark"$'\n工程: implement\n再開の時刻: 2026-01-02T03:04:05Z'
run implement 小さい
expect_status 3
expect_out "使用率の待ち: implement を 2026-01-02T03:04:05Z まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
[[ $(wakeup_count) == 0 ]]
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_rule other-process true "$mark"$'\n工程: fix\n再開の時刻: 2026-01-01T00:00:00Z'
add_rule disabled false "$mark"$'\n工程: implement\n再開の時刻: 2026-01-01T00:00:00Z'
run implement 小さい
expect_status 3
[[ $(wakeup_count) == 1 ]]
run implement 小さい
[[ $(wakeup_count) == 1 ]]
echo 'PASS usage-wait: 同じ工程の有効な起こしがあれば置き直さず、その時刻を使う。ほかの工程や無効な起こしは数えない'

# decide から呼ぶときは、回のコメントを指示に書く。スクワッドは、タスクの担当でなく、回を書いた役から決める。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_comment agent orchestrator round-7 $((now - 600)) '観点: qa（テスト）'
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue implement 小さい --round round-7) >"$test_dir/out" 2>"$test_dir/err" || status=$?
assert_jq '.instruction | split("\n") | any(. == "回: round-7") and any(contains("squad-review-next decide test-issue round-7"))' "$test_dir/wakeups.jsonl"
# 回を書いた役がどのスクワッドのリーダーでもなければ、担当にせず、起こしを置かずに失敗する。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_comment agent someone-else round-7 $((now - 600)) '観点: qa（テスト）'
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue implement 小さい --round round-7) >"$test_dir/out" 2>"$test_dir/err" || status=$?
[[ $status == 1 ]] || fail "回のスクワッドを決められないのに失敗しない: $status"
[[ $(wakeup_count) == 0 ]] || fail "起こしを置いてはいけない"
echo 'PASS usage-wait: --round で呼ぶと、起こしの指示に回のコメントと decide の流し直しを書く'
