#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-route-test.sh で実行する。
# squad-review-next decide の判定のうち、回の種類・返事の読み方・設計の見直しの回を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 早い止まり: 回の種類が決められない、返事が読めない。ネットワークを使わずにリーダーへ任せる。
add round-1 orchestrator $'見直しの種類: 設計の見直し\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions claude-principal)"
run round-1
expect_leader '設計の見直しの回はリーダーが扱う'
expect_no_calls pr-watch-calls
reset
add round-1 orchestrator $'見直しの種類: 設計と PR の見直し\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions claude-principal)"
run round-1
expect_leader '設計の見直しの回はリーダーが扱う'
reset
add round-1 orchestrator $'見直しの種類: 謎の回\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions qa)"
run round-1
expect_leader '回の種類が分からない'
reset
add round-1 orchestrator $'何でもない回\n確認するコミット: '"$sha"
run round-1
expect_leader '回を認められない（返事を待つ役: の行'
reset
add round-1 orchestrator $'観点: qa（テスト）\n確認するコミット: '"$sha"$'\n返事を待つ役: なし'
run round-1
expect_leader '回を認められない（返事を待つ役: の行'
reset
add round-1 orchestrator $'観点: qa（テスト）\n確認するコミット: 未定\n返事を待つ役: '"$(mentions qa)"
run round-1
expect_leader '16 進でない'
reset
review_round round-1 "$sha" code-reviewer qa
result round-1 code-reviewer ✅ "$sha" なし
run round-1
expect_leader '返事の結果がない: qa'
expect_no_calls pr-watch-calls
reset
base_round
add res-early qa $'返事の回: round-1\n確認したコミット: 0123456\n✅ demo-qa-test: 結果\n設計への指摘: なし' ""
run round-1
expect_leader '返事の結果がない: code-reviewer'
echo 'PASS review-next-decide: 回の種類が決められない、または返事がそろわないときは、PR を見ずにリーダーに任せる'

# ---- 返事が読めない値は、前の読める返事に戻らず止まる。
unreadable() { # 本文
	reset
	base_round
	result round-1 code-reviewer ✅ "$sha" なし
	result round-1 qa ✅ "$sha" なし
	add "bad-$n" qa "$1"
	run round-1
	expect_leader '返事の結果が読めない: qa'
}
unreadable $'返事の回: round-1\n設計への指摘: なし\n✅ demo-qa-test: 結果'
unreadable $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: たぶん\n✅ demo-qa-test: 結果'
unreadable $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: なし\n結果です'
unreadable $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: なし\n✅ 結果'
echo 'PASS review-next-decide: 最新の返事が読めなければ、前の読める返事に戻らずリーダーに任せる'

# ---- 結果の先頭の行。役の指示（squad-handoff の「レビューと E2E の返事を返す」）どおりの順は読め、文章やメンションが先頭の結果は読めない。
# 指示どおりの順: /note、返事の回、確認したコミット、マークの行、設計への指摘。全員がこの形で返ると、次の依頼まで決まる。
reset
ok_round
run round-1
expect_status 0
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
# 読む行の 1 つ目がマークの行でなく文章のとき、結果は読めない。同じ結果でも、マークの行を先頭にすると読める（上の ok_round）。
unreadable $'/note\n返事の回: round-1\n確認したコミット: 0123456\n全員そろいました。✅ demo-qa-test: 結果\n設計への指摘: なし'
unreadable $'/note\n返事の回: round-1\n確認したコミット: 0123456\n'"$(mention orchestrator) ✅ demo-qa-test: 結果"$'\n設計への指摘: なし'
unreadable $'/note\n返事の回: round-1\n指摘はありませんでした。\n確認したコミット: 0123456\n✅ demo-qa-test: 結果\n設計への指摘: なし'
echo 'PASS review-next-decide: 指示どおりの順の結果は読めて次の依頼が決まり、文章やメンションが先頭の結果は読めずリーダーに任せる'

# ---- 設計の見直しの回は、返事が ✅・コードの指摘・設計への指摘のどれでも、何も書かずにリーダーに任せる。
for kind in '設計の見直し' '設計と PR の見直し'; do
	for reply in '✅ 指摘なし|なし' '❌ コードの指摘|なし' '✅ 設計に指摘|あり'; do
		reset
		add pr-made orchestrator "PR を作りました ${pr_url}" ""
		add round-1 orchestrator "見直しの種類: ${kind}"$'\n'"確認するコミット: ${sha}"$'\n'"返事を待つ役: $(mentions claude-principal)"
		result round-1 claude-principal "${reply%%|*}" "$sha" "${reply##*|}"
		run round-1
		expect_leader '設計の見直しの回はリーダーが扱う'
	done
done
echo 'PASS review-next-decide: 設計の見直しの回は、返事の中身によらず書かずにリーダーに任せる'
