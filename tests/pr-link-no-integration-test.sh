#!/usr/bin/env bash
# 実際の squad-pr-link、link-check と decide をスタブのタスク・API・時計につなぐ。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
export MULTICA_SERVER_URL=https://multica.invalid MULTICA_TOKEN=fixture-token
export PR_LINK_STATE_ROOT=$test_dir/pr-link-state
pr=https://github.com/demo/project/pull/7
second=https://github.com/demo/project/pull/8
third=https://github.com/demo/project/pull/9
record=$PR_LINK_STATE_ROOT/project-integration/demo/project
watch_dir=$test_dir

mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-}" == 'issue get test-issue' ]]; then
	cat "$dir/task.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue comment add' ]]; then
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	body=$(jq -r 'index("--content-file") as $i | .[$i+1]' <<<"$args")
	jq -cn --argjson args "$args" --rawfile body "$body" '{args:$args,body:$body}' >>"$dir/posted.jsonl"
	jq --slurpfile base "$dir/comment-prototype.json" --rawfile body "$body" \
		'. + [$base[0] + {id:"notice-1", author_type:"agent", content:$body}]' "$dir/comments.json" >"$dir/comments.next"
	mv "$dir/comments.next" "$dir/comments.json"
	jq --rawfile body "$body" '.[0] + {id:"notice-1",content:$body}' "$PR_WATCH_TEST_ROOT/tests/fixtures/cli/issue-comment-add.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue metadata set' ]]; then
	case $6 in
	pr_link_pending | pr_url) [[ ! -f $dir/fail-$6 ]] || exit 1 ;;
	pr_link_no_integration)
		[[ ! -f $dir/fail-mark ]] || exit 1
		if [[ -f $dir/overlap ]]; then
			rm "$dir/overlap"
			(cd "$dir" && MULTICA_TOKEN='' bash "$PR_WATCH_TEST_ROOT/common/monitor/squad-pr-watch" link-check test-issue ci-thread) >"$dir/overlap-out"
		fi
		;;
	esac
fi
exec "$dir/bin/multica-base" "$@"
MOCK
cat >"$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
dir=$PR_WATCH_TEST_DIR
cat >/dev/null
echo called >>"$dir/curl-calls"
cat "$dir/api-status"
MOCK
cat >"$test_dir/bin/date" <<'MOCK'
#!/usr/bin/env bash
if [[ $* == +%s ]]; then cat "$PR_WATCH_TEST_DIR/clock"; else echo '2026-11-28T00:00:00Z'; fi
MOCK
cat >"$test_dir/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
dir=$PR_WATCH_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo "$(($(<"$dir/clock") + $1))" >"$dir/clock"
MOCK
command -v ln >"$test_dir/real-ln"
cat >"$test_dir/bin/ln" <<'MOCK'
#!/usr/bin/env bash
[[ ! -f $PR_WATCH_TEST_DIR/fail-record ]] || exit 1
exec "$(<"$PR_WATCH_TEST_DIR/real-ln")" "$@"
MOCK
chmod +x "$test_dir/bin/"{multica,curl,date,sleep,ln}

new_task() {
	reset_fixture
	jq '.project_id = "project-integration" | .metadata.repository = "demo/project" | del(.metadata.pr_url)' \
		"$test_dir/task.json" >"$test_dir/task.next"
	mv "$test_dir/task.next" "$test_dir/task.json"
	printf '{"pull_requests":[]}\n' >"$test_dir/pulls.json"
	printf '404' >"$test_dir/api-status"
	printf '1764288000\n' >"$test_dir/clock"
	: >"$test_dir/sleeps"
	: >"$test_dir/curl-calls"
}
new_scene() {
	rm -rf -- "$PR_LINK_STATE_ROOT"
	rm -f -- "$test_dir"/{fail-mark,fail-record,fail-pr_link_pending,fail-pr_url,overlap,overlap-out}
	new_task
}
link() {
	(cd "$test_dir" && bash "$root/common/monitor/squad-pr-link" test-issue "$1")
}
watch_link() {
	(cd "$test_dir" && MULTICA_TOKEN='' bash "$script" link-check test-issue ci-thread)
}
set_url() {
	jq --arg url "$1" '.metadata.pr_url = $url' "$test_dir/task.json" >"$test_dir/task.next"
	mv "$test_dir/task.next" "$test_dir/task.json"
}
notice_once() {
	assert_jq -s --arg url "$pr" 'length == 1 and (.[0].body | startswith("/note\n連携なしの知らせ: " + $url + "\n"))' "$test_dir/posted.jsonl"
}
expect_mark() {
	assert_jq --arg value "記録した $pr" '.metadata.pr_link_no_integration == $value' "$test_dir/task.json"
}
waited_once() {
	[[ $(awk '{ total += $1 } END { print total }' "$test_dir/sleeps") == 120 ]]
}
line="紐付け: 紐付いていない pr: $pr 連携: なし"

