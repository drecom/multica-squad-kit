#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-final-test.sh で実行する。
# この部分は、最終レビューを頼む実装の系統の選び方と、スクワッドの決め方・短い道を確認する。
# squad-review-next decide の判定のうち、最終レビューの依頼・範囲・最終レビューの回の返事を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 最終レビュー。
# 実装の系統は、完了した実装・修正の実行の数で決める。
run_item=$(fixture issue-runs)
set_runs() { # 役:状態...
	jq -n --argjson base "$run_item" --args '[$ARGS.positional[] | split(":") as $p | $base + {agent_id: $p[0], status: $p[1]}]' -- "$@" >"$test_dir/runs.json"
}
final_pick_call() { printf 'pick test-issue principal%s --round round-1' "${1:+ $1}"; }

reset
ok_round
set_runs claude-implementer:completed claude-fixer:completed codex-fixer:completed claude-implementer:failed codex-implementer:failed
set_principal_pick codex-principal
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体' codex-principal)"
expect_calls pick-calls "$(final_pick_call Claude)"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator codex-principal'
# 見張りを入れたあとに投稿に失敗したら、見張りを消してから 1 で終わる。
reset
ok_round
set_runs claude-implementer:completed
set_principal_pick codex-principal
touch "$test_dir/post-fail"
run round-1
expect_failure 'コメントの投稿に失敗した'
expect_calls watch-calls $'watch test-issue round-1 --agent-id orchestrator codex-principal\nunwatch test-issue'
# 同数なら系統を指定しない。
reset
ok_round
set_runs claude-implementer:completed codex-fixer:completed
run round-1
expect_calls pick-calls "$(final_pick_call)"
# Codex が多ければ Codex を指定する。
reset
ok_round
set_runs codex-implementer:completed codex-fixer:completed claude-fixer:completed
run round-1
expect_calls pick-calls "$(final_pick_call Codex)"
# 実行がなければ設計の役の系統を使う。
reset
ok_round
run round-1
expect_calls pick-calls "$(final_pick_call Claude)"
reset
ok_round
set_designer_model gpt-5.5
run round-1
expect_calls pick-calls "$(final_pick_call Codex)"
# 実行を読めなければ、系統を指定せずに選ぶ。
reset
ok_round
touch "$test_dir/runs-fail"
run round-1
expect_status 0
expect_calls pick-calls "$(final_pick_call)"
echo 'PASS review-next-decide: 最終レビューは、実装の系統を実行の数から決めて、最上位の役を選ぶ'

# スクワッドは、回を書いた役から決める。タスクの担当がメンバーでも、別のスクワッドでも、回を書いたリーダーのスクワッドの名簿を読む。
reset
ok_round
jq '.assignee_type = "member" | .assignee_id = "human-1"' "$test_dir/issue.json" >"$test_dir/issue.new" && mv "$test_dir/issue.new" "$test_dir/issue.json"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "担当がメンバーのとき、回のスクワッドから決めていない: $(<"$test_dir/out")"
reset
ok_round
jq '. + [.[0] + {id: "squad-other", name: "DEMO-OTHER", leader_id: "other-leader", creator_id: "human-2"}]' "$test_dir/squads.json" >"$test_dir/squads.new" && mv "$test_dir/squads.new" "$test_dir/squads.json"
jq '.assignee_id = "squad-other"' "$test_dir/issue.json" >"$test_dir/issue.new" && mv "$test_dir/issue.new" "$test_dir/issue.json"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "担当が別のスクワッドのとき、回のスクワッドから決めていない: $(<"$test_dir/out")"
grep -q 'squad-test' "$test_dir/calls.jsonl" || fail "回のスクワッドの名簿を読んでいない: $(<"$test_dir/calls.jsonl")"
! grep -q 'squad-other' "$test_dir/calls.jsonl" || fail "担当の別のスクワッドの名簿を読んでいる: $(<"$test_dir/calls.jsonl")"
jq 'map(select(.id == "squad-test"))' "$test_dir/squads.json" >"$test_dir/squads.new" && mv "$test_dir/squads.new" "$test_dir/squads.json"
# 回を書いた役がどのスクワッドのリーダーでもなければ、担当にせず失敗する。
reset
ok_round
jq 'map(.leader_id = "someone-else")' "$test_dir/squads.json" >"$test_dir/squads.new" && mv "$test_dir/squads.new" "$test_dir/squads.json"
run round-1
expect_failure 'スクワッドを決められない'
jq 'map(.leader_id = "orchestrator")' "$test_dir/squads.json" >"$test_dir/squads.new" && mv "$test_dir/squads.new" "$test_dir/squads.json"
echo 'PASS review-next-decide: スクワッドは、回を書いた役から決める'

# 短い道は、最上位の役が名簿にあっても最終レビューを頼まない。
reset
set_merge_roster
ok_round
add path orchestrator '道: 短い'
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼\n依頼: posted-comment' ]] || fail '短い道がマージの依頼へ進まない'
expect_no_calls pick-calls
expect_no_calls watch-calls
# 重要が付いた短い道は、最終レビューもマージも頼まず、リーダーを起こす。
reset
ok_round
add path orchestrator '道: 短い'
set_issue_labels label-imp
run round-1
expect_leader '短い道に重要のマークがある'
expect_no_calls pick-calls
# ❌ の結果があっても、修正の依頼を書かずに同じ理由で止まる。
reset
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
add path orchestrator '道: 短い'
set_issue_labels label-imp
run round-1
expect_leader '短い道に重要のマークがある'
# 重要が付いていても、通常に戻した記録が最新なら最終レビューを頼む。
reset
ok_round
add path-short orchestrator '道: 短い'
add path-normal orchestrator '道: 通常'
set_issue_labels label-imp
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
# 通常に戻した記録が最新なら最終レビューを頼む。
reset
ok_round
add path-short orchestrator '道: 短い'
add path-normal orchestrator '道: 通常'
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
echo 'PASS review-next-decide: 短い道だけ最終レビューを飛ばし、重要が付いた短い道は止め、通常の道では頼む'
