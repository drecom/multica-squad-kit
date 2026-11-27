#!/usr/bin/env bash
# 連携なしの記録とマークがあるときの link-check を確認する。
# 実際のタスク・PR・ホストの記録には触れない。記録の根は PR_LINK_STATE_ROOT で一時ディレクトリに向ける。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
export PR_LINK_STATE_ROOT=$test_dir/pr-link-state
pr=https://github.com/example/repo/pull/67
other=https://github.com/example/repo/pull/68
third=https://github.com/example/repo/pull/69
export MULTICA_TOKEN=fixture-token MULTICA_SERVER_URL=https://multica.invalid

# 時計は、now のファイルがあるときだけ差し替える。ないときは本物を呼ぶ。
real_date=$(command -v date)
printf '%s' "$real_date" >"$test_dir/real-date"
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
dir=$PR_WATCH_TEST_DIR
if [[ -f $dir/now && ${1-} == +%s ]]; then cat "$dir/now"; exit 0; fi
exec "$(<"$dir/real-date")" "$@"
EOF
cat >"$test_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
dir=$PR_WATCH_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo $(($(<"$dir/now") + $1)) >"$dir/now"
EOF

# API のあとに一覧を更新し、読み直しの失敗と metadata の書き込みの失敗も再現する。このテストだけの包みにする。
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-}" == 'issue get test-issue' ]]; then
	# この機能が保存する metadata の鍵を除き、実物の見本で検証する。
	jq 'del(.metadata.pr_link_pending, .metadata.pr_link_no_integration, .metadata.pr_link_tried_at)' \
		"$dir/task.json" >"$dir/task-base.json"
	python3 "$PR_WATCH_TEST_ROOT/tests/cli-stub.py" pr-watch "$dir" multica calls.jsonl \
		emit issue-get "$dir/task-base.json" -- "$@" >/dev/null
	cat "$dir/task.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue metadata set' ]]; then
	key=
	for ((i = 1; i <= $#; i++)); do
		if [[ ${!i} == --key ]]; then j=$((i + 1)); key=${!j}; fi
	done
	if [[ -f $dir/fail-set-$key ]]; then
		jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
		echo 'CLI mock failure' >&2
		exit 1
	fi
fi
if [[ "${1-} ${2-} ${3-}" == 'issue comment add' ]]; then
	if [[ -f $dir/fail-post ]]; then echo 'CLI mock failure' >&2; exit 1; fi
	python3 - "$@" <<'POSTPY'
import datetime
import json
import os
import sys
from pathlib import Path

work = Path(os.environ["PR_WATCH_TEST_DIR"])
args = sys.argv[1:]
with (work / "calls.jsonl").open("a") as out:
    out.write(json.dumps(args) + "\n")
parent = args[args.index("--parent") + 1]
body = Path(args[args.index("--content-file") + 1]).read_text()
comments = json.loads((work / "comments.json").read_text())
response = json.loads((Path(os.environ["PR_WATCH_TEST_ROOT"]) / "tests/fixtures/cli/issue-comment-add.json").read_text())[0]
response.update(id="link-record-" + str(len(comments) + 1), content=body,
                parent_id=parent or None, created_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
comment = json.loads((work / "comment-prototype.json").read_text())
comment.update({key: response[key] for key in ("id", "content", "parent_id", "created_at")})
comments.append(comment)
(work / "comments.json").write_text(json.dumps(comments))
with (work / "posted.jsonl").open("a") as out:
    out.write(json.dumps(dict(args=args, body=body)) + "\n")
print(json.dumps(response))
POSTPY
	exit $?
fi
if [[ "${1-} ${2-} ${3-}" == 'issue status test-issue' ]]; then
	jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
	if [[ -f $dir/fail-status ]]; then echo 'CLI mock failure' >&2; exit 1; fi
	jq --arg status "$4" '.status = $status' "$dir/task.json" >"$dir/task-status.json"
	mv "$dir/task-status.json" "$dir/task.json"
	if [[ -f $dir/rules-after-status.json ]]; then mv "$dir/rules-after-status.json" "$dir/rules.json"; fi
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue wakeup list' && -f $dir/rules-on-reread.json ]]; then
	if [[ -f $dir/rules-read ]]; then
		mv "$dir/rules-on-reread.json" "$dir/rules.json"
	else
		touch "$dir/rules-read"
	fi
fi
if [[ "${1-} ${2-} ${3-}" == 'workspace member list' ]]; then
	if [[ -f $dir/fail-members ]]; then echo 'CLI mock failure' >&2; exit 1; fi
	cat "$dir/human-members.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'squad list --output' && -f $dir/fail-notice-squad ]]; then
	[[ ! -f $dir/roster-read ]] || exit 1
	touch "$dir/roster-read"
fi
if [[ "${1-} ${2-} ${3-}" == 'issue pull-requests test-issue' && -f $dir/api-called && -f $dir/fail-after ]]; then
	exit 1
fi
exec "$dir/bin/multica-base" "$@"
EOF
cat >"$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/curl-calls.jsonl"
cat >"$dir/curl-config"
touch "$dir/api-called"
cp "$dir/pulls-after.json" "$dir/pulls.json"
[[ $(<"$dir/api-status") != transport ]] || exit 7
cat "$dir/api-status"
EOF
chmod +x "$test_dir/bin/multica" "$test_dir/bin/curl" "$test_dir/bin/date" "$test_dir/bin/sleep"

update_task() {
	jq "$1" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
}
reset_ni() {
	reset_fixture
	update_task '.project_id = "proj-1"'
	rm -rf -- "$PR_LINK_STATE_ROOT"
	: >"$test_dir/curl-calls.jsonl"
	rm -f "$test_dir/api-called" "$test_dir/fail-after" "$test_dir/curl-config" "$test_dir/now" "$test_dir/sleeps" "$test_dir"/fail-set-* "$test_dir/fail-status" "$test_dir/fail-members"
	rm -f "$test_dir/fail-post" "$test_dir/fail-notice-squad" "$test_dir/roster-read" "$test_dir/rules-read" "$test_dir/rules-on-reread.json" "$test_dir/rules-after-status.json"
	printf 'trigger-1' >"$test_dir/trigger-comment"
	printf '404' >"$test_dir/api-status"
	printf '{"pull_requests":[]}' >"$test_dir/pulls.json"
	printf '{"pull_requests":[]}' >"$test_dir/pulls-after.json"
}
urls_json() {
	jq -n --args '{pull_requests: [$ARGS.positional[] | {html_url:.}]}' -- "$@"
}
make_record() {
	(source "$root/common/monitor/squad-pr-link-lib"; pr_link_record_create "${1:-proj-1}" "${2:-$pr}" TASK-1) >/dev/null
}
record_path() { printf '%s/%s/%s' "$PR_LINK_STATE_ROOT" "$1" "$2"; }
record_present() { [[ -f $(record_path "${1:-proj-1}" "${2:-example/repo}") ]]; }
record_absent() { [[ ! -e $(record_path "${1:-proj-1}" "${2:-example/repo}") ]]; }
mark_is() { assert_jq --arg key "$1" --arg value "$2" '.metadata[$key] == $value' "$test_dir/task.json"; }
mark_absent() { assert_jq --arg key "$1" '.metadata | has($key) | not' "$test_dir/task.json"; }
both_marks() { mark_is pr_link_pending "$1"; mark_is pr_link_no_integration "$1"; }
set_marks() {
	update_task ".metadata.pr_link_pending = \"$1\" | .metadata.pr_link_no_integration = \"$1\""
}
stamp() {
	python3 -c 'import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}
tried_recent() {
	assert_jq '.metadata.pr_link_tried_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z https://github.com/example/repo/pull/67$")' "$test_dir/task.json"
}
tried_absent() { mark_absent pr_link_tried_at; }
add_record_comment() {
	# 試み直しの記録のコメントを、指定の秒数だけ前に書かれたものとして足す。
	local ago=$1 created
	created=$(stamp "-$ago")
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg created "$created" --arg pr "$pr" \
		'. + [$base[0] + {author_type:"agent", created_at:$created,
		content:("/note\n紐付けの試み直し: 見つからない（404） pr: " + $pr + " 時刻: " + $created + "\n")}]' \
		"$test_dir/comments.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/comments.json"
}
run_check() {
	(cd "$test_dir" && bash "$script" link-check test-issue trigger-1) >"$test_dir/out" 2>"$test_dir/err"
}
check_ni() {
	run_check
	[[ $(<"$test_dir/out") == "$1" ]] || {
		printf '期待した出力:\n%s\n実際の出力:\n%s\n' "$1" "$(<"$test_dir/out")" >&2
		exit 1
	}
}
no_api() { [[ ! -s $test_dir/curl-calls.jsonl ]]; }
api_once() {
	assert_jq -s --arg pr "$pr" 'length == 1 and (.[0] |
		(index("--max-time") as $i | .[$i+1] == "30") and
		(index("--data") as $i | .[$i+1] | fromjson | .url == $pr) and
		(.[-1] == "https://multica.invalid/api/issues/test-issue/pull-requests"))' "$test_dir/curl-calls.jsonl"
}
no_posts() { [[ ! -s $test_dir/posted.jsonl ]]; }
no_metadata_delete() { assert_jq -s 'all(.[]; .[0:3] != ["issue","metadata","delete"])' "$test_dir/calls.jsonl"; }
set_keys() {
	jq -s -c '[.[] | select(.[0:3] == ["issue","metadata","set"]) | .[index("--key") + 1]]' "$test_dir/calls.jsonl"
}
set_keys_are() { [[ $(set_keys) == "$1" ]]; }
err_empty() { [[ ! -s $test_dir/err ]]; }

# 記録があって紐付いていないと、2 つのマークを書き、「連携なし」を足す。試み直しの結果は書かず、時刻だけを残す。
reset_ni
make_record
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
both_marks "$pr"
api_once
no_posts
tried_recent
no_metadata_delete
record_present
err_empty
set_keys_are '["pr_link_pending","pr_link_no_integration","pr_link_tried_at"]'
# 通常のマークのメタデータ（型）は string で書く。
assert_jq -s '[.[] | select(.[0:3] == ["issue","metadata","set"]) | .[index("--type") + 1]] | all(. == "string")' "$test_dir/calls.jsonl"
echo 'PASS no-integration: 記録があると 2 つのマークを書いて連携なしを足し、API を 1 回呼んで時刻だけを残す'

# 書いたマークがあれば、記録がなくても「連携なし」のままにする。マークの書き直しは要らない。
reset_ni
set_marks "$pr"
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
api_once
no_posts
tried_recent
set_keys_are '["pr_link_tried_at"]'
record_absent
err_empty
echo 'PASS no-integration: 記録がなくても、2 つのマークが同じ PR なら連携なしのまま'

# 記録もなく、マークが揃わない・別の PR なら、今と同じ動作にする（連携なしを足さず、試み直しの記録を書く）。
for state in ni-other only-pending absent-marks; do
	reset_ni
	case $state in
	ni-other) update_task ".metadata.pr_link_pending = \"$pr\" | .metadata.pr_link_no_integration = \"$other\"" ;;
	only-pending) update_task ".metadata.pr_link_pending = \"$pr\"" ;;
	absent-marks) : ;;
	esac
	check_ni "紐付け: 紐付いていない pr: $pr"
	if [[ $state == absent-marks ]]; then
		no_api
		no_posts
		set_keys_are '[]'
	else
		api_once
		assert_jq -s --arg pr "$pr" 'length == 1 and (.[0].body | startswith("/note\n紐付けの試み直し: 見つからない（404） pr: " + $pr + " 時刻: "))' "$test_dir/posted.jsonl"
		tried_absent
	fi
	mark_absent pr_link_tried_at
	[[ $state == ni-other ]] && mark_is pr_link_no_integration "$other"
	record_absent
