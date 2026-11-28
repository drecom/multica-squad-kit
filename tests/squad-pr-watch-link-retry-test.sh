#!/usr/bin/env bash
# マークのある PR の紐付け直しと、読み直した一覧による判定を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
pr=https://github.com/example/repo/pull/67
other=https://github.com/example/repo/pull/68
export MULTICA_TOKEN=fixture-token MULTICA_SERVER_URL=https://multica.invalid
export PR_LINK_STATE_ROOT=$test_dir/pr-link-state

# API のあとに一覧を更新し、読み直しの失敗も再現する。このテストだけの包みにする。
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-}" == 'issue get test-issue' ]]; then
	# この機能が保存する metadata の鍵を除き、実物の見本で検証する。
	jq 'del(.metadata.pr_link_pending,.metadata.pr_link_no_integration,.metadata.pr_link_tried_at)' "$dir/task.json" >"$dir/task-base.json"
	python3 "$PR_WATCH_TEST_ROOT/tests/cli-stub.py" pr-watch "$dir" multica calls.jsonl \
		emit issue-get "$dir/task-base.json" -- "$@" >/dev/null
	cat "$dir/task.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue metadata set' && $6 == pr_link_tried_at && -f $dir/fail-tried ]]; then
	exit 1
fi
if [[ "${1-} ${2-} ${3-}" == 'issue comment add' ]]; then
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
if (work / "fail-post").exists():
    sys.exit(1)
parent = args[args.index("--parent") + 1]
# 起動したコメントのある実行は、そのコメントへの返信だけを受け付け、根のコメントや別の親を断る。
if (work / "trigger-comment").exists() and parent != (work / "trigger-comment").read_text():
    sys.exit(1)
body = Path(args[args.index("--content-file") + 1]).read_text()
comments = json.loads((work / "comments.json").read_text())
response = json.loads((Path(os.environ["PR_WATCH_TEST_ROOT"]) / "tests/fixtures/cli/issue-comment-add.json").read_text())[0]
posted = work / "posted.jsonl"
response.update(id="link-record-" + str(len(posted.read_text().splitlines()) + 1), content=body,
                parent_id=parent or None, created_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
comment = json.loads((work / "comment-prototype.json").read_text())
comment.update({key: response[key] for key in ("id", "content", "parent_id", "created_at")})
comment["author_id"] = os.environ.get("MULTICA_AGENT_ID", comment["author_id"])
# hide-post: 投稿は成り立つが、次の読みにはまだ見えない。
if not (work / "hide-post").exists():
    comments.append(comment)
(work / "comments.json").write_text(json.dumps(comments))
with posted.open("a") as out:
    out.write(json.dumps(dict(args=args, body=body)) + "\n")
# fail-post-created: コメントはできたが、応答は失敗として返る。
if (work / "fail-post-created").exists():
    sys.exit(1)
print(json.dumps(response))
POSTPY
	exit $?
fi
if [[ "${1-} ${2-} ${3-}" == 'issue comment delete' ]]; then
	# 消したコメントは、本文を空にして残す。fail-delete のあいだは消せない。
	jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
	[[ ! -f $dir/fail-delete ]] || exit 1
	jq --arg id "$4" 'map(if .id == $id then .content = "" else . end)' "$dir/comments.json" >"$dir/comments-deleted.json"
	mv "$dir/comments-deleted.json" "$dir/comments.json"
	echo '{}'
	exit 0
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
chmod +x "$test_dir/bin/multica" "$test_dir/bin/curl"

update_task() {
	jq "$1" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
}
reset_retry() {
	reset_fixture
	update_task ".metadata.pr_link_pending = \"$pr\""
	: >"$test_dir/curl-calls.jsonl"
	rm -f "$test_dir/api-called" "$test_dir/fail-after" "$test_dir/curl-config" "$test_dir/fail-post" "$test_dir/epoch" "$test_dir/fail-tried" \
		"$test_dir/fail-delete" "$test_dir/hide-post" "$test_dir/fail-post-created"
	printf 'trigger-1' >"$test_dir/trigger-comment"
	printf '200' >"$test_dir/api-status"
	printf '{"pull_requests":[]}' >"$test_dir/pulls-after.json"
}
after_urls() {
	jq -n --args '{pull_requests: [$ARGS.positional[] | {html_url:.}]}' -- "$@" >"$test_dir/pulls-after.json"
}
pending_remains() { assert_jq --arg pr "$pr" '.metadata.pr_link_pending == $pr' "$test_dir/task.json"; }
pending_deleted() { assert_jq '.metadata | has("pr_link_pending") | not' "$test_dir/task.json"; }
api_once() {
	# 呼ぶ側の squad-pr-link-lib と API が読む引数、正規形の URL、30 秒の時間切れを確認する。
	assert_jq -s --arg pr "$pr" 'length == 1 and (.[0] |
		(index("--max-time") as $i | .[$i+1] == "30") and
		(index("--config") as $i | .[$i+1] == "-") and
		(index("-X") as $i | .[$i+1] == "POST") and
		(index("--data") as $i | .[$i+1] | fromjson | .url == $pr) and
		(.[-1] == "https://multica.invalid/api/issues/test-issue/pull-requests") and
		(all(.[]; contains("fixture-token") | not)))' "$test_dir/curl-calls.jsonl"
	[[ $(<"$test_dir/curl-config") == 'header = "Authorization: Bearer fixture-token"' ]]
}
no_api() { [[ ! -s $test_dir/curl-calls.jsonl ]]; }
check_retry() { check_output "$1" link-check test-issue trigger-1; }
check_record() {
	# 読む側: squad-pr-watch の link_record_data が /note と固定の行を読む。
	assert_jq -s --arg result "$1" --arg pr "$pr" 'length == 1 and
		(.[0].args | (index("--parent") as $i | .[$i+1] == "trigger-1")) and
		(.[0].body | startswith("/note\n紐付けの試み直し: " + $result + " pr: " + $pr + " 時刻: ")) and
		(.[0].body | test("時刻: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\n$"))' "$test_dir/posted.jsonl"
}

