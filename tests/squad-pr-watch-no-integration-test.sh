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
# 見張りの知らせは、名簿のエージェント（リーダー）が書いたコメントとして残る。
comment.update(author_type="agent", author_id="orchestrator")
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
# 2 回目の規則の一覧の読み取りの直前に、ファイルを差し替える（書く直前の読み直しの前に、データが変わる場面）。
#   rules-on-reread.json → 規則、comments-on-reread.json → コメント、task-on-reread.json → タスク、fail-on-reread → fail（読めなくする）
if [[ "${1-} ${2-} ${3-}" == 'issue wakeup list' ]]; then
	reread=
	for name in rules-on-reread.json comments-on-reread.json task-on-reread.json fail-on-reread; do
		[[ ! -f $dir/$name ]] || reread=1
	done
	if [[ -n $reread ]]; then
		if [[ -f $dir/rules-read ]]; then
			if [[ -f $dir/rules-on-reread.json ]]; then mv "$dir/rules-on-reread.json" "$dir/rules.json"; fi
			if [[ -f $dir/comments-on-reread.json ]]; then mv "$dir/comments-on-reread.json" "$dir/comments.json"; fi
			if [[ -f $dir/task-on-reread.json ]]; then mv "$dir/task-on-reread.json" "$dir/task.json"; fi
			if [[ -f $dir/fail-on-reread ]]; then mv "$dir/fail-on-reread" "$dir/fail"; fi
		else
			touch "$dir/rules-read"
		fi
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
# 試み直しの API を呼んでいるあいだに、別のタスクが同じプロジェクトとリポジトリの記録を結んだ場面を作る。
if [[ -f $dir/record-on-api ]]; then
	bash -c 'source "$PR_WATCH_TEST_ROOT/common/monitor/squad-pr-link-lib"; pr_link_record_create proj-1 "$(cat "$PR_WATCH_TEST_DIR/record-on-api")" TASK-2' >/dev/null
fi
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
	rm -f "$test_dir/api-called" "$test_dir/fail-after" "$test_dir/curl-config" "$test_dir/now" "$test_dir/sleeps" "$test_dir"/fail-set-* "$test_dir/fail-status" "$test_dir/fail-members" "$test_dir/record-on-api"
	rm -f "$test_dir/fail-post" "$test_dir/fail-notice-squad" "$test_dir/roster-read" "$test_dir/rules-read" "$test_dir/rules-on-reread.json" "$test_dir/rules-after-status.json"
	rm -f "$test_dir/comments-on-reread.json" "$test_dir/task-on-reread.json" "$test_dir/fail-on-reread" "$test_dir/fail"
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

# 記録がなく link-check を始め、試み直しの API を呼んでいるあいだに別のタスクが記録を結び、そのあとに紐付いた: 記録を読み直して消す。
reset_ni
update_task ".metadata.pr_link_pending = \"$pr\""
printf '200' >"$test_dir/api-status"
urls_json "$pr" >"$test_dir/pulls-after.json"
printf '%s' "$pr" >"$test_dir/record-on-api"
check_ni "紐付け: 紐付いている pr: $pr"
api_once
record_absent
mark_absent pr_link_pending
echo 'PASS no-integration: 試み直しの間に結ばれた記録は、紐付いたあとに消える'

# unlinked-check のマージと閉じたときの扱い、見張りの終わりの知らせ。
add_comment() { # ID 作者の種類 作者の ID 本文（返信にするときは、環境変数 reply_to に返信先のコメントの ID を入れる）
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg id "$1" --arg type "$2" --arg author "$3" --arg content "$4" --arg parent "${reply_to-}" \
		'. + [($base[0] + {id: $id, author_type: $type, author_id: $author, content: $content}) | if $parent != "" then .parent_id = $parent else . end]' "$test_dir/comments.json" >"$test_dir/changed.json"
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
	# 回の後のマージの依頼（done の照合の 5）。head は PR から読む 40 桁で、回の確認するコミット（abcdef0）で始まる。
	add_comment merge-1 agent orchestrator "マージの依頼: $merge_head"
}
merge_head=abcdef0123456789abcdef0123456789abcdef01
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
unset prepare_extra
# タスクの担当がスクワッドでなくなったときは、名簿を読めないので、知らせを書かず規則を残す（知らせ済みの判定の場面に置く）。
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