done
echo 'PASS no-integration: 記録もなく、マークが揃わないか別の PR なら、今と同じ動作で連携なしを足さない'

# マークの正規形は、大文字と小文字・番号の 0・クエリを区別せず比べる。
reset_ni
update_task ".metadata.pr_link_pending = \"$pr\" | .metadata.pr_link_no_integration = \"http://GITHUB.COM/Example/Repo/pull/00067/files?diff=1\""
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
echo 'PASS no-integration: pr_link_no_integration は正規形で比べる'

# マークを書けなかったときは、「連携なし」を足さず、標準エラーに 1 行出す。次の確認で書き直し、足す。
# pr_link_pending を書けなかった PR は、書き直した同じ確認から試み直す。
# pr_link_no_integration だけを書けなかったときは、今の試み直しの動作で、記録のコメントを書く。
for key in pr_link_pending pr_link_no_integration; do
	reset_ni
	make_record
	touch "$test_dir/fail-set-$key"
	check_ni "紐付け: 紐付いていない pr: $pr"
	[[ $(wc -l <"$test_dir/err" | tr -d ' ') == 1 ]]
	grep -q "連携なしの扱いのマーク（${key}）を書けないため" "$test_dir/err"
	record_present
	tried_absent
	if [[ $key == pr_link_pending ]]; then
		no_api
		no_posts
		mark_absent pr_link_pending
		mark_is pr_link_no_integration "$pr"
	else
		api_once
		assert_jq -s --arg pr "$pr" 'length == 1 and (.[0].body | startswith("/note\n紐付けの試み直し: 見つからない（404） pr: " + $pr + " 時刻: "))' "$test_dir/posted.jsonl"
		mark_is pr_link_pending "$pr"
		mark_absent pr_link_no_integration
	fi
	rm -f "$test_dir/fail-set-$key"
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/curl-calls.jsonl"
	check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
	err_empty
	both_marks "$pr"
	if [[ $key == pr_link_pending ]]; then
		# 書けなかったマークは、この確認の中で書き直し、同じ確認で試み直す。
		api_once
		tried_recent
		[[ $(jq -s 'length' "$test_dir/posted.jsonl") == 0 ]]
	else
		# 直前にコメントの記録を書いたので、間隔の中は呼ばない。
		no_api
		[[ $(jq -s 'length' "$test_dir/posted.jsonl") == 1 ]]
	fi
