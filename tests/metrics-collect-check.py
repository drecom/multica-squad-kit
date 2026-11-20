"""Exercise collect through cli-stub.py, with cases derived from real CLI fixtures."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT, WORK = map(Path, sys.argv[1:])
FIXTURES = ROOT / "tests/fixtures/cli"
SCRIPT = ROOT / "scripts/metrics.py"


def sample(name):
    return json.loads((FIXTURES / (name + ".json")).read_text())[0]


def save(work, name, value):
    (work / name).write_text(json.dumps(value))


def make_case(name):
    work = WORK / name
    work.mkdir()
    prototype = sample("metrics-issues")
    issues = []
    for index, issue_id in enumerate(("synthetic-a", "synthetic-b")):
        row = copy.deepcopy(prototype["issues"][0])
        row.update(id=issue_id, identifier="EXAMPLE-" + issue_id[-1].upper(),
                   created_at=f"2026-01-01T00:0{2-index}:00Z", title="PRIVATE-ISSUE-TITLE")
        issues.append(row)
        page = copy.deepcopy(prototype)
        page.update(issues=[row], offset=index, limit=100, total=2, has_more=index == 0)
        save(work, f"issues-{index}.json", page)
    agents = sample("metrics-agents")
    agents[0].update(id="synthetic-agent", name="example-codex-fixer-member", instructions="PRIVATE-INSTRUCTIONS")
    unrelated = copy.deepcopy(agents[0])
    unrelated.update(id="unrelated-agent", name="PRIVATE-NAME person@example.invalid")
    agents.append(unrelated)
    save(work, "agents.json", agents)
    comments = sample("metrics-comments")
    for index, actor in enumerate(("member", "agent")):
        row = copy.deepcopy(next(row for row in comments if row["author_type"] == actor))
        row.update(id="synthetic-comment-" + str(index), issue_id="synthetic-a",
                   created_at=f"2026-01-01T00:0{4-index}:00Z",
                   content="PRIVATE-CONTENT [one](mention://member/human-one) "
                           "[again](mention://member/human-one) [two](mention://member/human-two)")
        if actor == "agent":
            row["author_id"] = "unrelated-agent"
        save(work, "comments-synthetic-a-" + ("first" if index == 0 else "next") + ".json", [row])
    (work / "comments-synthetic-a-first.json.stderr").write_text(
        (FIXTURES / "metrics-comments-cursor.txt").read_text())
    save(work, "comments-synthetic-b-first.json", [])
    timeline = sample("issue-timeline")
    changed = next(row for row in timeline if row["action"] == "status_changed")
    changed["details"].update({"from": "in_progress", "to": "in_review"})
    save(work, "timeline-synthetic-a.json", timeline)
    save(work, "timeline-synthetic-b.json", [])
    runs = sample("metrics-runs")
    completed = next(row for row in runs if "usage" in row)
    running = next(row for row in runs if "usage" not in row)
    for issue_id, row in (("synthetic-a", completed), ("synthetic-b", running)):
        row.update(issue_id=issue_id, agent_id="synthetic-agent")
        save(work, f"runs-{issue_id}.json", [row])
    return work


def run_collect(work, *arguments):
    return subprocess.run([sys.executable, str(SCRIPT), "collect", "--project", "synthetic-project",
                           "--output", str(work / "snapshot.json"), *arguments],
                          env={**os.environ, "METRICS_TEST_WORK": str(work)},
                          capture_output=True, text=True, timeout=120)


def read(work, name):
    return json.loads((work / name).read_text())


positive = make_case("positive")
result = run_collect(positive)
assert result.returncode == 0, result.stderr
snapshot = read(positive, "snapshot.json")
assert [row["id"] for row in snapshot["issues"]] == ["synthetic-b", "synthetic-a"]
assert len(snapshot["comments"]) == 2 and len(snapshot["transitions"]) == 1
assert snapshot["transitions"][0]["to_status"] == "in_review"
assert all(row["member_mentions"] == ["human-one", "human-two"] for row in snapshot["comments"])
assert snapshot["agents"] == [{"id": "synthetic-agent", "name": "example-codex-fixer-member"}]
assert all("content" not in row for row in snapshot["comments"])
assert "trace_definitions_sha256" not in snapshot
assert all("trace_matches" not in row for row in snapshot["comments"])
assert "PRIVATE-" not in (positive / "snapshot.json").read_text()
assert sorted(len(row["usage"]) for row in snapshot["runs"]) == [0, 1]
calls = [json.loads(line) for line in (positive / "calls").read_text().splitlines()]
issues = [args for args in calls if args[:2] == ["issue", "list"]]
assert [args[args.index("--offset") + 1] for args in issues] == ["0", "1"]
comments = [args for args in calls if args[:3] == ["issue", "comment", "list"]]
assert len(comments) == 3
assert all("--full" in args and "--compact" not in args and "--summary" not in args for args in comments)
thread_pages = [args for args in comments if args[3] == "synthetic-a"]
assert len(thread_pages) == 2
assert "--before" not in thread_pages[0] and "--before-id" in thread_pages[1]
assert ["agent", "list", "--include-archived", "--output", "json"] in calls
assert all("--activity-only" in args for args in calls if args[:2] == ["issue", "timeline"])
assert snapshot["cli_version"] == read(FIXTURES, "METRICS-CAPTURE.json")["version"]
print("PASS collect: タスクとコメントの全ページを読み、本文・指示・題名を残さず ID だけを保存する")

result = subprocess.run([sys.executable, str(SCRIPT), "count", str(positive / "snapshot.json"),
    "--cutoff", "2027-01-01T00:00:00Z", "--truncate", "2027-01-01T00:00:00Z",
    "--human", "human-one", "--project-key", "example", "--member-key", "member",
    "--output", str(positive / "result")], capture_output=True, text=True)
assert result.returncode == 0, result.stderr
counted = read(positive / "result", "metrics.json")
assert counted["totals"]["issue_count"] == 2
assert counted["totals"]["human_comments"] == 1
assert counted["totals"]["human_calls"] == 1
assert counted["totals"]["run_count"] == 2
assert counted["totals"]["roles"]["codex-fixer"]["unconfirmed_runs"] == 1
print("PASS collect: 保存した使用量と未確認の実行を count の入力として使える")

unfiltered = copy.deepcopy(snapshot)
unfiltered["agents"] = [{key: row[key] for key in ("id", "name")}
                        for row in read(positive, "agents.json")]
save(positive, "unfiltered.json", unfiltered)
result = subprocess.run([sys.executable, str(SCRIPT), "count", str(positive / "unfiltered.json"),
    "--cutoff", "2027-01-01T00:00:00Z", "--truncate", "2027-01-01T00:00:00Z",
    "--human", "human-one", "--project-key", "example", "--member-key", "member",
    "--output", str(positive / "unfiltered-result")], capture_output=True, text=True)
assert result.returncode == 0, result.stderr
before = read(positive / "unfiltered-result", "metrics.json")
for key in ("issues", "totals", "per_issue", "comparison"):
    assert counted[key] == before[key], key
print("PASS collect: 実行から参照されないエージェントを除いても、タスクごとの指標・役ごとの使用量・合計・平均は変わらない")

first = snapshot
result = run_collect(positive)
assert result.returncode == 0, result.stderr
second = read(positive, "snapshot.json")
first.pop("collected_at")
second.pop("collected_at")
assert first == second
print("PASS collect: 読んだ時刻を除く値と配列の並びを固定する")


traced = make_case("traced")
trace_path = ROOT / "tests/fixtures/metrics/traces.json"
no_match = copy.deepcopy(read(traced, "comments-synthetic-a-first.json")[0])
no_match.update(id="synthetic-no-match", content="UNMATCHED-PRIVATE-BODY")
save(traced, "comments-synthetic-b-first.json", [{**no_match, "issue_id": "synthetic-b"}])
result = run_collect(traced, "--traces", str(trace_path))
assert result.returncode == 0, result.stderr
traced_snapshot = read(traced, "snapshot.json")
assert traced_snapshot["trace_definitions_sha256"] == hashlib.sha256(trace_path.read_bytes()).hexdigest()
matches = {row["id"]: row["trace_matches"] for row in traced_snapshot["comments"]}
assert matches == {
    "synthetic-comment-0": ["m-member-only", "z-any-author"],
    "synthetic-comment-1": ["a-agent-only", "z-any-author"],
    "synthetic-no-match": [],
}, matches
assert all("content" not in row for row in traced_snapshot["comments"])
assert "PRIVATE-" not in (traced / "snapshot.json").read_text()
assert "UNMATCHED-PRIVATE-BODY" not in (traced / "snapshot.json").read_text()
assert all(row["member_mentions"] == ["human-one", "human-two"]
           for row in traced_snapshot["comments"] if row["id"] != "synthetic-no-match")
print("PASS collect traces: 全ページで正規表現と書き手を照合し、重複しない ID の一覧と定義の SHA-256 だけを残す")

result = run_collect(traced, "--traces", str(trace_path))
assert result.returncode == 0, result.stderr
repeated = read(traced, "snapshot.json")
traced_snapshot.pop("collected_at")
repeated.pop("collected_at")
assert traced_snapshot == repeated
print("PASS collect traces: 読んだ時刻を除いて、一致した跡の並びと保存値は変わらない")

for name, definition in (
    ("bad-json", "{"),
    ("bad-regex", {"schema_version": 1, "procedures": [
        {"id": "invalid", "trace": {"kind": "comment", "pattern": "["}}]}),
    ("duplicate-trace", {"schema_version": 1, "procedures": [
        {"id": "duplicate", "trace": None}, {"id": "duplicate", "trace": None}]}),
    ("missing-pattern", {"schema_version": 1, "procedures": [
        {"id": "invalid", "trace": {"kind": "comment"}}]}),
    ("unknown-kind", {"schema_version": 1, "procedures": [
        {"id": "invalid", "trace": {"kind": "unknown"}}]}),
):
    work = make_case(name)
    definition_path = work / "traces.json"
    definition_path.write_text(definition if isinstance(definition, str) else json.dumps(definition))
    (work / "snapshot.json").write_text("previous snapshot")
    result = run_collect(work, "--traces", str(definition_path))
    assert result.returncode != 0 and "エラー:" in result.stderr, (name, result)
    assert (work / "snapshot.json").read_text() == "previous snapshot"
    assert not (work / "calls").exists(), name
print("PASS collect traces: 不正な定義では CLI を呼ぶ前に止まり、既存の出力を保つ")


def failure(name, file=None, remove=None, warning=None, status=None, transform=None, previous=True):
    work = make_case(name)
    if remove:
        value = read(work, file)
        target = value
        for key in remove[:-1]:
            target = target[key]
        del target[remove[-1]]
        save(work, file, value)
        (work / "allow-missing-fields").touch()
    if warning:
        (work / (file + ".stderr")).write_text(warning)
    if status is not None:
        (work / (file + ".status")).write_text(str(status))
    if transform:
        value = read(work, file)
        transform(value)
        save(work, file, value)
    # A failed collection must preserve an earlier snapshot.
    if previous:
        (work / "snapshot.json").write_text("previous snapshot")
    result = run_collect(work)
    assert result.returncode != 0 and "エラー:" in result.stderr, (name, result)
    if previous:
        assert (work / "snapshot.json").read_text() == "previous snapshot"
    else:
        assert not (work / "snapshot.json").exists()
    assert not list(work.glob("snapshot.json.*"))


failure("truncated", "timeline-synthetic-a.json", warning="Warning: timeline truncated\n")
failure("truncated-new-output", "timeline-synthetic-a.json", warning="Warning: timeline truncated\n", previous=False)
failure("cli-error", "runs-synthetic-a.json", status=1)
failure("cursor-repeat", "comments-synthetic-a-next.json", warning=(FIXTURES / "metrics-comments-cursor.txt").read_text())
print("PASS collect: 切り詰めの警告・CLI の失敗・進まないページで止まり、既存の出力を保つ")
for name, file, path in (
    ("issue-field", "issues-0.json", ("issues", 0, "created_at")),
    ("page-field", "issues-0.json", ("has_more",)),
    ("comment-field", "comments-synthetic-a-first.json", (0, "content")),
    ("timeline-field", "timeline-synthetic-a.json", (0, "details", "to")),
    ("run-field", "runs-synthetic-a.json", (0, "agent_id")),
    ("usage-field", "runs-synthetic-a.json", (0, "usage", 0, "input_tokens")),
    ("agent-field", "agents.json", (0, "name")),
):
    failure(name, file, remove=path)
failure("empty-page", "issues-0.json", transform=lambda value: value.update(issues=[]))
print("PASS collect: 各読み取りの必須欄と使用量の欠け、次があるのに空のページで止まる")

empty = make_case("empty")
page = read(empty, "issues-0.json")
page.update(issues=[], total=0, has_more=False)
save(empty, "issues-0.json", page)
result = run_collect(empty)
assert result.returncode == 0, result.stderr
empty_snapshot = read(empty, "snapshot.json")
assert empty_snapshot["issues"] == []
assert empty_snapshot["agents"] == []
assert "PRIVATE-" not in (empty / "snapshot.json").read_text()
assert "person@example.invalid" not in (empty / "snapshot.json").read_text()
print("PASS collect: タスクが 0 件ならエージェントを保存せず、無関係な名前とメールも残らない")


def cp(*codes):
    return "".join(chr(code) for code in codes)


# --marks: marks and added fields only. Bodies, error text and branch names stay out.
marked = make_case("marks")
(marked / "allow-missing-fields").touch()
issues_a = read(marked, "issues-0.json")
issues_a["issues"][0]["labels"][0]["name"] = "重要"
issues_a["issues"][0]["metadata"]["branch"] = "feat/PRIVATE-BRANCH-agent"
save(marked, "issues-0.json", issues_a)
issues_b = read(marked, "issues-1.json")
del issues_b["issues"][0]["metadata"]["branch"]
save(marked, "issues-1.json", issues_b)
old_verb = cp(0x78BA, 0x304B, 0x3081)
member_comment = read(marked, "comments-synthetic-a-first.json")
member_comment[0]["content"] += ("\n見直しの種類: 設計と PR の見直し\n修正の依頼: 2 回目\n"
                                 "確認するコミット: ABCDEF0123456789abcdef0123456789abcdef01\n"
                                 "使用率の待ち: PRIVATE-WAIT-TEXT\nマージの前の CI の待ち: PRIVATE-CI-TEXT\n")
save(marked, "comments-synthetic-a-first.json", member_comment)
agent_comment = read(marked, "comments-synthetic-a-next.json")
agent_comment[0]["type"] = "system"
agent_comment[0]["content"] = "You've hit your usage limit. PRIVATE-LIMIT-TEXT\n"
save(marked, "comments-synthetic-a-next.json", agent_comment)
extra = copy.deepcopy(member_comment[0])
extra.update(id="synthetic-comment-2", issue_id="synthetic-b", created_at="2026-01-01T00:05:00Z",
             content="✅ PRIVATE-RESULT: 必須 0 件、推奨 3 件、実行中 9 件、高 1 件、性能は中 2 件、Level低 4 件\n⚠️ later\n"
                     + old_verb + "た" + "コミット: 0123ABCD4567ef\n")
save(marked, "comments-synthetic-b-first.json", [extra])
runs_a = read(marked, "runs-synthetic-a.json")
runs_a[0].update(status="failed", error="You've hit your usage limit. PRIVATE-ERROR-TEXT",
                 trigger_comment_id="synthetic-comment-0")
save(marked, "runs-synthetic-a.json", runs_a)
runs_b = read(marked, "runs-synthetic-b.json")
runs_b[0].update(status="failed", error="PRIVATE-OTHER-ERROR", trigger_comment_id=None)
save(marked, "runs-synthetic-b.json", runs_b)

result = run_collect(marked)
assert result.returncode == 0, result.stderr
plain = read(marked, "snapshot.json")
plain_text = (marked / "snapshot.json").read_text()
(marked / "plain-snapshot.json").write_text(plain_text)
assert "marks_version" not in plain
assert all(set(row) == {"id", "identifier", "created_at", "status"} for row in plain["issues"])
assert all("marks" not in row and "type" not in row for row in plain["comments"])
assert all("limit_stop" not in row and "trigger_comment_id" not in row for row in plain["runs"])
result = run_collect(marked, "--marks")
assert result.returncode == 0, result.stderr
text = (marked / "snapshot.json").read_text()
marks_snapshot = json.loads(text)
assert marks_snapshot["marks_version"] == 2 and marks_snapshot["schema_version"] == 1
for private in ("PRIVATE-", "usage limit", "feat/", "BRANCH"):
    assert private not in text, private
issues_by_id = {row["id"]: row for row in marks_snapshot["issues"]}
assert (issues_by_id["synthetic-a"]["important"], issues_by_id["synthetic-a"]["branch_type"]) == (True, "feat")
assert (issues_by_id["synthetic-b"]["important"], issues_by_id["synthetic-b"]["branch_type"]) == (False, None)
comments_by_id = {row["id"]: row for row in marks_snapshot["comments"]}
assert comments_by_id["synthetic-comment-0"]["type"] == "comment"
assert comments_by_id["synthetic-comment-0"]["marks"] == [
    {"kind": "review_kind", "value": "design_pr"}, {"kind": "fix_request", "value": 2},
    {"kind": "request_commit", "value": "abcdef012345"},
    {"kind": "usage_wait", "value": None}, {"kind": "ci_wait", "value": None}]
assert comments_by_id["synthetic-comment-1"]["type"] == "system"
assert comments_by_id["synthetic-comment-1"]["marks"] == [{"kind": "limit_notice", "value": None}]
assert comments_by_id["synthetic-comment-2"]["marks"] == [
    {"kind": "result_commit", "value": "0123abcd4567"}, {"kind": "result_mark", "value": "pass"},
    {"kind": "finding_counts", "value": {"required": 0, "recommended": 3, "high": 1, "medium": 2}}]
# 漢字・英字の直後の語（実行中・Level低）は数えず、かなの直後（性能は中）は数える
runs_by_issue = {row["issue_id"]: row for row in marks_snapshot["runs"]}
assert (runs_by_issue["synthetic-a"]["trigger_comment_id"], runs_by_issue["synthetic-a"]["limit_stop"]) == (
    "synthetic-comment-0", True)
assert (runs_by_issue["synthetic-b"]["trigger_comment_id"], runs_by_issue["synthetic-b"]["limit_stop"]) == (
    None, False)
assert read(marked, "snapshot.json")["runs"][0]["status"] == "failed"
half = len(calls := [json.loads(line) for line in (marked / "calls").read_text().splitlines()]) // 2
assert calls[:half] == calls[half:], "--marks でも読むコマンドは増えない"
print("PASS collect --marks: マークと足した欄だけを残し、本文・error の文・ブランチの名前を残さない")

stripped = copy.deepcopy(marks_snapshot)
for key in ("marks_version",):
    del stripped[key]
for row in stripped["issues"]:
    del row["important"], row["branch_type"]
for row in stripped["comments"]:
    del row["marks"], row["type"]
for row in stripped["runs"]:
    del row["trigger_comment_id"], row["limit_stop"]
stripped_with_time = copy.deepcopy(stripped)
plain.pop("collected_at")
stripped.pop("collected_at")
assert stripped == plain
print("PASS collect --marks: 足した欄を除くと、--marks を省略したスナップショットと同じになる")

# The added-field sample and the sample without them are different input files, so the only
# value in the result that may differ is the digest of the input file; it is replaced before comparing.
(marked / "stripped-snapshot.json").write_text(
    json.dumps(stripped_with_time, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
counts = []
digests = []
for name in ("stripped-snapshot.json", "snapshot.json"):
    output = marked / ("count-" + name)
    result = subprocess.run([sys.executable, str(SCRIPT), "count", str(marked / name),
        "--cutoff", "2027-01-01T00:00:00Z", "--truncate", "2027-01-01T00:00:00Z",
        "--human", "human-one", "--project-key", "example", "--member-key", "member",
        "--output", str(output)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    digest = hashlib.sha256((marked / name).read_bytes()).hexdigest()
    digests.append(digest)
    counts.append({file.name: file.read_bytes().replace(digest.encode(), b"SNAPSHOT-SHA256")
                   for file in sorted(output.iterdir())})
assert digests[0] != digests[1]
assert counts[0] and counts[0].keys() == counts[1].keys()
assert all(b"SNAPSHOT-SHA256" in data for name, data in counts[0].items() if name == "metrics.json")
for name in counts[0]:
    assert counts[0][name] == counts[1][name], name
print("PASS collect --marks: --marks の見本を count に渡した結果が、足した欄のない見本の結果と 1 バイトも違わない（入力ファイルの SHA-256 だけは置き換えて比べる）")

# previous_round and result_round: the form decide writes is kept, copies are not, and ids never are.
rounds = make_case("marks-rounds")
(rounds / "allow-missing-fields").touch()
template = read(rounds, "comments-synthetic-a-first.json")[0]
bodies = {
    "plain": "確認するコミット: abcdef0123456789\n前の回: ROUND-ID-1\n",
    "trailing-blank": "前の回: ROUND-ID-1 \t\n",
    "after-fence": "```\n前の回: ROUND-ID-1\n```\n前の回: ROUND-ID-2\n",
    "backtick-fence": "```text\n前の回: ROUND-ID-1\n```\n",
    "tilde-fence": "~~~\n前の回: ROUND-ID-1\n~~~\n",
    "longer-fence": "````\n```\n前の回: ROUND-ID-1\n```\n````\n",
    "unclosed-fence": "```\n前の回: ROUND-ID-1\n",
    "unclosed-by-shorter-close": "````\n前の回: ROUND-ID-1\n```\n",
    "indented-fence": "   ```\n前の回: ROUND-ID-1\n   ```\n",
    "backtick-in-info": "``` a`b\n前の回: ROUND-ID-1\n",
    "quote": "> 前の回: ROUND-ID-1\n",
    "list": "- 前の回: ROUND-ID-1\n",
    "indent": "  前の回: ROUND-ID-1\n",
    "extra-word": "前の回: ROUND-ID-1 ROUND-ID-2\n",
    "result": "✅ 結果\n返事の回: ROUND-ID-9\n",
    "result-in-fence": "```\n返事の回: ROUND-ID-9\n",
    "result-quoted": "> 返事の回: ROUND-ID-9\n",
    "both": "前の回: ROUND-ID-1\n返事の回: ROUND-ID-9\n",
}
rows = []
for index, (name, body) in enumerate(bodies.items()):
    row = copy.deepcopy(template)
    row.update(id="round-" + name, issue_id="synthetic-b", content=body, author_type="agent",
               created_at=f"2026-01-01T00:{10 + index:02d}:00Z")
    rows.append(row)
save(rounds, "comments-synthetic-b-first.json", rows)
result = run_collect(rounds, "--marks")
assert result.returncode == 0, result.stderr
round_text = (rounds / "snapshot.json").read_text()
assert "ROUND-ID" not in round_text
found = {row["id"][len("round-"):]: [mark["kind"] for mark in row["marks"] if mark["kind"].endswith("_round")]
         for row in json.loads(round_text)["comments"] if row["id"].startswith("round-")}
expected = {name: [] for name in bodies}
for name in ("plain", "trailing-blank", "after-fence", "both"):
    expected[name] = ["previous_round"]
for name in ("result", "result-in-fence"):
    expected[name] = ["result_round"]
expected["backtick-in-info"] = ["previous_round"]
expected["both"] = ["previous_round", "result_round"]
assert found == expected, found
assert all(mark["value"] is None for row in json.loads(round_text)["comments"] for mark in row["marks"]
           if mark["kind"].endswith("_round"))
print("PASS collect --marks: previous_round は decide が書く形の行だけに残り、囲み・引用・項目・字下げの中の写しと ID の後ろの語がある行には残らない。result_round は囲みの中の行にも残り（引用の記号の後ろは残らない）、どちらも ID を残さない")

missing_type = make_case("marks-no-type")
(missing_type / "allow-missing-fields").touch()
value = read(missing_type, "comments-synthetic-a-first.json")
del value[0]["type"]
save(missing_type, "comments-synthetic-a-first.json", value)
(missing_type / "snapshot.json").write_text("previous snapshot")
result = run_collect(missing_type, "--marks")
assert result.returncode != 0 and "エラー:" in result.stderr, result
assert (missing_type / "snapshot.json").read_text() == "previous snapshot"
print("PASS collect --marks: コメントの種類がなければ止まり、既存の出力を保つ")
