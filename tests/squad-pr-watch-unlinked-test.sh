#!/usr/bin/env bash
# 紐付けの判定を、実物の空の一覧と、見本なしとして宣言した要素の欄で確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
# ホストの連携なしの記録が結果を変えないよう、記録の根を空の一時ディレクトリに向ける。
export PR_LINK_STATE_ROOT=$test_dir/pr-link-state

# 要素はまだ採取できていないため、約束で宣言した html_url だけを判定に使う。link_source は squad-pr-link が表示にだけ使う。
assert_jq '.entries["issue-pull-requests"].items.fields == [{path:"html_url",class:"required",nullable:false},{path:"link_source",class:"optional",nullable:true}]' "$test_dir/contracts.json"
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-} ${2-} ${3-}" == 'issue pull-requests test-issue' ]]; then
	[[ "$*" == 'issue pull-requests test-issue --output json' ]]
	jq -cn --args '$ARGS.positional' -- "$@" >>"$PR_WATCH_TEST_DIR/calls.jsonl"
	[[ ! -f $PR_WATCH_TEST_DIR/fail-pulls ]] || exit 1
	cat "$PR_WATCH_TEST_DIR/pulls.json"
elif [[ "${1-} ${2-} ${3-}" == 'issue get test-issue' ]] && jq -e '.metadata | has("pr_link_no_integration")' "$PR_WATCH_TEST_DIR/task.json" >/dev/null; then
	# この機能が保存する metadata の鍵を除き、実物の見本で検証する。
	jq 'del(.metadata.pr_link_pending, .metadata.pr_link_no_integration)' "$PR_WATCH_TEST_DIR/task.json" >"$PR_WATCH_TEST_DIR/task-base.json"
	python3 "$PR_WATCH_TEST_ROOT/tests/cli-stub.py" pr-watch "$PR_WATCH_TEST_DIR" multica calls.jsonl \
		emit issue-get "$PR_WATCH_TEST_DIR/task-base.json" -- "$@" >/dev/null
	cat "$PR_WATCH_TEST_DIR/task.json"
else
	exec "$PR_WATCH_TEST_DIR/bin/multica-base" "$@"
fi
EOF
chmod +x "$test_dir/bin/multica"

pr=https://github.com/Example/Repo/pull/67
other=https://github.com/Example/Repo/pull/68
link_reset() {
	reset_fixture
	rm -f "$test_dir/fail-pulls"
	jq --arg pr "$pr" '.metadata.pr_url = $pr' "$test_dir/task.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/task.json"
	jq '.[0]' tests/fixtures/cli/issue-pull-requests.json >"$test_dir/pulls.json"
}
linked_urls() {
	jq -n --args '{pull_requests: [$ARGS.positional[] | {html_url: .}]}' -- "$@" >"$test_dir/pulls.json"
}
check_link() {
	check_output "$1" link-check test-issue
	[[ ! -s $test_dir/posted.jsonl && ! -s $test_dir/wakeups.jsonl ]]
	assert_jq -s 'all(.[]; .[0:2] == ["issue","get"] or .[0:2] == ["issue","pull-requests"] or . == ["version"])' "$test_dir/calls.jsonl"
}
unknown_link() {
	local line
	line=$(cd "$test_dir" && bash "$script" link-check test-issue)
	[[ $line == "紐付け: 未確認 pr: $1 理由: "* && $line != *$'\n'* ]]
}

link_reset
check_link "紐付け: 紐付いていない pr: $pr"
echo 'PASS link-check: 読めた空の一覧だけを紐付いていないとし、何も書き込まない'

for value in absent null empty; do
	link_reset
	case $value in
	absent) jq 'del(.metadata.pr_url)' "$test_dir/task.json" ;;
	null) jq '.metadata.pr_url = null' "$test_dir/task.json" ;;
	empty) jq '.metadata.pr_url = ""' "$test_dir/task.json" ;;
	esac >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/task.json"
	check_link '紐付け: pr_url なし pr: 不明'
	linked_urls "$other" "$pr"
	check_link "紐付け: pr_url なし pr: 不明 紐付いた PR: $other, $pr"
