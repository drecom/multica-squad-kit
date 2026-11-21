#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-unexecuted-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# squad-review-next decide が、検証スキルが未記入で未実行の結果（未実行: 検証スキルが未記入）を、マークによらずリーダーに戻すことを確認する。
# 場面は docs/review-next-step.md の「検証が未実行の結果」と、テストの表の「decide の未実行の結果」。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

unexec_line='未実行: 検証スキルが未記入'
# 未実行の結果の本文。マークの行・設計への指摘の行は役の指示どおりの順で、未実行の行はその次に置く。
unexec_result() { # 回の ID 役 マーク コミット [未実行の行]
	add "unexec-$2-$n" "$2" $'/note\n返事の回: '"$1"$'\n確認したコミット: '"$4"$'\n'"$3 demo-$2-test: 検証できていません"$'\n設計への指摘: なし\n'"${5-$unexec_line}"$'\n\n足りない欄: 検証スキルの記入'
}
# 次の依頼を何も書かず、PR の確認も最上位の役の選びも流さずに、理由つきで終了 3 になった。
stops() { # 回の ID 理由に含まれる文字列
	run "$1"
	expect_leader "$2"
	expect_no_calls pr-watch-calls
	expect_no_calls pick-calls
	expect_no_calls compare-calls
}
# 表の 9 は PR の確認のあとなので、PR の見張りは流れる。次の依頼は書かず、最上位の役も選ばない。
stops_late() { # 回の ID 理由に含まれる文字列
	run "$1"
	expect_leader "$2"
	expect_no_calls pick-calls
}

# 未実行の行がある結果は、⚠️・❌・マークの行なしのどれでも、リーダーに戻す。修正・最終レビュー・マージの依頼は書かない。
for mark in ⚠️ ❌; do
	reset
	set_merge_roster
	base_round
	result round-1 qa ✅ "$sha" なし
	unexec_result round-1 code-reviewer "$mark" "$sha"
	set_principal_pick claude-principal
	stops round-1 '検証スキルが未記入で未実行（code-reviewer）'
done
# マークの行がない結果（確認したコミットと設計への指摘だけ）も未実行として戻す。
reset
set_merge_roster
base_round
result round-1 qa ✅ "$sha" なし
add unexec-nomark code-reviewer $'/note\n返事の回: round-1\n確認したコミット: '"$sha"$'\n設計への指摘: なし\n'"$unexec_line"
stops round-1 '検証スキルが未記入で未実行（code-reviewer）'
# 確認したコミットも設計への指摘もない結果も、未実行として戻す。
reset
set_merge_roster
base_round
result round-1 qa ✅ "$sha" なし
add unexec-bare code-reviewer $'/note\n返事の回: round-1\n'"$unexec_line"
stops round-1 '検証スキルが未記入で未実行（code-reviewer）'
# 設計への指摘: あり でも、修正より先に戻る理由は未実行になる。
reset
set_merge_roster
base_round
result round-1 qa ✅ "$sha" なし
unexec_result round-1 code-reviewer ❌ "$sha"
jq 'map(if (.id | startswith("unexec-code-reviewer")) then .content |= sub("設計への指摘: なし"; "設計への指摘: あり") else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
stops round-1 '検証スキルが未記入で未実行（code-reviewer）'
echo 'PASS review-next-decide: 未実行の行がある結果は、⚠️・❌・マークなしでも、修正・最終レビュー・マージの依頼を書かず理由つきで終了 3 になる'

# 未実行の役のキーを、組の順にすべて並べる。
reset
base_round
unexec_result round-1 qa ⚠️ "$sha"
unexec_result round-1 code-reviewer ⚠️ "$sha"
stops round-1 '検証スキルが未記入で未実行（code-reviewer、qa）'
[[ $(<"$test_dir/out") == '次の依頼を決められません: 検証スキルが未記入で未実行（code-reviewer、qa）' ]] || fail "理由が決めた形でない: $(<"$test_dir/out")"
# 未実行の行のある結果のあとに、同じ役が検証した結果を返せば、その最新の結果を使う。
reset
base_round
unexec_result round-1 code-reviewer ⚠️ "$sha"
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$sha" なし
set_principal_pick claude-principal
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
echo 'PASS review-next-decide: 未実行の役のキーを組の順にすべて並べ、同じ役の最新の結果が検証済みなら未実行にしない'

