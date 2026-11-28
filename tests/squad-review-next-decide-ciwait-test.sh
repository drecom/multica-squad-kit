#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-ciwait-test.sh で実行する。
# この部分は、CI の成功・実行中・未確認の扱いと、待ちの記録を書く条件を確認する。
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

# ---- 成功とチェックなしは、その行を添えて、規則の登録とマージの依頼へ進む。保留した失敗は、最終レビューの回では読まない。
reset
ci_final_ok
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha}: 成功" "${lines_all[@]}")" final-1
expect_calls pr-watch-calls $'link-check test-issue final-1\nconflicts-check test-issue\nci test-issue ci-monitor final-1\nci-wait test-issue orchestrator final-1\nconflicts test-issue --leader orchestrator'
reset
ci_final_ok
ciwait "CI ${sha}: チェックなし"
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha}: チェックなし" "${lines_all[@]}")" final-1
reset
ci_final_ok
ciwait "CI ${sha}: 実行中（待つ上限の 2 時間を超えた）"
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha}: 実行中（待つ上限の 2 時間を超えた）" "${lines_all[@]}")" final-1
reset
ci_final_ok
ciwait "CI ${sha}: 未確認（待つ上限の 2 時間を超えた）"
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha}: 未確認（待つ上限の 2 時間を超えた）" "${lines_all[@]}")" final-1
expect_call_lacks pr-watch-calls ci-now
echo 'PASS review-next-decide: CI が成功・チェックなし・待つ上限を超えたなら、その行を添えてマージの依頼を書く'

# ---- 実行中と未確認は、CI の待ちの記録を書く。タスクの状態も規則の登録も変えない。
reset
ci_final_ok
ciwait "CI ${sha}: 実行中"
run final-1
expect_posted 'CI の待ち' "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1\n' "$sha")" final-1
[[ $(posted_body) != *'mention://'* ]] || fail "CI の待ちの記録にメンションがある: $(posted_body)"
expect_no_calls status-calls
expect_call_lacks pr-watch-calls 'conflicts test-issue'
expect_call_lacks pr-watch-calls 'unlinked test-issue'
expect_call_lacks pr-watch-calls ci-wait-clear
reset
ci_final_ok
ciwait "CI ${sha}: 未確認"
run final-1
expect_posted 'CI の待ち' "$(printf 'マージの前の CI の待ち: CI %s: 未確認\n前の回: final-1\n' "$sha")" final-1
expect_no_calls status-calls
# 紐付いていなくても、待つ。
reset
ci_final_ok
printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"
ciwait "CI ${sha}: 実行中"
run final-1
expect_posted 'CI の待ち' "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1\n' "$sha")" final-1
expect_call_lacks pr-watch-calls ci-now
expect_call_lacks pr-watch-calls 'unlinked test-issue'
# 同じ回と同じ head の記録があれば、書かない。
reset
ci_final_ok
add ci-wait-1 orchestrator "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1' "$sha")" final-1
ciwait "CI ${sha}: 実行中"
run final-1
expect_status 0
[[ $(<"$test_dir/out") == '次の依頼: CI の待ち（記録は書き済み）' ]] || fail "標準出力が違う: $(<"$test_dir/out")"
expect_nothing_written
# 実行の初めに読んだコメントになく、読み直したコメントに見える同じ回・同じ head の記録も、書き済みと数える。
reset
ci_final_ok
ciwait "CI ${sha}: 実行中"
jq --arg body "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1' "$sha")" \
	'. + [(map(select(.id == "final-1")) | first) + {id: "ci-wait-late", author_id: "orchestrator", author_type: "agent", content: $body, created_at: "2026-11-10T13:00:00Z"}]' \
	"$test_dir/comments.json" >"$test_dir/comments.later.json"
run final-1
expect_status 0
[[ $(<"$test_dir/out") == '次の依頼: CI の待ち（記録は書き済み）' ]] || fail "読み直しで見えた記録を数えていない: $(<"$test_dir/out")"
expect_nothing_written
# 4 個の囲みの中の 3 個の囲みの例文は、記録と数えない。
reset
ci_final_ok
add ci-wait-1 orchestrator "$(printf '````\n```\nマージの前の CI の待ち: CI %s: 実行中\n前の回: final-1\n```\n````' "$sha")" final-1
ciwait "CI ${sha}: 実行中"
run final-1
expect_posted 'CI の待ち' "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1\n' "$sha")" final-1
# 回が違う記録、head が違う記録があれば、書く。
reset
ci_final_ok
add ci-wait-1 orchestrator "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: round-1' "$sha")" round-1
add ci-wait-2 orchestrator "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1' "$old")" final-1
ciwait "CI ${sha}: 実行中"
run final-1
expect_posted 'CI の待ち' "$(printf 'マージの前の CI の待ち: CI %s: 実行中\n前の回: final-1\n' "$sha")" final-1
# 書けないときは、理由を出して失敗する。
reset
ci_final_ok
ciwait "CI ${sha}: 実行中"
touch "$test_dir/post-fail"
run final-1
expect_failure 'コメントの投稿に失敗した'
reset
ci_final_ok
ciwait "CI ${sha}: 実行中"
touch "$test_dir/comments-fail"
run final-1
expect_failure 'コメントを読めない'
echo 'PASS review-next-decide: CI が実行中か未確認なら、同じ回と head に 1 回だけ CI の待ちの記録を書き、状態を変えない'