for status in 200 404 500 transport; do
	reset_retry
	printf '%s' "$status" >"$test_dir/api-status"
	after_urls "$other" 'http://GITHUB.COM/Example/Repo/pull/00067/files?split=1'
	check_retry "紐付け: 紐付いている pr: $pr"
	pending_deleted
	api_once
	check_record '紐付いた'
	assert_jq -s '[.[] | select(.[0:2] == ["issue","pull-requests"])] | length == 2' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: API の結果より読み直した一覧を優先し、紐付いたマークを消す'

for status in 200 404 403 500 transport; do
	reset_retry
	printf '%s' "$status" >"$test_dir/api-status"
	check_retry "紐付け: 紐付いていない pr: $pr"
	pending_remains
	api_once
	case $status in
	200) check_record '一覧にない（200）' ;;
	404) check_record '見つからない（404）' ;;
	transport) check_record '失敗（通信に失敗した）' ;;
	*) check_record "失敗（応答の状態コード ${status}）" ;;
	esac
done
echo 'PASS link-retry: 一覧が空なら 200・404・ほかの状態コード・通信の失敗でもマークを残し、待たずに 1 回だけ呼ぶ'

reset_retry
after_urls "$other"
check_retry "紐付け: 食い違い pr: $pr 紐付いた PR: $other"
pending_remains
api_once
check_record '食い違い'
echo 'PASS link-retry: API のあとにほかの PR だけがあると食い違いを出し、マークを残す'

for failure in cli missing-field missing-url invalid-url; do
	reset_retry
	case $failure in
	cli) touch "$test_dir/fail-after" ;;
	missing-field) printf '{}' >"$test_dir/pulls-after.json" ;;
	missing-url) printf '{"pull_requests":[{}]}' >"$test_dir/pulls-after.json" ;;
	invalid-url) after_urls https://example.invalid/pull/67 ;;
	esac
	line=$(cd "$test_dir" && bash "$script" link-check test-issue trigger-1)
	[[ $line == "紐付け: 未確認 pr: $pr 理由: "* && $line != *$'\n'* ]]
	pending_remains
	api_once
	check_record '未確認（一覧を読めない）'
done
echo 'PASS link-retry: API のあとに一覧を読めなければ未確認を 1 行で出し、マークを残す'

for missing in token server; do
	reset_retry
	if [[ $missing == token ]]; then
		(cd "$test_dir" && unset MULTICA_TOKEN && bash "$script" link-check test-issue trigger-1) >"$test_dir/output"
	else
		(cd "$test_dir" && unset MULTICA_SERVER_URL && bash "$script" link-check test-issue trigger-1) >"$test_dir/output"
	fi
	[[ $(<"$test_dir/output") == "紐付け: 紐付いていない pr: $pr" ]]
	pending_remains
	no_api
	if [[ $missing == token ]]; then check_record '失敗（トークンがない）'; else check_record '失敗（サーバーの URL がない）'; fi
	assert_jq -s '[.[] | select(.[0:2] == ["issue","pull-requests"])] | length == 2' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: トークンかサーバーの URL がなくても一覧を読み直し、マークを残す'

