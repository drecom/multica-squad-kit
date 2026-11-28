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

# 新しい場面だけ時計を固定し、API の試みと知らせの投稿を別々に数える。
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
notice_count() {
	jq -sr '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | length' "$test_dir/posted.jsonl"
}
same_notice() { printf '/note\n連携なしの知らせ: %s\n' "$1"; }
no_integration_line="紐付け: 紐付いていない pr: $pr 連携: なし"
lookup_plain="紐付け: 紐付いていない pr: $pr"

leader=orchestrator
export MULTICA_AGENT_ID=$leader
linked_line="紐付け: 紐付いている pr: $pr"
at_old=2025-11-28T00:00:00Z at_new=2025-11-28T00:00:09Z
mark_is() { assert_jq --arg mark "$1" '.metadata.pr_link_no_integration == $mark' "$test_dir/task.json"; }
mark_gone() { assert_jq '.metadata | has("pr_link_no_integration") | not' "$test_dir/task.json"; }
# 作者・時刻・本文を決めたコメントを一覧に足す。第 1 引数は id、第 2 引数は作者の種類、第 3 引数は作者の ID、第 4 引数は本文、第 5 引数は時刻。
add_comment() {
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg id "$1" --arg type "$2" --arg author "$3" --arg body "$4" --arg at "${5:-$at_old}" \
		'. + [$base[0] + {id:$id,author_type:$type,author_id:$author,content:$body,created_at:$at,parent_id:null}]' \
		"$test_dir/comments.json" >"$test_dir/comments-added.json"
	mv "$test_dir/comments-added.json" "$test_dir/comments.json"
}
add_notice() { add_comment "$1" agent "${2:-$leader}" "$(same_notice "${4:-$pr}")" "${3:-$at_old}"; }
# 作者が自分で、消されていない知らせの id を並べる。
visible_notices() {
	jq -r --arg author "$leader" --arg url "$pr" \
		'[.[] | select(.author_type == "agent" and .author_id == $author and ((.content | split("\n")) as $l | $l[0] == "/note" and $l[1] == ("連携なしの知らせ: " + $url))) | .id] | join(",")' "$test_dir/comments.json"
}
deleted_ids() { jq -sr '[.[] | select(.[0:3] == ["issue","comment","delete"]) | .[3]] | sort | join(",")' "$test_dir/calls.jsonl"; }
posted_notice() { jq -sr '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | .[-1].body' "$test_dir/posted.jsonl"; }
notice_in_thread() {
	assert_jq -s '[.[] | select(.body | startswith("/note\n連携なしの知らせ: "))] | all(.args | (index("--parent") as $i | .[$i+1] == "trigger-1"))' "$test_dir/posted.jsonl"
}
linked_pulls() { after_urls "$pr"; cp "$test_dir/pulls-after.json" "$test_dir/pulls.json"; }
unset_agent() { (unset MULTICA_AGENT_ID; check_retry "$@"); }

# 中断した同じ PR の印を戻した回は、リーダーなら知らせを 1 回出す。紐付いていないあいだは印を消さない。
reset_no_integration
write_record "$pr"
check_retry "$no_integration_line"
mark_is "記録した $pr"
[[ $(notice_count) == 1 && $(visible_notices) == link-record-1 ]]
notice_in_thread
[[ $(posted_notice) == *'マージのあとタスクが done にならなければ、人間が done にしてください'* ]]
[[ $(posted_notice) != *'連携ありの扱いに戻しました'* ]]
check_retry "$no_integration_line"
check_retry "$no_integration_line"
[[ $(notice_count) == 1 && -z $(deleted_ids) ]]
mark_is "記録した $pr"
api_once
echo 'PASS link-retry: 中断した同じ PR の印を戻し、リーダーが知らせを一度だけ書き、紐付かないあいだは印を残す'

for state in linked other no-pending mismatch; do
	reset_no_integration
	case $state in
	linked) write_record "$pr"; linked_pulls ;;
	other) write_record "$other" ;;
	no-pending) write_record "$pr"; update_task 'del(.metadata.pr_link_pending)' ;;
	mismatch) set_kind '記録した' "$other" ;;
	esac
	if [[ $state == linked ]]; then
		check_retry "$linked_line"
		[[ ! -e $record ]]
	else
		check_retry "$lookup_plain"
	fi
	[[ $(notice_count) == 0 ]]
	assert_jq -s 'all(.[]; .[0:3] != ["issue", "metadata", "set"] or .[5] != "pr_link_no_integration")' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: 紐付いた PR、別の PR の記録、マークなし、不一致の印では復旧せず、知らせも出さない'

