#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-check-test.sh で実行する。
# この部分は、head の照合・QA の確認・状態と書けないときを確認する。
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

# ---- head の照合。
reset
final_ok
printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
run final-1
expect_leader "PR の今の head（${old}）が最終レビューの確認したコミット（${sha}）と違う"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
# 確認したコミットが短い SHA でも、head の先頭と合えば一致とする。
reset
final_ok
add res-short claude-principal $'/note\n返事の回: final-1\n確認したコミット: '"${sha:0:7}"$'\n✅ demo-claude-principal-test: 結果\n設計への指摘: なし' final-1
run final-1
expect_status 0
reset
final_ok
echo 1 >"$test_dir/head-fail"
run final-1
expect_failure 'PR の今の head を読めない'
reset
final_ok
printf '{"headRefOid": "short"}\n' >"$test_dir/head.json"
run final-1
expect_failure 'PR の今の head を読めない'
# 最上位の役が名簿になければ照合せず、マージの依頼の head は PR の今の head にする。
reset
set_roster orchestrator code-reviewer qa
ok_round
printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
run round-1
expect_merge_posted "$(merge_body round-1 "$old" "コンフリクト: MERGEABLE head: $sha" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
echo 'PASS review-next-decide: 最上位の役があれば、PR の今の head を最終レビューの確認したコミットと照合し、一致しなければ書かない'

# ---- QA の確認。QA が選ばれる変更なのに、組に QA の結果がなければ、確認を流さずにリーダーに任せる。
reset
set_merge_roster
base_round_without_qa() {
	add pr-made orchestrator "PR を作りました ${pr_url}" ""
	review_round round-1 "$sha" code-reviewer
	all_ok round-1 "$sha" code-reviewer
	set_principal_pick claude-principal
}
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
expect_no_calls pr-watch-calls
expect_no_calls head-calls
# 画面に触れない変更なら、QA が選ばれないので、結果がなくても進む。
set_changed_files README.md
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" '✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果')" final-1
# 画面に触れる変更なら、QA が選ばれるので、結果がなければ止まる。
reset
set_merge_roster
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
set_changed_files web/App.tsx
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
# マーク「重要」があれば、有効な観点がすべて選ばれる。
reset
set_merge_roster
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
set_changed_files README.md
set_issue_labels label-imp
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
# QA の役が名簿になければ、確認しない。
reset
set_roster orchestrator code-reviewer claude-principal
add pr-made orchestrator "PR を作りました ${pr_url}" ""
review_round round-1 "$sha" code-reviewer
all_ok round-1 "$sha" code-reviewer
set_principal_pick claude-principal
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "QA の役がないのに止まっている: $(<"$test_dir/out")"
echo 'PASS review-next-decide: QA が選ばれる変更で組に QA の結果がなければ、確認を流さずにリーダーに任せる'

# ---- 状態と書けないとき。
reset
final_ok
touch "$test_dir/post-fail"
run final-1
expect_failure 'コメントの投稿に失敗した'
expect_no_calls status-calls
echo 'PASS review-next-decide: 書けないときはタスクの状態を変えない'
