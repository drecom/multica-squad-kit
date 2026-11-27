#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-final-done-test.sh で実行する。
# この部分は、最終レビューを済みにする条件と、最終レビューの回の返事の読み方を確認する。
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

# 最上位の役が名簿になければ、最終レビューを書かずにマージの手順へ進む。head の照合は、最上位の役がないので流さない。
reset
set_roster orchestrator code-reviewer qa
ok_round
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "コンフリクト: MERGEABLE head: $sha" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
expect_no_calls pick-calls
# 同じコミットの最終レビューがすでにあり、その結果が ✅ なら、もう一度は頼まない。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" older
result final-1 claude-principal ✅ "$sha" なし
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "コンフリクト: MERGEABLE head: $sha" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果' '✅ demo-claude-principal-test: 結果')"
expect_no_calls pick-calls
# 依頼があるだけでは済みにしない。結果が ❌・設計への指摘あり・返事なし・読めない・別のコミットのときは、マージに進まない。
not_done() { # 理由に含まれる文字列
	run round-1
	expect_leader "$1"
	expect_no_calls pick-calls
}
reset
ok_round
final_round final-1 "$sha" older
result final-1 claude-principal ❌ "$sha" なし
not_done '❌ の結果がある'
reset
ok_round
final_round final-1 "$sha" older
result final-1 claude-principal ✅ "$sha" あり
not_done '設計への指摘: あり'
reset
ok_round
final_round final-1 "$sha" older
not_done '返事の結果がない'
reset
ok_round
final_round final-1 "$sha" older
add res-unreadable claude-principal $'/note\n返事の回: final-1\n確認したコミット: '"$sha"$'\n設計への指摘: なし\n\n結論のマークがない'
not_done '返事の結果が読めない'
reset
ok_round
final_round final-1 "$sha" older
result final-1 claude-principal ✅ "$old" なし
not_done '確認したコミットが合わない'
# ❌ の最終レビューのあとに、同じコミットで ✅ の通常の回が続いても、最終レビューの結果を読む。
reset
ok_round
final_round final-1 "$sha" older
result final-1 claude-principal ❌ "$sha" なし
review_round round-2 "$sha" code-reviewer qa
all_ok round-2 "$sha" code-reviewer qa
run round-2
expect_leader '❌ の結果がある'
# 違うコミットの最終レビューは、同じコミットのものと見なさない。
reset
final_round final-0 "$old" older
ok_round
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "違うコミットの最終レビューを同じと見なしている: $(<"$test_dir/out")"
echo 'PASS review-next-decide: 最終レビューが要らないとき、または済んでいるときは、マージの手順（未実装）に進む'

# 最終レビューの回の返事。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "コンフリクト: MERGEABLE head: $sha" '✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')" final-1
# 最上位の役が ❌ なら修正の依頼にする。
reset
ok_round
final_round final-1 "$sha" round-1
result final-1 claude-principal ❌ "$sha" なし
run final-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "最上位の役の ❌ が修正でない: $(<"$test_dir/out")"
grep -q '直す指摘: claude-principal（' <<<"$(posted_body)" || fail "直す指摘が最上位の役でない: $(posted_body)"
# 最上位の役の確認したコミットが合わなければ、最終レビューの形で頼み直す。
final_retry_body() { # 範囲 振り分け 役
	printf '見直しの種類: 最終レビュー\n確認するコミット: %s\n見る範囲: %s\n返事を待つ役: %s\n振り分け: %s\nコミットが合わず頼み直す役: %s\n前の回: final-1\n対象の PR: %s' "$sha" "$1" "$(mention "$3")" "$2" "$3" "$pr_url"
}
reset
ok_round
final_round final-1 "$sha" round-1 "$old..$sha"
result final-1 claude-principal ✅ "$old" なし
run final-1
expect_posted 頼み直し "$(final_retry_body "$old..$sha" 'Claude で足りる。工程: principal' claude-principal)" final-1
expect_calls watch-calls 'watch test-issue final-1 --agent-id orchestrator claude-principal'
expect_no_calls pick-calls
# 頼み直しの投稿に失敗したら、見張りを消してから 1 で終わる。
reset
ok_round
final_round final-1 "$sha" round-1 "$old..$sha"
result final-1 claude-principal ✅ "$old" なし
touch "$test_dir/post-fail"
run final-1
expect_failure 'コメントの投稿に失敗した'
expect_calls watch-calls $'watch test-issue final-1 --agent-id orchestrator claude-principal\nunwatch test-issue'
# 最上位の役以外の合わないものが混じれば、最終レビューの形では頼み直せないのでリーダーに任せる。
reset
base_round
result round-1 code-reviewer ✅ "$old" なし
result round-1 qa ✅ "$sha" なし
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$old" なし
run final-1
expect_leader '最上位の役以外の確認したコミットが合わない'
# 見る範囲: か 振り分け: の行が回になければ、書き写せないのでリーダーに任せる。
reset
ok_round
add final-1 orchestrator "見直しの種類: 最終レビュー"$'\n'"確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions claude-principal)"$'\n'"前の回: round-1"
result final-1 claude-principal ✅ "$old" なし
run final-1
expect_leader '見る範囲: か 振り分け: の行がない'
echo 'PASS review-next-decide: 最終レビューの回の返事は、マージの手順・修正・最終レビューの形の頼み直しに分ける'