# 印を戻せない回は連携なしと扱うだけで投稿せず、次の回に戻して投稿する。戻す前に紐付けば、戻さず投稿もしない。
reset_no_integration
write_record "$pr"
echo 'issue metadata set' >"$test_dir/fail"
check_retry "$no_integration_line"
mark_gone
[[ $(notice_count) == 0 ]]
rm "$test_dir/fail"
check_retry "$no_integration_line"
mark_is "記録した $pr"
[[ $(notice_count) == 1 ]]
reset_no_integration
write_record "$pr"
echo 'issue metadata set' >"$test_dir/fail"
check_retry "$no_integration_line"
rm "$test_dir/fail"
linked_pulls
check_retry "$linked_line"
mark_gone
[[ $(notice_count) == 0 && ! -e $record ]]
echo 'PASS link-retry: 印を戻せない回は連携なしだけを付けて投稿せず、次の回に戻して投稿する'

# 知らせを書くのは、MULTICA_AGENT_ID を leader_id に持つスクワッドが 1 つに決まるリーダーだけである。それ以外の回は、知らせにも印にも触れない。
for judged in unlinked linked; do
	for who in other empty unset ambiguous archived no-squad squad-list-failure; do
		reset_no_integration
		set_kind '記録した'
		add_notice dup-b "$leader" "$at_old"
		add_notice dup-a "$leader" "$at_old"
		if [[ $judged == linked ]]; then
			linked_pulls
			update_task 'del(.metadata.pr_link_pending)'
			expected=$linked_line
		else
			expected=$no_integration_line
		fi
		case $who in
		ambiguous) jq '. + [.[0] + {id:"second-squad"}]' "$test_dir/squads.json" >"$test_dir/squads-new.json"; mv "$test_dir/squads-new.json" "$test_dir/squads.json" ;;
		archived) jq '.[0].archived_at = "2025-11-01T00:00:00Z"' "$test_dir/squads.json" >"$test_dir/squads-new.json"; mv "$test_dir/squads-new.json" "$test_dir/squads.json" ;;
		no-squad) jq '.[0].leader_id = "someone-else"' "$test_dir/squads.json" >"$test_dir/squads-new.json"; mv "$test_dir/squads-new.json" "$test_dir/squads.json" ;;
		squad-list-failure) echo 'squad list --output' >"$test_dir/fail" ;;
		esac
		case $who in
		other) MULTICA_AGENT_ID=monitor check_retry "$expected" ;;
		empty) MULTICA_AGENT_ID= check_retry "$expected" ;;
		unset) unset_agent "$expected" ;;
		*) check_retry "$expected" ;;
		esac
		[[ $(notice_count) == 0 && -z $(deleted_ids) && $(visible_notices) == dup-b,dup-a ]] || { echo "$judged $who" >&2; exit 1; }
		mark_is "記録した $pr"
	done
done
echo 'PASS link-retry: リーダーでない役・ID がない・リーダーのスクワッドが 1 つに決まらない回は、知らせの投稿も消去もせず、印を消さない'

# 知らせを投稿できなかった回も、コメントを読めなかった回も、次の回に同じ条件で試す。投稿の応答が失敗でもコメントができていれば、重ねない。
for prior in read-failure post-failure post-failure-created; do
	reset_no_integration
	set_kind '記録した'
	case $prior in
	read-failure) printf 'issue comment list\n' >"$test_dir/fail" ;;
	post-failure) touch "$test_dir/fail-post" ;;
	post-failure-created) touch "$test_dir/fail-post-created" ;;
	esac
	check_retry "$no_integration_line"
	case $prior in
	read-failure) [[ $(notice_count) == 0 ]] ;;
	post-failure) [[ $(notice_count) == 0 ]] ;;
	post-failure-created) [[ $(notice_count) == 1 && $(visible_notices) == link-record-1 ]] ;;
	esac
	rm -f "$test_dir/fail" "$test_dir/fail-post" "$test_dir/fail-post-created"
	check_retry "$no_integration_line"
	check_retry "$no_integration_line"
	[[ $(visible_notices) == link-record-1 && -z $(deleted_ids) ]]
	mark_is "記録した $pr"
