#!/usr/bin/env bash
# 実際の squad-pr-link、link-check、unlinked-check と decide をスタブのタスク・API・時計につなぐ。
# 連携なしの知らせは、切り替えた squad-pr-link だけが 1 回出す。どの役の確認でも、件数が変わらないことを見る。
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
	jq -cn --argjson args "$args" --rawfile body "$body" '{args:$args,body:$body}' >>"$dir/attempts.jsonl"
	# fail-notice: 知らせの投稿だけを断る（コメントがきっかけの実行の、根のコメントの拒否に当たる）。
	if [[ -f $dir/fail-notice ]] && [[ $(<"$body") == $'/note\n連携なしの知らせ: '* ]]; then
		echo 'comment add refused' >&2
		exit 1
	fi
	jq -cn --argjson args "$args" --rawfile body "$body" '{args:$args,body:$body}' >>"$dir/posted.jsonl"
	id="comment-$(wc -l <"$dir/posted.jsonl" | tr -d ' ')"
	jq --rawfile body "$body" --arg id "$id" '.[0] + {id:$id,content:$body}' "$PR_WATCH_TEST_ROOT/tests/fixtures/cli/issue-comment-add.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue comment delete' ]]; then
	echo "$4" >>"$dir/deleted"
	echo '{}'
	exit 0
fi
if [[ "${1-} ${2-}" == 'squad list' ]]; then
	echo "$*" >>"$dir/squad-list-calls"
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