done
echo 'PASS no-integration: マークを書けなければ連携なしを足さず、次の確認で書き直して足す'

# 両方のマークを書けないときは、1 行に両方の名前を出す。
reset_ni
make_record
touch "$test_dir/fail-set-pr_link_pending" "$test_dir/fail-set-pr_link_no_integration"
check_ni "紐付け: 紐付いていない pr: $pr"
grep -q "連携なしの扱いのマーク（pr_link_pending と pr_link_no_integration）を書けないため" "$test_dir/err"
[[ $(wc -l <"$test_dir/err" | tr -d ' ') == 1 ]]
no_api
echo 'PASS no-integration: 両方のマークを書けなければ、1 行に両方の名前を出す'

# 試み直しの間隔は、コメントの記録と pr_link_tried_at の遅いほうから 5 分で測る。
reset_ni
make_record
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
api_once
: >"$test_dir/curl-calls.jsonl"
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
no_api
echo 'PASS no-integration: 直前に API を呼んだ時刻から 5 分たつまで、API を呼ばない'

for case_name in plain-recent other-pr-recent old-tried recent-tried-old-comment old-tried-recent-comment malformed future empty not-string; do
	reset_ni
	make_record
	set_marks "$pr"
	case $case_name in
	plain-recent) update_task ".metadata.pr_link_tried_at = \"$(stamp -60)\""; expected=1 ;;
	other-pr-recent) update_task ".metadata.pr_link_tried_at = \"$(stamp -60) $other\""; expected=1 ;;
	old-tried) update_task ".metadata.pr_link_tried_at = \"$(stamp -600) $pr\""; expected=1 ;;
	recent-tried-old-comment) update_task ".metadata.pr_link_tried_at = \"$(stamp -60) $pr\""; add_record_comment 600; expected=0 ;;
	old-tried-recent-comment) update_task ".metadata.pr_link_tried_at = \"$(stamp -600) $pr\""; add_record_comment 60; expected=0 ;;
	malformed) update_task '.metadata.pr_link_tried_at = "yesterday"'; expected=1 ;;
	future) update_task ".metadata.pr_link_tried_at = \"$(stamp 3600) $pr\""; expected=1 ;;
	empty) update_task ".metadata.pr_link_tried_at = \"2026-13-45T00:00:00Z $pr\""; expected=1 ;;
	not-string) update_task '.metadata.pr_link_tried_at = 12345'; expected=1 ;;
	esac
	check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
	if ((expected)); then
		api_once
		tried_recent
	else
		no_api
	fi
	no_posts
done
echo 'PASS no-integration: 時刻が古い・読めない・未来なら 1 回呼び、直近の記録かあとの時刻があれば呼ばない'

# 紐付かなかった結果ごとに、連携なしでは試み直しの記録を書かず、時刻だけを残す。
for status in 200 404 403 500 transport; do
	reset_ni
	make_record
	printf '%s' "$status" >"$test_dir/api-status"
	check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
	api_once
	no_posts
	tried_recent
	both_marks "$pr"
	record_present
done
echo 'PASS no-integration: 200・404・403・500・通信の失敗でも、試み直しの記録を書かず時刻を残す'