done
echo 'PASS link-check: pr_url がなければ、一覧から自動で選ばず、正規形の URL を並べる'

link_reset
linked_urls "$other" https://github.com/Another/Repo/pull/67
check_link "紐付け: 食い違い pr: $pr 紐付いた PR: $other, https://github.com/Another/Repo/pull/67"
echo 'PASS link-check: 一覧に別の PR だけがあれば、食い違いと両方の URL を出す'

for url in "$pr" https://GITHUB.COM/example/REPO/pull/67/ 'https://github.com/EXAMPLE/repo/pull/67/files?diff=split'; do
	link_reset
	linked_urls "$other" "$url"
	check_link "紐付け: 紐付いている pr: $pr"
done
link_reset
pr_suffix='https://github.com/EXAMPLE/repo/pull/67/files?diff=split'
jq --arg pr "$pr_suffix" '.metadata.pr_url = $pr' "$test_dir/task.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/task.json"
linked_urls "$pr"
check_link "紐付け: 紐付いている pr: https://github.com/EXAMPLE/repo/pull/67"
echo 'PASS link-check: 複数 PR、大文字・小文字、末尾の /・files・クエリを同じ PR と読む'

link_reset
touch "$test_dir/fail-pulls"
unknown_link "$pr"
for response in '{}' '{"pull_requests":null}' '{"pull_requests":{}}' '{"pull_requests":[{}]}' '{"pull_requests":[{"html_url":null}]}' '{"pull_requests":[{"html_url":42}]}' 'not-json'; do
	link_reset
	printf '%s\n' "$response" >"$test_dir/pulls.json"
	unknown_link "$pr"
done
echo 'PASS link-check: 一覧の読み取り失敗・欄の欠落・null・形の不正は未確認を 1 行で出し、0 で終える'

link_reset
echo 'issue get test-issue' >"$test_dir/fail"
unknown_link 不明
link_reset
jq 'del(.metadata)' "$test_dir/task.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/task.json"
touch "$test_dir/allow-missing-fields"
unknown_link 不明
echo 'PASS link-check: タスクを読めないときも未確認を出す'

for args in 'link-check' 'link-check test-issue trigger extra'; do
	status=0
	# 引数の不足と過剰は、使い方と終了コード 2 を返す。
	# shellcheck disable=SC2086
	bash "$script" $args >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 2 && ! -s $test_dir/output ]]
	grep -q '使い方: squad-pr-watch link-check <タスク> \[<きっかけのコメント>\]' "$test_dir/error"
done
echo 'PASS link-check: 引数の数が違えば使い方を標準エラーに出し、2 で終える'

