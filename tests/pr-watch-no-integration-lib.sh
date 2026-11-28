#!/usr/bin/env bash
# 連携なしの記録とマークを扱う squad-pr-watch のテスト（squad-pr-watch-no-integration-test.sh と squad-pr-watch-no-integration-unlinked-test.sh）の、共通の準備と補助の関数。
# 実際のタスク・PR・ホストの記録には触れない。記録の根は PR_LINK_STATE_ROOT で一時ディレクトリに向ける。
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
update_pr() {
	jq "$1" "$test_dir/mergeable.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/mergeable.json"
}

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
merge_request_body() {
	printf 'マージの依頼: %s\n前の回: %s\nマージする PR: %s' "${1-$merge_head}" "${2-round-1}" "${3-$pr}"
}
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
	# マージした PR の head。依頼の head と比べる（done の照合の 4 と 5）。
	update_pr ".headRefOid = \"$merge_head\""
	add_comment round-1 agent orchestrator "$(round_body "$pr")"
	# 回の後のマージの依頼（done の照合の 5）。head は PR から読む 40 桁で、回の確認するコミット（abcdef0）で始まる。
	add_comment merge-1 agent orchestrator "$(merge_request_body)"
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
same_pr_round() { add_comment round-2 agent orchestrator "$(round_body "$pr")"; }
drop_request() {
	jq 'map(select(.id != "merge-1"))' "$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
prepend_comment() { # ID 作者の種類 作者の ID 本文（コメントの並びの先頭に足す）
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg id "$1" --arg type "$2" --arg author "$3" --arg content "$4" \
		'[$base[0] + {id: $id, author_type: $type, author_id: $author, content: $content}] + .' "$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