# 前の回: でたどった役の未実行の結果でも止まる。
reset
base_round
unexec_result round-1 code-reviewer ⚠️ "$sha"
result round-1 qa ✅ "$sha" なし
add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
add round-2 qa "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n'"コミットが合わず頼み直す役: qa"$'\n'"前の回: round-1"$'\n'"対象の PR: ${pr_url}"
result round-2 qa ✅ "$sha" なし
set_principal_pick claude-principal
stops round-2 '検証スキルが未記入で未実行（code-reviewer）'
echo 'PASS review-next-decide: 前の回: でたどった役の未実行の結果でも、理由つきで終了 3 になる'

# 読めない結果と未実行の結果が組にあれば、未実行の理由で止まる。読めない結果だけなら、今の理由で止まる。
reset
base_round
add unreadable code-reviewer $'/note\n返事の回: round-1\n確認したコミット: '"$sha"$'\n結論のマークがない'
unexec_result round-1 qa ⚠️ "$sha"
stops round-1 '検証スキルが未記入で未実行（qa）'
reset
base_round
result round-1 qa ✅ "$sha" なし
add unreadable code-reviewer $'/note\n返事の回: round-1\n確認したコミット: '"$sha"$'\n結論のマークがない'
stops round-1 '返事の結果が読めない: code-reviewer'
# 結果がない役があっても、未実行の結果があれば未実行の理由で止まる。
reset
base_round
unexec_result round-1 qa ⚠️ "$sha"
stops round-1 '検証スキルが未記入で未実行（qa）'
echo 'PASS review-next-decide: 読めない結果や結果のない役が組にあっても、未実行の結果があれば未実行の理由で止まる'

# 違う値の未実行: の行、字下げの行、引用の行は当たらず、今のとおり読む（✅ の結果なら最終レビューの依頼へ進む）。
for line in '未実行: ガードに止められた' '未実行: 検証スキルが未記入です' "  $unexec_line" "> $unexec_line" "\`$unexec_line\`"; do
	reset
	base_round
	result round-1 qa ✅ "$sha" なし
	unexec_result round-1 code-reviewer ✅ "$sha" "$line"
	set_principal_pick claude-principal
	run round-1
	expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
done
# 行末の空白だけは除いて読む。
reset
base_round
result round-1 qa ✅ "$sha" なし
unexec_result round-1 code-reviewer ⚠️ "$sha" "$unexec_line   "
stops round-1 '検証スキルが未記入で未実行（code-reviewer）'
echo 'PASS review-next-decide: 違う値の未実行: の行、字下げと引用の行は当たらず、行末の空白だけ除いて読む'

# 最上位の役の結果が未実行なら、同じコミットの最終レビューを済んでいないとする。マージの依頼は書かない。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" older
all_ok older "$sha" code-reviewer qa
unexec_result final-1 claude-principal ⚠️ "$sha"
stops_late round-1 '同じコミットの最終レビューが済んでいない: 検証スキルが未記入で未実行（claude-principal）'
# 最終レビューの回で流したときは、組に最上位の役の結果が入るので、表の 1 で止まる。
: >"$test_dir/pr-watch-calls"
stops final-1 '検証スキルが未記入で未実行（claude-principal）'
# マークが ✅ でも、最上位の役の未実行の行を優先する。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" older
unexec_result final-1 claude-principal ✅ "$sha"
stops_late round-1 '同じコミットの最終レビューが済んでいない: 検証スキルが未記入で未実行（claude-principal）'
echo 'PASS review-next-decide: 最上位の役の結果が未実行なら、同じコミットの最終レビューを済んでいないとして、マージを頼まず理由つきで終了 3 になる'

# 前の最終レビューの最上位の役の結果が未実行なら、見る範囲に使わず、PR の差分全体にする。
reset
final_round prev-final "$old" older-round
unexec_result prev-final claude-principal ⚠️ fedcba9
ok_round
set_principal_pick claude-principal
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
echo 'PASS review-next-decide: 未実行の最上位の役の結果は、見る範囲の前の結果に使わず、PR の差分全体にする'