for marker in absent other invalid number canonical; do
	reset_retry
	case $marker in
	absent) update_task 'del(.metadata.pr_link_pending)' ;;
	other) update_task ".metadata.pr_link_pending = \"$other\"" ;;
	invalid) update_task '.metadata.pr_link_pending = "https://example.invalid/pull/67"' ;;
	number) update_task '.metadata.pr_link_pending = 42' ;;
	canonical) update_task '.metadata.pr_link_pending = "http://GITHUB.COM/Example/Repo/pull/00067/files?diff=1"' ;;
	esac
	check_retry "紐付け: 紐付いていない pr: $pr"
	if [[ $marker == canonical ]]; then api_once; else no_api; fi
	assert_jq -s 'all(.[]; .[0:3] != ["issue","metadata","delete"])' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: マークの正規形を大文字と小文字を区別せず比べ、ない・不正・別の PR なら試み直さない'

for state in foreign invalid absent mismatch unreadable; do
	reset_retry
	case $state in
	foreign) update_task '.metadata.repository = "example/other"' ;;
	invalid) update_task '.metadata.pr_url = "invalid"' ;;
	absent) update_task 'del(.metadata.pr_url)' ;;
	mismatch) after_urls "$other"; cp "$test_dir/pulls-after.json" "$test_dir/pulls.json" ;;
	unreadable) echo 'issue pull-requests test-issue' >"$test_dir/fail" ;;
	esac
	(cd "$test_dir" && bash "$script" link-check test-issue trigger-1) >"$test_dir/output"
	no_api
	[[ ! -s $test_dir/posted.jsonl ]]
	pending_remains
	assert_jq -s 'all(.[]; .[0:2] != ["issue","metadata"])' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: 作業先の不一致・不正・pr_url なし・食い違い・未確認ではマークを変えず試み直さない'

for deletion in success failure; do
	reset_retry
	after_urls "$pr"
	cp "$test_dir/pulls-after.json" "$test_dir/pulls.json"
	if [[ $deletion == failure ]]; then echo 'issue metadata delete' >"$test_dir/fail"; fi
	check_retry "紐付け: 紐付いている pr: $pr"
	no_api
	check_record '紐付いていた'
	if [[ $deletion == success ]]; then pending_deleted; else pending_remains; fi
done
reset_retry
after_urls "$pr"
echo 'issue metadata delete' >"$test_dir/fail"
check_retry "紐付け: 紐付いている pr: $pr"
pending_remains
api_once
echo 'PASS link-retry: すでに紐付いたマークも消し、削除の失敗では出力と終了コードを変えない'

# 一度紐付いた記録のある PR は、マークが残り、人間が紐付けを外しても試み直さない。
for kind in record-deletion-failed retry-deletion-failed; do
	reset_retry
	if [[ $kind == record-deletion-failed ]]; then
		after_urls "$pr"
		cp "$test_dir/pulls-after.json" "$test_dir/pulls.json"
	else
		after_urls "$pr"
	fi
	echo 'issue metadata delete' >"$test_dir/fail"
	check_retry "紐付け: 紐付いている pr: $pr"
	pending_remains
	rm -f "$test_dir/fail"
	calls_before=$(jq -s 'length' "$test_dir/curl-calls.jsonl")
	# 人間がタスクの画面で紐付けを外す。
	printf '{"pull_requests":[]}' >"$test_dir/pulls.json"
	check_retry "紐付け: 紐付いていない pr: $pr"
	[[ $(jq -s 'length' "$test_dir/curl-calls.jsonl") == "$calls_before" ]]
	[[ $(jq -s 'length' "$test_dir/posted.jsonl") == 1 ]]
	pending_deleted
done
echo 'PASS link-retry: 一度紐付いた記録があれば、マークが残り紐付けが外されても API を呼ばず記録を書かず、マークを消し直す'

# すでに紐付いていてマークがあり、コメントを読めないときは、記録を書かず、マークだけを消す。
reset_retry
after_urls "$pr"
cp "$test_dir/pulls-after.json" "$test_dir/pulls.json"
echo 'issue comment list' >"$test_dir/fail"
check_retry "紐付け: 紐付いている pr: $pr"
no_api
[[ ! -s $test_dir/posted.jsonl ]]
pending_deleted
assert_jq -s 'all(.[]; .[0:3] != ["issue","metadata","set"])' "$test_dir/calls.jsonl"
echo 'PASS link-retry: 紐付いていてもコメントを読めなければ、記録を書かず、マークだけを消す'

for failure in comments post; do
	reset_retry
	if [[ $failure == comments ]]; then
		echo 'issue comment list' >"$test_dir/fail"
	else
		touch "$test_dir/fail-post"
	fi
	check_retry "紐付け: 紐付いていない pr: $pr"
	if [[ $failure == comments ]]; then
		no_api
		[[ ! -s $test_dir/posted.jsonl ]]
		pending_remains
		assert_jq -s 'all(.[]; .[0:3] != ["issue","metadata","delete"] and .[0:3] != ["issue","metadata","set"])' "$test_dir/calls.jsonl"
	else
		api_once
		# 投稿が断られても出力と終了コードは変わらず、記録がないので、5 分の中でも次の呼び出しが API を呼ぶ。
		[[ $(jq length "$test_dir/comments.json") == 0 ]]
		rm -f "$test_dir/fail-post"
		check_retry "紐付け: 紐付いていない pr: $pr"
		[[ $(jq -s 'length' "$test_dir/curl-calls.jsonl") == 2 ]]
		[[ $(jq -s 'length' "$test_dir/posted.jsonl") == 1 ]]
	fi