# トークンがなく API を呼べないときは、時刻を書かず、記録も書かない。
reset_ni
make_record
(cd "$test_dir" && unset MULTICA_TOKEN && bash "$script" link-check test-issue trigger-1) >"$test_dir/out" 2>"$test_dir/err"
[[ $(<"$test_dir/out") == "紐付け: 紐付いていない pr: $pr 連携: なし" ]]
no_api
no_posts
tried_absent
echo 'PASS no-integration: API を呼べないときは時刻を書かない'

# 時刻の書き込みに失敗しても、出力と終了コードは変えない。
reset_ni
make_record
touch "$test_dir/fail-set-pr_link_tried_at"
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
api_once
no_posts
tried_absent
echo 'PASS no-integration: 時刻を書けなくても出力を変えない'

# 呼んだあとに、別の PR だけが紐付いたときは食い違いを出し、連携なしを足さない。一覧を読めないときは未確認を出す。
reset_ni
make_record
urls_json "$other" >"$test_dir/pulls-after.json"
check_ni "紐付け: 食い違い pr: $pr 紐付いた PR: $other"
api_once
no_posts
tried_recent
reset_ni
make_record
touch "$test_dir/fail-after"
run_check
[[ $(<"$test_dir/out") == "紐付け: 未確認 pr: $pr 理由: "* && $(<"$test_dir/out") != *'連携: なし'* ]]
api_once
no_posts
tried_recent
echo 'PASS no-integration: 呼んだあとの一覧が食い違いか読めないなら、連携なしを足さず記録も書かない'

# 試み直しで紐付いたときは、記録を書き、連携なしの記録と 3 つのマークを消す。「連携なし」は足さない。
reset_ni
make_record
urls_json "$pr" >"$test_dir/pulls-after.json"
check_ni "紐付け: 紐付いている pr: $pr"
api_once
assert_jq -s --arg pr "$pr" 'length == 1 and
	(.[0].args | index("--parent") as $i | .[$i+1] == "trigger-1") and
	(.[0].body | startswith("/note\n紐付けの試み直し: 紐付いた pr: " + $pr + " 時刻: "))' "$test_dir/posted.jsonl"
record_absent
mark_absent pr_link_pending
mark_absent pr_link_no_integration
echo 'PASS no-integration: 試み直しで紐付くと、記録を書き、連携なしの記録とマークを消す'

# すでに紐付いていて記録があれば、記録を消す。API は呼ばない。
reset_ni
make_record
urls_json "$pr" >"$test_dir/pulls.json"
check_ni "紐付け: 紐付いている pr: $pr"
no_api
no_posts
record_absent
err_empty
echo 'PASS no-integration: 紐付いているときは記録を消す'

# 記録とマークの両方があって紐付いたときは、記録も 2 つのマークも消す。
reset_ni
make_record
set_marks "$pr"
urls_json "$pr" >"$test_dir/pulls.json"
check_ni "紐付け: 紐付いている pr: $pr"
no_api
record_absent
mark_absent pr_link_pending
mark_absent pr_link_no_integration
echo 'PASS no-integration: 紐付いたマークの PR は、記録と 2 つのマークを消す'

# 自動の関連付け（link_source が title）で紐付いたときも、紐付いていると読み、記録を消す。
reset_ni
make_record
jq -n --arg url "$pr" '{pull_requests: [{html_url: $url, link_source: "title"}]}' >"$test_dir/pulls.json"
check_ni "紐付け: 紐付いている pr: $pr"
no_api
record_absent
echo 'PASS no-integration: link_source が title の PR でも紐付いていると読み、記録を消す'

# 消すのは、タスクのプロジェクトとリポジトリの記録だけ。ほかのプロジェクトとほかのリポジトリの記録は残す。
reset_ni
make_record proj-1 "$pr"
make_record proj-1 https://github.com/example/other/pull/1
make_record proj-2 "$pr"
urls_json "$pr" >"$test_dir/pulls.json"
check_ni "紐付け: 紐付いている pr: $pr"
record_absent proj-1 example/repo
record_present proj-1 example/other
record_present proj-2 example/repo
echo 'PASS no-integration: 消すのはこのプロジェクトとリポジトリの記録だけ'

# 別のタスクの PR が紐付いて記録が消えても、マークのある PR は連携なしのまま。記録のないあとの PR は、今と同じ動作に戻る。
reset_ni
make_record
# A: 連携なしで始める。
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
both_marks "$pr"
# B: 同じプロジェクトとリポジトリの別のタスクで PR が紐付き、記録が消える。
cp "$test_dir/task.json" "$test_dir/task-a.json"
update_task ".metadata.pr_url = \"$other\" | del(.metadata.pr_link_pending, .metadata.pr_link_no_integration, .metadata.pr_link_tried_at)"
urls_json "$other" >"$test_dir/pulls.json"
check_ni "紐付け: 紐付いている pr: $other"
record_absent
# A のマークは残っているので、そのまま連携なし。
cp "$test_dir/task-a.json" "$test_dir/task.json"
printf '{"pull_requests":[]}' >"$test_dir/pulls.json"
: >"$test_dir/curl-calls.jsonl"
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
no_posts
# C: マークのない PR は、記録がないので連携なしを足さず、今と同じ動作。
update_task ".metadata.pr_url = \"$third\" | del(.metadata.pr_link_pending, .metadata.pr_link_no_integration, .metadata.pr_link_tried_at)"
check_ni "紐付け: 紐付いていない pr: $third"
no_posts
echo 'PASS no-integration: 別の PR で記録が消えても、マークのある PR は連携なしのまま、あとの PR は今の動作に戻る'

