#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-control-kinds-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# この部分は、各種類の記録と人間を呼ぶ行を書き済みにすることを確認する。
# squad-review-next decide の判定のうち、制御記録（書き済みとするか）を確認する。
# 条件は docs/review-next-step.md の「制御記録の読み方」にある。認める回と最終レビューの認め方は squad-review-next-decide-recognize-test.sh。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

written() { # 何も書かず、書き済みを出す
	expect_status 0
	[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "書き済みを出していない: $(<"$test_dir/out")"
	expect_nothing_written
}
not_written() { # 書き済みにせず、次の依頼を 1 回書く
	expect_status 0
	[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "書き済みにしている"
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "次の依頼が 1 件でない: $(<"$test_dir/posted.jsonl")"
}

# 決める実行の役とリーダーが書いた各種類の記録は、書き済みにする。使用率の待ちと CI の待ちは、書き済みにしない。
for author in orchestrator qa; do
	for body in $'修正の依頼: 直してください\n前の回: round-1' $'コミットが合わず頼み直す役: qa\n前の回: round-1' \
		$'見直しの種類: 最終レビュー\n前の回: round-1' $'マージの依頼: '"$sha"$'\n前の回: round-1' \
		$'使用率の待ち: 24 時間を超えるので人間に聞く\n前の回: round-1'; do
		reset
		ok_round
		[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
		add next "$author" "$body"
		run round-1
		written || fail "$author の記録を書き済みにしていない: $body"
	done
	for body in $'使用率の待ち: fix を待つ。\n前の回: round-1' $'マージの前の CI の待ち: 待つ。\n前の回: round-1'; do
		reset
		ok_round
		[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
		add next "$author" "$body"
		run round-1
		[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "$author の待ちの記録を書き済みにしている: $body"
	done
done
echo 'PASS review-next-decide: 決める実行の役とリーダーの各種類の記録は書き済み、使用率の待ちと CI の待ちは書き済みにしない'

# 人間を呼ぶ行は、古い形も新しい形も人間の呼び出しとして書き済みにする。答えの記録の行と、「人間の答えで進める」を足した振り分けの行は、書き済みにしない。
human_new_line=$'使用率の待ち: fix は 2026-11-12T03:00:00Z まで待つと通算 24 時間を超える。待ち始め: 2026-11-11T03:00:00Z。Claude 週 90%'
for author in orchestrator qa; do
	for body in "$human_new_line"$'\n前の回: round-1' $'使用率の待ち: fix の待ちが通算 24 時間を超える\n前の回: round-1'; do
		reset
		ok_round
		[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
		add next "$author" "$body"
		run round-1
		written || fail "$author の人間を呼ぶ行を書き済みにしていない: $body"
	done
	for body in $'使用率の答え: 進める。答えた時刻: 2026-11-11T03:00:00Z。期限: 2026-11-12T03:00:00Z。スクワッド: squad-1。Claude 週 90%\n前の回: round-1' \
		$'使用率の待ち: fix を 2026-11-12T03:00:00Z まで待つ。待ち始め: 2026-11-11T03:00:00Z。Claude 週 90%。人間の答えで待つ（期限 2026-11-12T03:00:00Z、答えのタスク DEMO-90）\n前の回: round-1' \
		$'振り分け: Claude で足りる。人間の答えで進める（期限 2026-11-12T03:00:00Z、答えのタスク DEMO-90）。工程: fix\n前の回: round-1'; do
		reset
		ok_round
		[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
		add next "$author" "$body"
		run round-1
		[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "$author の答えの記録か 1 文を足した行を書き済みにしている: $body"
	done
done
echo 'PASS review-next-decide: 古い形と新しい形の人間を呼ぶ行は書き済み、答えの記録の行と「人間の答えで」を足した行は書き済みにしない'