# 知らせ済みと読むのは、ci_watch_thread への名簿のエージェントの返信だけ。同じ 1 行目でも、人間・名簿の外のエージェント・別のコメントへの返信・返信でないコメントは、知らせを省かない。
not_done_first="連携なしのリポジトリの PR がマージされましたが、見張りはタスクを \`done\` にしませんでした（規則の確認した回（round-1）が今の回（round-2）と違う）。このタスクの成果をマージしたなら、タスクを \`done\` にしてください。PR: \`${pr}\`"
not_done_scene() {
	unlinked_scene record
	same_pr_round
	update_pr '.state = "MERGED"'
}
# 作者の種類・作者の ID・返信先（空なら返信でない）の組ごとに、知らせを書くか。
for who in 'member human-1 ci-thread' 'agent outsider ci-thread' 'agent orchestrator other-comment' 'agent monitor' 'agent orchestrator ci-thread' 'agent monitor ci-thread'; do
	read -r type author reply <<<"$who"
	not_done_scene
	reply_to=$reply add_comment existing-notice "$type" "$author" "$not_done_first"
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 知らせ済み（$who）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	rule_gone
	if [[ $reply == ci-thread && $author != outsider && $type == agent ]]; then
		no_posts
	else
		assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
	fi
done
echo 'PASS no-integration: マージ後の知らせは、ci_watch_thread への名簿のエージェントの返信だけを知らせ済みと読む'

