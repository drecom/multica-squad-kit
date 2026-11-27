#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-conflict-test.sh で実行する。
# この部分は、規則の登録とコンフリクトと CI の止まる値、コンフリクトで止まったあとの再開を確認する。
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

# ---- 規則の登録とコンフリクトと CI の止まる値。止まるときは、書かず、状態も変えない。
reset
final_ok
echo 1 >"$test_dir/conflicts-status"
run final-1
expect_leader 'コンフリクトの規則を入れ直せない'
reset
final_ok
printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
run final-1
expect_leader 'コンフリクト: CONFLICTING'
expect_call_lacks pr-watch-calls 'conflicts test-issue'
reset
final_ok
unlinked
printf 'CI %s: 失敗あり（lint）\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_leader "CI ${sha:0:7}: 失敗あり（lint）"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
reset
final_ok
unlinked
printf 'CI %s: 失敗あり（テスト）\n' "${sha:0:7}" >"$test_dir/held-out"
run final-1
expect_leader '保留した CI の失敗がある'
reset
final_ok
unlinked
echo 1 >"$test_dir/cinow-status"
run final-1
expect_leader 'CI のその場の確認が 0 以外で終わった'
# コンフリクトの行が出なければ、未確認として書く。
reset
final_ok
: >"$test_dir/conf-out"
run final-1
expect_status 0
[[ $(posted_body) == *$'\nコンフリクト: 未確認 head: '"$sha"$' 理由: 判定の行が出なかった\n'* ]] || fail "未確認の行がない: $(posted_body)"
echo 'PASS review-next-decide: マージの依頼の確認で止まる値は、書かず、状態も変えずにリーダーに任せる'

# ---- コンフリクトで止まったあとの再開。止まった回は何も書かないので、解消のあとに同じ回で流し直せば、conflicts と、紐付いていないときの unlinked が登録される。
# 同じ回の流し直しで、最上位の役の有無と紐付けの有無の 4 つの組のどれでも同じ登録が揃う。手で流す経路の文は agent-templates-test.sh が確認する。
resume_after_conflict() { # 構成（principal|plain） 紐付け（linked|unlinked）
	local kind=$1 link=$2 round
	reset
	if [[ $kind == principal ]]; then
		final_ok
		round=final-1
	else
		set_roster orchestrator code-reviewer qa
		ok_round
		round=round-1
	fi
	[[ $link == linked ]] || unlinked
	[[ $link == linked ]] || printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
	printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
	run "$round"
	expect_leader 'コンフリクト: CONFLICTING'
	expect_call_lacks pr-watch-calls 'conflicts test-issue'
	expect_call_lacks pr-watch-calls 'unlinked test-issue'
	printf 'コンフリクト: MERGEABLE head: %s\n' "$sha" >"$test_dir/conf-out"
	run "$round"
	expect_status 0
	[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "再開しても依頼が書かれない: $(<"$test_dir/out")"
	expect_call_has pr-watch-calls 'conflicts test-issue --leader orchestrator'
	if [[ $link == linked ]]; then
		expect_call_lacks pr-watch-calls 'unlinked test-issue'
	else
		grep -q -- "^unlinked test-issue ${round} --leader orchestrator" "$test_dir/pr-watch-calls" || fail "unlinked が登録されない: $(<"$test_dir/pr-watch-calls")"
	fi
	[[ $(grep -c -- '^conflicts test-issue' "$test_dir/pr-watch-calls") == 1 ]] || fail "conflicts の登録が 1 回でない: $(<"$test_dir/pr-watch-calls")"
}
for kind in principal plain; do
	for link in linked unlinked; do
		resume_after_conflict "$kind" "$link"
	done
done
echo 'PASS review-next-decide: コンフリクトで止まったあと、解消してから同じ回を流し直すと、最上位の役の有無と紐付けの有無によらず conflicts（と、紐付いていなければ unlinked）を登録する'
