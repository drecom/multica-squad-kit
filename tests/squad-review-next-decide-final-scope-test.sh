#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-final-scope-test.sh で実行する。
# この部分は、最終レビューの範囲（前の最終レビューのコミットが祖先かどうか）を確認する。
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

# 範囲。前の最終レビューの最上位の役の結果の確認したコミットが祖先なら、そこからの差分にする。
prev_final() { # 確認したコミット
	final_round prev-final "$old" older-round
	result prev-final claude-principal ✅ "$1" なし
}
reset
prev_final fedcba9
ok_round
set_principal_pick claude-principal
run round-1
expect_posted 最終レビュー "$(final_request_body "fedcba9..$sha")"
expect_calls compare-calls "fedcba9...$sha"
# 同じコミットの比較（identical）も祖先にする。
reset
prev_final fedcba9
ok_round
fixture gh-compare | jq '.status = "identical"' >"$test_dir/compare.json"
run round-1
[[ $(posted_body) == *"見る範囲: fedcba9..$sha"* ]] || fail "identical を祖先にしていない: $(posted_body)"
# 祖先でない（diverged・behind）なら全体にする。
for state in diverged behind; do
	reset
	prev_final fedcba9
	ok_round
	fixture gh-compare | jq --arg state "$state" '.status = $state' >"$test_dir/compare.json"
	run round-1
	[[ $(posted_body) == *'見る範囲: PR の差分全体'* ]] || fail "$state を全体にしていない: $(posted_body)"
done
# 比較に失敗したら全体にする。
reset
prev_final fedcba9
ok_round
touch "$test_dir/compare-fail"
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
# 前の結果のコミットが読めなければ、比較せずに全体にする。
reset
prev_final なし
ok_round
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
# 前の結果が複数なら、最新の結果を使う。
reset
final_round prev-final "$old" older-round
result prev-final claude-principal ✅ 1111111 なし
result prev-final claude-principal ✅ fedcba9 なし
ok_round
run round-1
[[ $(posted_body) == *"見る範囲: fedcba9..$sha"* ]] || fail "最新の結果を使っていない: $(posted_body)"
# 前の最終レビューの最新の結果が読めないとき（結論のマークがない）は、古い読める結果へ戻らず、全体にする。
reset
final_round prev-final "$old" older-round
result prev-final claude-principal ✅ 1111111 なし
add res-unreadable claude-principal $'/note\n返事の回: prev-final\n確認したコミット: fedcba9\n設計への指摘: なし\n\n結論のマークがない'
ok_round
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
# 別の回への返事は、前の最終レビューの結果にしない。
reset
final_round prev-final "$old" older-round
result older-round claude-principal ✅ fedcba9 なし
ok_round
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
# 前の最終レビューがなければ全体にする。
reset
ok_round
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
echo 'PASS review-next-decide: 最終レビューの範囲は、前の最終レビューのコミットが祖先のときだけ差分にする'