# 公開の検査が UUID の形の文字列を止めるので、実行時に組み立てる。
trigger=$(printf '%s-%s-%s-%s-%s' 0a1b2c3d 4e5f 4a6b 8c7d 9e0f1a2b3c4d)
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
	: >"$test_dir/attempts.jsonl"
	: >"$test_dir/posted.jsonl"
}
new_scene() {
	rm -rf -- "$PR_LINK_STATE_ROOT"
	rm -f -- "$test_dir"/{fail-mark,fail-record,fail-pr_link_pending,fail-pr_url,fail-notice,overlap,overlap-out,deleted,squad-list-calls}
	new_task
}
# 第 1 引数が PR の URL。第 2 引数があれば、きっかけのコメントの ID として渡す。
link() {
	(cd "$test_dir" && bash "$root/common/monitor/squad-pr-link" test-issue "$@")
}
roles=(orchestrator other-leader monitor none)
# 第 1 引数の役の実行にする。none は MULTICA_AGENT_ID を持たない実行。
as_role() {
	local role=$1
	shift
	if [[ $role == none ]]; then
		(cd "$test_dir" && unset MULTICA_AGENT_ID && MULTICA_TOKEN='' "$@")
	else
		(cd "$test_dir" && MULTICA_TOKEN='' MULTICA_AGENT_ID=$role "$@")
	fi
}
watch_link() { as_role "${1-orchestrator}" bash "$script" link-check test-issue ci-thread; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# unlinked-check は、このタスクの状態でも動かして、終了コードだけを見る。知らせの件数は別に数える。
watch_unlinked() {
	as_role "${1-orchestrator}" bash "$script" unlinked-check test-issue orchestrator >"$test_dir/unlinked-out" 2>"$test_dir/unlinked-err" || fail "unlinked-check が 0 以外で終わった（役: ${1-orchestrator}）: $(cat "$test_dir/unlinked-err")"
}
set_url() {
	jq --arg url "$1" '.metadata.pr_url = $url' "$test_dir/task.json" >"$test_dir/task.next"
	mv "$test_dir/task.next" "$test_dir/task.json"
}
# 知らせの件数は、合わなければその場で失敗にする。あとの検査の成否で打ち消さない。
notice_count() {
	jq -sr '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length' "$test_dir/posted.jsonl"
}
attempt_count() {
	jq -sr '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length' "$test_dir/attempts.jsonl"
}
expect_notices() {
	local want=$1 got
	got=$(notice_count)
	[[ $got == "$want" ]] || fail "知らせは $want 件のはずが $got 件（$2）"
}
expect_attempts() {
	local want=$1 got
	got=$(attempt_count)
	[[ $got == "$want" ]] || fail "知らせの投稿は $want 回のはずが $got 回（$2）"
}
# link-check は、知らせを投稿も削除もせず、スクワッドの一覧も読まない。
expect_untouched() {
	[[ ! -e $test_dir/deleted ]] || fail "コメントを削除した（$1）"
	[[ ! -e $test_dir/squad-list-calls ]] || fail "スクワッドの一覧を読んだ（$1）"
}
expect_notice_form() {
	jq -s -e --arg url "$pr" --arg parent "$1" '
		([.[] | select(.body | startswith("/note\n連携なしの知らせ: "))]) as $n
		| ($n | length) == 1
		and ($n[0].body | startswith("/note\n連携なしの知らせ: " + $url + "\n\n"))
		and ($n[0].body | contains("タスクの画面で紐付ける必要はなく") and contains("done にならなければ"))
		and ($n[0].args | (index("--parent") as $i | if $i == null then "" else .[$i+1] end) == $parent)' "$test_dir/posted.jsonl" >/dev/null || fail "知らせの形か返信先が違う（返信先 '$1'）"
}
expect_mark() {
	assert_jq --arg value "記録した $pr" '.metadata.pr_link_no_integration == $value' "$test_dir/task.json" || fail '印が「記録した」でない'
}
waited_once() {
	[[ $(awk '{ total += $1 } END { print total }' "$test_dir/sleeps") == 120 ]] || fail '待ちが 120 秒でない'
}
line="紐付け: 紐付いていない pr: $pr 連携: なし"
mark_gone() { assert_jq '.metadata | has("pr_link_no_integration") | not' "$test_dir/task.json" || fail '印が残っている'; }
become_linked() {
	printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$pr" >"$test_dir/pulls.json"
	set_url "$pr"
}
linked_line="紐付け: 紐付いている pr: $pr"
switched() { [[ $1 == "連携なしにしました: DEMO-4 $pr" ]] || fail "切り替えの出力が違う: $1"; }

# A を切り替え、B の成功で共有の記録だけを消す。C は通常の待ちに戻る。知らせは切り替えの 1 件だけである。
new_scene
switched "$(link "$pr" "$trigger")"
waited_once
expect_mark
expect_notice_form "$trigger"
[[ $(watch_link) == "$line" ]]
expect_notices 1 'A の切り替えのあとの link-check'
expect_untouched 'A'
cp "$test_dir/task.json" "$test_dir/task-a.json"
new_task
printf '200' >"$test_dir/api-status"
[[ $(link "$second" "$trigger") == '紐付けました: '* ]]
[[ ! -s $test_dir/sleeps && ! -e $record && $(wc -l <"$test_dir/curl-calls") -eq 1 ]]
expect_attempts 0 'B の紐付け'
cp "$test_dir/task-a.json" "$test_dir/task.json"
kept_line=$(watch_link)
[[ $kept_line == "$line" && ! -s $test_dir/posted.jsonl ]]
expect_untouched 'B のあとの A'
watch_dir=$test_dir
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
echo 'PASS pr-link-no-integration: B の紐付けで記録だけ消え、A は連携なしのまま decide は done の 1 行。知らせは切り替えの 1 件'
new_task
[[ $(link "$third" "$trigger") == "連携なしにしました: DEMO-4 $third" ]]
waited_once
echo 'PASS pr-link-no-integration: B のあとの C は、通常どおり 120 秒待つ'

# きっかけのコメントの ID がなければ、知らせは根のコメントになる。
new_scene
switched "$(link "$pr")"
expect_notice_form ''
echo 'PASS pr-link-no-integration: きっかけのコメントの ID がなければ、知らせは根のコメントで 1 件'

for stage in pr_link_pending pr_url record; do
	new_scene
	touch "$test_dir/fail-$stage"
	rc=0
	link "$pr" "$trigger" >"$test_dir/failure-out" 2>"$test_dir/failure-err" || rc=$?
	[[ $rc == 1 && ! -e $record ]] || fail "手順の失敗（${stage}）で終了コードか記録が違う（rc=${rc}）"
	grep -q '紐付けられませんでした' "$test_dir/failure-err" || fail "手順の失敗（${stage}）の警告がない"
	expect_attempts 0 "手順の失敗（${stage}）"
	# 役が pr_url を補ったあとの確認。
	set_url "$pr"
	[[ $(watch_link) == "紐付け: 紐付いていない pr: $pr" ]] || fail "手順の失敗（${stage}）のあとの link-check の行が違う"
	[[ ! -e $record ]]
	expect_notices 0 "手順の失敗のあとの link-check（${stage}）"
done
echo 'PASS pr-link-no-integration: 手順 1〜3 の失敗は従来の試み直しに戻り、知らせは出ない'

# B が紐付いて共有の記録を消す。A のタスクと投稿の記録は、そのまま戻す。
other_pr_links() {
	cp "$test_dir/task.json" "$test_dir/task-a.json"
	cp "$test_dir/posted.jsonl" "$test_dir/posted-a.jsonl"
	cp "$test_dir/attempts.jsonl" "$test_dir/attempts-a.jsonl"
	new_task
	printf '200' >"$test_dir/api-status"
	[[ $(link "$second" "$trigger") == '紐付けました: '* && ! -e $record ]] || fail 'B の紐付けが通らない'
	cp "$test_dir/task-a.json" "$test_dir/task.json"
	cp "$test_dir/posted-a.jsonl" "$test_dir/posted.jsonl"
	cp "$test_dir/attempts-a.jsonl" "$test_dir/attempts.jsonl"
}

# 印を書けなかった実行は 1 で終わり、結んだ記録を残し、知らせを出さない。次の確認が印を戻しても、知らせは 0 件のままである。
new_scene
touch "$test_dir/fail-mark"
rc=0
link "$pr" "$trigger" >"$test_dir/failure-out" 2>"$test_dir/failure-err" || rc=$?
[[ $rc == 1 && -z $(<"$test_dir/failure-out") && -f $record ]] || fail "印を書けない切り替えの終了コードか出力が違う（rc=${rc}）"
grep -q '紐付けられませんでした' "$test_dir/failure-err" || fail '印を書けない切り替えの警告がない'
expect_attempts 0 '印を書けない切り替え'
mark_gone
rm "$test_dir/fail-mark"
for role in "${roles[@]}"; do
	[[ $(watch_link "$role") == "$line" ]] || fail "印を戻した link-check の行が違う（役: ${role}）"
	expect_mark
	expect_notices 0 "印を戻したあと（役: ${role}）"
done
expect_untouched '印の復旧'
echo 'PASS pr-link-no-integration: 印を書けない実行は 1 で終わり、次の確認が印を戻して連携なしにするが、知らせは 0 件のまま'

# 戻す前に B が記録を消すと、A は連携なしにならず、知らせも出ない。
new_scene
touch "$test_dir/fail-mark"
rc=0
link "$pr" "$trigger" >/dev/null 2>&1 || rc=$?
[[ $rc == 1 && -f $record ]] || fail "印を書けない切り替えの終了コードか記録が違う（rc=${rc}）"
rm "$test_dir/fail-mark"
other_pr_links
set_url "$pr"
for role in "${roles[@]}"; do
	[[ $(watch_link "$role") == "紐付け: 紐付いていない pr: $pr" ]] || fail "記録が消えたあとの link-check の行が違う（役: ${role}）"
done
mark_gone
expect_notices 0 '戻す前に記録が消えた PR'
echo 'PASS pr-link-no-integration: 印を書けず、戻す前に記録が消えた PR は、連携なしにならず知らせも出ない'

# 印を書けた A は、B が記録を消しても連携なしのままで、知らせは切り替えの 1 件のままである。
new_scene
switched "$(link "$pr" "$trigger")"
[[ -f $record ]] || fail '切り替えで記録を結んでいない'
expect_mark
expect_notices 1 'A の切り替え'
other_pr_links
for role in "${roles[@]}"; do
	[[ $(watch_link "$role") == "$line" && ! -e $record ]] || fail "B のあとの A の link-check の行が違う（役: ${role}）"
	expect_notices 1 "B のあと（役: ${role}）"
done
expect_mark
expect_untouched 'B のあとの A'
echo 'PASS pr-link-no-integration: 印を書けた PR は、記録が消えても連携なしで、知らせは切り替えの 1 件のまま'

# タスクの一覧にほかの PR があると、待ち切れても連携なしにせず、食い違いのままになる。
for existing in absent present; do
	new_scene
	if [[ $existing == present ]]; then
		mkdir -p "${record%/*}"
		printf 'repository: demo/project\npr: %s\ntask: OTHER-1\n記録した時刻: 2026-11-28T00:00:00Z\n' "$second" >"$record"
	fi
	printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$second" >"$test_dir/pulls.json"
	rc=0
	link "$pr" "$trigger" >"$test_dir/failure-out" 2>"$test_dir/failure-err" || rc=$?
	[[ $rc == 1 && -z $(<"$test_dir/failure-out") ]] || fail "食い違いの終了コードか出力が違う（記録: $existing, rc=${rc}）"
	grep -q '紐付けられませんでした' "$test_dir/failure-err" || fail "食い違いの警告がない（記録: ${existing}）"
	if [[ $existing == present ]]; then grep -qxF "pr: $second" "$record" || fail '食い違いで別の PR の記録が変わった'; else [[ ! -e $record ]] || fail '食い違いで記録を結んだ'; fi
	set_url "$pr"
	for role in "${roles[@]}"; do
		[[ $(watch_link "$role") == "紐付け: 食い違い pr: $pr 紐付いた PR: $second" ]] || fail "食い違いの行が違う（役: ${role}）"
	done
	mark_gone
	expect_attempts 0 "食い違い（記録: ${existing}）"
done
echo 'PASS pr-link-no-integration: 一覧にほかの PR があるタスクは連携なしにならず、食い違いで記録も印も知らせもない'

# 手順 3 と 4 の間に link-check が走ると、印が戻り、link-check は投稿しない。切り替えが終わると知らせは 1 件で、印は変わらない。
for role in "${roles[@]}"; do
	new_scene
	if [[ $role == none ]]; then echo '' >"$test_dir/overlap"; else echo "$role" >"$test_dir/overlap"; fi
	switched "$(link "$pr" "$trigger")"
	[[ $(<"$test_dir/overlap-out") == "$line" ]] || fail "3 と 4 の間の link-check の行が違う（役: ${role}）"
	expect_mark
	expect_notices 1 "3 と 4 の間に link-check（役: ${role}）"
	expect_attempts 1 "3 と 4 の間に link-check（役: ${role}）"
	[[ $(watch_link "$role") == "$line" ]] || fail "切り替えのあとの link-check の行が違う（役: ${role}）"
	expect_notices 1 "切り替えのあと（役: ${role}）"
	expect_untouched "3 と 4 の間（役: ${role}）"
done
echo 'PASS pr-link-no-integration: 手順 3 と 4 の間に link-check が走っても印が戻るだけで、知らせは切り替えの 1 件'

# どの役の link-check と、マージのあとの unlinked-check を流しても、知らせは 1 件のままである。同じ PR を一覧に足しても変わらない。
new_scene
switched "$(link "$pr" "$trigger")"
expect_notices 1 '切り替え'
for role in "${roles[@]}"; do
	[[ $(watch_link "$role") == "$line" ]] || fail "link-check の行が違う（役: ${role}）"
	expect_notices 1 "link-check（役: ${role}）"
	watch_unlinked "$role"
	expect_notices 1 "unlinked-check（役: ${role}）"
	expect_attempts 1 "役: $role"
done
expect_untouched '各役の確認'
expect_mark
become_linked
for role in "${roles[@]}"; do
	[[ $(watch_link "$role") == "$linked_line" ]] || fail "紐付いたあとの link-check の行が違う（役: ${role}）"
	mark_gone
	watch_unlinked "$role"
	expect_notices 1 "紐付いたあと（役: ${role}）"
	expect_attempts 1 "紐付いたあと（役: ${role}）"
done
expect_untouched '紐付いたあと'
echo 'PASS pr-link-no-integration: どの役の link-check と unlinked-check を流しても、知らせは 1 件のまま'

# 120 秒の 404 で切り替えたあと、最初の link-check の前に同じ PR が紐付く。2 回で、知らせは切り替えの 1 件のままで、記録・待ちの印・マークがない。
new_scene
switched "$(link "$pr" "$trigger")"
[[ -f $record ]] || fail '切り替えで記録を結んでいない'
become_linked
[[ $(watch_link) == "$linked_line" ]] || fail '最初の link-check の行が違う'
expect_notices 1 '最初の link-check'
[[ ! -e $record ]] || fail '最初の link-check で記録が残った'
assert_jq '.metadata | has("pr_link_pending") | not' "$test_dir/task.json" || fail '最初の link-check で待ちの印が残った'
mark_gone
[[ $(watch_link monitor) == "$linked_line" ]] || fail '2 回目の link-check の行が違う'
expect_notices 1 '2 回目の link-check'
mark_gone
expect_untouched '最初の確認の前に紐付いた'
echo 'PASS pr-link-no-integration: 最初の確認の前に紐付いても、知らせは切り替えの 1 件で、記録も待ちの印も連携なしの印も、最初の確認で消える'

# 知らせの投稿を失敗させると 0 件で、どの役の確認でも、squad-pr-link の流し直しでも増えない。
new_scene
touch "$test_dir/fail-notice"
rc=0
link "$pr" "$trigger" >"$test_dir/out" 2>"$test_dir/err" || rc=$?
[[ $rc == 0 && $(<"$test_dir/out") == "連携なしにしました: DEMO-4 $pr" && ! -s $test_dir/err ]] || fail "投稿に失敗した切り替えの終了コードか出力が変わった（rc=${rc}）"
expect_mark
expect_attempts 1 '投稿の失敗'
expect_notices 0 '投稿の失敗'
for role in "${roles[@]}"; do
	[[ $(watch_link "$role") == "$line" ]] || fail "link-check の行が違う（役: ${role}）"
	watch_unlinked "$role"
	expect_notices 0 "投稿の失敗のあと（役: ${role}）"
	expect_attempts 1 "投稿の失敗のあと（役: ${role}）"
done
rm "$test_dir/fail-notice"
rc=0
link "$pr" "$trigger" >"$test_dir/out" 2>"$test_dir/err" || rc=$?
[[ $rc == 0 && ! -s $test_dir/err ]] || fail "流し直しの終了コードか標準エラーが違う（rc=${rc}）"
expect_notices 0 '同じ PR で流し直した'
expect_attempts 1 '同じ PR で流し直した'
expect_untouched '投稿の失敗'
echo 'PASS pr-link-no-integration: 投稿に失敗すると知らせは 0 件で、どの役の確認でも、流し直しでも増えない'

# 同じリポジトリの 2 つの PR が待ち切れると、知らせは記録を結んだ PR にだけ 1 件出る。
# 記録は ln で結ぶ 1 つの共有のファイルなので、先に結んだ側が勝つ。2 つのタスクのスタブは持たず、順に流して、勝つ PR を入れ替える。
for order in first-then-second second-then-first; do
	new_scene
	if [[ $order == first-then-second ]]; then winner=$pr loser=$second; else winner=$second loser=$pr; fi
	[[ $(link "$winner" "$trigger") == "連携なしにしました: DEMO-4 $winner" ]] || fail "先の PR の切り替えの出力が違う（${order}）"
	cp "$test_dir/posted.jsonl" "$test_dir/posted-a.jsonl"
	cp "$test_dir/attempts.jsonl" "$test_dir/attempts-a.jsonl"
	new_task
	cp "$test_dir/posted-a.jsonl" "$test_dir/posted.jsonl"
	cp "$test_dir/attempts-a.jsonl" "$test_dir/attempts.jsonl"
	[[ $(link "$loser" "$trigger") == "紐付けていません（連携なし）: DEMO-4 $loser" ]] || fail "あとの PR の出力が違う（${order}）"
	expect_notices 1 "待ち切れた 2 つの PR（${order}）"
	expect_attempts 1 "待ち切れた 2 つの PR（${order}）"
	[[ $(jq -sr '.[] | select(.body | startswith("/note\n連携なしの知らせ: ")) | .body | split("\n")[1]' "$test_dir/posted.jsonl") == "連携なしの知らせ: $winner" ]] || fail "知らせが、記録を結んだ PR にない（${order}）"
done
echo 'PASS pr-link-no-integration: 同じリポジトリの 2 つの PR が待ち切れても、知らせは記録を結んだ PR にだけ 1 件'
