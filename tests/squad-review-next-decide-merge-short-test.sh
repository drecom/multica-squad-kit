#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-short-test.sh で実行する。
# squad-review-next decide の短い道のマージの依頼（head の照合・最終レビューなしの行・生成物の読み戻し）を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

conf_line="コンフリクト: MERGEABLE head: $sha"

# 短い道の head は、最上位の役の有無によらず、組の確認するコミットと照合する。
for with_principal in yes no; do
	reset
	if [[ $with_principal == yes ]]; then set_merge_roster; else set_roster orchestrator code-reviewer qa; fi
	ok_round
	add path orchestrator '道: 短い'
	run round-1
	expect_merge_posted "$(merge_body round-1 "$sha" '最終レビューなし（短い道）' "$conf_line" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
	expect_no_calls pick-calls
	expect_calls pr-watch-calls $'link-check test-issue round-1\nconflicts-check test-issue\nconflicts test-issue --leader orchestrator'
	# head が進んだときはマージを頼まず、古い組を根拠に進めない。
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/status-calls"
	printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
	run round-1
	expect_leader "PR の今の head（${old}）が組の確認するコミット（${sha}）と違う"
done
echo 'PASS review-next-decide: 短い道は組のコミットと head が合うときだけ進み、最終レビューなしの行を添える'

# 新しい head の組。回 round-2 に、全員が ✅ で返る。PR の今の head も新しい値にする。
new_head_pair() {
	review_round round-2 "$old" code-reviewer qa
	all_ok round-2 "$old" code-reviewer qa
	printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
	printf 'コンフリクト: MERGEABLE head: %s\n' "$old" >"$test_dir/conf-out"
}
# 生成から次の組まで通す。短い道の decide が書いたマージの依頼を、リーダーの作者で記録に足しても、短い道のままである。
reset
set_merge_roster
ok_round
add path orchestrator '道: 短い'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" '最終レビューなし（短い道）' "$conf_line" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
notice=$(posted_body)
[[ $notice != *$'\n道:'* && $notice != 道:* ]] || fail "マージの依頼に道: で始まる行がある: $notice"
: >"$test_dir/posted.jsonl"
: >"$test_dir/status-calls"
add merge-notice orchestrator "$notice" round-1
new_head_pair
run round-2
expect_merge_posted "$(merge_body round-2 "$old" '最終レビューなし（短い道）' "コンフリクト: MERGEABLE head: $old" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')" round-2
expect_no_calls pick-calls
echo 'PASS review-next-decide: 生成したマージの依頼を記録に足しても短い道のままで、新しい head の組は最終レビューなしでマージへ進む'
# 前の形の行は、不明な値として短い道を外し、次の組で最終レビューを頼む。
reset
set_merge_roster
ok_round
add path orchestrator '道: 短い'
add merge-old orchestrator "$(merge_body round-1 "$sha" '道: 短い（最終レビューなし）' "$conf_line" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')" round-1
new_head_pair
run round-2
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー\n依頼: posted-comment' ]] || fail "前の形の行で最終レビューを頼んでいない: $(<"$test_dir/out")"
[[ $(posted_body) == '見直しの種類: 最終レビュー'$'\n''確認するコミット: '"$old"$'\n'* ]] || fail "最終レビューの依頼の本文が違う: $(posted_body)"
echo 'PASS review-next-decide: 前の形のマージの依頼の行は短い道を外し、次の組で最終レビューを頼む'
