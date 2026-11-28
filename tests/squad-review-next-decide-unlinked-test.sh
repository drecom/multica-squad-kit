#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-unlinked-test.sh で実行する。
# squad-review-next decide の判定のうち、紐付いていない PR の確認（その場の CI・コンフリクト）・書けないときの失敗・引数を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# 紐付いていないときの確認（表の 4）。
unlinked() { printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"; }
reset
set_roster orchestrator code-reviewer qa claude-principal
ok_round
unlinked
set_principal_pick claude-principal
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_call_has pr-watch-calls 'ci-held test-issue round-1'
expect_call_has pr-watch-calls 'ci-now test-issue orchestrator round-1'
expect_call_has pr-watch-calls 'conflicts-check test-issue'
expect_call_lacks pr-watch-calls 'ci test-issue'
# 見張りの役がいれば、見張りを入れてから、見張りの役の ID を付けてその場の確認を流す。
reset
ok_round
unlinked
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci test-issue ci-monitor round-1'
expect_call_has pr-watch-calls 'ci-now test-issue orchestrator round-1 ci-monitor'
# 見張りの役がいなければ、見張りの役の ID は付けない。
reset
set_roster orchestrator code-reviewer qa
ok_round
unlinked
run round-1
expect_status 0
expect_call_has pr-watch-calls 'unlinked test-issue round-1 --leader orchestrator'
expect_call_lacks pr-watch-calls 'unlinked test-issue round-1 ci-monitor'
# 見張りを入れられなければ止まる。
reset
ok_round
unlinked
echo 1 >"$test_dir/ci-status"
run round-1
expect_leader 'CI の見張りを入れられない'
# マージの手順で見張りの役がいれば、その場の確認（ci-now）は流さず、見張りを入れて ci-wait で CI を待つ。
reset
set_roster orchestrator code-reviewer qa ci-monitor
ok_round
unlinked
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci-held test-issue round-1'
expect_call_has pr-watch-calls 'ci test-issue ci-monitor round-1'
expect_call_has pr-watch-calls 'ci-wait test-issue orchestrator round-1'
expect_call_lacks pr-watch-calls ci-now
# 紐付いていない PR のマージ待ちは、見張りの役の ID を付けて登録する。付けないと、見張りの役を使わずリーダーを 1 時間おきに起こす規則になる。
expect_call_has pr-watch-calls 'unlinked test-issue round-1 ci-monitor --leader orchestrator'
expect_call_lacks pr-watch-calls 'unlinked test-issue round-1 --leader'
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "CI が成功なのに、マージの依頼を書いていない: $(<"$test_dir/out")"
# その場の確認が止まる値。
reset
ok_round
unlinked
printf '紐付け: 紐付いていない pr: 不明\n' >"$test_dir/cinow-out"
run round-1
expect_leader '紐付け: 紐付いていない'
reset
ok_round
unlinked
printf 'CI 0123456: 失敗あり（lint）\n' >"$test_dir/cinow-out"
run round-1
expect_leader 'CI 0123456: 失敗あり（lint）'
reset
ok_round
unlinked
echo 1 >"$test_dir/cinow-status"
run round-1
expect_leader 'CI のその場の確認が 0 以外で終わった'
# 実装の作業中なので保留した失敗と、/note の行は、止めない。
reset
ok_round
unlinked
printf '/note\nCI 0123456: 失敗あり（lint。修正の作業中なので保留）\n/note 補足\n' >"$test_dir/cinow-out"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "保留の失敗で止まっている: $(<"$test_dir/out")"
# コンフリクトで止まる。
reset
ok_round
unlinked
printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
run round-1
expect_leader 'コンフリクト: CONFLICTING'
# 判定できないコンフリクト（UNKNOWN・空）は止めない。
reset
ok_round
unlinked
printf 'コンフリクト: UNKNOWN head: %s\n' "$sha" >"$test_dir/conf-out"
run round-1
expect_status 0
# 紐付いているときは、その場の確認もコンフリクトの確認もしない。
reset
ok_round
run round-1
expect_call_lacks pr-watch-calls ci-now
expect_call_lacks pr-watch-calls conflicts-check
expect_call_lacks pr-watch-calls 'ci '
# 依頼のコメントに書く PR は、紐付けの確認が出した URL にする。
reset
ok_round
printf '紐付け: 紐付いている pr: https://github.com/demo/project/pull/99\n' >"$test_dir/link-out"
run round-1
[[ $(posted_body) == *$'\n対象の PR: https://github.com/demo/project/pull/99' ]] || fail "対象の PR が紐付けの URL でない: $(posted_body)"
echo 'PASS review-next-decide: 紐付いていない PR は、その場の CI（見張りの役がある構成は ci-wait）とコンフリクトを確認し、止まる値ならリーダーに任せる'

# 試み直しの結果で、マージの依頼に添える紐付けの依頼の行と、紐付けの失敗の段落が変わる。
# PR を作った役の引き継ぎには紐付けの失敗の段落がある。link-check は偽物なので、試み直しの結果は、link-check が出す紐付けの行で表す。
retry_merge_setup() {
	reset
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
	jq 'map(if .id == "pr-made" then .content = "PR を作りました https://github.com/demo/project/pull/7\n\n紐付けの失敗: PR をタスクに紐付けられなかった。\n404 で待ち切れなかったため、連携を確認してほしい。" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new" && mv "$test_dir/comments.new" "$test_dir/comments.json"
}
# 試み直しで紐付いたときは、紐付けの依頼の行も、紐付けの失敗の段落も、マージのあとに done にする案内もない。
retry_merge_setup
run final-1
expect_status 0
body=$(posted_body)
[[ $body == "[@Owner]"*'マージの依頼: '* ]] || fail "マージの依頼を書いていない: $body"
[[ $body != *'紐付けの失敗:'* && $body != *'紐付いていないので'* && $body != *'GitHub 連携'* && $body != *'ワークスペースの設定'* ]] || fail "紐付いたのに、紐付けの依頼か段落がある: $body"
expect_call_lacks pr-watch-calls 'unlinked '
expect_call_has pr-watch-calls 'link-check test-issue final-1'
# 404 のまま紐付かないときは、今と同じく、紐付けの依頼の行と紐付けの失敗の段落がある。
retry_merge_setup
unlinked
printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_status 0
body=$(posted_body)
[[ $body == "[@Owner]"*'マージの依頼: '* ]] || fail "マージの依頼を書いていない: $body"
[[ $body == *'紐付いていないので、マージのあとにタスクを `done` にしてほしい（または先に紐付けてほしい）。PR: `'"$pr_url"'`'* ]] || fail "紐付けの依頼の行がない: $body"
[[ $body == *$'\n紐付けの失敗: PR をタスクに紐付けられなかった。\n404 で待ち切れなかったため、連携を確認してほしい。'* ]] || fail "紐付けの失敗の段落がない: $body"
expect_call_has pr-watch-calls 'link-check test-issue final-1'
expect_call_has pr-watch-calls 'unlinked test-issue final-1 --leader orchestrator'
echo 'PASS review-next-decide: 試み直しで紐付いたマージの依頼には紐付けの依頼と段落がなく、紐付かないままなら両方が残る'
plain_lines=$(posted_body | grep -E '^(コンフリクト|CI )')
retry_merge_setup
printf '紐付け: 紐付いていない pr: %s 連携: なし\n' "$pr_url" >"$test_dir/link-out"
printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_status 0
body=$(posted_body)
[[ $(grep -c '^このリポジトリは GitHub 連携なしとして扱っています。マージのあとに、タスクを `done` にしてください。PR: ' <<<"$body") == 1 ]]
[[ $(grep -E '^(コンフリクト|CI )' <<<"$body") == "$plain_lines" ]]
[[ $body != *'紐付けの失敗:'* && $body != *'先に紐付けてほしい'* && $body != *'ワークスペースの設定'* ]]
expect_call_has pr-watch-calls 'unlinked test-issue final-1 --leader orchestrator'
echo 'PASS review-next-decide: 連携なしでは人間に done を一度頼み、CI・コンフリクト・見張りは同じ'

human_setup() {
	reset
	add pr-made orchestrator "PR を作りました ${pr_url}"$'\n'"紐付けの失敗: PR をタスクに紐付けられませんでした。"$'\n'"GitHub 連携が見つかりません。" ""
	review_round round-1 "$sha" code-reviewer qa
	result round-1 code-reviewer ❌ "$sha" なし
	result round-1 qa ✅ "$sha" なし
	printf '使用率の待ち: fix を通算 24 時間待った。\n' >"$test_dir/pick-out"
	echo 4 >"$test_dir/pick-status"
}
human_setup
printf '紐付け: 紐付いていない pr: %s 連携: なし\n' "$pr_url" >"$test_dir/link-out"
run round-1
expect_status 0
body=$(posted_body)
[[ $body == *'使用率が上限に近く'* && $body != *'連携なし'* && $body != *'紐付け'* && $body != *'`done`'* ]]
echo 'PASS review-next-decide: マージ以外で人間を呼ぶときは連携なしの案内を添えない'


# ---- 書く前の失敗。
reset
ok_round
touch "$test_dir/comments-fail"
run round-1
expect_failure 'コメントを読めない'
reset
ok_round
echo 1 >"$test_dir/watch-status"
run round-1
expect_failure '返事の待ちの見張りを入れられない'
expect_no_calls status-calls
reset
ok_round
touch "$test_dir/post-fail"
run round-1
expect_failure 'コメントの投稿に失敗した'
reset
ok_round
run 'ないコメント'
expect_failure '返事の組を読めない'
# CI の待ちの規則があれば、書く前に消す。消せなければ何も書かない。
reset
set_metadata ci_wait_head "$sha"
ok_round
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci-wait-clear test-issue'
reset
set_metadata ci_wait_head "$sha"
ok_round
echo 1 >"$test_dir/clear-status"
run round-1
expect_failure 'CI の待ちの規則を消せない'
expect_nothing_written
reset
ok_round
run round-1
expect_call_lacks pr-watch-calls ci-wait-clear
echo 'PASS review-next-decide: 書けないときは、理由を出して失敗し、CI の待ちの規則は書く前にだけ消す'

# 引数の数。
status=0
(cd "$test_dir" && bash monitor/squad-review-next decide test-issue) >/dev/null 2>"$test_dir/err" || status=$?
[[ $status == 2 && $(<"$test_dir/err") == *使い方* ]] || fail "decide の引数の数を検査していない"
reset
ok_round
status=0
(cd "$test_dir" && bash monitor/squad-review-next decide test-issue round-1 規則) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 0
echo 'PASS review-next-decide: 第 3 引数（起きた規則）は受け取り、引数が足りなければ使い方を出す'