# 記録がなくなったあとの PR は、squad-pr-link が 404 を 120 秒まで待つ。待つ間の時計は差し替える。
reset_ni
make_record
check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
urls_json "$other" >"$test_dir/pulls.json"
update_task ".metadata.pr_url = \"$other\" | del(.metadata.pr_link_pending, .metadata.pr_link_no_integration, .metadata.pr_link_tried_at)"
check_ni "紐付け: 紐付いている pr: $other"
record_absent
update_task 'del(.metadata.pr_url)'
printf '{"pull_requests":[]}' >"$test_dir/pulls.json"
printf '1000' >"$test_dir/now"
: >"$test_dir/sleeps"
link_out=$(cd "$test_dir" && bash "$root/common/monitor/squad-pr-link" test-issue "$third" 2>/dev/null)
[[ $link_out == '連携なしにしました: '* ]]
[[ $(awk '{ sum += $1 } END { print sum }' "$test_dir/sleeps") == 120 ]]
echo 'PASS no-integration: 記録のない次の PR は、404 を 120 秒まで待つ'

# 記録が壊れている（シンボリックリンク）ときは、記録がないものとして今の動作で進み、標準エラーに 1 行出す。
reset_ni
mkdir -p "$PR_LINK_STATE_ROOT/proj-1/example" "$test_dir/elsewhere"
: >"$test_dir/elsewhere/file"
ln -s "$test_dir/elsewhere/file" "$PR_LINK_STATE_ROOT/proj-1/example/repo"
check_ni "紐付け: 紐付いていない pr: $pr"
[[ $(wc -l <"$test_dir/err" | tr -d ' ') == 1 ]]
no_api
set_keys_are '[]'
[[ -L $PR_LINK_STATE_ROOT/proj-1/example/repo ]]
echo 'PASS no-integration: 記録のパスを断ったときは記録がないものとして進み、1 行だけ出す'

# project_id がないタスクは、記録を読まず、今と同じ動作にする。
reset_ni
make_record
update_task 'del(.project_id)'
check_ni "紐付け: 紐付いていない pr: $pr"
no_api
set_keys_are '[]'
record_present
echo 'PASS no-integration: project_id がないときは記録を読まない'

# 紐付いていない・紐付いている以外の判定（未確認・食い違い・作業先の不一致）は、記録があっても変えない。
for state in foreign mismatch unreadable; do
	reset_ni
	make_record
	case $state in
	foreign) update_task '.metadata.repository = "example/other"' ;;
	mismatch) urls_json "$other" >"$test_dir/pulls.json" ;;
	unreadable) echo 'issue pull-requests test-issue' >"$test_dir/fail" ;;
	esac
	run_check
	[[ $(<"$test_dir/out") != *'連携: なし'* ]]
	no_api
	set_keys_are '[]'
	record_present
	rm -f "$test_dir/fail"
done
echo 'PASS no-integration: 未確認・食い違い・作業先の不一致は、記録があっても変えない'

# unlinked-check の CI とコンフリクトの行と知らせは、記録があってもないときと同じにする。
update_pr() {
	jq "$1" "$test_dir/mergeable.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/mergeable.json"
}
for with_record in 0 1; do
	reset_ni
	if ((with_record)); then make_record; fi
	update_task ".status = \"in_review\" | .metadata.pr_url = \"$pr\""
	fixture issue-wakeups | jq --arg mark '紐付いていない PR のマージ待ちの見張りで起きました。' \
		'. as $base | [$base + {id:"mine",instruction:($mark + "\n確認")}]' >"$test_dir/rules.json"
	update_pr '.mergeable = "CONFLICTING"'
	line=$(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator monitor)
	[[ $line == $'/note\nCI abcdef0: 失敗をリーダーに知らせた\nコンフリクト: CONFLICTING head: abcdef0123456789 知らせ: 書いた' ]]
	assert_jq -s 'length == 2 and all(.[]; (.body | contains("mention://squad/test-squad")))
		and (.[1].body | startswith("head: abcdef0\nコンフリクトを検出しました。\n"))' "$test_dir/posted.jsonl"
	if ((with_record)); then record_present; else record_absent; fi
done
echo 'PASS no-integration: unlinked-check の CI とコンフリクトの行と知らせは、記録があってもないときと同じ'

# unlinked-check のマージと閉じたときの扱い、見張りの終わりの知らせ。
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
# 規則の指示の最後の 2 行。省くと、round-1 と $pr の標準の 2 行にする。
rule_lines() { printf '見張る PR: %s\n確認した回: %s' "${1-$pr}" "${2-round-1}"; }
unlinked_prepare() {
	local lines=${2-$(rule_lines)}
	update_task ".status = \"in_review\" | .metadata.pr_url = \"$pr\""
	fixture issue-wakeups | jq --arg mark "$UNLINKED_MARK" --arg created "${1-$(stamp -3600)}" --arg lines "$lines" \
		'. as $base | [$base + {id:"mine",instruction:($mark + "\n確認\n" + $lines),created_at:$created}]' >"$test_dir/rules.json"
	jq '.[0] += {creator_id:"human-1"} | map(.name = "Demo-Test")' "$test_dir/squads.json" >"$test_dir/squads-updated.json"
	mv "$test_dir/squads-updated.json" "$test_dir/squads.json"
	fixture member-list | jq '[. + {user_id:"human-1",name:"Owner"}]' >"$test_dir/human-members.json"
	# 名簿のリーダーが書いた回。回の判定は、登録と同じく名簿から読む。
	fixture squad-member-list | jq '. as $base | [$base + {member_id: "orchestrator", member_type: "agent"}, $base + {member_id: "monitor", member_type: "agent"}]' >"$test_dir/members.json"
	add_comment round-1 agent orchestrator "$(round_body "$pr")"
}
unlinked_scene() {
	reset_ni
	[[ ${1-} != record ]] || { make_record; set_marks "$pr"; }
	if (($# > 2)); then unlinked_prepare "${2-}" "$3"; else unlinked_prepare "${2-}"; fi
}
unlinked_run() {
	set +e
	(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator monitor) >"$test_dir/out" 2>"$test_dir/err"
	unlinked_status=$?
	set -e
}
done_calls() { jq -s '[.[] | select(.[0:3] == ["issue","status","test-issue"])]' "$test_dir/calls.jsonl"; }
# 見張りの終わりの知らせだけを数える（CI の知らせは同じ場面で出る）。
notice_filter='[.[] | select(.body | startswith("連携なしのリポジトリの PR のマージ待ちの見張りが、"))]'
not_done_filter='[.[] | select(.body | startswith("連携なしのリポジトリの PR がマージされましたが、"))]'
no_notice() { assert_jq -s "$notice_filter | length == 0" "$test_dir/posted.jsonl"; }
rule_kept() { assert_jq 'length == 1' "$test_dir/rules.json"; }
rule_gone() { assert_jq 'length == 0' "$test_dir/rules.json"; }
UNLINKED_MARK='紐付いていない PR のマージ待ちの見張りで起きました。'

# 連携なしのマークが同じ PR のままマージされたら、タスクを done にし、見張りを止める。
unlinked_scene record
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 0))
[[ $(done_calls | jq -c 'map(.[0:5])') == '[["issue","status","test-issue","done","--no-start"]]' ]]
assert_jq '.status == "done"' "$test_dir/task.json"
rule_gone
no_posts
echo 'PASS no-integration: unlinked-check は、連携なしのマークの PR がマージされたら done にして止める'

