#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-written-test.sh で実行する。
# squad-review-next decide の判定のうち、結果のあとの記録の扱いと、書き済みの判定を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 結果のあとに、同じ役が返事の回の行を持たない記録や知らせを書いても、返事の組は結果から選ぶ。
reset
ok_round
run round-1
expect_status 0
expected=$(posted_body)
reset
ok_round
for role in code-reviewer qa; do
	add "decision-$role" "$role" $'/note\n決める記録: 返事がそろいました\n❌ demo-'"$role"$'-test: 知らせ'
	add "notice-$role" "$role" $'使用率の待ち: 15 分後に流し直します'
	# report が書く決める記録そのもの。結果のあとに同じ役が書いても、返事の組に入らない。
	add "record-$role" "$role" $'/note\n返事の待ち: 次の依頼を決めます'
done
run round-1
expect_status 0
[[ $(posted_body) == "$expected" ]] || fail "返事の回の行がない記録が、組を変えた: $(posted_body)"
echo 'PASS review-next-decide: 結果のあとの記録や知らせは、返事の組を変えない'

# ---- 書き済み: 同じ回の依頼があれば何も書かない。待ちのコメントは書き済みにしない。
reset
ok_round
add next orchestrator $'修正の依頼: 直してください\n前の回: round-1'
run round-1
expect_status 0
[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "書き済みを出していない: $(<"$test_dir/out")"
expect_nothing_written
expect_no_calls pr-watch-calls
expect_no_calls pick-calls
reset
ok_round
add next orchestrator $'/note 修正の依頼: 直してください\n前の回: round-1'
run round-1
[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "/note 付きの書き済みを見つけていない: $(<"$test_dir/out")"
for waiting in '使用率の待ち: fix を待つ。' 'マージの前の CI の待ち: 待つ。'; do
	reset
	ok_round
	add next orchestrator "${waiting}"$'\n前の回: round-1'
	run round-1
	[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "待ちのコメントを書き済みにしている: $waiting"
done
echo 'PASS review-next-decide: 同じ回に書いた依頼があれば書かず、使用率の待ちとマージ前の CI の待ちのコメントは書き済みにしない'