done
echo 'PASS link-retry: コメントを読めなければ API を呼ばず、投稿が失敗しても出力を変えず、次の呼び出しで試み直す'

# 起動したコメントのある実行が根のコメントを断られても、出力と終了コードを変えず、次の呼び出しは API を呼ぶ。
reset_retry
check_output "紐付け: 紐付いていない pr: $pr" link-check test-issue
[[ $(jq -s 'length' "$test_dir/curl-calls.jsonl") == 1 && ! -s $test_dir/posted.jsonl ]]
grep -q '"--parent", ""' "$test_dir/calls.jsonl"
check_output "紐付け: 紐付いていない pr: $pr" link-check test-issue
[[ $(jq -s 'length' "$test_dir/curl-calls.jsonl") == 2 && ! -s $test_dir/posted.jsonl ]]
echo 'PASS link-retry: 根のコメントを断る実行でも出力を変えず、5 分の中でも次の呼び出しが API を呼ぶ'

# マージ待ちの見張りでは、最後の記録から 6 時間がたっているときだけ試み直す。
reset_retry
rm -f "$test_dir/trigger-comment"
update_task '.status = "in_review"'
line=$(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator)
[[ $line == /note$'\nCI abcdef0: 失敗あり\nコンフリクト: MERGEABLE head: abcdef0123456789 知らせ: なし' ]]
api_once
assert_jq -s '[.[] | select(.body | startswith("/note\n紐付けの試み直し: 一覧にない（200） pr: '"$pr"' 時刻: "))] | length == 1 and (.[0].args | (index("--parent") as $i | .[$i+1] == "ci-thread"))' "$test_dir/posted.jsonl"
pending_remains
echo 'PASS link-retry: マージ待ちの見張りは、記録がなければ API を 1 回呼び、今の出力を保つ'

reset_retry
fixture issue-wakeups >"$test_dir/rule-base.json"
python3 - "$test_dir" "$script" <<'RECORDPY'
import copy
import datetime
import json
import subprocess
import sys
from pathlib import Path

work, script = Path(sys.argv[1]), sys.argv[2]
pr = "https://github.com/example/repo/pull/67"
other = "https://github.com/example/repo/pull/68"
original = json.loads((work / "task.json").read_text())
prototype = json.loads((work / "comment-prototype.json").read_text())

def read(name):
    return json.loads((work / name).read_text())

def write(name, value):
    (work / name).write_text(json.dumps(value))

def rows(name):
    return [json.loads(line) for line in (work / name).read_text().splitlines()]

def reset():
    write("task.json", copy.deepcopy(original))
    write("comments.json", [])
    write("pulls.json", {"pull_requests": []})
    write("pulls-after.json", {"pull_requests": []})
    for name in ("calls.jsonl", "curl-calls.jsonl", "posted.jsonl"):
        (work / name).write_text("")
    for name in ("fail", "api-called", "fail-after", "fail-post", "trigger-comment"):
        (work / name).unlink(missing_ok=True)
    (work / "api-status").write_text("404")

def run(linked=False, trigger="trigger-1", started=True):
    # started は起動したコメントのある実行。その実行は、そのコメント（引数に渡さないときは trigger-1）への返信だけを投稿できる。
    if started:
        (work / "trigger-comment").write_text("trigger-1" if trigger is None else trigger)
    else:
        (work / "trigger-comment").unlink(missing_ok=True)
    args = ["bash", script, "link-check", "test-issue"] + ([trigger] if trigger else [])
    result = subprocess.run(args, cwd=work, text=True, capture_output=True)
    expected = "紐付いている" if linked else "紐付いていない"
    assert result.returncode == 0 and result.stdout == f"紐付け: {expected} pr: {pr}\n", result

def comment(author="agent", content=None, created=None, parent=None, cid="previous"):
    value = copy.deepcopy(prototype)
    value.update(id=cid, author_type=author, parent_id=parent,
                 content=content or f"/note\n紐付けの試み直し: 見つからない（404） pr: {pr} 時刻: 2099-01-01T00:00:00Z\n",
                 created_at=created or "2000-01-01T00:00:00Z")
    return value

def aged(value):
    value["created_at"] = "2000-01-01T00:00:00Z"
    return value