# 照合に必要な読み取りが失敗しても、規則を残す。次の確認で読めれば同じ規則で done にする。
for query in 'issue comment list' 'squad list --output' 'squad member list' 'agent get monitor'; do
	unlinked_scene record
	update_pr '.state = "MERGED"'
	printf '%s\n' "$query" >"$test_dir/fail"
	unlinked_run
	((unlinked_status == 1))
	grep -qF '照合できませんでした' "$test_dir/err"
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	rule_kept
	no_posts
	rm -f "$test_dir/fail"
	unlinked_run
	((unlinked_status == 0))
	assert_jq '.status == "done"' "$test_dir/task.json"
	rule_gone
	no_posts
done
echo 'PASS no-integration: コメントや名簿を読めないときは規則を残し、読めるようになれば done にする'

# 終わりの知らせでも、照合に必要な名簿を読めるまで知らせを待つ。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
echo 'squad member list' >"$test_dir/fail"
unlinked_run
((unlinked_status == 1))
grep -qF '名簿を読めない' "$test_dir/err"
rule_kept
no_notice
rm -f "$test_dir/fail"
unlinked_run
((unlinked_status == 0))
rule_kept
assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: 名簿を読めるまで見張りの終わりの知らせを待つ'

# マークがない（または別の PR の）マージは、今と同じく done にせず止める。
for kind in none other; do
	unlinked_scene record
	if [[ $kind == none ]]; then
		update_task 'del(.metadata.pr_link_pending, .metadata.pr_link_no_integration)'
	else
		set_marks "$other"
	fi
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0))
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	rule_gone
done
echo 'PASS no-integration: マークがない・別の PR のマージは done にしない'

# 閉じた PR は、マークがあっても done にしない。見張りは止める。
unlinked_scene record
update_pr '.state = "CLOSED"'
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq '.status == "in_review"' "$test_dir/task.json"
rule_gone
echo 'PASS no-integration: 閉じた PR は done にしない'

# done にできなかったときは、規則を残し、理由を標準エラーに出して 1 で終わる。
unlinked_scene record
update_pr '.state = "MERGED"'
: >"$test_dir/fail-status"
unlinked_run
((unlinked_status == 1))
[[ $(<"$test_dir/err") == *'done にできませんでした'* ]]
rule_kept
assert_jq '.status == "in_review"' "$test_dir/task.json"
echo 'PASS no-integration: done にできないときは規則を残して 1 で終わる'

# 作成から 71 時間を過ぎたら、終わりの知らせを 1 回だけ書く。呼ぶ人間をメンションする。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
unlinked_run
((unlinked_status == 0))
assert_jq -s "$notice_filter"' | length == 1 and (.[0].args | index("--parent") as $i | .[$i + 1] == "ci-thread")
	and (.[0].body | rtrimstr("\n") | split("\n") | length == 2)
	and (.[0].body | split("\n")[0] | endswith("に終わります。そのあとにマージしたときは、タスクを `done` にしてください。マージせずに閉じたときは、`done` にしません。PR: `'"$pr"'`"))
	and (.[0].body | split("\n")[1] == "[@Owner](mention://member/human-1)")' "$test_dir/posted.jsonl"
rule_kept
unlinked_run
((unlinked_status == 0))
assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: 71 時間を過ぎた連携なしのマージ待ちは、終わりの知らせを 1 回だけ書く'