done
echo 'PASS link-retry: 読むか書くかに失敗した知らせは次の回に試し、応答だけが失敗でもできたコメントを重ねない'

# 作者が自分でないか、2 行目が違うか、消えたコメントは数えず、消さない。自分の知らせがなければ 1 件投稿する。
for prior in member other-agent other-url deleted partial; do
	reset_no_integration
	set_kind '記録した'
	case $prior in
	member) add_comment foreign member "$leader" "$(same_notice "$pr")" ;;
	other-agent) add_comment foreign agent someone-else "$(same_notice "$pr")" ;;
	other-url) add_notice foreign "$leader" "$at_old" "$other" ;;
	deleted) add_comment foreign agent "$leader" '' ;;
	partial) add_comment foreign agent "$leader" "/note"$'\n'"連携なしの知らせ: $pr 追加" ;;
	esac
	check_retry "$no_integration_line"
	[[ $(notice_count) == 1 && -z $(deleted_ids) ]]
	[[ $(visible_notices) == link-record-1 ]]
	check_retry "$no_integration_line"
	[[ $(notice_count) == 1 && -z $(deleted_ids) ]]
done
echo 'PASS link-retry: 人間・ほかのエージェント・別の PR・消えたコメントの知らせは数えず消さず、リーダーが自分の知らせを 1 件出す'

# 紐付いていると判定したときは、紐付いているときの文面で投稿して印を残し、次の回に 1 件と読んでから印を消す。
reset_no_integration
set_kind '記録した'
linked_pulls
check_retry "$linked_line"
pending_deleted
mark_is "記録した $pr"
[[ $(notice_count) == 1 && $(visible_notices) == link-record-2 ]]
notice_in_thread
[[ $(posted_notice) == *'連携ありの扱いに戻しました'* && $(posted_notice) != *'done にしてください'* ]]
[[ $(posted_notice) == *'人間がタスクを done にする必要もありません'* ]]
check_retry "$linked_line"
mark_gone
[[ $(notice_count) == 1 && -z $(deleted_ids) ]]
check_retry "$linked_line"
[[ $(notice_count) == 1 && $(visible_notices) == link-record-2 ]]
echo 'PASS link-retry: 紐付いていると判定すると、復帰の文面で 1 回投稿して印を残し、次の回に 1 件と読んで印を消す'

# 試み直しで紐付いた回も同じである。404 のあとにこの PR が紐付く経路も、2 回の link-check で知らせが 1 件になる。
reset_no_integration
set_kind '記録した'
printf '200' >"$test_dir/api-status"
after_urls "$pr"
check_retry "$linked_line"
api_once
pending_deleted
mark_is "記録した $pr"
[[ $(notice_count) == 1 ]]
check_retry "$linked_line"
mark_gone
[[ $(notice_count) == 1 && $(visible_notices) != '' ]]
echo 'PASS link-retry: 試み直しで紐付いたときも、知らせを 1 件出してから印を消す'

# 紐付いていて、投稿できないかコメントを読めないと、印が残る。知らせがすでに 1 件なら、投稿せずに印を消す。種類 `記録があった` はすぐ消す。
for failure in post read; do
	reset_no_integration
	set_kind '記録した'
	linked_pulls
	update_task 'del(.metadata.pr_link_pending)'
	if [[ $failure == post ]]; then touch "$test_dir/fail-post"; else echo 'issue comment list' >"$test_dir/fail"; fi
	check_retry "$linked_line"
	mark_is "記録した $pr"
	[[ $(notice_count) == 0 ]]
	check_retry "$linked_line"
	mark_is "記録した $pr"
	rm -f "$test_dir/fail" "$test_dir/fail-post"
	check_retry "$linked_line"
	mark_is "記録した $pr"
	[[ $(notice_count) == 1 ]]
	check_retry "$linked_line"
	mark_gone
	[[ $(notice_count) == 1 ]]
done
reset_no_integration
set_kind '記録した'
linked_pulls
update_task 'del(.metadata.pr_link_pending)'
add_notice only
check_retry "$linked_line"
mark_gone
[[ $(notice_count) == 0 && -z $(deleted_ids) ]]
reset_no_integration
set_kind '記録があった'
linked_pulls
update_task 'del(.metadata.pr_link_pending)'
check_retry "$linked_line"
mark_gone
[[ $(notice_count) == 0 ]]
echo 'PASS link-retry: 紐付いていて投稿やコメントの読みに失敗すると印を残し、知らせが 1 件なら投稿せず印を消し、記録があったはすぐ消す'