reset()
run()
posted = rows("posted.jsonl")
assert len(posted) == 1 and posted[0]["args"][posted[0]["args"].index("--parent") + 1] == "trigger-1"
assert read("comments.json")[0]["parent_id"] == "trigger-1"
body_path = work / posted[0]["args"][posted[0]["args"].index("--content-file") + 1]
assert body_path.parent == work / "tmp" and not body_path.exists()
assert "pr_link_record" not in read("task.json")["metadata"]
# 5 分の中は、同じスレッドでも別のコメントでも試みない。
run()
run(trigger="trigger-2")
assert len(rows("curl-calls.jsonl")) == len(rows("posted.jsonl")) == 1
# 本文の時刻ではなくコメントの作成時刻で判定し、5 分を過ぎたら、起動したコメントへの返信を足す。
comments = read("comments.json")
comments[0]["content"] = comments[0]["content"].split(" 時刻:")[0] + " 時刻: 2099-01-01T00:00:00Z\n"
write("comments.json", [aged(comments[0])])
run(trigger="trigger-2")
assert len(rows("curl-calls.jsonl")) == len(rows("posted.jsonl")) == 2
assert read("comments.json")[-1]["parent_id"] == "trigger-2"
# 最新の返信が一覧の先頭でも、その作成時刻で間隔を判定する。
write("comments.json", list(reversed(read("comments.json"))))
run(trigger="trigger-3")
assert len(rows("curl-calls.jsonl")) == len(rows("posted.jsonl")) == 2
print("PASS link-record: 記録は起動したコメントへの返信にし、5 分の中は別のスレッドの記録も数えて試みず、本文の時刻と一覧の順序を判定に使わない")

reset()
run(trigger=None, started=False)
assert read("comments.json")[0]["parent_id"] is None and len(rows("posted.jsonl")) == 1
print("PASS link-record: 起動したコメントがなく、コメントから起動した実行でもなければ、ルートのコメントに置く")

recent = datetime.datetime.now(datetime.timezone.utc).isoformat()
for kind in ("member", "system", "first-line", "second-line", "other-pr", "other-thread-trusted"):
    reset()
    value = comment(created=recent, parent="elsewhere")
    if kind in ("member", "system"):
        value["author_type"] = kind
    elif kind == "first-line":
        value["content"] = value["content"].replace("/note", "別の行", 1)
    elif kind == "second-line":
        value["content"] = "/note\n別の記録\n" + value["content"].split("\n")[1]
    elif kind == "other-pr":
        value["content"] = value["content"].replace(pr, other)
    write("comments.json", [value])
    run()
    # 検証できない記録は間隔に数えず、検証できた記録は、どのスレッドのものでも数える。
    expected = 0 if kind == "other-thread-trusted" else 1
    assert len(rows("curl-calls.jsonl")) == expected, kind
    assert len(rows("posted.jsonl")) == expected, kind
    if expected:
        assert read("comments.json")[-1]["parent_id"] == "trigger-1", kind
print("PASS link-record: 人間・system・形が違う・別の PR の行は間隔に数えず、検証できた行は別のスレッドのものも数える")

reset()
write("comments.json", [comment(created=recent, parent="elsewhere")])
run(trigger=None, started=True)
assert len(rows("curl-calls.jsonl")) == 0
reset()
run(trigger=None, started=True)
# 根のコメントを断られても、出力と終了コードは変えず、次の呼び出しは 5 分の中でも API を呼ぶ。
assert len(rows("curl-calls.jsonl")) == 1 and rows("posted.jsonl") == []
run(trigger=None, started=True)
assert len(rows("curl-calls.jsonl")) == 2 and rows("posted.jsonl") == []
print("PASS link-record: 根のコメントを断られても出力と終了コードを保ち、記録がないので次の呼び出しが API を呼ぶ")

reset()
write("pulls-after.json", {"pull_requests": [{"html_url": pr}]})
(work / "fail-post").touch()
run(linked=True)
assert "pr_link_pending" not in read("task.json")["metadata"]
calls = rows("calls.jsonl")
posting = next(i for i,c in enumerate(calls) if c[:3] == ["issue", "comment", "add"])
deletion = next(i for i,c in enumerate(calls) if c[:3] == ["issue", "metadata", "delete"])
assert posting < deletion
print("PASS link-record: 投稿が失敗しても、判定と終了コードを保ち、マークを消す")

# 紐付いていてマークがあり、検証できる「紐付いた」「紐付いていた」の記録があれば、どのスレッドのものでも、記録を書かずマークだけを消す。
for result in ("紐付いた", "紐付いていた"):
    reset()
    task = read("task.json")
    task["metadata"]["pr_link_pending"] = pr
    write("task.json", task)
    write("pulls.json", {"pull_requests": [{"html_url": pr}]})
    write("comments.json", [aged(comment(content=f"/note\n紐付けの試み直し: {result} pr: {pr} 時刻: 2099-01-01T00:00:00Z\n", parent="elsewhere"))])
    run(linked=True)
    assert rows("posted.jsonl") == [] and rows("curl-calls.jsonl") == []
    assert "pr_link_pending" not in read("task.json")["metadata"]
    assert any(c[:3] == ["issue", "metadata", "delete"] for c in rows("calls.jsonl"))
