#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-fix-test.sh で実行する。
# この部分は、修正の依頼を書く条件と、手戻りの見直しで止まる場面の前半を確認する。
# squad-review-next decide の判定のうち、修正の依頼・使用率の待ち・24 時間を超えた待ちの人間の呼びを確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 修正の依頼。
fix_body() { # 役 回数 指摘
	printf '%s PR の ❌ の指摘を直してください。\n前の回: round-1\n修正の依頼: %s 回目\n振り分け: Claude で足りる。工程: fix\n直す指摘: %s（結果は、この回の返事のコメントと PR のコメントにある）\n対象の PR: %s' "$(mention "$1")" "$2" "$3" "$pr_url"
}

reset
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ❌ "$sha" なし
run round-1
expect_posted 修正 "$(fix_body claude-fixer 1 'code-reviewer、qa')"
expect_calls pick-calls 'pick test-issue fix --round round-1'
expect_no_calls watch-calls
# 2-1: ✅ の結果に前からある不具合の件数だけがあるときは、修正の依頼を書かず、マージの依頼へ進む。
reset
set_roster orchestrator code-reviewer qa
base_round
result round-1 code-reviewer ✅ "$sha" なし '前からある不具合 2 件'
result round-1 qa ✅ "$sha" なし
merge_depth='読む深さ: このコメントと PR の注意（重要でない。注意なし、残した指摘 0 件、前からある不具合 2 件）'
merge_pre='前からある不具合: 2 件（demo-code-reviewer-test 2 件）'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "コンフリクト: MERGEABLE head: $sha" '✅ demo-code-reviewer-test: 前からある不具合 2 件' '✅ demo-qa-test: 結果')"
expect_no_calls pick-calls
echo 'PASS review-next-decide: ✅ で前からある不具合の件数だけの結果は、修正の依頼を書かずマージの依頼へ進む'
# 自動で書くのは、タスクに 修正の依頼: の行がないときの 1 回目だけ。1 つ以上あれば、2 回目からとして書かずにリーダーを起こす。
second_reason='修正の依頼が 2 回目から（同じ誤りと同じ部品はリーダーが判断する）'
reset
base_round
add fix-1 orchestrator $'修正の依頼: 1 回目\n前の回: older-1'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
expect_no_calls watch-calls
reset
base_round
add fix-1 orchestrator $'修正の依頼: 1 回目\n前の回: older-1'
add fix-2 orchestrator $'修正の依頼: 2 回目\n前の回: older-2'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ❌ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
# 3 つあるときは、手戻りの見直しか続行の確認の理由で止まる。
reset
base_round
for i in 1 2 3; do add "fix-$i" orchestrator "修正の依頼: $i 回目"$'\n'"前の回: older-$i"; done
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '修正の依頼が 3 回に達している（手戻りの見直しか続行の確認）'
[[ $(<"$test_dir/out") != *'（共通 4）'* ]] || fail "古い理由の行のまま: $(<"$test_dir/out")"
[[ $(<"$test_dir/out") != *"$second_reason"* ]] || fail "3 回の理由に 2 回目からの理由が混ざった: $(<"$test_dir/out")"
expect_no_calls pick-calls
# コンフリクトや CI の失敗の依頼も 修正の依頼: の行なので、そのあとの最初の ❌ もリーダーに任せる。
reset
base_round
add conflict-fix orchestrator $'コンフリクトを解消してください。\n修正の依頼: 1 回目\n前の回: older-1'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
# codex-fixer が再現した 4 つの場面。今の decide は、どれも自動の依頼を書いていた。
# マークのあるタスクの 7 回目の前（修正の依頼が 6 つ）。最上位の役の結果はあるので、マークの規則には当たらない。
reset
set_issue_labels label-imp
add design-r orchestrator $'見直しの種類: 設計と PR の見直し\n確認するコミット: '"$old"$'\n返事を待つ役: '"$(mentions claude-principal)"
result design-r claude-principal ✅ "$old" なし
for i in 1 2 3 4 5 6; do add "fix-$i" orchestrator "修正の依頼: $i 回目"$'\n'"前の回: older-$i"; done
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
# 同じ部品の 2 回目（修正の依頼が 1 つ。前の依頼に 同じ部品: がある）。
reset
base_round
add fix-1 orchestrator $'修正の依頼: 1 回目\n同じ部品: decide の修正の依頼\n前の回: older-1'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
# 同じ部品の 3 回目（修正の依頼が 2 つ）。
reset
base_round
add fix-1 orchestrator $'修正の依頼: 1 回目\n同じ部品: decide の修正の依頼\n前の回: older-1'
add fix-2 orchestrator $'修正の依頼: 2 回目\n同じ部品: decide の修正の依頼\n前の回: older-2'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
# 同じ誤りの 2 回目（修正の依頼が 1 つ。前の依頼に 同じ誤り: がある）。
reset
base_round
add fix-1 orchestrator $'修正の依頼: 1 回目\n同じ誤り: 同じ入力で同じ部品が落ちる\n前の回: older-1'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$second_reason"
expect_no_calls pick-calls
# 設計の変更が実装を始めたあとで、マークもリーダーの 手戻りの見直し: の行もないなら、リーダーに任せる。
design_stop='設計の変更が実装を始めたあとで、マークも 手戻りの見直し: もない（手戻りの見直しの判断）'
reset
base_round
add design-change human-1 $'設計の変更: 実装を始めたあと\n理由: テスト'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$design_stop"
expect_no_calls pick-calls
# リーダーが 手戻りの見直し: の行を書いていれば、止まらずに 1 回目の修正の依頼を書く。
reset
base_round
add design-change human-1 $'設計の変更: 実装を始めたあと\n理由: テスト'
add rework-review orchestrator $'手戻りの見直し: 頼まない。合図: 設計の変更。理由: 見直しの結果が PR にある'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "リーダーの 手戻りの見直し: があるのに修正でない: $(<"$test_dir/out")"