# 自分の知らせが 2 件以上あると、created_at の古い順（同じなら id の順）の 1 件を残して消す。
reset_no_integration
set_kind '記録した'
add_notice c-3 "$leader" "$at_new"
add_notice b-2 "$leader" "$at_old"
add_notice a-1 "$leader" "$at_old"
add_notice other-agent-1 someone-else "$at_old"
check_retry "$no_integration_line"
[[ $(deleted_ids) == b-2,c-3 && $(visible_notices) == a-1 && $(notice_count) == 0 ]]
mark_is "記録した $pr"
echo 'PASS link-retry: 重複は created_at の古い順、同じなら id の順で 1 件を残して消し、紐付かないあいだは印を残す'

# 紐付いている判定では、消せないと印を残し、次の回に消し直して、1 件と読めたその回に印を消す。
reset_no_integration
set_kind '記録した'
linked_pulls
update_task 'del(.metadata.pr_link_pending)'
add_notice c-3 "$leader" "$at_new"
add_notice a-1 "$leader" "$at_old"
touch "$test_dir/fail-delete"
check_retry "$linked_line"
mark_is "記録した $pr"
[[ $(visible_notices) == c-3,a-1 || $(visible_notices) == a-1,c-3 ]]
rm "$test_dir/fail-delete"
check_retry "$linked_line"
mark_gone
[[ $(visible_notices) == a-1 && $(notice_count) == 0 ]]
echo 'PASS link-retry: 重複を消せない回は印を消さず、次の回に消し直して 1 件と読めたら印を消す'

# 1 件ずつ消せなかった重複があっても、ほかのエージェントの同じ 2 行は消さない。
reset_no_integration
set_kind '記録した'
add_comment foreign agent someone-else "$(same_notice "$pr")" "$at_old"
add_comment human member "$leader" "$(same_notice "$pr")" "$at_old"
add_notice mine-2 "$leader" "$at_new"
add_notice mine-1 "$leader" "$at_old"
check_retry "$no_integration_line"
[[ $(deleted_ids) == mine-2 && $(notice_count) == 0 ]]
echo 'PASS link-retry: 重複を消すのは、作者が自分の知らせだけである'

# 前のリーダーの知らせは数えず、新しいリーダーが 1 件出す。
reset_no_integration
set_kind '記録した'
add_comment previous agent old-leader "$(same_notice "$pr")" "$at_old"
check_retry "$no_integration_line"
[[ $(notice_count) == 1 && -z $(deleted_ids) ]]
jq -e --arg id link-record-1 'map(select(.id == $id)) | length == 1' "$test_dir/comments.json" >/dev/null
echo 'PASS link-retry: 前のリーダーの知らせは数えず、今のリーダーが 1 件出す'

# 種類 `記録があった` は、知らせを出さず、コメントも読まない。
reset_no_integration
set_kind '記録があった'
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
echo 'PASS link-retry: 印がある場合は有効な試みだけ数え、時刻の保存前には呼ばず、記録があったでは知らせを出さない'

for when in before after; do
	reset_no_integration
	write_record "$other"
	set_kind '記録があった'
	case $when in
	before) linked_pulls ;;
	after) after_urls "$pr" ;;
	esac
	check_retry "$linked_line"
	pending_deleted
	mark_gone
	[[ ! -e $record && $(notice_count) == 0 ]]
done
echo 'PASS link-retry: 最初から紐付いている場合も試み直しで紐付く場合も記録と印を消す'

reset_no_integration
write_record "$pr"
set_kind '記録があった' "$other"
linked_pulls
check_retry "$linked_line"
mark_is "記録があった $other"
[[ ! -e $record && $(notice_count) == 0 ]]
echo 'PASS link-retry: 別の PR が紐付いても進行中の PR の印は消さない'

# 知らせのあとに記録が消えても、知らせは記録を読まない。印がある PR は 1 件の知らせを持つ。
reset_no_integration
set_kind '記録した'
write_record "$other"
check_retry "$no_integration_line"
rm -f "$record"
check_retry "$no_integration_line"
[[ $(notice_count) == 1 ]]
echo 'PASS link-retry: 知らせは記録の有無を読まず、印だけで 1 件出す'