print("PASS link-record: 紐付いた記録があれば、記録を書かずマークだけを消す")

def run_unlinked(expect=None):
    result = subprocess.run(["bash", script, "unlinked-check", "test-issue", "orchestrator"], cwd=work,
                            text=True, capture_output=True)
    assert result.returncode == 0, result
    if expect is not None:
        assert expect in result.stdout or expect in " ".join(rows("calls.jsonl")[-1]), result
    return result

def unlinked_task():
    task = read("task.json")
    task["status"] = "in_review"
    write("task.json", task)

now = datetime.datetime.now(datetime.timezone.utc)
for age, expected in ((datetime.timedelta(hours=6, minutes=1), 1), (datetime.timedelta(hours=5, minutes=59), 0)):
    reset()
    unlinked_task()
    value = comment(created=(now - age).isoformat())
    write("comments.json", [value])
    run_unlinked()
    assert len(rows("curl-calls.jsonl")) == expected, age
    assert len([r for r in rows("posted.jsonl") if r["body"].startswith("/note\n紐付けの試み直し:")]) == expected, age
print("PASS link-record: マージ待ちの見張りは 6 時間を過ぎたときだけ API を 1 回呼び、6 時間の中では呼ばない")

# 人間が書いた行は間隔に数えない。
reset()
unlinked_task()
write("comments.json", [comment(author="member", created=now.isoformat())])
run_unlinked()
assert len(rows("curl-calls.jsonl")) == 1
print("PASS link-record: 人間が書いた試み直しの行は、マージ待ちの見張りの間隔に数えない")

# 試み直しで紐付くと、見張りの規則を消し、止めた記録を標準出力に出す。
reset()
unlinked_task()
write("comments.json", [comment(created=(now - datetime.timedelta(hours=7)).isoformat())])
write("pulls-after.json", {"pull_requests": [{"html_url": pr}]})
(work / "api-status").write_text("200")
rules = read("rule-base.json")
mark = "紐付いていない PR のマージ待ちの見張りで起きました。"
write("rules.json", [dict(rules, id="mine", instruction=mark + "\n確認"),
                     dict(rules, id="other", instruction="PR の CI が終わりました。")])
result = run_unlinked()
assert len(rows("curl-calls.jsonl")) == 1
assert "pr_link_pending" not in read("task.json")["metadata"]
assert result.stdout == "/note\n止めた: PR がタスクに紐付いた\n", result
assert [rule["id"] for rule in read("rules.json")] == ["other"], read("rules.json")
print("PASS link-record: マージ待ちで紐付くと、見張りの規則を消し、止めた記録を出す")
RECORDPY

# 新しい場面だけ時計を固定し、API の試みと印の読み書きを別々に数える。
command -v date >"$test_dir/real-date"
cat >"$test_dir/bin/date" <<'MOCK'
#!/usr/bin/env bash
dir=$PR_WATCH_TEST_DIR
if [[ -f $dir/epoch ]]; then
	if [[ $* == +%s ]]; then cat "$dir/epoch"; exit 0; fi
	if [[ $* == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then
		python3 -c 'import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$(<"$dir/epoch")"
		exit 0
	fi
fi
exec "$(<"$dir/real-date")" "$@"
MOCK
chmod +x "$test_dir/bin/date"

record=$PR_LINK_STATE_ROOT/project-retry/example/repo
reset_no_integration() {
	reset_retry
	rm -rf -- "$PR_LINK_STATE_ROOT"
	update_task '.project_id = "project-retry"'
	printf '404' >"$test_dir/api-status"
	printf '1764288000' >"$test_dir/epoch"
}
write_record() {
	mkdir -p "${record%/*}"
	printf 'repository: example/repo\npr: %s\ntask: TASK-7\n記録した時刻: 2025-11-28T00:00:00Z\n' "$1" >"$record"
}
set_kind() {
	update_task ".metadata.pr_link_no_integration = \"$1 ${2-$pr}\""
}
no_integration_line="紐付け: 紐付いていない pr: $pr 連携: なし"
lookup_plain="紐付け: 紐付いていない pr: $pr"
linked_line="紐付け: 紐付いている pr: $pr"
mark_is() { assert_jq --arg mark "$1" '.metadata.pr_link_no_integration == $mark' "$test_dir/task.json"; }
mark_gone() { assert_jq '.metadata | has("pr_link_no_integration") | not' "$test_dir/task.json"; }
linked_pulls() { after_urls "$pr"; cp "$test_dir/pulls-after.json" "$test_dir/pulls.json"; }
unset_agent() { (unset MULTICA_AGENT_ID; check_retry "$@"); }
# link-check は、どの役・どの判定でも、知らせの投稿・コメントの消去・スクワッド一覧の読みをしない。件数の確認が外れたら、理由を出して落とす。
roles=(orchestrator other-leader monitor empty none)
check_as() {
	case $1 in
	none) unset_agent "$2" ;;
	empty) MULTICA_AGENT_ID= check_retry "$2" ;;
	*) MULTICA_AGENT_ID=$1 check_retry "$2" ;;
	esac
}
notice_count() { jq -sr '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length' "$test_dir/posted.jsonl"; }
call_count() { jq -sr --argjson prefix "$1" '[.[] | select(.[0:($prefix | length)] == $prefix)] | length' "$test_dir/calls.jsonl"; }
expect_count() {
	local label=$1 actual=$2 expected=$3
	[[ $actual == "$expected" ]] || { echo "件数が違う: ${label} は ${expected} のはずが ${actual}" >&2; exit 1; }
}
expect_untouched() {
	expect_count "$1: 知らせの投稿" "$(notice_count)" 0
	expect_count "$1: コメントの消去" "$(call_count '["issue","comment","delete"]')" 0
	expect_count "$1: スクワッド一覧の読み" "$(call_count '["squad","list"]')" 0
}