# A を切り替え、B の成功で共有の記録だけを消す。C は通常の待ちに戻る。
new_scene
[[ $(link "$pr") == '連携なしにしました: '* ]]
waited_once
expect_mark
[[ $(watch_link) == "$line" ]]
notice_once
cp "$test_dir/task.json" "$test_dir/task-a.json"
cp "$test_dir/comments.json" "$test_dir/comments-a.json"
new_task
printf '200' >"$test_dir/api-status"
[[ $(link "$second") == '紐付けました: '* ]]
[[ ! -s $test_dir/sleeps && ! -e $record && $(wc -l <"$test_dir/curl-calls") -eq 1 ]]
cp "$test_dir/task-a.json" "$test_dir/task.json"
cp "$test_dir/comments-a.json" "$test_dir/comments.json"
kept_line=$(watch_link)
[[ $kept_line == "$line" && ! -s $test_dir/posted.jsonl ]]
(
	source "$root/tests/review-next-decide-common.sh"
	reset
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
	printf '%s\n' "$kept_line" >"$test_dir/link-out"
	printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
	run final-1
	expect_status 0
	body=$(posted_body)
	[[ $(grep -c '^このリポジトリは GitHub 連携なしとして扱っています。マージのあとに、タスクを `done` にしてください。PR: ' <<<"$body") == 1 ]]
	[[ $body != *'紐付けの失敗:'* && $body != *'先に紐付けてほしい'* ]]
)
test_dir=$watch_dir
new_task
[[ $(link "$third") == '連携なしにしました: '* ]]
waited_once
echo 'PASS pr-link-no-integration: 別の PR の紐付けで記録だけ消え、A は連携なしのまま、次の PR は待つ'

for stage in pr_link_pending pr_url record; do
	new_scene
	touch "$test_dir/fail-$stage"
	rc=0
	link "$pr" >"$test_dir/failure-out" 2>"$test_dir/failure-err" || rc=$?
	[[ $rc == 1 && ! -e $record ]]
	grep -q '紐付けられませんでした' "$test_dir/failure-err"
	# 役が pr_url を補ったあとの確認。
	set_url "$pr"
	[[ $(watch_link) == "紐付け: 紐付いていない pr: $pr" ]]
	[[ ! -e $record ]]
done
echo 'PASS pr-link-no-integration: 手順 1〜3 の失敗は従来の試み直しに戻る'

new_scene
touch "$test_dir/fail-mark"
[[ $(link "$pr") == '連携なしにしました: '* && -f $record ]]
rm "$test_dir/fail-mark"
[[ $(watch_link) == "$line" && $(watch_link) == "$line" ]]
expect_mark
notice_once
echo 'PASS pr-link-no-integration: 印を書けない場合は次の確認で復旧し、初回の知らせを一度だけ出す'

new_scene
touch "$test_dir/overlap"
[[ $(link "$pr") == '連携なしにしました: '* ]]
[[ $(<"$test_dir/overlap-out") == "$line" && $(watch_link) == "$line" ]]
expect_mark
notice_once
echo 'PASS pr-link-no-integration: 手順 3 と 4 の間に link-check が走っても印と初回の知らせがそろう'