# 終了時刻は、規則の作成時刻の 72 時間後の UTC にする。
created=$(stamp -$((71 * 3600 + 60)))
unlinked_scene record "$created"
unlinked_run
expected_end=$(python3 -c 'import datetime, sys
print((datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ") + datetime.timedelta(hours=72)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$created")
assert_jq -s --arg end "$expected_end" "$notice_filter"' | .[0].body | split("\n")[0] | contains("見張りが、" + $end + " に終わります")' "$test_dir/posted.jsonl"
echo 'PASS no-integration: 終わりの時刻は規則の作成の 72 時間後'

# 71 時間に満ちないとき、マークがないとき、記録の別の PR のときは書かない。
unlinked_scene record "$(stamp -$((71 * 3600 - 600)))"
unlinked_run
((unlinked_status == 0))
no_notice
unlinked_scene record
unlinked_run
no_notice
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
update_task 'del(.metadata.pr_link_pending, .metadata.pr_link_no_integration)'
unlinked_run
no_notice
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
set_marks "$other"
unlinked_run
no_notice
echo 'PASS no-integration: 71 時間に満ちないとき・マークがないとき・別の PR のときは知らせない'

# 呼ぶ人間を決められないときは、メンションの行を省いて書き、理由を標準エラーに出して 1 で終わる。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
: >"$test_dir/fail-members"
unlinked_run
((unlinked_status == 1))
assert_jq -s "$notice_filter"' | length == 1 and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
[[ $(<"$test_dir/err") == *'メンションを省きました'* ]]
echo 'PASS no-integration: 呼ぶ人間を決められないときは、メンションなしで書いて 1 で終わる'

# done の照合。規則の 2 行・回の判定と対象の PR・metadata のどれかが合わなければ、マージされても done にしない。
# どの場合も、標準エラーと知らせに同じ理由を書き、見張りを止める。
merged_refuses() { # 名前 [規則の最後の 2 行 [created]]
	local name=$1 created=${3-} reason url first
	if (($# > 1)); then unlinked_scene record "$created" "$2"; else unlinked_scene record; fi
	"${prepare_extra:-:}"
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL $name: 終了コード $unlinked_status" >&2; exit 1; }
	[[ $(done_calls) == '[]' ]] || { echo "FAIL $name: done にした" >&2; exit 1; }
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	rule_gone
	[[ $(grep -c 'done にしません' "$test_dir/err") == 1 ]] || { echo "FAIL $name: 理由が 1 行でない" >&2; cat "$test_dir/err" >&2; exit 1; }
	reason=$(grep -F 'PR はマージされましたが、done にしません（' "$test_dir/err")
	reason=${reason#*done にしません（}
	reason=${reason%）。}
	[[ -n $reason ]] || { echo "FAIL $name: 照合の理由が空" >&2; cat "$test_dir/err" >&2; exit 1; }
	url=$(jq -r '.metadata.pr_url' "$test_dir/task.json")
	first="連携なしのリポジトリの PR がマージされましたが、見張りはタスクを \`done\` にしませんでした（${reason}）。このタスクの成果をマージしたなら、タスクを \`done\` にしてください。PR: \`${url}\`"
	assert_jq -s --arg first "$first" "$not_done_filter"' | length == 1
		and (.[0].args | index("--parent") as $i | .[$i + 1] == "ci-thread")
		and (.[0].body | rtrimstr("\n") | split("\n") == [$first, "[@Owner](mention://member/human-1)"])' "$test_dir/posted.jsonl" \
		|| { echo "FAIL $name: 知らせの内容か宛先が違う" >&2; cat "$test_dir/posted.jsonl" >&2; exit 1; }
}
other_round() { add_comment other-round agent orchestrator "$(round_body "$other")"; }
merged_refuses '見張る PR が同じリポジトリの別の PR' "$(rule_lines "$other")"
merged_refuses '見張る PR の行がない' $'確認した回: round-1'
merged_refuses '見張る PR の行が 2 つ' "$(rule_lines)"$'\n見張る PR: '"$pr"
merged_refuses '確認した回の行がない' "見張る PR: $pr"
merged_refuses '確認した回の行が 2 つ' "$(rule_lines)"$'\n確認した回: round-1'
merged_refuses '見張る PR が URL でない' "$(rule_lines 'https://example.com/x')"
merged_refuses '回が存在しない' "$(rule_lines "$pr" no-such-round)"
prepare_extra=other_round merged_refuses '回の対象の PR が見張る PR と違う' "$(rule_lines "$pr" other-round)"
human_round() { add_comment human-round member human-1 "$(round_body "$pr")"; }
prepare_extra=human_round merged_refuses '回が人間のコメント' "$(rule_lines "$pr" human-round)"
rogue_round() { add_comment rogue-round agent rogue "$(round_body "$pr")"; }
prepare_extra=rogue_round merged_refuses '回が名簿の外のエージェントのコメント' "$(rule_lines "$pr" rogue-round)"
result_round() { add_comment result-round agent orchestrator "$(round_body "$pr")"$'\n返事の回: round-1'; }
prepare_extra=result_round merged_refuses '回が結果のコメント' "$(rule_lines "$pr" result-round)"
# 登録のあとに pr_url と連携なしのマークを別のマージ済みの PR に書き換えても、回の PR と合わないので done にしない。
swapped_marks() { update_task ".metadata.pr_url = \"$other\" | .metadata.pr_link_pending = \"$other\" | .metadata.pr_link_no_integration = \"$other\""; }
prepare_extra=swapped_marks merged_refuses 'pr_url とマークが別の PR に変わった'
edit_round_pr() {
	jq --arg content "$(round_body "$other")" 'map(if .id == "round-1" then .content = $content else . end)' \
		"$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
prepare_extra=edit_round_pr merged_refuses '登録した回のコメントの対象 PR が編集された'
change_assignee() { update_task '.assignee_type = "agent" | .assignee_id = "orchestrator"'; }
prepare_extra=change_assignee merged_refuses 'タスクの担当がスクワッドから変わった'
unset prepare_extra
echo 'PASS no-integration: 規則の行・回・metadata のどれかが合わないマージは、done にせず、理由と知らせを出して止める'

same_pr_round() { add_comment round-2 agent orchestrator "$(round_body "$pr")"; }
prepare_extra=same_pr_round merged_refuses '同じ PR の新しい回の途中でマージ'
grep -q '確認した回（round-1）が今の回（round-2）と違う' "$test_dir/err"
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
prepare_extra=other_round merged_refuses 'PR 差し替え後に規則と metadata とマークがすべて旧 PR に戻り、旧 PR がマージ'
grep -q '確認した回（round-1）が今の回（other-round）と違う' "$test_dir/err"
echo 'PASS no-integration: 同じ PR の再レビューや PR の差し替え後は、古い回で done にせず、人間に一度だけ知らせる'

# 差し替えた PR は OPEN のまま、旧 PR だけが MERGED になったときも done にしない。
unlinked_scene record
other_round
swapped_marks
mv "$test_dir/bin/gh" "$test_dir/bin/gh-base"
cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-} ${5-}" == 'pr view https://github.com/example/repo/pull/67 state,headRefOid,mergeable' ]]; then
	jq '.state = "MERGED"' "$dir/mergeable.json"
else
	exec "$dir/bin/gh-base" "$@"
fi
EOF
chmod +x "$test_dir/bin/gh"
unlinked_run
mv "$test_dir/bin/gh-base" "$test_dir/bin/gh"
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq '.status == "in_review"' "$test_dir/task.json"
assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
echo 'PASS no-integration: metadata が差し替え先を指したまま、旧 PR だけがマージされても done にしない'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
: >"$test_dir/fail-post"
unlinked_run
((unlinked_status == 1))
rule_kept
no_posts
rm "$test_dir/fail-post"
unlinked_run
((unlinked_status == 0))
rule_gone
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: done にしなかったときの知らせの投稿に失敗したら規則を残し、次の確認で一度だけ書く'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
: >"$test_dir/fail-members"
unlinked_run
((unlinked_status == 1))
rule_gone
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
grep -q 'メンションを省きました' "$test_dir/err"
echo 'PASS no-integration: 呼ぶ人間を決められないときは、マージ後の知らせをメンションなしで書いて 1 で終わる'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
touch "$test_dir/fail-notice-squad"
unlinked_run
((unlinked_status == 1))
rule_gone
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
grep -q 'メンションを省きました' "$test_dir/err"
echo 'PASS no-integration: 照合後に知らせの宛先のスクワッドを取得できなくても、マージ後の知らせをメンションなしで書く'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
first="連携なしのリポジトリの PR がマージされましたが、見張りはタスクを \`done\` にしませんでした（規則の確認した回（round-1）が今の回（round-2）と違う）。このタスクの成果をマージしたなら、タスクを \`done\` にしてください。PR: \`${pr}\`"
add_comment existing-notice member human-1 "$first"
unlinked_run
((unlinked_status == 0))
rule_gone
no_posts
echo 'PASS no-integration: 人間が同じ 1 行目を投稿済みなら、マージ後の知らせを重ねない'

# 書き込み直前に規則が入れ替わったら、古い規則では done・マージ後の知らせ・期限の知らせのどれも書かない。
for write in done not-done end; do
	unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
	if [[ $write != end ]]; then update_pr '.state = "MERGED"'; fi
	if [[ $write == not-done ]]; then same_pr_round; fi
	jq --arg created "$(stamp -3600)" '.[0] += {id:"replacement",created_at:$created}' \
		"$test_dir/rules.json" >"$test_dir/rules-on-reread.json"
	unlinked_run
	((unlinked_status == 0))
	[[ $(done_calls) == '[]' ]]
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	assert_jq 'map(.id) == ["replacement"]' "$test_dir/rules.json"
	assert_jq -s '[.[] | select(.[0:3] == ["issue","wakeup","list"])] | length == 2' "$test_dir/calls.jsonl"
	if [[ $write == end ]]; then
		unlinked_run
		((unlinked_status == 0))
		no_notice
	fi
done
echo 'PASS no-integration: 書く直前に規則が入れ替わったら何も書かず、新しい規則の時刻を次の確認で使う'

# done を書いたあとに新しい規則が入っても、停止でその規則を消さない。
unlinked_scene record
update_pr '.state = "MERGED"'
jq '. + [.[0] + {id:"replacement"}]' "$test_dir/rules.json" >"$test_dir/rules-after-status.json"
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
assert_jq 'map(.id) == ["replacement"]' "$test_dir/rules.json"
echo 'PASS no-integration: done を書いたあとの停止では、確認に使った一覧の規則だけを消す'

# 規則の作り手が人間でも、照合がすべて合えば done にする。作り手は信頼の根拠にしない。
unlinked_scene record
jq '.[0] += {created_by:"human-1", created_by_name:"Owner", created_by_agent:false}' "$test_dir/rules.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/rules.json"
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
rule_gone
echo 'PASS no-integration: 規則の作り手が人間でも、照合が合えば done にする'

# 照合が合わないときは、71 時間を過ぎても終わりの知らせを書かない。標準エラーに理由を出し、CI とコンフリクトの行は今のままにする。
for case in line round latest; do
	case $case in
	line) lines='確認した回: round-1' ;;
	round) lines=$(rule_lines "$pr" other-round) ;;
	latest) lines=$(rule_lines) ;;
	esac
	unlinked_scene record "$(stamp -$((71 * 3600 + 60)))" "$lines"
	if [[ $case == round ]]; then other_round; fi
	if [[ $case == latest ]]; then same_pr_round; fi
	unlinked_run
	((unlinked_status == 0))
	no_notice
	[[ $(grep -c '知らせを書きません' "$test_dir/err") == 1 ]]
	[[ $(<"$test_dir/out") == $'/note'* ]]
done
echo 'PASS no-integration: 照合が合わなければ 71 時間を過ぎても知らせず、理由を標準エラーに出す'

# マークの片方を書けなかった PR は、link-check で書き直したあとにマージされれば、unlinked-check で done になる。
for key in pr_link_pending pr_link_no_integration; do
	reset_ni
	make_record
	touch "$test_dir/fail-set-$key"
	check_ni "紐付け: 紐付いていない pr: $pr"
	rm -f "$test_dir/fail-set-$key"
	check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
	both_marks "$pr"
	unlinked_prepare
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0))
	assert_jq '.status == "done"' "$test_dir/task.json"
	rule_gone
done
echo 'PASS no-integration: マークの片方を書き直したあと、マージされると done になる'
