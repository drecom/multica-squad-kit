#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-retry-test.sh で実行する。
# squad-review-next decide の判定のうち、頼み直し・設計への指摘・診断の回を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 頼み直し。確認したコミットが合わない役だけを、同じコミットの新しい回で頼み直す。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s\nコミットが合わず頼み直す役: qa\n前の回: round-1\n対象の PR: %s' "$sha" "$(mention qa)" "$pr_url")"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator qa'
expect_no_calls pick-calls
# 頼み直しでも、前の回の列挙の行を PR の行の後ろに、同じ順で写す。
reset
base_round
jq 'map(if .id == "round-1" then .content += "\n列挙を頼む部品: src/cart/Badge.tsx:formatCount\n列挙を頼む部品: src/cart/CartIcon.tsx:CartIcon" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new"
mv "$test_dir/comments.new" "$test_dir/comments.json"
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s\nコミットが合わず頼み直す役: qa\n前の回: round-1\n対象の PR: %s\n列挙を頼む部品: src/cart/Badge.tsx:formatCount\n列挙を頼む部品: src/cart/CartIcon.tsx:CartIcon' "$sha" "$(mention qa)" "$pr_url")"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator qa'
expect_no_calls pick-calls
# 先頭のコミットの一部（7 文字以上の前方一致）は合う。大文字でも合う。
reset
ok_round
result round-1 qa ✅ 0123456789ABCDEF なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "前方一致を合うと読んでいない: $(<"$test_dir/out")"
# 6 文字は短すぎるので合わない。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ 012345 なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s\nコミットが合わず頼み直す役: qa\n前の回: round-1\n対象の PR: %s' "$sha" "$(mention qa)" "$pr_url")"
# 2 つの役が合わなければ、キーを「、」でつなぎ、見張りに両方を渡す。
reset
base_round
result round-1 code-reviewer ✅ "$old" なし
result round-1 qa ✅ "$old" なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s %s\nコミットが合わず頼み直す役: code-reviewer、qa\n前の回: round-1\n対象の PR: %s' "$sha" "$(mention code-reviewer)" "$(mention qa)" "$pr_url")"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator code-reviewer qa'
echo 'PASS review-next-decide: 確認したコミットが合わない役だけを、同じコミットの新しい回で頼み直す'

# 頼み直しの回の返事が合えば、前の回の返事とあわせて次へ進む（ここでは最終レビュー）。
retry_round() { # 回の ID 役 前の回
	add "$1" orchestrator "確認するコミット: $sha"$'\n'"返事を待つ役: $(mention "$2")"$'\n'"コミットが合わず頼み直す役: $2"$'\n'"前の回: $3"$'\n'"対象の PR: ${pr_url}"
}
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
retry_round round-2 qa round-1
result round-2 qa ✅ "$sha" なし
set_principal_pick claude-principal
run round-2
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体' | sed 's/前の回: round-1/前の回: round-2/')" round-2
# 前の回の返事の古い（合わない）ものは、頼み直した役の分を新しい回の返事に置き換えるので読み直さない。
# 頼み直した回でも合わなければ、リーダーに任せる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
retry_round round-2 qa round-1
result round-2 qa ✅ "$old" なし
run round-2
expect_leader '前の回でも合わなかった役がいる: qa'
# 頼み直しの回の返事が ❌ なら、前の回の ✅ とあわせて修正の依頼になる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
retry_round round-2 qa round-1
result round-2 qa ❌ "$sha" なし
run round-2
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "修正の依頼でない: $(<"$test_dir/out")"
grep -q '直す指摘: qa（' <<<"$(posted_body)" || fail "直す指摘が qa でない: $(posted_body)"
# 名簿にない役の返事が合わなければ、頼み直せないのでリーダーに任せる。
reset
add pr-made orchestrator "PR を作りました ${pr_url}" ""
add round-1 orchestrator "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa) [@ghost](mention://agent/ghost)"$'\n'"観点: qa（テスト）"
result round-1 qa ✅ "$sha" なし
result round-1 ghost ✅ "$old" なし
run round-1
expect_leader '名簿にない: ghost'
echo 'PASS review-next-decide: 返事の組は前の回をたどって作り、頼み直した回でも合わなければリーダーに任せる'

# ---- 設計への指摘: あり は、PR の確認のあとでリーダーに任せる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ⚠️ "$sha" あり
run round-1
expect_leader '設計への指摘: あり（qa）'
expect_call_has pr-watch-calls 'link-check test-issue round-1'
# 設計への指摘: あり が ❌ と同じ回にあっても、修正より先にリーダーに任せる。
reset
base_round
result round-1 code-reviewer ❌ "$sha" あり
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '設計への指摘: あり（code-reviewer）'
expect_no_calls pick-calls
# 紐付けの判定は設計への指摘より先なので、紐付けが止まる値ならその理由で止まる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" あり
result round-1 qa ✅ "$sha" なし
echo '紐付け: 別のタスクに紐付いている pr: https://github.com/demo/project/pull/7' >"$test_dir/link-out"
run round-1
expect_leader '紐付け: 別のタスクに紐付いている'
echo 'PASS review-next-decide: 設計への指摘があれば、修正より先にリーダーに任せる'


# ---- 診断の回は、返事が ✅・コードの指摘・設計への指摘のどれでも、何も書かずにリーダーに任せる。PR の確認も呼ばない。
for reply in '✅ 指摘なし|なし' '❌ 診断の結果|なし' '✅ 設計に指摘|あり'; do
	reset
	add pr-made orchestrator "PR を作りました ${pr_url}" ""
	add diag-1 orchestrator $'見直しの種類: 診断\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions claude-principal)"$'\n診断の依頼: 1 回目。失敗: テスト foo'
	result diag-1 claude-principal "${reply%%|*}" "$sha" "${reply##*|}"
	run diag-1
	expect_leader '診断の回はリーダーが扱う'
	expect_no_calls pr-watch-calls
	expect_no_calls pick-calls
done
# 診断の回の最上位の役の結果は、マークのあるタスクの「最上位の役の結果」に数えない。診断だけが返っているタスクの ❌ は、設計と PR の見直しのためにリーダーに任せる。
reset
set_issue_labels label-imp
add diag-1 orchestrator $'見直しの種類: 診断\n確認するコミット: '"$old"$'\n返事を待つ役: '"$(mentions claude-principal)"
result diag-1 claude-principal ✅ "$old" なし
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '最上位の役の結果がタスクにない'
expect_no_calls pick-calls
echo 'PASS review-next-decide: 診断の回は何も書かずにリーダーに任せ、診断の回の結果をマークのあるタスクの最上位の役の結果に数えない'

# ---- 診断の依頼だけがあるタスクの ❌ は、修正の依頼に数えない。1 回目の修正の依頼を書く。
reset
add diag orchestrator $'診断の依頼: 1 回目。失敗: 同じ誤り テスト foo\n直す役: 修正の役'
add recount orchestrator $'数え直し: 同じ誤り テスト foo。理由: 直った（同じテストが通った）'
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ❌ "$sha" なし
run round-1
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "修正の依頼でない: $(<"$test_dir/out")"
grep -qx '修正の依頼: 1 回目' <<<"$(posted_body)" || fail "診断の依頼が数えられた: $(posted_body)"
echo 'PASS review-next-decide: 診断の依頼を修正の依頼に数えない'
