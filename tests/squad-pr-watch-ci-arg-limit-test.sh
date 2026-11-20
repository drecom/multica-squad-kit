#!/usr/bin/env bash
# ci-check と ci-now が、Linux の引数の上限（131,072 バイト）を超えるコメントの全件でも、小さなコメントと同じ判断をすることを確認する。
# 準備の jq は上限を超える引数を拒む包みで、拒んだ呼び出しがあれば終わるときにテストが失敗する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"

# 140,000 バイトの本文を持つ、見張りと無関係なコメントを 1 件足す。大きな値は引数に載せず、標準入力で jq に渡す。
add_big_comment() {
	head -c 140000 /dev/zero | tr '\0' a \
		| jq -Rs --slurpfile base "$test_dir/comment-prototype.json" '$base[0] + {author_type: "member", content: .}' >"$test_dir/big-comment.json"
	jq --slurpfile big "$test_dir/big-comment.json" '. + [$big[0]]' "$test_dir/comments.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/comments.json"
	(($(wc -c <"$test_dir/comments.json") >= 140000))
}

# 場面を作る。hold は、作業中の役がいて保留する場面。handoff は、作業中の役が引き継ぎ済みで、通常の通知に進む場面。
prepare() {
	local scene=$1 size=$2
	reset_fixture
	fixture issue-runs direct | jq '. as $base | [$base + {"id": "fixer-run", "agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
	if [[ $scene == handoff ]]; then
		fixture issue-comments agent | jq '. as $base | [$base + {"author_type": "agent", "author_id": "fixer", "source_task_id": "fixer-run", "content": "[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます", "test_thread": "handoff-thread"}]' >"$test_dir/comments.json"
	fi
	if [[ $size == big ]]; then add_big_comment; fi
}

for size in small big; do
	for mode in check now; do
		# 見張りを続ける場面: 作業中の役の名前で保留し、何も投稿しない。
		prepare hold "$size"
		if [[ $mode == check ]]; then
			check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
		else
			printf 'trigger-comment' >"$test_dir/allowed-parent"
			check_output $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）' ci-now test-issue orchestrator trigger-comment monitor
		fi
		[[ ! -s $test_dir/posted.jsonl ]]

		# 引き継ぎ済みの場面: 保留せず、失敗を 1 回だけ知らせる。
		prepare handoff "$size"
		if [[ $mode == check ]]; then
			check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
		else
			printf 'trigger-comment' >"$test_dir/allowed-parent"
			check_output $'/note\nCI abcdef0: 失敗あり' ci-now test-issue orchestrator trigger-comment monitor
		fi
		assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\nCI の失敗を検出しました。\n"))' "$test_dir/posted.jsonl"
	done
done
echo 'PASS ci-check・ci-now: 140,000 バイトのコメントがあっても、保留と引き継ぎ済みの判断が小さなコメントと同じで、拒まれた jq の呼び出しがない'
