#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-fix-rework-test.sh で実行する。
# この部分は、手戻りの見直しの記録の読み方と、重要のマークでの止まり方を確認する。
# squad-review-next decide の判定のうち、修正の依頼・使用率の待ち・24 時間を超えた待ちの人間の呼びを確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

design_stop='設計の変更が実装を始めたあとで、マークも 手戻りの見直し: もない（手戻りの見直しの判断）'

# ---- 修正の依頼。
fix_body() { # 役 回数 指摘
	printf '%s PR の ❌ の指摘を直してください。\n前の回: round-1\n修正の依頼: %s 回目\n振り分け: Claude で足りる。工程: fix\n直す指摘: %s（結果は、この回の返事のコメントと PR のコメントにある）\n対象の PR: %s' "$(mention "$1")" "$2" "$3" "$pr_url"
}

# 見本・引用・読めない本文の行は、リーダーが書いても正式な記録にしない。
review_record='手戻りの見直し: 頼まない。合図: 設計の変更。理由: 見本'
for body in \
	$'記録の見本\n```text\n'"$review_record"$'\n```' \
	$'~~~text\n'"$review_record"$'\n~~~' \
	$'<!--\n'"$review_record"$'\n-->' \
	$'> 引用\n'"$review_record" \
	$'    '"$review_record" \
	$'- '"$review_record" \
	$'```text\n'"$review_record" \
	"$review_record"$'\n読めない\033本文'; do
	reset
	base_round
	add design-change human-1 $'設計の変更: 実装を始めたあと\n理由: テスト'
	add rework-example orchestrator "$body"
	result round-1 code-reviewer ❌ "$sha" なし
	result round-1 qa ✅ "$sha" なし
	run round-1
	expect_leader "$design_stop"
	expect_no_calls pick-calls
	expect_no_calls watch-calls
done
# /note の正式な行と、閉じた囲みの外の正式な行は認める。
for body in \
	$'/note\n'"$review_record" \
	$'/note '"$review_record" \
	$'```text\n見本\n```\n'"$review_record"; do
	reset
	base_round
	add design-change human-1 $'設計の変更: 実装を始めたあと\n理由: テスト'
	add rework-review orchestrator "$body"
	result round-1 code-reviewer ❌ "$sha" なし
	result round-1 qa ✅ "$sha" なし
	run round-1
	expect_posted 修正 "$(fix_body claude-fixer 1 code-reviewer)"
done
# リーダー以外が書いた 手戻りの見直し: の行では、止まる。
reset
base_round
add design-change human-1 $'設計の変更: 実装を始めたあと\n手戻りの見直し: 頼まない。合図: 設計の変更。理由: テスト'
add rework-review-other code-reviewer $'手戻りの見直し: 頼まない。合図: 設計の変更。理由: テスト'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$design_stop"
expect_no_calls pick-calls
# 重要のマーク: の行だけがあり、マークがないときも、止まる。
reset
base_round
add design-change human-1 $'設計の変更: 実装を始めたあと\n重要のマーク: 付けない（テスト）'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader "$design_stop"
expect_no_calls pick-calls
# マークがあれば、手戻りの見直し: の行がなくても、この規則では止まらない（マークの規則は最上位の役の結果で決まる）。
reset
set_issue_labels label-imp
add design-change human-1 $'設計の変更: 実装を始めたあと\n理由: テスト'
add design-r orchestrator $'見直しの種類: 設計と PR の見直し\n確認するコミット: '"$old"$'\n返事を待つ役: '"$(mentions claude-principal)"
result design-r claude-principal ✅ "$old" なし
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "マークがあり最上位の役の結果もあるのに修正でない: $(<"$test_dir/out")"
# マークがあり、最上位の役の結果がタスクにないなら、リーダーに任せる。
reset
set_issue_labels label-imp
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '最上位の役の結果がタスクにない'
expect_no_calls pick-calls
# マークがあっても、見直しの種類の回に最上位の役の結果があれば、修正に進む。
reset
set_issue_labels label-imp
add design-r orchestrator $'見直しの種類: 設計と PR の見直し\n確認するコミット: '"$old"$'\n返事を待つ役: '"$(mentions claude-principal)"
result design-r claude-principal ✅ "$old" なし
base_round
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "最上位の役の結果があるのに修正でない: $(<"$test_dir/out")"
echo 'PASS review-next-decide: ❌ があれば、修正の依頼がないときだけ書き、2 回目からはリーダーを起こす'
