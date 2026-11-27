#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-ciwait-fail-test.sh で実行する。
# この部分は、CI の失敗・書かない行・ci-wait に渡す規則・保留した失敗の読み方を確認する。
# squad-review-next decide のマージの前の CI の待ち（見張り役がある構成の ci-wait の行の分け方・CI の待ちの記録・起きた規則の受け渡し）を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

conf_line="コンフリクト: MERGEABLE head: $sha"
lines_all=('✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')
ci_final_ok() { # 見張り役がある構成で、最終レビューまで済んだ状態にする。回は final-1
	set_ci_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
}
ciwait() { printf '%s\n' "$@" >"$test_dir/ciwait-out"; }

# ---- 失敗あり、書かない行、読めない出力。
reset
ci_final_ok
ciwait "CI ${sha}: 失敗あり" lint
run final-1
expect_leader "CI ${sha}: 失敗あり"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
for line in "CI ${sha}: マージを依頼済み" "CI ${sha}: PR がマージ済みか閉じている" 'CI 待ち: タスクが終わっている' 'CI 待ち: 終わった規則で起きた'; do
	reset
	ci_final_ok
	ciwait "$line"
	run final-1
	expect_status 0
	[[ $(<"$test_dir/out") == "次の依頼: 書かない（${line}）" ]] || fail "標準出力が違う: $(<"$test_dir/out")"
	expect_nothing_written
	expect_call_lacks pr-watch-calls 'conflicts test-issue'
done
reset
ci_final_ok
echo 1 >"$test_dir/ciwait-status"
run final-1
expect_failure 'CI の待ちを流せない'
reset
ci_final_ok
: >"$test_dir/ciwait-out"
run final-1
expect_failure 'CI の待ちの行を読めない'
reset
ci_final_ok
ciwait "CI ${sha}: 不明な状態"
run final-1
expect_failure 'CI の待ちの行を読めない'
reset
ci_final_ok
echo 1 >"$test_dir/ci-status"
run final-1
expect_leader 'CI の見張りを入れられない'
expect_call_lacks pr-watch-calls ci-wait
echo 'PASS review-next-decide: 失敗ありはリーダーに任せ、書かない行は何も書かず、読めない出力は失敗にする'

# ---- 起きた規則は、ci-wait の最後の引数に渡す。
reset
ci_final_ok
run final-1 rule-9
expect_status 0
expect_call_has pr-watch-calls 'ci-wait test-issue orchestrator final-1 rule-9'
reset
ci_final_ok
run final-1
expect_call_has pr-watch-calls 'ci-wait test-issue orchestrator final-1'
echo 'PASS review-next-decide: 第 3 引数の起きた規則を、ci-wait の最後の引数に渡す'

# ---- 保留した失敗を読む条件。見張り役があっても、最終レビューの回と、CI を待っているタスクでは読まない。
reset
set_roster orchestrator code-reviewer qa ci-monitor
ok_round
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
run round-1
expect_leader '保留した CI の失敗がある'
reset
set_roster orchestrator code-reviewer qa ci-monitor
ok_round
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
set_metadata ci_wait_head "$sha"
run round-1
expect_status 0
expect_call_lacks pr-watch-calls ci-held
expect_call_has pr-watch-calls 'ci-wait test-issue orchestrator round-1'
reset
ci_final_ok
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
run final-1
expect_status 0
expect_call_lacks pr-watch-calls ci-held
echo 'PASS review-next-decide: 保留した失敗は、CI を待っているタスクと、見張り役がある構成の最終レビューの回では読まない'

# ---- 見張り役がない構成は、ci-wait を流さない。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_status 0
expect_call_lacks pr-watch-calls ci-wait
expect_call_lacks pr-watch-calls 'ci test-issue'
echo 'PASS review-next-decide: 見張り役がない構成は、ci-wait を流さない'