# 見張りの終わりの知らせも、同じ判定で読む。
for who in 'member human-1 ci-thread' 'agent orchestrator other-comment' 'agent orchestrator ci-thread'; do
	created=$(stamp -$((71 * 3600 + 60)))
	read -r type author reply <<<"$who"
	unlinked_scene record "$created"
	end=$(python3 -c 'import datetime,sys;print((datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")+datetime.timedelta(hours=72)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$created")
	first_line="連携なしのリポジトリの PR のマージ待ちの見張りが、${end} に終わります。そのあとにマージしたときは、タスクを \`done\` にしてください。マージせずに閉じたときは、\`done\` にしません。PR: \`${pr}\`"
	reply_to=$reply add_comment existing-notice "$type" "$author" "$first_line"
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 終わりの知らせ（$who）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	if [[ $reply == ci-thread && $type == agent ]]; then
		no_notice
	else
		assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
	fi
done
echo 'PASS no-integration: 見張りの終わりの知らせも、ci_watch_thread への名簿のエージェントの返信だけを知らせ済みと読む'

# unlinked_link_stop の知らせも同じ判定で読む。タイトルと判定の行が同じでも、人間・名簿の外・別のコメントへの返信は、知らせを省かない。
link_stop_scene() {
	unlinked_scene record
	update_task '.metadata.repository = "example/other"'
}
link_stop_scene
unlinked_run
((unlinked_status == 0))
link_stop_body=$(jq -rs '.[0].body | split("\n") | .[0:2] | join("\n")' "$test_dir/posted.jsonl")
[[ $link_stop_body == 'PR の URL を確認できませんでした。'$'\n''紐付け: '* ]]
rule_gone
for who in 'member human-1 ci-thread' 'agent outsider ci-thread' 'agent orchestrator ci-thread'; do
	read -r type author reply <<<"$who"
	link_stop_scene
	reply_to=$reply add_comment existing-notice "$type" "$author" "$link_stop_body"$'\n\nメンション'
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 紐付けの知らせ（$who）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	rule_gone
	if [[ $reply == ci-thread && $type == agent && $author != outsider ]]; then
		no_posts
	else
		assert_jq -s 'map(select(.body | startswith("PR の URL を確認できませんでした。"))) | length == 1' "$test_dir/posted.jsonl"
	fi
done
echo 'PASS no-integration: 紐付けの知らせも、ci_watch_thread への名簿のエージェントの返信だけを知らせ済みと読む'

# 名簿を読めないときは、3 つの知らせのどれも書かず、規則を残して 1 で終わる。
roster_gone() { update_task '.assignee_type = "agent" | .assignee_id = "orchestrator"'; }
link_stop_scene
roster_gone
unlinked_run
((unlinked_status == 1))
rule_kept
no_posts
grep -q '名簿を読めないため' "$test_dir/err"
unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
roster_gone
unlinked_run
((unlinked_status == 1))
rule_kept
no_posts
# 見張りの終わりの知らせは、名簿を読めないと照合の段階で待つので、前の「名簿を読めるまで見張りの終わりの知らせを待つ」の場面で見ている。
echo 'PASS no-integration: 名簿を読めないときは、知らせを書かず、規則を残して 1 で終わる'

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

# done の照合の 5。確認した回より後に、その回の確認するコミットを指すマージの依頼がなければ、マージされても done にしない。
# レビュー中に人間が手でマージした PR は、依頼の前なので、done にせず、人間に知らせる。
drop_request() {
	jq 'map(select(.id != "merge-1"))' "$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
no_request() { drop_request; }
human_request() { drop_request; add_comment merge-x member human-1 "マージの依頼: $merge_head"; }
rogue_request() { drop_request; add_comment merge-x agent rogue "マージの依頼: $merge_head"; }
other_head_request() { drop_request; add_comment merge-x agent orchestrator 'マージの依頼: 1111111111111111111111111111111111111111'; }
fenced_request() { drop_request; add_comment merge-x agent orchestrator $'```\nマージの依頼: '"$merge_head"$'\n```'; }
result_request() { drop_request; add_comment merge-x agent orchestrator $'/note\n返事の回: round-1\nマージの依頼: '"$merge_head"; }
before_round_request() {
	drop_request
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg content "マージの依頼: $merge_head" \
		'[$base[0] + {id: "merge-before", author_type: "agent", author_id: "orchestrator", content: $content}] + .' \
		"$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
prepare_extra=no_request merged_refuses 'レビュー中（マージの依頼の前）に人間がマージ'
grep -q '確認した回より後に、確認するコミット（abcdef0）のマージの依頼がない' "$test_dir/err"
prepare_extra=human_request merged_refuses 'マージの依頼が人間のコメント'
prepare_extra=rogue_request merged_refuses 'マージの依頼が名簿の外のエージェントのコメント'
prepare_extra=other_head_request merged_refuses 'マージの依頼が回のコミットと別の head'
prepare_extra=fenced_request merged_refuses 'マージの依頼がコードの囲みの中'
prepare_extra=result_request merged_refuses 'マージの依頼が結果のコメント'
prepare_extra=before_round_request merged_refuses 'マージの依頼が回より前（前の回の依頼）'
unset prepare_extra
echo 'PASS no-integration: 確認した回より後のマージの依頼がなければ、マージされても done にせず、理由と知らせを出して止める'

# 依頼として読むもの。名簿のリーダーのコメントと、回で待つ役の制御記録。回の確認するコミットは、接頭辞でも 40 桁でもよい。
for case in leader control full; do
	unlinked_scene record
	case $case in
	control)
		drop_request
		add_comment decide-1 agent monitor $'/note\n返事の待ち: 次の依頼を決めます'
		add_comment merge-x agent monitor "マージの依頼: $merge_head"$'\n前の回: round-1' ;;
	full)
		jq --arg commit "$merge_head" 'map(if .id == "round-1" then .content |= sub("確認するコミット: abcdef0"; "確認するコミット: " + $commit) else . end)' \
			"$test_dir/comments.json" >"$test_dir/changed.json"
		mv "$test_dir/changed.json" "$test_dir/comments.json" ;;
	esac
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL ${case}: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	assert_jq '.status == "done"' "$test_dir/task.json" || { echo "FAIL ${case}: done でない" >&2; cat "$test_dir/err" >&2; exit 1; }
	rule_gone
	no_posts
done
echo 'PASS no-integration: リーダーの依頼と、待つ役の制御記録の依頼で done にする。回のコミットは 40 桁でもよい'

# 依頼の候補を読めないとき（引用）は、done にも知らせにもせず、規則を残して 1 で終わる。読めるようになれば、次の確認で決める。
unlinked_scene record
drop_request
add_comment merge-x agent orchestrator $'> マージの依頼: '"$merge_head"$'\n> 前の回: round-1'
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 1))
grep -q '照合できませんでした' "$test_dir/err"
[[ $(done_calls) == '[]' ]]
rule_kept
no_posts
drop_request
jq 'map(select(.id != "merge-x"))' "$test_dir/comments.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/comments.json"
add_comment merge-1 agent orchestrator "マージの依頼: $merge_head"
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
echo 'PASS no-integration: マージの依頼の候補を読めないときは、規則を残して 1 で終わり、読めれば次の確認で決める'

# 見張りの終わりの知らせは、照合の 1 から 3 だけで書く。マージの依頼は要らない。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
drop_request
unlinked_run
((unlinked_status == 0))
assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: 終わりの知らせは、マージの依頼がなくても書く'

# 名簿は照合の 1 回だけ読み、書く直前の読み直しでは読み直さない。
unlinked_scene record
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 0))
assert_jq -s '[.[] | select(.[0:3] == ["squad","member","list"])] | length == 1' "$test_dir/calls.jsonl"
assert_jq -s '[.[] | select(.[0:3] == ["issue","wakeup","list"])] | length == 2' "$test_dir/calls.jsonl"
echo 'PASS no-integration: done の前の読み直しで、名簿は読み直さない'