# 有効な印は、種類によらず、紐付いていない回の出力に連携なしを付けるだけである。何も書かず、知らせにも触れない。
for who in "${roles[@]}"; do
	for kind in 記録した 記録があった; do
		reset_no_integration
		set_kind "$kind"
		check_as "$who" "$no_integration_line"
		check_as "$who" "$no_integration_line"
		mark_is "$kind $pr"
		expect_untouched "印 ${kind} の役 ${who}"
	done
done
echo 'PASS link-retry: 有効な印があると連携なしを付け、どの役でも知らせの投稿・消去・スクワッド一覧の読みをしない'

# 印の URL が pr_url と違うと印は有効でなく、連携なしを付けない。記録だけでは何も変わらない。
reset_no_integration
set_kind '記録した' "$other"
check_retry "$lookup_plain"
mark_is "記録した $other"
reset_no_integration
update_task 'del(.metadata.pr_link_pending)'
write_record "$pr"
check_retry "$lookup_plain"
mark_gone
assert_jq -s 'all(.[]; .[0:3] != ["issue", "metadata", "set"] or .[5] != "pr_link_no_integration")' "$test_dir/calls.jsonl"
no_api
expect_untouched '印の URL が違う・記録だけ'
echo 'PASS link-retry: 印の URL が pr_url と違うときと、記録だけのときは、連携なしを付けず何も書かない'

# 印がなく、pending と pr_url と記録の pr が合うと、印（記録した）を戻して連携なしを付ける。戻す回も知らせは出さない。
for who in "${roles[@]}"; do
	reset_no_integration
	write_record "$pr"
	check_as "$who" "$no_integration_line"
	mark_is "記録した $pr"
	check_as "$who" "$no_integration_line"
	mark_is "記録した $pr"
	api_once
	expect_untouched "復旧の役 ${who}"
done
echo 'PASS link-retry: 印がなく pending・pr_url・記録が合うと、どの役でも印を戻して連携なしを付け、知らせは出さない'

for state in linked other no-pending mismatch; do
	reset_no_integration
	case $state in
	linked) write_record "$pr"; linked_pulls ;;
	other) write_record "$other" ;;
	no-pending) write_record "$pr"; update_task 'del(.metadata.pr_link_pending)' ;;
	mismatch) update_task ".metadata.pr_link_pending = \"$other\""; write_record "$pr" ;;
	esac
	if [[ $state == linked ]]; then
		check_retry "$linked_line"
		[[ ! -e $record ]]
	elif [[ $state == mismatch ]]; then
		check_retry "紐付け: 紐付いていない pr: $pr"
	else
		check_retry "$lookup_plain"
	fi
	mark_gone
	assert_jq -s 'all(.[]; .[0:3] != ["issue", "metadata", "set"] or .[5] != "pr_link_no_integration")' "$test_dir/calls.jsonl"
	expect_untouched "復旧しない ${state}"
done
echo 'PASS link-retry: 紐付いた PR・別の PR の記録・pending なし・pending の PR 違いでは、印を戻さず、何も出さない'

