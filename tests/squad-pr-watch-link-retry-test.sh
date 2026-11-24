#!/usr/bin/env bash
# マークのある PR の紐付け直しと、読み直した一覧による判定を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
pr=https://github.com/example/repo/pull/67
other=https://github.com/example/repo/pull/68
export MULTICA_TOKEN=fixture-token MULTICA_SERVER_URL=https://multica.invalid

# API のあとに一覧を更新し、読み直しの失敗も再現する。このテストだけの包みにする。
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-}" == 'issue get test-issue' ]]; then
	# この機能が保存する metadata の鍵を除き、実物の見本で検証する。
	jq 'del(.metadata.pr_link_pending, .metadata.pr_link_record)' "$dir/task.json" >"$dir/task-base.json"
	python3 "$PR_WATCH_TEST_ROOT/tests/cli-stub.py" pr-watch "$dir" multica calls.jsonl \
		emit issue-get "$dir/task-base.json" -- "$@" >/dev/null
	cat "$dir/task.json"
	exit 0
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
	rm -f "$test_dir/api-called" "$test_dir/fail-after" "$test_dir/curl-config" "$test_dir/fail-post"
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
check_retry() { check_output "$1" link-check test-issue; }
check_record() {
	# 読む側: squad-pr-watch の link_record_data が /note と固定の行を読む。
	assert_jq -s --arg result "$1" --arg pr "$pr" 'length == 1 and
		(.[0].body | startswith("/note\n紐付けの試み直し: " + $result + " pr: " + $pr + " 時刻: ")) and
		(.[0].body | test("時刻: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\n$"))' "$test_dir/posted.jsonl"
	assert_jq '.metadata.pr_link_record | startswith("link-record-")' "$test_dir/task.json"
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
	line=$(cd "$test_dir" && bash "$script" link-check test-issue)
	[[ $line == "紐付け: 未確認 pr: $pr 理由: "* && $line != *$'\n'* ]]
	pending_remains
	api_once
	check_record '未確認（一覧を読めない）'
done
echo 'PASS link-retry: API のあとに一覧を読めなければ未確認を 1 行で出し、マークを残す'

for missing in token server; do
	reset_retry
	if [[ $missing == token ]]; then
		(cd "$test_dir" && unset MULTICA_TOKEN && bash "$script" link-check test-issue) >"$test_dir/output"
	else
		(cd "$test_dir" && unset MULTICA_SERVER_URL && bash "$script" link-check test-issue) >"$test_dir/output"
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
	(cd "$test_dir" && bash "$script" link-check test-issue) >"$test_dir/output"
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

reset_retry
update_task '.status = "in_review"'
line=$(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator)
[[ $line == /note$'\nCI abcdef0: 失敗あり\nコンフリクト: MERGEABLE head: abcdef0123456789 知らせ: なし' ]]
no_api
pending_remains
echo 'PASS link-retry: マージ待ちの見張りの判定では試み直さず、今の出力を保つ'

reset_retry
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
    for name in ("fail", "api-called", "fail-after", "fail-post"):
        (work / name).unlink(missing_ok=True)
    (work / "api-status").write_text("404")

def run(linked=False):
    result = subprocess.run(["bash", script, "link-check", "test-issue"], cwd=work,
                            text=True, capture_output=True)
    expected = "紐付いている" if linked else "紐付いていない"
    assert result.returncode == 0 and result.stdout == f"紐付け: {expected} pr: {pr}\n", result

def comment(author="agent", content=None, created=None):
    value = copy.deepcopy(prototype)
    value.update(id="previous", author_type=author, parent_id=None,
                 content=content or f"/note\n紐付けの試み直し: 見つからない（404） pr: {pr} 時刻: 2099-01-01T00:00:00Z\n",
                 created_at=created or "2000-01-01T00:00:00Z")
    return value

reset()
run()
root = read("task.json")["metadata"]["pr_link_record"]
assert read("comments.json")[0]["parent_id"] is None
posted = rows("posted.jsonl")[0]
body_path = work / posted["args"][posted["args"].index("--content-file") + 1]
assert body_path.parent == work / "tmp" and not body_path.exists()
run()
assert len(rows("curl-calls.jsonl")) == len(rows("posted.jsonl")) == 1
comments = read("comments.json")
comments[0]["created_at"] = "2000-01-01T00:00:00Z"
comments[0]["content"] = comments[0]["content"].split(" 時刻:")[0] + " 時刻: 2099-01-01T00:00:00Z\n"
write("comments.json", comments)
run()
assert read("task.json")["metadata"]["pr_link_record"] == root
assert read("comments.json")[-1]["parent_id"] == root
assert len(rows("curl-calls.jsonl")) == len(rows("posted.jsonl")) == 2
# 最新の返信が一覧の先頭でも、その作成時刻で間隔を判定する。
write("comments.json", list(reversed(read("comments.json"))))
run()
assert len(rows("curl-calls.jsonl")) == len(rows("posted.jsonl")) == 2
print("PASS link-record: 元のコメントの ID を保存し、5 分の中は試みず、過ぎたら返信し、本文の時刻と一覧の順序を判定に使わない")

recent = datetime.datetime.now(datetime.timezone.utc).isoformat()
for kind in ("member", "system", "first-line", "second-line", "missing"):
    reset()
    value = comment(created=recent)
    if kind in ("member", "system"):
        value["author_type"] = kind
    elif kind == "first-line":
        value["content"] = value["content"].replace("/note", "別の行", 1)
    elif kind == "second-line":
        value["content"] = "/note\n別の記録\n" + value["content"].split("\n")[1]
    else:
        value["id"] = "other-id"
        value["created_at"] = "2000-01-01T00:00:00Z"
    write("comments.json", [value])
    task = read("task.json")
    task["metadata"]["pr_link_record"] = "previous"
    write("task.json", task)
    run()
    assert len(rows("curl-calls.jsonl")) == 1
    assert read("task.json")["metadata"]["pr_link_record"] != "previous"
    assert read("comments.json")[-1]["parent_id"] is None
print("PASS link-record: 元のコメントが人間・system・形が違う・見つからないときは、新しい元のコメントを書いて ID を直す")

reset()
# 返信先には条件 1・2 だけ、間隔には同じ PR の条件も使う。
write("comments.json", [comment(content=f"/note\n紐付けの試み直し: 見つからない（404） pr: {other} 時刻: 2099-01-01T00:00:00Z\n", created=recent)])
task = read("task.json")
task["metadata"]["pr_link_record"] = "previous"
write("task.json", task)
run()
assert len(rows("curl-calls.jsonl")) == 1
assert read("comments.json")[-1]["parent_id"] == "previous"
print("PASS link-record: 別の PR の記録は間隔に数えず、検証できた元のコメントへの返信にする")

for failure in ("post", "metadata"):
    reset()
    write("pulls-after.json", {"pull_requests": [{"html_url": pr}]})
    if failure == "post":
        (work / "fail-post").touch()
    else:
        (work / "fail").write_text("issue metadata set")
    run(linked=True)
    assert "pr_link_pending" not in read("task.json")["metadata"]
    calls = rows("calls.jsonl")
    posting = next(i for i,c in enumerate(calls) if c[:3] == ["issue", "comment", "add"])
    deletion = next(i for i,c in enumerate(calls) if c[:3] == ["issue", "metadata", "delete"])
    assert posting < deletion
print("PASS link-record: 投稿か ID の保存が失敗しても、判定と終了コードを保ち、マークを消す")
RECORDPY