# 照合のあと書く前にデータが変わったら、古い判定では何も書かず、規則を残して 0 で終わる。次の確認で決め直す。
reread_add() { # ID 作者の種類 作者の ID 本文（読み直しのときに増えるコメント）
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg id "$1" --arg type "$2" --arg author "$3" --arg content "$4" \
		'. + [$base[0] + {id: $id, author_type: $type, author_id: $author, content: $content}]' "$test_dir/comments.json" >"$test_dir/comments-on-reread.json"
}
reread_drop_request() { jq 'map(select(.id != "merge-1"))' "$test_dir/comments.json" >"$test_dir/comments-on-reread.json"; }
changed_window() { # 名前
	((unlinked_status == 0)) || { echo "FAIL $1: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	[[ $(done_calls) == '[]' ]] || { echo "FAIL $1: done にした" >&2; exit 1; }
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	rule_kept
	assert_jq -s '[.[] | select(.[0:3] == ["issue","wakeup","list"])] | length == 2' "$test_dir/calls.jsonl"
	grep -q '書かずに規則を残します' "$test_dir/err" || { echo "FAIL $1: 理由を出さない" >&2; cat "$test_dir/err" >&2; exit 1; }
}
# done: 別の PR の回が書かれる。次の確認は、確認した回が今の回でないので、知らせを 1 回だけ書く。
unlinked_scene record
update_pr '.state = "MERGED"'
reread_add round-2 agent orchestrator "$(round_body "$other")"
unlinked_run
changed_window 'done: 別の PR の回'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
rule_gone
# done: マージの依頼がコメントから消える。次の確認で知らせを書く。
unlinked_scene record
update_pr '.state = "MERGED"'
reread_drop_request
unlinked_run
changed_window 'done: 依頼が消えた'
rm -f "$test_dir/rules-read"
unlinked_run
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
# done: metadata の PR とマークが別の PR に変わる。
unlinked_scene record
update_pr '.state = "MERGED"'
jq ".metadata.pr_url = \"$other\" | .metadata.pr_link_pending = \"$other\" | .metadata.pr_link_no_integration = \"$other\"" "$test_dir/task.json" >"$test_dir/task-on-reread.json"
unlinked_run
changed_window 'done: metadata が変わった'
# done にしなかったときの知らせ: 依頼が書かれて照合が合う。次の確認で done にする。
unlinked_scene record
no_request
update_pr '.state = "MERGED"'
reread_add merge-x agent orchestrator "マージの依頼: $merge_head"
unlinked_run
changed_window 'not-done: 依頼が書かれた'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
no_posts
# done にしなかったときの知らせ: 理由が変わる（別の PR の回）。次の確認で、新しい理由の知らせを 1 回だけ書く。
unlinked_scene record
no_request
update_pr '.state = "MERGED"'
reread_add round-2 agent orchestrator "$(round_body "$pr")"
unlinked_run
changed_window 'not-done: 回が変わった'
rm -f "$test_dir/rules-read"
unlinked_run
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("確認した回（round-1）が今の回（round-2）と違う"))' "$test_dir/posted.jsonl"
# 終わりの知らせ: 別の PR の回が書かれる。次の確認は照合が合わないので、書かない。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
reread_add round-2 agent orchestrator "$(round_body "$other")"
unlinked_run
changed_window 'end: 別の PR の回'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
no_notice
echo 'PASS no-integration: 照合のあと書く前に回・依頼・metadata が変わったら、何も書かず規則を残し、次の確認で決め直す'

# 書く直前の読み直しで、コメントを読めなければ、何も書かず規則を残して 1 で終わる。読めるようになれば決め直す。
for write in done not-done end; do
	case $write in
	end) unlinked_scene record "$(stamp -$((71 * 3600 + 60)))" ;;
	*) unlinked_scene record; update_pr '.state = "MERGED"' ;;
	esac
	if [[ $write == not-done ]]; then no_request; fi
	echo 'issue comment list' >"$test_dir/fail-on-reread"
	unlinked_run
	((unlinked_status == 1)) || { echo "FAIL ${write}: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	grep -q '書く直前の読み直しで' "$test_dir/err"
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	rule_kept
	rm -f "$test_dir/fail" "$test_dir/rules-read"
	unlinked_run
	((unlinked_status == 0))
	case $write in
	done) assert_jq '.status == "done"' "$test_dir/task.json" ;;
	not-done) assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl" ;;
	end) assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl" ;;
	esac
done
echo 'PASS no-integration: 書く直前の読み直しで読めないものがあれば、何も書かず規則を残して 1 で終わる'

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
