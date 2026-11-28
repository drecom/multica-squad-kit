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
	id="notice-$(wc -l <"$dir/posted.jsonl" | tr -d ' ')"
	# during-post: 読んだあと、投稿の前に、別の役の link-check を 1 回挟む。第 2 語が link なら、そのあいだに PR が紐付く。
	if [[ -f $dir/during-post ]]; then
		read -r during_agent during_mode <"$dir/during-post"
		rm "$dir/during-post"
		[[ $during_mode != link ]] || printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$(jq -r .metadata.pr_url "$dir/task.json")" >"$dir/pulls.json"
		(cd "$dir" && MULTICA_TOKEN='' MULTICA_AGENT_ID=$during_agent bash "$PR_WATCH_TEST_ROOT/common/monitor/squad-pr-watch" link-check test-issue ci-thread) >"$dir/during-out"
	fi
	if [[ ! -f $dir/hide-post ]]; then
		jq --slurpfile base "$dir/comment-prototype.json" --rawfile body "$body" --arg id "$id" --arg agent "${MULTICA_AGENT_ID-}" \
			'. + [$base[0] + {id:$id, author_type:"agent", author_id:$agent, content:$body, created_at:"2026-11-28T00:00:00Z"}]' "$dir/comments.json" >"$dir/comments.next"
		mv "$dir/comments.next" "$dir/comments.json"
	fi
	jq --rawfile body "$body" --arg id "$id" '.[0] + {id:$id,content:$body}' "$PR_WATCH_TEST_ROOT/tests/fixtures/cli/issue-comment-add.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue comment delete' ]]; then
	echo "$4" >>"$dir/deleted"
	jq --arg id "$4" 'map(if .id == $id then .content = "" else . end)' "$dir/comments.json" >"$dir/comments.next"
	mv "$dir/comments.next" "$dir/comments.json"
	echo '{}'
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue metadata set' ]]; then
	case $6 in
	pr_link_pending | pr_url) [[ ! -f $dir/fail-$6 ]] || exit 1 ;;
	pr_link_no_integration)
		[[ ! -f $dir/fail-mark ]] || exit 1
		if [[ -f $dir/overlap ]]; then
			overlap_agent=$(<"$dir/overlap")
			rm "$dir/overlap"
			(cd "$dir" && MULTICA_TOKEN='' MULTICA_AGENT_ID=$overlap_agent bash "$PR_WATCH_TEST_ROOT/common/monitor/squad-pr-watch" link-check test-issue ci-thread) >"$dir/overlap-out"
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
	rm -f -- "$test_dir"/{fail-mark,fail-record,fail-pr_link_pending,fail-pr_url,overlap,overlap-out,hide-post,deleted,during-post,during-out,newest-notice}
	new_task
}
link() {
	(cd "$test_dir" && bash "$root/common/monitor/squad-pr-link" test-issue "$1")
}
# 知らせはリーダーの link-check だけが扱う。第 1 引数に別の ID を渡すと、その役の実行にする。
watch_link() {
	(cd "$test_dir" && MULTICA_TOKEN='' MULTICA_AGENT_ID=${1-orchestrator} bash "$script" link-check test-issue ci-thread)
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
notice_once_among_posts() {
	assert_jq -s --arg url "$pr" '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length == 1' "$test_dir/posted.jsonl"
}
waited_once() {
	[[ $(awk '{ total += $1 } END { print total }' "$test_dir/sleeps") == 120 ]]
}
line="紐付け: 紐付いていない pr: $pr 連携: なし"
# 見えなかった投稿を、あとの読みで見えるようにする。時刻は同じにして、id の順で決まる場合を試す。
reveal_posted() {
	python3 -I - "$test_dir" <<'PY'
import json, sys
from pathlib import Path
work = Path(sys.argv[1])
comments = json.loads((work / "comments.json").read_text())
base = json.loads((work / "comment-prototype.json").read_text())
for number, row in enumerate((json.loads(line) for line in (work / "posted.jsonl").read_text().splitlines()), start=1):
    if not row["body"].startswith("/note\n連携なしの知らせ: "):
        continue
    comments.append(dict(base, id=f"notice-{number}", author_type="agent", author_id="orchestrator", content=row["body"], created_at="2026-11-28T00:00:00Z"))
(work / "comments.json").write_text(json.dumps(comments))
(work / "newest-notice").write_text(comments[-1]["id"])
PY
}
notice_total() {
	jq -sr '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length' "$test_dir/posted.jsonl"
}
mark_gone() { assert_jq '.metadata | has("pr_link_no_integration") | not' "$test_dir/task.json"; }
become_linked() {
	printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$pr" >"$test_dir/pulls.json"
	set_url "$pr"
}
linked_line="紐付け: 紐付いている pr: $pr"

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

# B が紐付いて共有の記録を消す。A のタスクと知らせの前の状態は、そのまま戻す。
other_pr_links() {
	cp "$test_dir/task.json" "$test_dir/task-a.json"
	cp "$test_dir/comments.json" "$test_dir/comments-a.json"
	new_task
	printf '200' >"$test_dir/api-status"
	[[ $(link "$second") == '紐付けました: '* && ! -e $record ]]
	cp "$test_dir/task-a.json" "$test_dir/task.json"
	cp "$test_dir/comments-a.json" "$test_dir/comments.json"
}
no_notice_no_mark() {
	# 試み直しの記録は投稿されてよい。連携なしの知らせだけが出ないことを見る。
	[[ ! -s $test_dir/posted.jsonl ]] || ! grep -qF '連携なしの知らせ' "$test_dir/posted.jsonl"
	assert_jq '.metadata | has("pr_link_no_integration") | not' "$test_dir/task.json"
}

# 印を書けなかった実行は 1 で終わり、結んだ記録を残す。
new_scene
touch "$test_dir/fail-mark"
rc=0
link "$pr" >"$test_dir/failure-out" 2>"$test_dir/failure-err" || rc=$?
[[ $rc == 1 && -z $(<"$test_dir/failure-out") && -f $record ]]
grep -q '紐付けられませんでした' "$test_dir/failure-err"
no_notice_no_mark
rm "$test_dir/fail-mark"
# 記録がこの PR を指すあいだは、link-check が印を戻し、初回の知らせを一度だけ出す。
[[ $(watch_link) == "$line" && $(watch_link) == "$line" ]]
expect_mark
notice_once
echo 'PASS pr-link-no-integration: 印を書けない実行は 1 で終わり、記録が残るあいだは次の確認で復旧して知らせを一度だけ出す'

# 戻す前に B が記録を消すと、A は連携なしにならず、知らせも出ない。
new_scene
touch "$test_dir/fail-mark"
rc=0
link "$pr" >/dev/null 2>&1 || rc=$?
[[ $rc == 1 && -f $record ]]
rm "$test_dir/fail-mark"
other_pr_links
set_url "$pr"
[[ $(watch_link) == "紐付け: 紐付いていない pr: $pr" ]]
no_notice_no_mark
echo 'PASS pr-link-no-integration: 印を書けず、戻す前に記録が消えた PR は、連携なしにならず知らせも出ない'

# 印を書けた A は、知らせの前に B が記録を消しても、連携なしで知らせを一度だけ出す。
new_scene
[[ $(link "$pr") == '連携なしにしました: '* && -f $record ]]
expect_mark
[[ ! -s $test_dir/posted.jsonl ]]
other_pr_links
[[ $(watch_link) == "$line" && $(watch_link) == "$line" && ! -e $record ]]
expect_mark
notice_once
echo 'PASS pr-link-no-integration: 印を書けた PR は、知らせの前に記録が消えても連携なしで知らせを一度だけ出す'

# タスクの一覧にほかの PR があると、待ち切れても連携なしにせず、食い違いのままになる。
for existing in absent present; do
	new_scene
	if [[ $existing == present ]]; then
		mkdir -p "${record%/*}"
		printf 'repository: demo/project\npr: %s\ntask: OTHER-1\n記録した時刻: 2026-11-28T00:00:00Z\n' "$second" >"$record"
	fi
	printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$second" >"$test_dir/pulls.json"
	rc=0
	link "$pr" >"$test_dir/failure-out" 2>"$test_dir/failure-err" || rc=$?
	[[ $rc == 1 && -z $(<"$test_dir/failure-out") ]]
	grep -q '紐付けられませんでした' "$test_dir/failure-err"
	if [[ $existing == present ]]; then grep -qxF "pr: $second" "$record"; else [[ ! -e $record ]]; fi
	set_url "$pr"
	[[ $(watch_link) == "紐付け: 食い違い pr: $pr 紐付いた PR: $second" ]]
	no_notice_no_mark
done
echo 'PASS pr-link-no-integration: 一覧にほかの PR があるタスクは連携なしにならず、食い違いで記録も印も知らせもない'

# 手順 3 と 4 の間にリーダーの link-check が走っても、印と初回の知らせがそろう。
new_scene
echo orchestrator >"$test_dir/overlap"
[[ $(link "$pr") == '連携なしにしました: '* ]]
[[ $(<"$test_dir/overlap-out") == "$line" && $(watch_link) == "$line" ]]
expect_mark
notice_once
echo 'PASS pr-link-no-integration: 手順 3 と 4 の間にリーダーの link-check が走っても印と初回の知らせがそろう'

# リーダーでない役が間に走っても、知らせも印の削除もせず、次のリーダーの回が 1 件だけ出す。
new_scene
echo monitor >"$test_dir/overlap"
[[ $(link "$pr") == '連携なしにしました: '* ]]
[[ $(<"$test_dir/overlap-out") == "$line" ]]
[[ ! -s $test_dir/posted.jsonl ]]
expect_mark
[[ $(watch_link monitor) == "$line" && ! -s $test_dir/posted.jsonl ]]
[[ $(watch_link) == "$line" && $(watch_link) == "$line" ]]
notice_once
echo 'PASS pr-link-no-integration: リーダーでない役が間に走っても知らせを出さず、リーダーの回が 1 件だけ出す'

# 投稿が次の読みに見えないあいだに続けて走ると、知らせが 2 件になる。次のリーダーの回が、古い 1 件を残して新しい方を消し、印は残す。
new_scene
[[ $(link "$pr") == '連携なしにしました: '* ]]
touch "$test_dir/hide-post"
[[ $(watch_link) == "$line" && $(watch_link) == "$line" ]]
assert_jq -s '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length == 2' "$test_dir/posted.jsonl"
rm "$test_dir/hide-post"
reveal_posted
[[ $(watch_link) == "$line" ]]
[[ $(<"$test_dir/deleted") == "$(<"$test_dir/newest-notice")" ]]
expect_mark
[[ $(watch_link) == "$line" && $(wc -l <"$test_dir/deleted") -eq 1 ]]
echo 'PASS pr-link-no-integration: 続けて 2 件になった知らせは、次のリーダーの回が古い 1 件を残して消し、印を残す'

# 紐付いたあとも印は残り、リーダーが 1 件と読んだ次の回に消える。
new_scene
[[ $(link "$pr") == '連携なしにしました: '* ]]
[[ $(watch_link) == "$line" ]]
printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$pr" >"$test_dir/pulls.json"
set_url "$pr"
[[ $(watch_link monitor) == "紐付け: 紐付いている pr: $pr" ]]
expect_mark
[[ $(watch_link) == "紐付け: 紐付いている pr: $pr" ]]
assert_jq '.metadata | has("pr_link_no_integration") | not' "$test_dir/task.json"
notice_once_among_posts
echo 'PASS pr-link-no-integration: 紐付いたあとも印は残り、リーダーが知らせ 1 件と読んだ回に消す'

# 120 秒の 404 で切り替えたあと、最初の link-check の前に同じ PR が紐付く。2 回で、復帰の文面の知らせ 1 件だけが残り、記録・待ちの印・マークがない。
new_scene
[[ $(link "$pr") == '連携なしにしました: '* && -f $record ]]
become_linked
[[ $(watch_link) == "$linked_line" ]]
[[ $(notice_total) == 1 && ! -e $record ]]
assert_jq '.metadata | has("pr_link_pending") | not' "$test_dir/task.json"
expect_mark
[[ $(watch_link) == "$linked_line" ]]
mark_gone
[[ $(notice_total) == 1 && ! -e $record ]]
assert_jq -s '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length == 1 and (.[0].body | contains("連携ありの扱いに戻しました") and (contains("done にしてください") | not))' "$test_dir/posted.jsonl"
echo 'PASS pr-link-no-integration: 切り替えのあと最初の確認の前に紐付くと、復帰の知らせ 1 件だけで記録も印も残らない'

# リーダーの回の読みと投稿のあいだに、リーダーでない役の回が走る。判定がそろう場合も、先に紐付く場合も、残る知らせは 1 件で、リーダーでない役は印を消さない。
for mode in same link; do
	new_scene
	[[ $(link "$pr") == '連携なしにしました: '* ]]
	echo "monitor $mode" >"$test_dir/during-post"
	[[ $(watch_link) == "$line" ]]
	if [[ $mode == link ]]; then [[ $(<"$test_dir/during-out") == "$linked_line" ]]; else [[ $(<"$test_dir/during-out") == "$line" ]]; fi
	[[ $(notice_total) == 1 ]]
	expect_mark
	[[ ! -e $test_dir/deleted ]]
	if [[ $mode == link ]]; then
		[[ $(watch_link) == "$linked_line" ]]
		mark_gone
	else
		[[ $(watch_link) == "$line" ]]
		expect_mark
	fi
	[[ $(notice_total) == 1 && ! -e $test_dir/deleted ]]
done
echo 'PASS pr-link-no-integration: 読みと投稿のあいだにリーダーでない役が走っても知らせは 1 件で、その役は印を消さない'

# 投稿が見えないスタブで、2 回目が紐付いていると判定する場合も、2 件になり、3 回目に古い 1 件を残して消して印を消す。
new_scene
[[ $(link "$pr") == '連携なしにしました: '* ]]
touch "$test_dir/hide-post"
[[ $(watch_link) == "$line" ]]
become_linked
[[ $(watch_link) == "$linked_line" ]]
[[ $(notice_total) == 2 ]]
rm "$test_dir/hide-post"
reveal_posted
[[ $(watch_link) == "$linked_line" ]]
[[ $(<"$test_dir/deleted") == "$(<"$test_dir/newest-notice")" ]]
mark_gone
[[ $(notice_total) == 2 && $(wc -l <"$test_dir/deleted") -eq 1 ]]
echo 'PASS pr-link-no-integration: 2 回目が紐付いていても 2 件になり、3 回目に 1 件へ絞って印を消す'