# 印を戻せない回も連携なしを付け、次の回に戻す。戻す前に紐付けば、戻さない。
reset_no_integration
write_record "$pr"
echo 'issue metadata set' >"$test_dir/fail"
check_retry "$no_integration_line"
mark_gone
expect_untouched '戻せない回'
rm "$test_dir/fail"
check_retry "$no_integration_line"
mark_is "記録した $pr"
expect_untouched '戻した回'
reset_no_integration
write_record "$pr"
echo 'issue metadata set' >"$test_dir/fail"
check_retry "$no_integration_line"
rm "$test_dir/fail"
linked_pulls
check_retry "$linked_line"
mark_gone
[[ ! -e $record ]]
expect_untouched '戻す前に紐付いた回'
echo 'PASS link-retry: 印を戻せない回は連携なしだけを付け、次の回に戻し、戻す前に紐付けば戻さない'

# 紐付いたと判定した回は、種類・役によらず、その回のうちに印・pending・記録を消す。知らせの有無は読まない。
for who in "${roles[@]}"; do
	for kind in 記録した 記録があった; do
		for pending in without with; do
			reset_no_integration
			set_kind "$kind"
			write_record "$pr"
			linked_pulls
			if [[ $pending == without ]]; then update_task 'del(.metadata.pr_link_pending)'; fi
			check_as "$who" "$linked_line"
			mark_gone
			pending_deleted
			[[ ! -e $record ]] || { echo "記録が残った: ${kind} ${who} ${pending}" >&2; exit 1; }
			expect_untouched "紐付いた判定 ${kind} 役 ${who} pending ${pending}"
			check_as "$who" "$linked_line"
			expect_untouched "紐付いた判定の次の回 ${kind} 役 ${who}"
		done
	done
done
echo 'PASS link-retry: 紐付いたと判定した回に、どの種類の印も・pending も・記録も消し、知らせには触れない'

# 別の PR の印は、ほかの PR が紐付いても消さない。
reset_no_integration
write_record "$pr"
set_kind '記録があった' "$other"
linked_pulls
check_retry "$linked_line"
mark_is "記録があった $other"
[[ ! -e $record ]]
expect_untouched '別の PR の印'
echo 'PASS link-retry: 別の PR の印は、進行中の PR が紐付いても消さない'

# 試み直しで紐付く経路も、その回に印と記録を消し、試み直しの行を 1 件だけ書く。知らせは出さない。
for kind in 記録した 記録があった; do
	reset_no_integration
	write_record "$pr"
	set_kind "$kind"
	printf '200' >"$test_dir/api-status"
	after_urls "$pr"
	check_retry "$linked_line"
	api_once
	pending_deleted
	mark_gone
	[[ ! -e $record ]]
	check_record '紐付いた'
	expect_untouched "試み直しで紐付いた ${kind}"
done
echo 'PASS link-retry: 試み直しで紐付いた回に、印・pending・記録を消し、試み直しの行を 1 件書く'

# 印がある PR の試み直し: API を呼ぶ前に pr_link_tried_at を書き、5 分以内と書けない回は呼ばない。トークンのない回は呼ばず、書かない。
for kind in 記録した 記録があった; do
	reset_no_integration
	set_kind "$kind"
	touch "$test_dir/fail-tried"
	check_retry "$no_integration_line"
	no_api
	rm "$test_dir/fail-tried"
	MULTICA_TOKEN='' check_retry "$no_integration_line"
	no_api
	assert_jq '.metadata | has("pr_link_tried_at") | not' "$test_dir/task.json"
	check_retry "$no_integration_line"
	api_once
	assert_jq --arg expected "2025-11-28T00:00:00Z $pr" '.metadata.pr_link_tried_at == $expected' "$test_dir/task.json"
	printf '1764288299' >"$test_dir/epoch"
	check_retry "$no_integration_line"
	api_once
	printf '1764288301' >"$test_dir/epoch"
	check_retry "$no_integration_line"
	assert_jq -s 'length == 2' "$test_dir/curl-calls.jsonl"
	[[ ! -s $test_dir/posted.jsonl ]]
	expect_untouched "試み直し ${kind}"
done
echo 'PASS link-retry: 印がある PR は有効な試みだけ数え、時刻の保存前には呼ばず、紐付かない試み直しは何も書かない'

# 印のない回（pending だけ）は、トークンがなくても 1 回試した行を書く。印がある回と違う。
reset_no_integration
MULTICA_TOKEN='' check_retry "紐付け: 紐付いていない pr: $pr"
no_api
expect_count 'トークンなしの試み直しの行' "$(jq -sr 'length' "$test_dir/posted.jsonl")" 1
expect_untouched 'トークンなし・印なし'
echo 'PASS link-retry: 印のない回は、トークンがないときの失敗を 1 件書き、知らせには触れない'

# 知らせのあとに記録が消えても、印がある限り出力は変わらない。
reset_no_integration
set_kind '記録した'
write_record "$other"
check_retry "$no_integration_line"
rm -f "$record"
check_retry "$no_integration_line"
mark_is "記録した $pr"
expect_untouched '記録が消えたあと'
echo 'PASS link-retry: 記録が消えても、印がある限り連携なしを付け、何も出さない'
