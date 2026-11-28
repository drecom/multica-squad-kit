#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-test.sh で実行する。
# この部分は、紐付いているとき・いないときのマージの依頼の確認と、unlinked の出力を確認する。
# squad-review-next decide のマージの依頼（確認の流れ・規則の登録・コメント・止まる値）を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

unlinked() { printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"; }
conf_line="コンフリクト: MERGEABLE head: $sha"
final_ok() { # 最終レビューまで済んだ状態にする。回は final-1
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
}
lines_all=('✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')

# ---- 紐付いているとき。確認は head・コンフリクトだけで、CI は読まず、コンフリクトの規則だけを入れ直す。
reset
final_ok
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "${lines_all[@]}")" final-1
expect_calls pr-watch-calls $'link-check test-issue final-1\nconflicts-check test-issue\nconflicts test-issue --leader orchestrator'
expect_calls head-calls 'pr view 7 --repo demo/project --json headRefOid'
echo 'PASS review-next-decide: 紐付いているマージの依頼は、head とコンフリクトを確認し、CI を読まず、コンフリクトの規則を入れてから書く'

# ---- 紐付いていないとき。その場の CI を読み、unlinked を入れ、紐付けの案内と見張りの行を添える。
reset
final_ok
unlinked
printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha:0:7}: 成功" "${lines_all[@]}" \
	"紐付いていないので、マージのあとにタスクを \`done\` にしてほしい（または先に紐付けてほしい）。PR: \`${pr_url}\`" \
	'見張り: 1 時間おき、2026-11-17 まで')" final-1
expect_calls pr-watch-calls $'link-check test-issue final-1\nround-pr test-issue final-1\nconflicts-check test-issue\nci-held test-issue final-1\nci-now test-issue orchestrator final-1\nconflicts test-issue --leader orchestrator\nunlinked test-issue final-1 --leader orchestrator'
echo 'PASS review-next-decide: 紐付いていないマージの依頼は、その場の CI を読み、unlinked を入れて、紐付けの案内と見張りの行を添える'

# 紐付けの失敗の段落と連携の案内は、PR を作った役の引き継ぎから写す。
reset
final_ok
unlinked
n=0
comments=$(jq 'del(.[] | select(.id == "pr-made"))' "$test_dir/comments.json")
echo "$comments" >"$test_dir/comments.json"
add pr-made claude-implementer "PR を作りました ${pr_url}"$'\n\n紐付けの失敗: PR をタスクに紐付けられなかった。\n404 で待ち切れなかったため、連携を確認してほしい。' ""
run final-1
expect_status 0
body=$(posted_body)
[[ $body == *$'\n紐付けの失敗: PR をタスクに紐付けられなかった。'* ]] || fail "紐付けの失敗の段落がない: $body"
echo 'PASS review-next-decide: 紐付けの失敗の段落を、PR を作った役の引き継ぎから写す'

# ---- unlinked の出力。
reset
final_ok
unlinked
printf '紐付け: 紐付いていない pr: 不明\n' >"$test_dir/unlinked-out"
run final-1
expect_leader '紐付け: 紐付いていない'
reset
final_ok
unlinked
echo 1 >"$test_dir/unlinked-status"
run final-1
expect_status 0
body=$(posted_body)
[[ $body == *'登録できませんでした。ホストでセットアップを流し直してください。'* ]] || fail "登録できなかった旨がない: $body"
[[ $body != *'見張り:'* ]] || fail "見張りの行を書いてはいけない: $body"
reset
final_ok
unlinked
printf '{"id": "rule-1"}\n' >"$test_dir/unlinked-out"
run final-1
expect_status 0
[[ $(posted_body) == *'登録できませんでした。ホストでセットアップを流し直してください。'* ]] || fail "見張りの行がないのに、登録できなかった旨がない: $(posted_body)"
# 紐付いているときは、unlinked を流さない。
reset
final_ok
run final-1
expect_status 0
expect_call_lacks pr-watch-calls unlinked
expect_call_lacks pr-watch-calls ci-now
expect_call_lacks pr-watch-calls ci-held
echo 'PASS review-next-decide: unlinked は、紐付け: の行なら止まり、0 以外や行なしなら見張りなしで進み、紐付いていれば流さない'