# 登録の照合。回のコメントを名簿で認め、回の `対象の PR:` が pr_url と同じときだけ、規則に見張る PR と確認した回を固定する。
export MULTICA_AGENT_ID=orchestrator
repo_pr=https://github.com/example/repo/pull/67
repo_other=https://github.com/example/repo/pull/68
register_reset() {
	reset_fixture
	jq 'map(.name = "Demo-Test")' "$test_dir/squads.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/squads.json"
	fixture squad-member-list | jq '. as $base | [$base + {member_id: "orchestrator", member_type: "agent"}, $base + {member_id: "monitor", member_type: "agent"}]' >"$test_dir/members.json"
}
add_comment() { # ID 作者の種類 作者の ID 本文
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg id "$1" --arg type "$2" --arg author "$3" --arg content "$4" \
		'. + [$base[0] + {id: $id, author_type: $type, author_id: $author, content: $content}]' "$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
round_body() { # 対象の PR の行に入れる URL...
	local body=$'確認するコミット: abcdef0\n返事を待つ役: [@demo-monitor-test](mention://agent/monitor)\n観点: code-reviewer（テスト）' url
	for url; do body+=$'\n'"対象の PR: $url"; done
	printf '%s' "$body"
}
no_integration() {
	jq --arg pr "$1" '.metadata.pr_link_no_integration = $pr' "$test_dir/task.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/task.json"
}
run_unlinked() {
	status=0
	(cd "$test_dir" && bash "$script" unlinked test-issue "$@") >"$test_dir/output" 2>"$test_dir/error" || status=$?
}
expect_one_reason() { [[ $(grep -c . "$test_dir/error") == 1 ]] || { cat "$test_dir/error" >&2; return 1; }; }

register_reset
add_comment round-1 agent orchestrator "$(round_body "$repo_pr")"
run_unlinked round-1 monitor
[[ $status == 0 && ! -s $test_dir/error ]]
assert_jq -s 'length == 1 and (.[0].body | split("\n") | map(select(. != "")) | .[-2:] == ["見張る PR: https://github.com/example/repo/pull/67", "確認した回: round-1"])
	and (.[0].body | contains("squad-pr-watch unlinked-check test-issue orchestrator monitor\n"))' "$test_dir/wakeups.jsonl"
echo 'PASS unlinked: 回を認め、pr_url が回の対象の PR と同じなら、規則の最後に見張る PR と確認した回を足す'

register_reset
add_comment round-1 agent orchestrator "$(round_body "$repo_pr")"
jq --arg pr "$repo_other" '.metadata.pr_url = $pr' "$test_dir/task.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/task.json"
printf '%s\n' "$(fixture issue-wakeups | jq --arg instruction $'紐付いていない PR のマージ待ちの見張りで起きました。\n古い指示' '.id = "old" | .instruction = $instruction')" | jq -s . >"$test_dir/rules.json"
run_unlinked round-1 monitor
[[ $status == 0 && ! -s $test_dir/error && ! -s $test_dir/wakeups.jsonl ]]
[[ $(<"$test_dir/output") == "紐付け: 食い違い pr: $repo_other 回の PR: $repo_pr" ]]
assert_jq 'map(.id) == ["old"]' "$test_dir/rules.json"
echo 'PASS unlinked: 回のあとに pr_url が別の PR に変わっていれば、規則を作らず、既存の規則にも触れず、食い違いの行を出して 0 で終える'

# 連携なしで回を認められないときは、規則を作らず、理由を標準エラーに 1 行出して 1 で終える。
register_reset
no_integration "$repo_pr"
add_comment human-round member human-1 "$(round_body "$repo_pr")"
add_comment result-round agent orchestrator "$(round_body "$repo_pr")"$'\n返事の回: round-1'
add_comment rogue-round agent rogue "$(round_body "$repo_pr")"
add_comment two-lines agent orchestrator "$(round_body "$repo_pr" "$repo_pr")"
add_comment no-line agent orchestrator "$(round_body)"
for args in 'human-round monitor' 'result-round monitor' 'no-such-comment monitor' 'rogue-round monitor --leader rogue' 'two-lines monitor' 'no-line monitor'; do
	: >"$test_dir/wakeups.jsonl"
	# shellcheck disable=SC2086
	run_unlinked $args
	[[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/wakeups.jsonl ]] || { echo "連携なしで 1 で終わらない: $args" >&2; exit 1; }
	expect_one_reason
done
echo 'PASS unlinked: 連携なしで、人間・結果・名簿の外のエージェント・存在しないコメント・対象の PR の行が 1 つでない回は、規則を作らず 1 で終わる'

# 連携なしでないときは、2 行を足さずに今のとおり登録し、理由を標準エラーに 1 行出す。
register_reset
add_comment human-round member human-1 "$(round_body "$repo_pr")"
for args in 'human-round monitor' 'no-such-comment monitor'; do
	: >"$test_dir/wakeups.jsonl"
	# shellcheck disable=SC2086
	run_unlinked $args
	[[ $status == 0 && $(<"$test_dir/output") == *'見張り: '* ]]
	expect_one_reason
	assert_jq -s 'length == 1 and (.[0].body | contains("見張る PR:") | not) and (.[0].body | contains("確認した回:") | not)' "$test_dir/wakeups.jsonl"
done
echo 'PASS unlinked: 連携なしでなく回を認められなければ、2 行を足さずに登録し、標準エラーに理由を 1 行出す'
