#!/usr/bin/env python3
"""Collect Multica records, then count workflow metrics from a saved snapshot.

Snapshot v1 has collected_at, cli_version, project_id and the arrays issues,
comments, transitions, runs and agents. See tests/fixtures/metrics/snapshot.json
for a synthetic example of the contract used by the collector.
"""

import argparse
from datetime import datetime, timezone
from decimal import Decimal, ROUND_FLOOR, ROUND_HALF_UP
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


TOKEN_FIELDS = ("input_tokens", "cache_write_tokens", "cache_read_tokens", "output_tokens")
METRIC_FIELDS = ("human_comments", "human_calls", "run_seconds", "run_count",
                 "fixer_runs", "in_review_transitions")
# Names are the roles shipped in common/agents (FORMAT is not a role).
ROLES = frozenset((
    "ci-monitor", "claude-fixer", "claude-implementer", "claude-principal",
    "code-reviewer", "codex-fixer", "codex-implementer", "codex-principal",
    "dependabot-merger", "designer", "orchestrator", "performance-reviewer",
    "planner", "qa", "security-reviewer", "usage-monitor", "ux-reviewer",
))


def cli(arguments, cursor=False, version=False):
    """Only the comment paginator may emit the documented cursor on stderr."""
    command = ["multica", *arguments]
    if not version:
        command += ["--output", "json"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f"Multica の読み取りに失敗しました: {' '.join(arguments[:3])}")
    next_page = None
    for line in result.stderr.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"Next thread cursor: --before (\S+) --before-id (\S+)", line)
        if not cursor or not match or next_page is not None:
            raise ValueError(f"Multica の警告で読み取りを止めました: {line}")
        timestamp(match[1])
        next_page = (match[1], match[2])
    if version:
        lines = result.stdout.splitlines()
        if not lines or not lines[0].startswith("multica "):
            raise ValueError("CLI のバージョンを読めません")
        return lines[0]
    return json.loads(result.stdout), next_page


def records(value):
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise ValueError("CLI の記録はオブジェクトの配列にしてください")
    return value


def fields(row, names, nullable=()):
    selected = {name: row[name] for name in names}
    for name, value in selected.items():
        if name in nullable and value is None:
            continue
        if not isinstance(value, str) or not value:
            raise ValueError(f"必須の文字列の欄がありません: {name}")
    return selected


def ordered(rows):
    return sorted(rows, key=lambda row: (timestamp(row["created_at"]), row["id"]))


def read_trace_definitions(path):
    """Keep the exact input digest so later judgments can verify their definitions."""
    raw = path.read_bytes()
    definitions = json.loads(raw)
    if not isinstance(definitions, dict) or definitions.get("schema_version") != 1:
        raise ValueError("対応していない跡の定義のバージョンです")
    procedures = records(definitions["procedures"])
    ids = set()
    for procedure in procedures:
        trace_id = fields(procedure, ("id",))["id"]
        if trace_id in ids:
            raise ValueError("跡の定義の ID が重複しています")
        ids.add(trace_id)
        trace = procedure["trace"]
        if trace is None:
            continue
        if not isinstance(trace, dict) or trace.get("kind") not in ("comment", "transition", "run"):
            raise ValueError("跡の形は comment・transition・run にしてください")
    return definitions, hashlib.sha256(raw).hexdigest()


def comment_trace_patterns(definitions):
    patterns = []
    for procedure in definitions["procedures"]:
        trace = procedure["trace"]
        if trace is None or trace["kind"] != "comment":
            continue
        if not isinstance(trace["pattern"], str):
            raise ValueError("コメントの跡の pattern は文字列にしてください")
        author_type = fields(trace, ("author_type",))["author_type"] if "author_type" in trace else None
        try:
            pattern = re.compile(trace["pattern"])
        except re.error as error:
            raise ValueError(f"コメントの跡の正規表現が不正です: {procedure['id']}") from error
        patterns.append((procedure["id"], pattern, author_type))
    return sorted(patterns, key=lambda item: item[0])


# --marks: the fixed line forms read from comment bodies. Bodies are never stored.
# Old commit-line names (a past wording kept so older tasks can be measured again) are
# written by code point, as tests/check-terms.py does, so the terms check does not stop them.
_OLD_VERB = "".join(chr(code) for code in (0x78BA, 0x304B, 0x3081))
MARKS_VERSION = 2
REVIEW_KINDS = {"最終レビュー": "final", "設計の見直し": "design", "設計と PR の見直し": "design_pr"}
BRANCH_TYPES = frozenset(("feat", "feature", "fix", "docs", "release", "test", "chore", "refactor", "agent"))
FINDING_WORDS = (("必須", "required"), ("推奨", "recommended"), ("高", "high"), ("中", "medium"), ("低", "low"))
LIMIT_PATTERNS = (
    re.compile(r"^You(?:'|\u2019)ve hit your [\w -]*limit", re.MULTILINE),
    re.compile(r"^Claude (?:AI )?usage limit reached", re.MULTILINE),
)
MARK_LINES = (
    ("review_kind", re.compile(r"^見直しの種類:[ \t]*(.*?)[ \t]*$", re.MULTILINE)),
    ("fix_request", re.compile(r"^修正の依頼:[ \t]*([0-9]+) 回目", re.MULTILINE)),
    ("request_commit", re.compile(
        r"^(?:確認する|" + _OLD_VERB + r"る)コミット:[ \t]*([0-9a-fA-F]{7,64})(?![0-9A-Za-z])", re.MULTILINE)),
    ("result_commit", re.compile(
        r"^(?:確認した|" + _OLD_VERB + r"た)コミット:[ \t]*([0-9a-fA-F]{7,64})(?![0-9A-Za-z])", re.MULTILINE)),
)
RESULT_MARK = re.compile("^(?:(\u274c)|(\u26a0)\ufe0f?|(\u2705))", re.MULTILINE)
# A finding word counts after kana and punctuation ("指摘は必須 1 件"), and not after a kanji, a Latin
# letter or a digit, where it is part of another word ("実行中 9 件").
FINDING_COUNT = re.compile(r"(?<![0-9A-Za-z\u3400-\u9fff])(必須|推奨|高|中|低)[ \t]*([0-9]+)[ \t]*件")
WAIT_LINES = (
    ("usage_wait", re.compile(r"^使用率の待ち(?:の延長)?:", re.MULTILINE)),
    ("ci_wait", re.compile(r"^マージの前の CI の待ち:", re.MULTILINE)),
)


PREVIOUS_ROUND = re.compile(r"前の回: (\S+)[ \t]*")
RESULT_ROUND = re.compile(r"^返事の回:", re.MULTILINE)
FENCE_OPEN = re.compile(r" {0,3}(`{3,}|~{3,})(.*)")


def limit_text(text):
    return any(pattern.search(text) for pattern in LIMIT_PATTERNS)


def lines_outside_fences(content):
    """Return the lines outside fenced code blocks, read by the CommonMark rule.

    A fence opens on a line indented 0-3 with three or more backticks or tildes (a backtick
    fence has no backtick after the marks) and closes on a line indented 0-3 with at least as
    many of the same mark followed only by spaces and tabs. A fence left open runs to the end.
    Fences inside quotes and list items are not told apart.
    """
    outside = []
    fence = None
    for line in content.split("\n"):
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(fence[1]) + r",}[ \t]*", line):
                fence = None
            continue
        opening = FENCE_OPEN.fullmatch(line)
        if opening and not (opening[1][0] == "`" and "`" in opening[2]):
            fence = (opening[1][0], len(opening[1]))
            continue
        outside.append(line)
    return outside


def read_marks(content, comment_type):
    """Return the marks of one comment body as [{"kind", "value"}], each kind at most once."""
    found = {}
    for kind, pattern in MARK_LINES:
        match = pattern.search(content)
        if not match:
            continue
        value = match[1]
        if kind == "review_kind":
            value = REVIEW_KINDS.get(value, "other")
        elif kind == "fix_request":
            value = int(value)
        else:
            value = value[:12].lower()
        found[kind] = value
    match = RESULT_MARK.search(content)
    if match:
        found["result_mark"] = "fail" if match[1] else "warn" if match[2] else "pass"
    counts = {}
    names = dict(FINDING_WORDS)
    for match in FINDING_COUNT.finditer(content):
        counts.setdefault(names[match[1]], int(match[2]))
    if counts:
        found["finding_counts"] = {name: counts[name] for _, name in FINDING_WORDS if name in counts}
    for kind, pattern in WAIT_LINES:
        if pattern.search(content):
            found[kind] = None
    if comment_type == "system" and limit_text(content):
        found["limit_notice"] = None
    # The round ids are never kept: the marks only tell a request written by decide from a copy.
    if any(PREVIOUS_ROUND.fullmatch(line) for line in lines_outside_fences(content)):
        found["previous_round"] = None
    if RESULT_ROUND.search(content):
        found["result_round"] = None
    order = ("review_kind", "fix_request", "request_commit", "result_commit", "result_mark",
             "finding_counts", "usage_wait", "ci_wait", "limit_notice", "previous_round", "result_round")
    return [{"kind": kind, "value": found[kind]} for kind in order if kind in found]


def issue_marks(row):
    labels = row.get("labels") or []
    metadata = row.get("metadata")
    branch = metadata.get("branch") if isinstance(metadata, dict) else None
    branch_type = None
    if isinstance(branch, str) and branch:
        head = branch.split("/", 1)[0]
        branch_type = head if head in BRANCH_TYPES else "other"
    return {"important": any(isinstance(label, dict) and label.get("name") == "重要" for label in labels),
            "branch_type": branch_type}


def collect(project, traces_path=None, marks=False):
    patterns = None
    if traces_path is not None:
        definitions, definitions_sha256 = read_trace_definitions(traces_path)
        patterns = comment_trace_patterns(definitions)
    snapshot = {"schema_version": 1, "project_id": project,
                "collected_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "cli_version": cli(["version"], version=True),
                "issues": [], "comments": [], "transitions": [], "runs": [], "agents": []}
    if patterns is not None:
        snapshot["trace_definitions_sha256"] = definitions_sha256
    if marks:
        snapshot["marks_version"] = MARKS_VERSION
    offset = 0
    while True:
        page, _ = cli(["issue", "list", "--project", project, "--limit", "100",
                       "--offset", str(offset), "--sort", "created_at", "--direction", "asc"])
        rows = records(page["issues"])
        if (type(page["has_more"]) is not bool or type(page["offset"]) is not int
                or page["offset"] != offset or type(page["limit"]) is not int
                or page["limit"] <= 0 or type(page["total"]) is not int or page["total"] < 0):
            raise ValueError("タスクのページの情報が不正です")
        for row in rows:
            issue = fields(row, ("id", "identifier", "created_at", "status"))
            if marks:
                issue.update(issue_marks(row))
            snapshot["issues"].append(issue)
        if not page["has_more"]:
            break
        if not rows:
            raise ValueError("次のページがあるのにタスクが空です")
        offset += len(rows)
    snapshot["issues"] = ordered(snapshot["issues"])
    if len({row["id"] for row in snapshot["issues"]}) != len(snapshot["issues"]):
        raise ValueError("タスクのページが重複しています")
    for issue in snapshot["issues"]:
        issue_id = issue["id"]
        before = None
        seen_cursors = set()
        while True:
            arguments = ["issue", "comment", "list", issue_id, "--recent", "100", "--full"]
            if before:
                arguments += ["--before", before[0], "--before-id", before[1]]
            comments, next_page = cli(arguments, cursor=True)
            for row in records(comments):
                comment = fields(row, ("id", "issue_id", "author_type", "author_id", "created_at"))
                content = row["content"]
                if not isinstance(content, str) or comment["issue_id"] != issue_id:
                    raise ValueError("コメントの本文の型かタスクが不正です")
                comment["member_mentions"] = sorted(set(re.findall(
                    r"mention://member/([A-Za-z0-9_-]+)", content)))
                if marks:
                    comment_type = row["type"]
                    if not isinstance(comment_type, str) or not comment_type:
                        raise ValueError("コメントの種類がありません")
                    comment["type"] = comment_type
                    comment["marks"] = read_marks(content, comment_type)
                if patterns is not None:
                    comment["trace_matches"] = [trace_id for trace_id, pattern, author_type in patterns
                                                if (author_type is None or author_type == comment["author_type"])
                                                and pattern.search(content)]
                snapshot["comments"].append(comment)
            if next_page is None:
                break
            if not comments or next_page in seen_cursors:
                raise ValueError("コメントのページが進みません")
            seen_cursors.add(next_page)
            before = next_page
        timeline, _ = cli(["issue", "timeline", issue_id, "--activity-only"])
        for row in ordered(records(timeline)):
            activity = fields(row, ("id", "type", "action", "created_at"))
            if activity["type"] != "activity":
                raise ValueError("状態の変化に活動以外の記録があります")
            if activity["action"] == "status_changed":
                change = fields(row["details"], ("from", "to"))
                snapshot["transitions"].append({"id": activity["id"], "issue_id": issue_id,
                    "created_at": activity["created_at"],
                    "from_status": change["from"], "to_status": change["to"]})
        runs, _ = cli(["issue", "runs", issue_id])
        for row in records(runs):
            run = fields(row, ("id", "issue_id", "agent_id", "status", "created_at",
                               "started_at", "completed_at"), nullable=("started_at", "completed_at"))
            if run["issue_id"] != issue_id:
                raise ValueError("実行のタスクが一致しません")
            # CLI 0.7.0 omits usage on runs without a usage record (captured fixture).
            usage = row["usage"] if "usage" in row else []
            if marks:
                trigger = row.get("trigger_comment_id")
                if trigger is not None and (not isinstance(trigger, str) or not trigger):
                    raise ValueError("trigger_comment_id は文字列か null にしてください")
                error = row.get("error")
                if error is not None and not isinstance(error, str):
                    raise ValueError("実行の error は文字列か null にしてください")
                run["trigger_comment_id"] = trigger
                run["limit_stop"] = (run["status"] == "failed" and error is not None
                                     and limit_text(error.strip()))
            run["usage"] = []
            for item in records(usage):
                normalized = fields(item, ("provider", "model"))
                normalized.update({field: item[field] for field in TOKEN_FIELDS})
                run["usage"].append(normalized)
            add_usage(empty_role(), run["usage"])
            run["usage"].sort(key=lambda item: (item["provider"], item["model"],
                                               *(item[field] for field in TOKEN_FIELDS)))
            snapshot["runs"].append(run)
    agent_ids = {run["agent_id"] for run in snapshot["runs"]}
    agents, _ = cli(["agent", "list", "--include-archived"])
    snapshot["agents"] = sorted((fields(row, ("id", "name")) for row in records(agents)
                                 if row["id"] in agent_ids), key=lambda row: row["id"])
    for name in ("comments", "runs"):
        snapshot[name] = ordered(snapshot[name])
    snapshot["transitions"] = [{key: value for key, value in row.items() if key != "id"}
                               for row in ordered(snapshot["transitions"])]
    validate_snapshot(snapshot)
    return snapshot


def write_snapshot(path, snapshot):
    """Publish only a fully read and validated snapshot; keep an older file on failure."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(snapshot, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def timestamp(value):
    """Parse RFC3339 without losing fractional seconds or using floats."""
    match = re.fullmatch(
        r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})", value)
    if not match:
        raise ValueError("時刻はタイムゾーン付きの RFC3339 にしてください")
    base, fraction, offset = match.groups()
    instant = datetime.fromisoformat(base + ("+00:00" if offset == "Z" else offset))
    delta = instant.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return Decimal(delta.days * 86400 + delta.seconds) + Decimal(fraction or "0")


def one_decimal(numerator, denominator=1):
    if not denominator:
        return None
    return str((Decimal(numerator) / Decimal(denominator)).quantize(
        Decimal("0.1"), rounding=ROUND_HALF_UP))


def empty_metrics():
    return dict.fromkeys(METRIC_FIELDS, 0)


def empty_role():
    return {"run_count": 0, "confirmed_runs": 0, "unconfirmed_runs": 0,
            "agent_names": [], "tokens": None}


def add_usage(role, usage):
    role["run_count"] += 1
    if not usage:
        role["unconfirmed_runs"] += 1
        return
    role["confirmed_runs"] += 1
    if role["tokens"] is None:
        role["tokens"] = dict.fromkeys((*TOKEN_FIELDS, "total_tokens"), 0)
    for row in usage:
        for field in TOKEN_FIELDS:
            value = row[field]
            if type(value) is not int or value < 0:
                raise ValueError("使用量は 0 以上の整数にしてください")
            role["tokens"][field] += value
            role["tokens"]["total_tokens"] += value


def role_name(name, project_key, member_key):
    prefix, suffix = project_key + "-", "-" + member_key
    if name.startswith(prefix) and name.endswith(suffix):
        role = name[len(prefix):-len(suffix)]
        if role in ROLES:
            return role
    return "その他"


def validate_snapshot(snapshot):
    if snapshot["schema_version"] != 1:
        raise ValueError("対応していないスナップショットのバージョンです")
    timestamp(snapshot["collected_at"])
    for field in ("cli_version", "project_id"):
        if not isinstance(snapshot[field], str) or not snapshot[field]:
            raise ValueError(f"{field} がありません")
    fields = {
        "issues": ("id", "identifier", "created_at", "status"),
        "comments": ("id", "issue_id", "author_type", "author_id", "created_at", "member_mentions"),
        "transitions": ("issue_id", "from_status", "to_status", "created_at"),
        "runs": ("id", "issue_id", "agent_id", "status", "created_at", "started_at", "completed_at", "usage"),
        "agents": ("id", "name"),
    }
    for group, required in fields.items():
        if not isinstance(snapshot[group], list):
            raise ValueError(f"{group} は配列にしてください")
        ids = set()
        for row in snapshot[group]:
            for field in required:
                if field not in row:
                    raise ValueError(f"{group} に {field} がありません")
            if "id" in required:
                if row["id"] in ids:
                    raise ValueError(f"{group} の ID が重複しています")
                ids.add(row["id"])
            for field in ("created_at", "started_at", "completed_at"):
                if field in row and row[field] is not None:
                    timestamp(row[field])
            if group == "comments" and not isinstance(row["member_mentions"], list):
                raise ValueError("member_mentions は配列にしてください")
            if group == "runs":
                if not isinstance(row["usage"], list):
                    raise ValueError("usage は配列にしてください（未確認は空の配列）")
                # Check even excluded runs, so malformed input cannot be hidden by a cutoff.
                add_usage(empty_role(), row["usage"])
    issue_ids = {row["id"] for row in snapshot["issues"]}
    agent_ids = {row["id"] for row in snapshot["agents"]}
    for group in ("comments", "transitions", "runs"):
        for row in snapshot[group]:
            if row["issue_id"] not in issue_ids:
                raise ValueError(f"{group} のタスクがスナップショットにありません")
            if group == "runs" and row["agent_id"] not in agent_ids:
                raise ValueError("実行のエージェントがスナップショットにありません")


PROTECTIONS = ("secrets", "write_scope", "gate", "irreversible")


def source_git(repository, *arguments):
    result = subprocess.run(["git", "--no-optional-locks", "-C", str(repository), *arguments],
                            capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f"見直し元の Git の読み取りに失敗しました: {arguments[0]}")
    return result.stdout


def procedure_file(name):
    return (re.fullmatch(r"common/agents/[^/]+\.md", name) is not None
            or name.startswith("common/skills/squad-handoff/") and name.endswith(".md")
            or name in ("common/squad.md", "common/autopilots.md"))


def markdown_sections(content):
    """Read headings outside fenced code; a section includes its child sections."""
    lines = content.splitlines(keepends=True)
    headings = []
    fence = None
    previous = None
    frontmatter = bool(lines and lines[0].strip() == "---")
    for index, line in enumerate(lines):
        if frontmatter:
            if index and line.strip() in ("---", "..."):
                frontmatter = False
            continue
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(fence[1]) + r",}\s*", line):
                fence = None
            previous = None
            continue
        opening = re.match(r" {0,3}(`{3,}|~{3,})(.*)", line)
        if opening and (opening[1][0] == "~" or "`" not in opening[2]):
            fence = (opening[1][0], len(opening[1]))
            previous = None
            continue
        atx = re.match(r" {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*\r?\n?$)", line)
        underline = re.fullmatch(r" {0,3}(=+|-+)[ \t]*\r?\n?", line)
        if atx:
            title = re.sub(r"[ \t]+#+[ \t]*$", "", (atx[2] or "").strip())
            headings.append({"level": len(atx[1]), "title": title, "start": index, "body": index + 1})
        elif underline and previous is not None:
            headings.append({"level": 1 if underline[1][0] == "=" else 2,
                             "title": previous.strip(), "start": index - 1, "body": index + 1})
        previous = (line if line.strip() and not atx and not underline
                    and not line.startswith(("    ", "\t")) else None)
    stack = []
    for index, heading in enumerate(headings):
        while stack and stack[-1]["level"] >= heading["level"]:
            stack.pop()
        heading["path"] = " / ".join([row["title"] for row in stack] + [heading["title"]])
        stack.append(heading)
        end = next((row["start"] for row in headings[index + 1:] if row["level"] <= heading["level"]), len(lines))
        heading["content"] = "".join(lines[heading["body"]:end])
    return headings


def procedure_sources(procedures, args):
    repository = Path(source_git(args.repository, "rev-parse", "--show-toplevel").strip())
    if source_git(repository, "rev-parse", "--is-shallow-repository").strip() != "false":
        raise ValueError("最初に足したコミットを調べるには、浅くない履歴が必要です")
    revision = source_git(repository, "rev-parse", "--verify", "--end-of-options",
                          args.revision + "^{commit}").strip()
    names = source_git(repository, "ls-tree", "-r", "--full-tree", "--name-only", "-z", revision).split("\0")
    sections = {name: markdown_sections(source_git(repository, "show", revision + ":" + name))
                for name in sorted(names) if procedure_file(name)}
    covered = set()
    for procedure in procedures:
        name, title = procedure["file"], procedure["section"]
        if name not in sections:
            raise ValueError(f"範囲のファイルが見直し元にありません: {name}")
        matches = [(index, row) for index, row in enumerate(sections[name]) if row["path"] == title]
        if not matches:
            matches = [(index, row) for index, row in enumerate(sections[name]) if row["title"] == title]
        if len(matches) != 1:
            raise ValueError(f"節が存在しないか一意に決まりません: {name}: {title}")
        index, section = matches[0]
        if section["content"].count(procedure["marker"]) != 1:
            raise ValueError(f"目印が節の中にちょうど 1 回現れません: {name}: {title}")
        covered.add((name, index))
    missing = [f"{name}: {row['path']}" for name, rows in sections.items()
               for index, row in enumerate(rows) if (name, index) not in covered]
    if missing:
        raise ValueError("跡の定義が覆わない見出しがあります: " + "; ".join(missing))
    return repository, revision


def introduced_commit(repository, revision, procedure):
    # -m also reads each merge against its parents, so a line first written while resolving a merge conflict
    # has a commit; a clean merge only lists the merge after the commit that added the line (topological order).
    history = source_git(repository, "log", "--root", "--reverse", "--topo-order", "--no-renames", "-m",
                         "--format=%H%x00%s", "-S", procedure["marker"], revision, "--", procedure["file"])
    if not history.strip():
        raise ValueError(f"目印を最初に足したコミットが読めません: {procedure['id']}")
    sha, subject = history.splitlines()[0].split("\0", 1)
    return {"sha": sha, "subject": subject}


def trace_procedures(definitions):
    # Validate the same comment definitions that collect used, without reading bodies.
    comment_trace_patterns(definitions)
    for procedure in definitions["procedures"]:
        fields(procedure, ("file", "section", "marker"))
        protection = procedure.get("protection")
        not_procedure = procedure.get("not_procedure", False)
        if protection is not None and protection not in PROTECTIONS:
            raise ValueError("守る手順の分類は secrets・write_scope・gate・irreversible にしてください")
        if type(not_procedure) is not bool:
            raise ValueError("not_procedure は真偽値にしてください")
        trace = procedure["trace"]
        if not_procedure and (trace is not None or protection is not None):
            raise ValueError("手順でない節に跡や守る手順の分類を付けないでください")
        if trace is not None and trace["kind"] == "transition":
            fields(trace, ("from_status", "to_status"))
        if trace is not None and trace["kind"] == "run":
            fields(trace, ("role", "status"))
            if trace["role"] not in ROLES and trace["role"] != "その他":
                raise ValueError("実行の跡の role が役の名前と一致しません")
    return sorted(definitions["procedures"], key=lambda row: row["id"])


def traces(snapshot, raw, definitions, definitions_sha256, args):
    validate_snapshot(snapshot)
    if snapshot.get("trace_definitions_sha256") != definitions_sha256:
        raise ValueError("スナップショットと跡の定義の SHA-256 が一致しません")
    procedures = trace_procedures(definitions)
    repository, revision = procedure_sources(procedures, args)
    comment_ids = {row["id"] for row in procedures
                   if row["trace"] is not None and row["trace"]["kind"] == "comment"}
    for comment in snapshot["comments"]:
        matches = comment["trace_matches"]
        if (not isinstance(matches, list) or any(not isinstance(item, str) for item in matches)
                or len(set(matches)) != len(matches) or not set(matches).issubset(comment_ids)):
            raise ValueError("コメントの trace_matches が跡の定義と一致しません")
    cutoff = timestamp(snapshot["collected_at"])
    selected = sorted((issue for issue in snapshot["issues"]
                       if timestamp(issue["created_at"]) <= cutoff),
                      key=lambda row: (-timestamp(row["created_at"]), row["id"]))[:20]
    issue_ids = {issue["id"] for issue in selected}
    groups = {name: [row for row in snapshot[name] if row["issue_id"] in issue_ids]
              for name in ("comments", "transitions", "runs")}
    agents = {row["id"]: row["name"] for row in snapshot["agents"]}
    rows = []
    for procedure in procedures:
        trace = procedure["trace"]
        count = None
        if trace is not None:
            if trace["kind"] == "comment":
                count = sum(procedure["id"] in row["trace_matches"] for row in groups["comments"])
            elif trace["kind"] == "transition":
                count = sum(row["from_status"] == trace["from_status"]
                            and row["to_status"] == trace["to_status"] for row in groups["transitions"])
            else:
                count = sum(role_name(agents[row["agent_id"]], args.project_key, args.member_key) == trace["role"]
                            and row["status"] == trace["status"] for row in groups["runs"])
        protection = procedure.get("protection")
        if procedure.get("not_procedure", False):
            judgment = "手順でない"
        elif protection is not None:
            judgment = "守る手順で残す"
        elif trace is None:
            judgment = "判定できない"
        else:
            judgment = "効いた" if count else "削る候補"
        rows.append({**{key: procedure[key] for key in ("id", "file", "section", "marker", "trace")},
                     "protection": protection, "count": count, "judgment": judgment,
                     "introduced_commit": (introduced_commit(repository, revision, procedure)
                                           if judgment in ("削る候補", "守る手順で残す", "判定できない") else None)})
    return {"schema_version": 1,
            "input": {"snapshot_sha256": hashlib.sha256(raw).hexdigest(),
                      "trace_definitions_sha256": definitions_sha256,
                      "collected_at": snapshot["collected_at"], "project_id": snapshot["project_id"],
                      "project_key": args.project_key, "member_key": args.member_key, "revision": revision},
            "issues": selected, "procedures": rows}


def traces_markdown(result):
    lines = ["# 手順の見直し", "", "## 入力", ""]
    lines += table(("入力", "値"), result["input"].items())
    lines += ["## 対象のタスク", "", f"対象のタスク: {len(result['issues'])} 件", ""]
    lines += table(("タスク", "ID", "作られた時刻"),
                   ((row["identifier"], row["id"], row["created_at"]) for row in result["issues"]))
    lines += ["## 判定の一覧", ""]
    lines += table(("ID", "ファイル", "節", "目印", "跡", "20 件での回数", "判定", "守る手順の分類", "足したコミット"),
                   ((row["id"], row["file"], row["section"], row["marker"],
                     json.dumps(row["trace"], ensure_ascii=False, sort_keys=True),
                     row["count"], row["judgment"], row["protection"],
                     (row["introduced_commit"]["sha"] + " " + row["introduced_commit"]["subject"]
                      if row["introduced_commit"] is not None else "—")) for row in result["procedures"]))
    return "\n".join(lines)


def with_minutes(metrics):
    return {**metrics, "run_minutes": one_decimal(metrics["run_seconds"], 60)}


def average_roles(roles, count):
    return {
        name: {
            **{field: one_decimal(role[field], count)
               for field in ("run_count", "confirmed_runs", "unconfirmed_runs")},
            "tokens": ({field: one_decimal(value, count)
                        for field, value in role["tokens"].items()}
                       if role["tokens"] is not None else None),
        }
        for name, role in sorted(roles.items())
    }


def comparison(plan, totals):
    result = {"metrics": {}, "roles": {}}
    for field, expected in sorted(plan["metrics"].items()):
        if field not in (*METRIC_FIELDS, "issue_count") or type(expected) is not int or expected < 0:
            raise ValueError("比較する指標は整数の合計にしてください（実行時間は run_seconds）")
        actual = totals[field]
        result["metrics"][field] = {"plan": expected, "actual": actual,
                                    "difference": actual - expected}
    for name, expected in sorted(plan["roles"].items()):
        role = totals["roles"].get(name, empty_role())
        tokens = role["tokens"]
        actual = tokens["total_tokens"] if tokens is not None else None
        prior = expected["total_tokens"]
        if prior is not None and (type(prior) is not int or prior < 0):
            raise ValueError("比較するトークン数は 0 以上の整数か null にしてください")
        result["roles"][name] = {
            "plan": prior, "actual": actual,
            "difference": actual - prior if actual is not None and prior is not None else None,
            "unconfirmed_runs": role["unconfirmed_runs"],
        }
    # Include newly observed roles, too: they did not have a row in the plan.
    for name, role in sorted(totals["roles"].items()):
        if name not in result["roles"]:
            result["roles"][name] = {
                "plan": None,
                "actual": role["tokens"]["total_tokens"] if role["tokens"] is not None else None,
                "difference": None, "unconfirmed_runs": role["unconfirmed_runs"],
            }
    return result


SETTLED_STATUSES = ("done", "cancelled", "in_review")


def status_at(issue, transitions, cutoff):
    """Status at cutoff: the last change before it, else the first change at or after it."""
    before = [row for row in transitions if timestamp(row["created_at"]) < cutoff]
    if before:
        return max(before, key=lambda row: (timestamp(row["created_at"]), row["from_status"],
                                            row["to_status"]))["to_status"]
    after = [row for row in transitions if timestamp(row["created_at"]) >= cutoff]
    if after:
        return min(after, key=lambda row: (timestamp(row["created_at"]), row["from_status"],
                                           row["to_status"]))["from_status"]
    return issue["status"]


def count(snapshot, raw, args, plan):
    validate_snapshot(snapshot)
    cutoff, truncate = timestamp(args.cutoff), timestamp(args.truncate)
    start = timestamp(args.from_time) if args.from_time else None
    if start is not None and start >= cutoff:
        raise ValueError("--from は --cutoff より前にしてください")
    agents = {row["id"]: row["name"] for row in snapshot["agents"]}
    selected = sorted((issue for issue in snapshot["issues"]
                       if timestamp(issue["created_at"]) < cutoff
                       and (start is None or timestamp(issue["created_at"]) >= start)),
                      key=lambda issue: (timestamp(issue["created_at"]), issue["id"]))
    limit = getattr(args, "limit", None)
    settled = getattr(args, "settled", False)
    if limit is not None:
        if start is None:
            raise ValueError("--limit は --from と一緒に指定してください")
        if limit < 1:
            raise ValueError("--limit は 1 以上にしてください")
        if len(selected) < limit:
            raise ValueError(f"対象のタスクが {limit} 件に足りません（{len(selected)} 件）")
        selected = selected[:limit]
    statuses = {}
    if settled:
        by_issue = {}
        for transition in snapshot["transitions"]:
            by_issue.setdefault(transition["issue_id"], []).append(transition)
        statuses = {issue["id"]: status_at(issue, by_issue.get(issue["id"], []), cutoff)
                    for issue in selected}
        unsettled = [f"{issue['identifier']}: {statuses[issue['id']]}" for issue in selected
                     if statuses[issue["id"]] not in SETTLED_STATUSES]
        if unsettled:
            raise ValueError("測る時刻の状態が done・cancelled・in_review でないタスクがあります\n"
                             + "\n".join(unsettled))
    issues = {issue["id"]: {"id": issue["id"], "identifier": issue["identifier"],
                            **empty_metrics(), "roles": {}} for issue in selected}
    humans = set(args.human)
    for comment in snapshot["comments"]:
        issue = issues.get(comment["issue_id"])
        if issue is None or timestamp(comment["created_at"]) >= cutoff:
            continue
        if comment["author_type"] == "member":
            issue["human_comments"] += 1
        elif comment["author_type"] == "agent" and humans.intersection(comment["member_mentions"]):
            issue["human_calls"] += 1
    for transition in snapshot["transitions"]:
        issue = issues.get(transition["issue_id"])
        if (issue is not None and timestamp(transition["created_at"]) < cutoff
                and transition["to_status"] == "in_review"
                and transition["from_status"] != "in_review"):
            issue["in_review_transitions"] += 1
    for run in snapshot["runs"]:
        issue = issues.get(run["issue_id"])
        if issue is None or timestamp(run["created_at"]) >= cutoff or run["started_at"] is None:
            continue
        begin = timestamp(run["started_at"])
        end = min(timestamp(run["completed_at"]), truncate) if run["completed_at"] else truncate
        issue["run_count"] += 1
        issue["run_seconds"] += int(max(Decimal(0), end - begin))
        name = agents[run["agent_id"]]
        role = role_name(name, args.project_key, args.member_key)
        if role in ("claude-fixer", "codex-fixer"):
            issue["fixer_runs"] += 1
        usage = issue["roles"].setdefault(role, empty_role())
        add_usage(usage, run["usage"])
        if role == "その他" and name not in usage["agent_names"]:
            usage["agent_names"].append(name)

    totals = {"issue_count": len(issues), **empty_metrics(), "roles": {}}
    for issue in issues.values():
        for field in METRIC_FIELDS:
            totals[field] += issue[field]
        for name, role in issue["roles"].items():
            role["agent_names"].sort()
            total_role = totals["roles"].setdefault(name, empty_role())
            for field in ("run_count", "confirmed_runs", "unconfirmed_runs"):
                total_role[field] += role[field]
            total_role["agent_names"] = sorted(set(total_role["agent_names"] + role["agent_names"]))
            if role["tokens"] is not None:
                if total_role["tokens"] is None:
                    total_role["tokens"] = dict.fromkeys((*TOKEN_FIELDS, "total_tokens"), 0)
                for field, value in role["tokens"].items():
                    total_role["tokens"][field] += value
    result = {
        "schema_version": 1,
        "input": {"cutoff": args.cutoff, "truncate": args.truncate, "from": args.from_time,
                  "human": sorted(humans), "project_key": args.project_key, "member_key": args.member_key,
                  "project_id": snapshot["project_id"], "snapshot_sha256": hashlib.sha256(raw).hexdigest(),
                  "collected_at": snapshot["collected_at"], "cli_version": snapshot["cli_version"],
                  "compare": plan},
        "issues": [with_minutes(issue) for issue in issues.values()],
        "totals": with_minutes(totals),
        "per_issue": {**{field: one_decimal(totals[field], len(issues)) for field in METRIC_FIELDS},
                      "run_minutes": one_decimal(totals["run_seconds"], len(issues) * 60),
                      "roles": average_roles(totals["roles"], len(issues))},
        "comparison": comparison(plan, totals) if plan is not None else None,
    }
    if limit is not None or settled:
        # Added only when asked, so a run without them stays byte-identical.
        result["input"]["limit"] = limit
        result["input"]["settled"] = settled
        result["range"] = {"first_created_at": selected[0]["created_at"] if selected else None,
                           "last_created_at": selected[-1]["created_at"] if selected else None}
        if settled:
            for row in result["issues"]:
                row["status_at_cutoff"] = statuses[row["id"]]
    return result


def cell(value):
    if value is None:
        return "未確認"
    return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>").replace("\r", "")


def table(headers, rows):
    return ["| " + " | ".join(map(cell, headers)) + " |",
            "| " + " | ".join("---" for _ in headers) + " |",
            *("| " + " | ".join(map(cell, row)) + " |" for row in rows), ""]


def markdown(result):
    lines = ["# 作業の指標", "", "## 入力", ""]
    lines += table(("入力", "値"), ((key, json.dumps(value, ensure_ascii=False, sort_keys=True))
                                   for key, value in result["input"].items()))
    if "range" in result:
        lines += ["## 範囲", ""]
        lines += table(("項目", "値"), (
            ("最初のタスクの作られた時刻", result["range"]["first_created_at"]),
            ("最後のタスクの作られた時刻", result["range"]["last_created_at"]),
            *((issue["identifier"], issue["status_at_cutoff"]) for issue in result["issues"]
              if "status_at_cutoff" in issue)))
    columns = ("human_comments", "human_calls", "run_seconds", "run_minutes", "run_count",
               "fixer_runs", "in_review_transitions")
    headers = ("タスク", "人間のコメント", "人間の呼び出し", "実行秒", "実行分", "実行回数", "差し戻し", "in_review")
    lines += ["## タスクごと・合計・1 タスクあたり", "", f"対象のタスク: {result['totals']['issue_count']} 件", ""]
    lines += table(headers, [(issue["identifier"], *(issue[key] for key in columns)) for issue in result["issues"]]
                   + [(label, *(result[group][key] for key in columns))
                      for label, group in (("合計", "totals"), ("1 タスクあたり", "per_issue"))])
    lines += ["## 役ごとのトークン数", "", "トークンは確認できた実行の合計。未確認の実行は加算せず、別の件数に示す。", ""]
    rows = []
    for label, roles in [(issue["identifier"], issue["roles"]) for issue in result["issues"]] + [
            ("合計", result["totals"]["roles"]), ("1 タスクあたり", result["per_issue"]["roles"])]:
        for name, role in sorted(roles.items()):
            rows.append((label, name, ", ".join(role.get("agent_names", [])), role["run_count"],
                         role["confirmed_runs"], role["unconfirmed_runs"],
                         *((role["tokens"] or {}).get(field) for field in (*TOKEN_FIELDS, "total_tokens"))))
    lines += table(("タスク", "役", "その他のエージェント", "実行", "確認済み", "未確認",
                    "入力", "キャッシュ作成", "キャッシュ読み出し", "出力", "合計"), rows)
    lines += ["## 計画の表との差", ""]
    if result["comparison"] is None:
        lines += ["比較の入力なし。", ""]
    else:
        lines += ["差は今回の値から計画の値を引いた値。差の理由は、数えた人が結果のコメントに記す。", ""]
        lines += table(("指標", "計画", "今回", "差"),
                       ((name, row["plan"], row["actual"], row["difference"])
                        for name, row in result["comparison"]["metrics"].items()))
        lines += table(("役", "計画のトークン合計", "今回の確認済み合計", "差", "未確認の実行"),
                       ((name, row["plan"], row["actual"], row["difference"], row["unconfirmed_runs"])
                        for name, row in result["comparison"]["roles"].items()))
    return "\n".join(lines)


# Allocation order of the 時間の内訳: the first category with a running run owns the interval.
BREAKDOWN_CATEGORIES = (
    "implementation", "fix", "code_review_first", "code_review_later",
    "other_review_first", "other_review_later", "e2e", "final_review_first",
    "final_review_later", "design_review", "design_requirements", "orchestrator", "unknown")
# An interval with no running run is a wait, and the first kind that fits names it.
WAIT_KINDS = ("wait_startup", "wait_human", "wait_usage_limit", "wait_ci", "wait_other")
SMALL_IMPLEMENTATION_SECONDS = 1800
IMPLEMENTER_ROLES = frozenset(("claude-implementer", "codex-implementer"))
FIXER_ROLES = frozenset(("claude-fixer", "codex-fixer"))
OTHER_REVIEWER_ROLES = frozenset(("security-reviewer", "performance-reviewer", "ux-reviewer"))
PRINCIPAL_ROLES = frozenset(("claude-principal", "codex-principal"))
# Marks of a request: the leader writes them, and so does `decide` in the role that wrote the reply.
# A mark from anyone else is not read and is counted.
LEADER_MARKS = ("fix_request", "review_kind", "request_commit", "usage_wait", "ci_wait")
# Marks only a review role, qa or a principal writes; the same rule counts what is skipped.
RESULT_ROLES = frozenset(("code-reviewer", "qa")) | OTHER_REVIEWER_ROLES | PRINCIPAL_ROLES
RESULT_MARKS = ("result_commit", "result_mark", "finding_counts")
SKIPPED_MARKS = LEADER_MARKS + RESULT_MARKS
# The processes the findings are counted by. A fix request whose basis results are all in one of them
# is that process's own; design_review has no fix request, so only its results are shown.
FINDING_PROCESSES = ("code_review", "other_review", "e2e", "final_review", "design_review", "unknown")
# The processes with a first round and later rounds; their findings are also counted by round.
ROUNDED_PROCESSES = ("code_review", "other_review", "final_review")
ROUNDS = ("first", "later")
BLOCKING_WORDS = ("required", "high", "medium")
NON_BLOCKING_WORDS = ("recommended", "low")
FINDING_FIELDS = ("results", "with_findings", "without_findings", "unreadable", "led_to_fix", "overlapping",
                  "only_fix_requests", "blocking", "non_blocking", "counts_unread")
BREAKDOWN_FIELDS = {
    "issues": ("important", "branch_type"),
    "comments": ("type", "marks"),
    "runs": ("trigger_comment_id", "limit_stop"),
}


def whole_seconds(value):
    return int(timestamp(value).to_integral_value(rounding=ROUND_FLOOR))


def validate_breakdown_input(snapshot):
    if snapshot.get("marks_version") != MARKS_VERSION:
        raise ValueError(f"スナップショットに marks_version {MARKS_VERSION} がありません。"
                         "collect --marks で取り直してください")
    validate_snapshot(snapshot)
    for group, required in BREAKDOWN_FIELDS.items():
        for row in snapshot[group]:
            for field in required:
                if field not in row:
                    raise ValueError(f"{group} に {field} がありません。collect --marks で取り直してください")
    for row in snapshot["comments"]:
        if not isinstance(row["marks"], list):
            raise ValueError("marks は配列にしてください")
        for mark in row["marks"]:
            if not isinstance(mark, dict) or "kind" not in mark or "value" not in mark:
                raise ValueError("marks の要素は kind と value を持つオブジェクトにしてください")


def run_category(role, review_kind):
    """Return (category without the round, round key); the key is None for categories with no rounds."""
    if role in IMPLEMENTER_ROLES:
        return "implementation", None
    if role in FIXER_ROLES:
        return "fix", None
    if role == "code-reviewer":
        return "code_review", role
    if role in OTHER_REVIEWER_ROLES:
        return "other_review", role
    if role == "qa":
        return "e2e", None
    if role in PRINCIPAL_ROLES:
        if review_kind == "final":
            return "final_review", "final"
        if review_kind in ("design", "design_pr"):
            return "design_review", None
        return "unknown", None
    if role in ("designer", "planner"):
        return "design_requirements", None
    if role == "orchestrator":
        return "orchestrator", None
    return "unknown", None


def process_of(category):
    """Return the process of a run category: the category without its round."""
    for suffix in ("_first", "_later"):
        if category.endswith(suffix):
            return category[:-len(suffix)]
    return category


def round_of(category):
    """Return first or later for a category with a round, otherwise None."""
    for round_name in ROUNDS:
        if category.endswith("_" + round_name):
            return round_name
    return None


def result_state(marks):
    """Return with, without or unreadable for the marks of a result comment."""
    mark, counts = marks.get("result_mark"), marks.get("finding_counts")
    if mark is not None:
        return "without" if mark == "pass" else "with"
    if counts:
        return "with" if any(number >= 1 for number in counts.values()) else "without"
    return "unreadable"


def empty_row():
    return {"passed": False, **dict.fromkeys(FINDING_FIELDS, 0)}


def empty_findings():
    processes = {name: empty_row() for name in FINDING_PROCESSES}
    for name in ROUNDED_PROCESSES:
        processes[name]["rounds"] = {round_name: empty_row() for round_name in ROUNDS}
    return {"processes": processes,
            "other_review_roles": {name: empty_row() for name in sorted(OTHER_REVIEWER_ROLES)},
            "fix_requests": {"total": 0, "review": 0, "non_review": 0}}


def count_findings(results, fixes, start, passed_processes, passed_roles, passed_rounds):
    """Count the results and fix requests of one task; results and fixes are sorted by time.

    A result is counted in the rows of its process, of its round (code, other and final review only) and,
    for the other reviews, of its role. A row keeps the fix requests whose basis results all lie in the row
    (only_fix_requests); a basis result outside the row makes the row's results overlapping.
    """
    findings = empty_findings()

    def rows(result):
        """Return (row, group) pairs; a group names the basis results that lie inside the row."""
        process, round_name, role = result["process"], result["round"], result["role"]
        found = [(findings["processes"][process], ("process", process))]
        if round_name is not None:
            found.append((findings["processes"][process]["rounds"][round_name],
                          ("round", process, round_name)))
        if process == "other_review" and role in findings["other_review_roles"]:
            found.append((findings["other_review_roles"][role], ("role", role)))
        return found

    def groups(result):
        return {group for _, group in rows(result)}

    for name in passed_processes & set(FINDING_PROCESSES):
        findings["processes"][name]["passed"] = True
    for name in passed_roles:
        findings["other_review_roles"][name]["passed"] = True
    for name, round_name in passed_rounds:
        findings["processes"][name]["rounds"][round_name]["passed"] = True
    for result in results:
        for row, _ in rows(result):
            row["results"] += 1
            row[{"with": "with_findings", "without": "without_findings", "unreadable": "unreadable"}[
                result["state"]]] += 1
            if result["counts"] is None:
                row["counts_unread"] += 1
            else:
                row["blocking"] += sum(result["counts"].get(word, 0) for word in BLOCKING_WORDS)
                row["non_blocking"] += sum(result["counts"].get(word, 0) for word in NON_BLOCKING_WORDS)
    previous = Decimal(start)
    for fix in fixes:
        # Results between the previous fix request and this one; a design review returns to the designer.
        last = {}
        for result in results:
            if previous < result["time"] <= fix["time"] and result["process"] != "design_review":
                last[result["role"]] = result
        basis = [result for result in last.values() if result["state"] != "without"]
        previous = fix["time"]
        findings["fix_requests"]["total"] += 1
        if not basis:
            findings["fix_requests"]["non_review"] += 1
            continue
        findings["fix_requests"]["review"] += 1
        # Every row the basis touches: the results inside its group led to the fix; a result of another
        # group (another process, round or review role) makes them overlapping; with none, the fix is its own.
        touched = {}
        for result in basis:
            for row, group in rows(result):
                touched.setdefault(group, row)
        for group, row in touched.items():
            inside = [result for result in basis if group in groups(result)]
            row["led_to_fix"] += len(inside)
            if len(inside) < len(basis):
                row["overlapping"] += len(inside)
            else:
                row["only_fix_requests"] += 1
    return findings


def verify_total(allocation, elapsed):
    if sum(allocation.values()) != elapsed:
        raise ValueError("区分の合計が経過時間と一致しません")


def allocate(runs, start, end, cuts, wait_kind):
    """Split [start, end) at every run edge and extra cut, and give each interval to one category.

    An interval with no running run is a wait; wait_kind(left) names it.
    """
    edges = sorted({start, end, *(point for point in (*cuts, *(point for run in runs
                                                              for point in (run["start"], run["end"])))
                                  if start < point < end)})
    allocation = dict.fromkeys((*BREAKDOWN_CATEGORIES, *WAIT_KINDS), 0)
    for left, right in zip(edges, edges[1:]):
        active = {run["category"] for run in runs if run["start"] <= left and run["end"] >= right}
        owner = next((name for name in BREAKDOWN_CATEGORIES if name in active), None)
        allocation[owner or wait_kind(left)] += right - left
    return allocation


def busy_periods(runs):
    """Merge the runs into the stretches in which some run is always running."""
    periods = []
    for run in sorted(runs, key=lambda row: (row["start"], row["end"])):
        if periods and run["start"] <= periods[-1][1]:
            periods[-1][1] = max(periods[-1][1], run["end"])
        else:
            periods.append([run["start"], run["end"]])
    return periods


def wait_classifier(started_runs, transitions, comments, counted, request_wrote):
    """Return wait_kind(left): the kind of the wait that has no running run at `left`."""
    periods = busy_periods(counted)
    changes = sorted((whole_seconds(row["created_at"]), row["from_status"], row["to_status"])
                     for row in transitions)
    timed = [(whole_seconds(row["created_at"]), row) for row in comments]
    # A run's limit_stop is trusted only when the run failed.
    limit_ends = [whole_seconds(run["completed_at"]) for run in started_runs
                  if run["limit_stop"] is True and run["status"] == "failed" and run["completed_at"] is not None]

    def status_at(at):
        status = changes[0][1] if changes else None
        for time, _, to_status in changes:
            if time > at:
                break
            status = to_status
        return status

    def wait_kind(left):
        if any(whole_seconds(run["created_at"]) <= left < whole_seconds(run["started_at"])
               for run in started_runs):
            return "wait_startup"
        if status_at(left) == "in_review":
            return "wait_human"
        before = [period for period in periods if period[1] <= left]
        if before:
            # The reason for a wait is written just before the run stops: read the records after the
            # start of the busy stretch that ended the run, up to the start of the wait.
            begin, stop = before[-1]
            recent = [row for time, row in timed if begin < time <= stop]
            marks = {mark["kind"] for row in recent if request_wrote(row) for mark in row["marks"]}
            notice = any(row["type"] == "system" and row["author_type"] == "agent"
                         and any(mark["kind"] == "limit_notice" for mark in row["marks"]) for row in recent)
            if "usage_wait" in marks or notice or any(begin < end <= stop for end in limit_ends):
                return "wait_usage_limit"
            if "ci_wait" in marks:
                return "wait_ci"
            if any(row["author_type"] == "agent" and row["member_mentions"] for row in recent):
                return "wait_human"
        return "wait_other"

    return wait_kind


def breakdown(snapshot, raw, args):
    validate_breakdown_input(snapshot)
    agents = {row["id"]: row["name"] for row in snapshot["agents"]}
    roles = {key: role_name(name, args.project_key, args.member_key) for key, name in agents.items()}
    comments = {row["id"]: row for row in snapshot["comments"]}
    by_issue = {}
    for group in ("comments", "transitions", "runs"):
        for row in snapshot[group]:
            by_issue.setdefault((group, row["issue_id"]), []).append(row)

    def result_writer(comment):
        return comment["author_type"] == "agent" and roles.get(comment["author_id"]) in RESULT_ROLES

    def request_wrote(comment):
        """The leader wrote it, or `decide` did: a review role, qa or a principal wrote a request line
        (previous_round) in a comment that is not a result (no result_round)."""
        if comment["author_type"] == "agent" and roles.get(comment["author_id"]) == "orchestrator":
            return True
        kinds = {mark["kind"] for mark in comment["marks"]}
        return result_writer(comment) and "previous_round" in kinds and "result_round" not in kinds

    def trusted_marks(run):
        comment = comments.get(run["trigger_comment_id"])
        if comment is None or not request_wrote(comment):
            return {}
        return {mark["kind"]: mark["value"] for mark in comment["marks"]}

    excluded = {"not_done": 0, "no_implementer_run": 0, "unmeasurable": 0}
    skipped = dict.fromkeys(SKIPPED_MARKS, 0)
    tasks = []
    for issue in sorted(snapshot["issues"], key=lambda row: (timestamp(row["created_at"]), row["id"])):
        issue_runs = [run for run in by_issue.get(("runs", issue["id"]), []) if run["started_at"] is not None]
        if issue["status"] != "done":
            excluded["not_done"] += 1
            continue
        implementer = [run for run in issue_runs if roles.get(run["agent_id"]) in IMPLEMENTER_ROLES]
        if not implementer:
            excluded["no_implementer_run"] += 1
            continue
        done = [timestamp(row["created_at"]) for row in by_issue.get(("transitions", issue["id"]), [])
                if row["to_status"] == "done"]
        start = min(whole_seconds(run["started_at"]) for run in implementer)
        end = int(max(done).to_integral_value(rounding=ROUND_FLOOR)) if done else None
        if end is None or end <= start:
            excluded["unmeasurable"] += 1
            continue
        task_skipped = dict.fromkeys(SKIPPED_MARKS, 0)
        task_comments = by_issue.get(("comments", issue["id"]), [])
        for comment in task_comments:
            trusted = {"leader": request_wrote(comment), "result": result_writer(comment)}
            for mark in comment["marks"]:
                family = "leader" if mark["kind"] in LEADER_MARKS else "result"
                if mark["kind"] in task_skipped and not trusted[family]:
                    task_skipped[mark["kind"]] += 1
        for kind, count in task_skipped.items():
            skipped[kind] += count

        rounds, counted, started = {}, [], []
        for run in sorted(issue_runs, key=lambda row: (timestamp(row["started_at"]), row["id"])):
            marks = trusted_marks(run)
            category, key = run_category(roles.get(run["agent_id"], "その他"), marks.get("review_kind"))
            if key is not None:
                seen = rounds.setdefault(key, [])
                commit = marks.get("request_commit")
                if commit is None or commit not in seen:
                    seen.append(commit)
                    number = len(seen)
                else:
                    number = seen.index(commit) + 1
                category += "_first" if number == 1 else "_later"
            started.append({"agent_id": run["agent_id"], "started": timestamp(run["started_at"]),
                            "process": process_of(category), "round": round_of(category)})
            run_start = max(whole_seconds(run["started_at"]), start)
            run_end = min(whole_seconds(run["completed_at"]) if run["completed_at"] is not None else end, end)
            counted.append({"category": category, "start": run_start, "end": run_end,
                            "role": roles.get(run["agent_id"], "その他")})
        counted = [run for run in counted if run["end"] > run["start"]]
        task_transitions = by_issue.get(("transitions", issue["id"]), [])
        cuts = [whole_seconds(row["created_at"]) for row in (*issue_runs, *task_transitions)]
        wait_kind = wait_classifier(issue_runs, task_transitions, by_issue.get(("comments", issue["id"]), []),
                                    counted, request_wrote)
        allocation = allocate(counted, start, end, cuts, wait_kind)
        verify_total(allocation, end - start)
        execution = dict.fromkeys(BREAKDOWN_CATEGORIES, 0)
        unknown = {}
        for run in counted:
            execution[run["category"]] += run["end"] - run["start"]
            if run["category"] == "unknown":
                row = unknown.setdefault(run["role"], {"seconds": 0, "runs": 0})
                row["seconds"] += run["end"] - run["start"]
                row["runs"] += 1
        results, fixes = [], []
        for comment in sorted(task_comments, key=lambda row: (timestamp(row["created_at"]), row["id"])):
            if not start <= whole_seconds(comment["created_at"]) <= end:
                continue
            marks = {mark["kind"]: mark["value"] for mark in comment["marks"]}
            at = timestamp(comment["created_at"])
            if request_wrote(comment) and "fix_request" in marks:
                fixes.append({"time": at})
            if result_writer(comment) and "result_commit" in marks:
                # The process and round of a result are those of the author's last run that started by then.
                before = [row for row in started if row["agent_id"] == comment["author_id"]
                          and row["started"] <= at]
                results.append({"time": at, "role": roles[comment["author_id"]],
                                "process": before[-1]["process"] if before else "unknown",
                                "round": before[-1]["round"] if before else None,
                                "state": result_state(marks), "counts": marks.get("finding_counts")})
        findings = count_findings(
            results, fixes, start, {process_of(run["category"]) for run in counted},
            {run["role"] for run in counted if run["category"].startswith("other_review")},
            {(process_of(run["category"]), round_of(run["category"])) for run in counted
             if round_of(run["category"]) is not None})
        # The seconds of each implementer run are floored one by one, then added.
        implementation_seconds = sum(
            int(max(Decimal(0), min(timestamp(run["completed_at"]) if run["completed_at"] is not None
                                    else Decimal(end), Decimal(end)) - timestamp(run["started_at"])))
            for run in implementer)
        tasks.append({"id": issue["id"], "identifier": issue["identifier"],
                      "created_seconds": whole_seconds(issue["created_at"]),
                      "window_start": start, "window_end": end, "elapsed_seconds": end - start,
                      "seconds_before_implementation": start - whole_seconds(issue["created_at"]),
                      "implementation_run_seconds": implementation_seconds,
                      "kinds": {"docs_only": issue["branch_type"] == "docs",
                                "small_implementation": implementation_seconds <= SMALL_IMPLEMENTATION_SECONDS,
                                "important": issue["important"] is True},
                      "allocation_seconds": allocation, "execution_seconds": execution,
                      "unknown_roles": unknown, "findings": findings, "skipped_marks": task_skipped})
    return {"schema_version": 1, "input": {"snapshot_sha256": hashlib.sha256(raw).hexdigest()},
            "cutoff": args.cutoff, "excluded": excluded, "skipped_marks": skipped, "tasks": tasks}


def share(seconds, total):
    return one_decimal(seconds * 100, total)


def findings_row(rows, process=None):
    """Add up one process's (or role's) findings over the tasks."""
    total = {field: sum(row[field] for row in rows) for field in FINDING_FIELDS}
    result = {"task_count": sum(1 for row in rows if row["passed"]), "results": total["results"],
              "with_findings": total["with_findings"]}
    if process == "design_review":
        # A design review's findings return to the designer with no fix request: only these are shown.
        return result
    result.update(
        without_findings=total["without_findings"], unreadable=total["unreadable"],
        led_to_fix=total["led_to_fix"], overlapping=total["overlapping"],
        only_fix_requests=total["only_fix_requests"],
        finding_counts={"blocking": total["blocking"], "non_blocking": total["non_blocking"],
                        "unreadable_results": total["counts_unread"]})
    return result


def findings_process(rows, process):
    """One process's row; a process with rounds also carries the row of each round."""
    result = findings_row(rows, process)
    if process in ROUNDED_PROCESSES:
        result["rounds"] = {round_name: findings_row([row["rounds"][round_name] for row in rows], process)
                            for round_name in ROUNDS}
    return result


def findings_summary(tasks):
    findings = [task["findings"] for task in tasks]
    return {
        "processes": {name: findings_process([row["processes"][name] for row in findings], name)
                      for name in FINDING_PROCESSES},
        "other_review_roles": {name: findings_row([row["other_review_roles"][name] for row in findings])
                               for name in sorted(OTHER_REVIEWER_ROLES)},
        "fix_requests": {name: sum(row["fix_requests"][name] for row in findings)
                         for name in ("total", "review", "non_review")}}


def group_summary(tasks, excluded=None):
    count = len(tasks)
    elapsed = sum(task["elapsed_seconds"] for task in tasks)
    rows = {}
    for name in (*BREAKDOWN_CATEGORIES, "wait_human", "wait_usage_limit", "wait_ci", "wait_other"):
        seconds = sum(task["allocation_seconds"][name] for task in tasks)
        if name in BREAKDOWN_CATEGORIES:
            passed = sum(1 for task in tasks if task["execution_seconds"][name] > 0)
        else:
            passed = sum(1 for task in tasks if task["allocation_seconds"][name] > 0)
        row = {"seconds": seconds, "share_percent": share(seconds, elapsed),
               "per_task_seconds": one_decimal(seconds, count), "task_count": passed}
        if name == "wait_other":
            # A startup wait is kept inside "other" and shown as its part.
            startup = sum(task["allocation_seconds"]["wait_startup"] for task in tasks)
            row = {"seconds": seconds + startup, "share_percent": share(seconds + startup, elapsed),
                   "per_task_seconds": one_decimal(seconds + startup, count),
                   "task_count": sum(1 for task in tasks if task["allocation_seconds"]["wait_other"]
                                     + task["allocation_seconds"]["wait_startup"] > 0),
                   "startup_seconds": startup}
        rows[name] = row
    human = rows["wait_human"]["seconds"]
    unknown = rows["unknown"]["seconds"]
    sides = {"agent": elapsed - human - unknown, "human_wait": human, "unknown": unknown}
    before = sum(task["seconds_before_implementation"] for task in tasks)
    unknown_roles = {}
    for task in tasks:
        for role, row in task["unknown_roles"].items():
            total = unknown_roles.setdefault(role, {"seconds": 0, "runs": 0})
            total["seconds"] += row["seconds"]
            total["runs"] += row["runs"]
    result = {
        "task_count": count,
        "elapsed": {"total_seconds": elapsed, "per_task_seconds": one_decimal(elapsed, count)},
        "allocation": rows,
        "sides": {name: {"seconds": seconds, "share_percent": share(seconds, elapsed)}
                  for name, seconds in sides.items()},
        "execution_seconds": {name: sum(task["execution_seconds"][name] for task in tasks)
                              for name in BREAKDOWN_CATEGORIES},
        "before_implementation": {"total_seconds": before, "per_task_seconds": one_decimal(before, count)},
        "unknown_roles": unknown_roles,
        "findings": findings_summary(tasks),
        "skipped_marks": {name: sum(task["skipped_marks"][name] for task in tasks) for name in SKIPPED_MARKS},
    }
    if excluded is not None:
        result["excluded"] = excluded
    return result


def breakdown_summary(result, args):
    """The 集計: every group of tasks, with no row per task."""
    tasks = result["tasks"]
    cutoff = whole_seconds(args.cutoff)
    groups = {
        "all": group_summary(tasks, result["excluded"]),
        "before_cutoff": group_summary([task for task in tasks if task["created_seconds"] < cutoff]),
        "after_cutoff": group_summary([task for task in tasks if task["created_seconds"] >= cutoff]),
        **{name: group_summary([task for task in tasks if task["kinds"][name]])
           for name in ("docs_only", "small_implementation", "important")},
    }
    return {"schema_version": 1,
            "input": {"snapshot_sha256": result["input"]["snapshot_sha256"], "cutoff": args.cutoff,
                      "project_key": args.project_key, "member_key": args.member_key},
            "groups": groups}


GROUP_LABELS = {"all": "全件", "before_cutoff": "区切りの前", "after_cutoff": "区切りの後",
                "docs_only": "文書だけ", "small_implementation": "小さい実装", "important": "重要"}
CATEGORY_LABELS = {
    "implementation": "実装", "fix": "修正", "code_review_first": "コードレビュー 1 回目",
    "code_review_later": "コードレビュー 2 回目以降", "other_review_first": "そのほかのレビュー 1 回目",
    "other_review_later": "そのほかのレビュー 2 回目以降", "e2e": "E2E",
    "final_review_first": "最終レビュー 1 回目", "final_review_later": "最終レビュー 2 回目以降",
    "design_review": "設計の見直し", "design_requirements": "設計と要件の直し",
    "orchestrator": "リーダーの振り分け", "unknown": "不明",
    "wait_human": "待ち: 人間の返事", "wait_usage_limit": "待ち: 使用率の上限", "wait_ci": "待ち: CI",
    "wait_other": "待ち: そのほか（起動を含む）"}
SIDE_LABELS = {"agent": "エージェント側", "human_wait": "人間の返事待ち", "unknown": "不明"}
PROCESS_LABELS = {"code_review": "コードレビュー", "other_review": "そのほかのレビュー", "e2e": "E2E",
                  "final_review": "最終レビュー", "design_review": "設計の見直し",
                  "unknown": "工程を読めない"}
FINDING_LIMITS = (
    "回の行を足すと工程の合計になるのは、足せる列だけである。足せない列は、「通ったタスク」（両方の回を通ったタスクを"
    "重複を除いて数える）、「うち重なる」、「その工程だけの修正の依頼」で、回の行を足しても工程の値にならない。",
    "重なりは、同じ修正の依頼にまとめられたかどうかで数える。指摘の中身が同じかどうかは読めないので、"
    "この数は中身の重なりの上限になる。",
    "その工程だけの修正の依頼は、その工程がなければ出なかった修正の数の下限になる。",
    "指摘の件数は、結果のコメントに決まった行がなく、読めない結果がある。件数を読めなかった結果は 0 件として足さない。"
    "古いタスクのセキュリティのレビューは、ほぼ読めない。",
    "設計の見直しの指摘は、修正の依頼を使わずに設計の役へ戻るので、結果の数と指摘のある結果の数だけを出す。")


def hours(seconds):
    return one_decimal(seconds, 3600)


def findings_markdown(findings):
    headers = ("工程", "通ったタスク（重複を除く）", "結果", "指摘のある", "指摘のない", "指摘を読めない", "修正につながった",
               "うち重なる", "その工程だけの修正の依頼", "必須・高・中の件数", "推奨・低の件数", "件数を読めなかった結果")

    def line(label, row):
        counts = row.get("finding_counts")
        return (label, row["task_count"], row["results"], row["with_findings"],
                row.get("without_findings", "-"), row.get("unreadable", "-"), row.get("led_to_fix", "-"),
                row.get("overlapping", "-"), row.get("only_fix_requests", "-"),
                counts["blocking"] if counts else "-", counts["non_blocking"] if counts else "-",
                counts["unreadable_results"] if counts else "-")

    def tables(rows):
        rows = list(rows)
        count_columns = (0, 2, 11, 9, 10)
        return (table(headers[:9], (row[:9] for row in rows))
                + table(tuple(headers[index] for index in count_columns),
                        (tuple(row[index] for index in count_columns) for row in rows)))

    # Plain lines, not headings: the same names repeat in every group.
    lines = ["工程ごとの指摘:", ""]
    # A round's row follows its process's row; the process's row is the total of its rounds.
    lines += tables(
        entry for name, row in findings["processes"].items()
        for entry in (line(PROCESS_LABELS[name], row),
                      *(line(CATEGORY_LABELS[f"{name}_{round_name}"], round_row)
                        for round_name, round_row in row.get("rounds", {}).items())))
    lines += ["そのほかのレビューの役ごとの指摘:", ""]
    lines += tables(line(name, row) for name, row in findings["other_review_roles"].items())
    fixes = findings["fix_requests"]
    lines += table(("修正の依頼", "件数"), (
        ("合計", fixes["total"]), ("根拠の結果がある", fixes["review"]),
        ("レビュー以外（根拠の結果がない）", fixes["non_review"])))
    lines += ["数え方の限り:", "", *(f"- {text}" for text in FINDING_LIMITS), ""]
    return lines


def breakdown_markdown(summary):
    lines = ["# 時間の内訳", "", "## 入力", ""]
    lines += table(("入力", "値"), ((key, value) for key, value in summary["input"].items()))
    lines += ["秒は整数で数え、時間と割合は小数第 1 位までで表示する。", ""]
    for name, group in summary["groups"].items():
        lines += [f"## {GROUP_LABELS[name]}", "", f"対象のタスク: {group['task_count']} 件", ""]
        if "excluded" in group:
            excluded = group["excluded"]
            lines += table(("対象から外した", "件数"), (
                ("実装の役の実行がない", excluded["no_implementer_run"]),
                ("done でない", excluded["not_done"]), ("測れなかった", excluded["unmeasurable"])))
        elapsed = group["elapsed"]
        lines += table(("項目", "秒", "時間"), (
            ("経過時間の合計", elapsed["total_seconds"], hours(elapsed["total_seconds"])),
            ("経過時間の 1 タスクあたり", elapsed["per_task_seconds"],
             None if elapsed["per_task_seconds"] is None else hours(Decimal(elapsed["per_task_seconds"]))),
            ("起票から実装の開始までの合計", group["before_implementation"]["total_seconds"],
             hours(group["before_implementation"]["total_seconds"])),
            ("起票から実装の開始までの 1 タスクあたり", group["before_implementation"]["per_task_seconds"],
             None if group["before_implementation"]["per_task_seconds"] is None
             else hours(Decimal(group["before_implementation"]["per_task_seconds"])))))
        lines += table(("区分", "秒", "時間", "割合 %", "1 タスクあたり（秒）", "通ったタスク"), (
            (CATEGORY_LABELS[key] + (f"（うち起動 {row['startup_seconds']} 秒）" if "startup_seconds" in row else ""),
             row["seconds"], hours(row["seconds"]), row["share_percent"], row["per_task_seconds"],
             row["task_count"]) for key, row in group["allocation"].items()))
        lines += table(("側", "秒", "時間", "割合 %"), (
            (SIDE_LABELS[key], row["seconds"], hours(row["seconds"]), row["share_percent"])
            for key, row in group["sides"].items()))
        lines += table(("区分", "実行時間の合計（並行を重ねる、秒）"), (
            (CATEGORY_LABELS[key], seconds) for key, seconds in group["execution_seconds"].items()))
        lines += findings_markdown(group["findings"])
        lines += table(("不明の役", "秒", "実行"), (
            (role, row["seconds"], row["runs"]) for role, row in sorted(group["unknown_roles"].items())))
        lines += table(("飛ばしたマーク", "件数"), sorted(group["skipped_marks"].items()))
    return "\n".join(lines)


def anonymize(snapshot, project_key, member_key):
    """Replace identities without changing the ordering used by count and breakdown."""
    validate_snapshot(snapshot)
    snapshot = json.loads(json.dumps(snapshot))
    originals = set()

    def aliases(values, prefix, minimum=4):
        values = sorted(set(values))
        if any(not isinstance(value, str) or not value for value in values):
            raise ValueError("匿名にする ID と名前は空でない文字列にしてください")
        originals.update(values)
        width = max(minimum, len(str(len(values))))
        return {value: f"{prefix}-{index:0{width}d}" for index, value in enumerate(values, 1)}

    comments, runs = snapshot["comments"], snapshot["runs"]
    identities = {
        "task": aliases((row["id"] for row in snapshot["issues"]), "task"),
        "comment": aliases([row["id"] for row in comments]
                           + [row["trigger_comment_id"] for row in runs if row.get("trigger_comment_id")],
                           "comment-anonymous"),
        "run": aliases((row["id"] for row in runs), "run-anonymous"),
        "agent": aliases([row["id"] for row in snapshot["agents"]]
                         + [row["author_id"] for row in comments if row["author_type"] == "agent"], "agent"),
        "member": aliases([row["author_id"] for row in comments if row["author_type"] == "member"]
                          + [value for row in comments for value in row["member_mentions"]], "member"),
        "project": aliases([snapshot["project_id"]], "project"),
        "commit": aliases([mark["value"] for row in comments for mark in row.get("marks", [])
                           if mark["kind"] in ("request_commit", "result_commit")], "commit"),
    }
    for kind in sorted({row["author_type"] for row in comments} - {"agent", "member"}):
        identities["author_" + kind] = aliases(
            (row["author_id"] for row in comments if row["author_type"] == kind), "author-" + kind)
    identities["identifier"] = {
        row["identifier"]: f"TASK-{int(identities['task'][row['id']].split('-')[1])}"
        for row in snapshot["issues"]}
    originals.update(identities["identifier"])
    names = {}
    unknown = sorted(row["id"] for row in snapshot["agents"]
                     if role_name(row["name"], project_key, member_key) == "その他")
    width = max(3, len(str(len(unknown))))
    unknown_names = {key: f"other-agent-{index:0{width}d}" for index, key in enumerate(unknown, 1)}
    for row in snapshot["agents"]:
        original = row["name"]
        originals.add(original)
        role = role_name(original, project_key, member_key)
        row["name"] = (unknown_names[row["id"]] if role == "その他"
                       else f"example-{role}-anonymous")
        names[original] = row["name"]
        row["id"] = identities["agent"][row["id"]]
    identities["agent_name"] = names
    snapshot["project_id"] = identities["project"][snapshot["project_id"]]
    for row in snapshot["issues"]:
        row["id"] = identities["task"][row["id"]]
        row["identifier"] = identities["identifier"][row["identifier"]]
    for row in comments:
        row["id"] = identities["comment"][row["id"]]
        kind = row["author_type"]
        row["author_id"] = identities[kind if kind in ("agent", "member") else "author_" + kind][row["author_id"]]
        row["member_mentions"] = [identities["member"][value] for value in row["member_mentions"]]
        for mark in row.get("marks", []):
            if mark["kind"] in ("request_commit", "result_commit"):
                mark["value"] = identities["commit"][mark["value"]]
    for row in runs:
        row["id"] = identities["run"][row["id"]]
        row["agent_id"] = identities["agent"][row["agent_id"]]
        if row.get("trigger_comment_id") is not None:
            row["trigger_comment_id"] = identities["comment"][row["trigger_comment_id"]]
    for group in ("comments", "runs", "transitions"):
        for row in snapshot[group]:
            row["issue_id"] = identities["task"][row["issue_id"]]
    # Inspect unknown fields and keys too, before JSON escaping can hide a match.
    # Diagnostics must not expose matched values.
    def strings(value):
        if isinstance(value, dict):
            for key, item in value.items():
                yield key
                yield from strings(item)
        elif isinstance(value, list):
            for item in value:
                yield from strings(item)
        elif isinstance(value, str):
            yield value

    # An original is inside a string exactly when a slice of the same length equals it, so look
    # slices up in sets grouped by length instead of testing every string against every original.
    by_length = {}
    for original in originals:
        by_length.setdefault(len(original), set()).add(original)
    if any(value[start:start + length] in group
           for value in set(strings(snapshot)) for length, group in by_length.items()
           for start in range(len(value) - length + 1)):
        raise ValueError("匿名のコピーに元の名前か識別子が残っています。コピーは書きません")
    validate_snapshot(snapshot)
    return snapshot, identities


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    collector = subparsers.add_parser("collect", help="Multica の記録をスナップショットに残す")
    collector.add_argument("--project", required=True)
    collector.add_argument("--output", type=Path, required=True)
    collector.add_argument("--traces", type=Path, help="コメントの跡の定義 JSON")
    collector.add_argument("--marks", action="store_true",
                           help="時間の内訳に使うマークと欄を足して残す（本文・error の文・ブランチの名前は残さない）")
    counter = subparsers.add_parser("count", help="保存したスナップショットから数える")
    counter.add_argument("snapshot", type=Path)
    for flag in ("cutoff", "truncate", "project-key", "member-key"):
        counter.add_argument("--" + flag, required=True)
    counter.add_argument("--human", action="append", required=True, help="複数の人間はこの引数を繰り返す")
    counter.add_argument("--from", dest="from_time")
    counter.add_argument("--limit", type=int, help="--from 以後の先頭の N 件だけを数える")
    counter.add_argument("--settled", action="store_true",
                         help="測る時刻の状態が done・cancelled・in_review でなければ止まる")
    counter.add_argument("--compare", type=Path)
    counter.add_argument("--output", type=Path, required=True, help="結果のディレクトリ")
    breaker = subparsers.add_parser("breakdown", help="保存したスナップショットから時間の内訳を測る")
    breaker.add_argument("snapshot", type=Path)
    for flag in ("cutoff", "project-key", "member-key"):
        breaker.add_argument("--" + flag, required=True)
    breaker.add_argument("--output", type=Path, required=True, help="結果のディレクトリ")
    anonymizer = subparsers.add_parser("anonymize", help="添付用に名前と識別子を置き換える")
    anonymizer.add_argument("snapshot", type=Path)
    anonymizer.add_argument("--project-key", required=True)
    anonymizer.add_argument("--member-key", required=True)
    anonymizer.add_argument("--output", type=Path, required=True, help="匿名のスナップショット")
    anonymizer.add_argument("--map", dest="mapping", type=Path, required=True, help="添付しない対応表")
    reviewer = subparsers.add_parser("traces", help="保存した跡の件数と手順の判定を一覧にする")
    reviewer.add_argument("snapshot", type=Path)
    reviewer.add_argument("--traces", type=Path, required=True)
    reviewer.add_argument("--project-key", required=True)
    reviewer.add_argument("--member-key", required=True)
    reviewer.add_argument("--revision", required=True, help="見直し元のコミット")
    reviewer.add_argument("--repository", type=Path, default=Path("."), help="原本のリポジトリ（既定は現在の場所）")
    reviewer.add_argument("--output", type=Path, required=True, help="結果のディレクトリ")
    args = parser.parse_args()
    try:
        if args.command == "collect":
            write_snapshot(args.output, collect(args.project, args.traces, args.marks))
            return
        raw = args.snapshot.read_bytes()
        if args.command == "anonymize":
            if len({path.resolve() for path in (args.snapshot, args.output, args.mapping)}) != 3:
                raise ValueError("入力、コピー、対応表は別のファイルにしてください")
            result, identities = anonymize(json.loads(raw), args.project_key, args.member_key)
            write_snapshot(args.mapping, identities)
            write_snapshot(args.output, result)
            return
        if args.command == "traces":
            definitions, digest = read_trace_definitions(args.traces)
            result = traces(json.loads(raw), raw, definitions, digest, args)
            rendered = traces_markdown(result)
            args.output.mkdir(parents=True, exist_ok=True)
            write_snapshot(args.output / "traces.json", result)
            (args.output / "traces.md").write_text(rendered, encoding="utf-8")
            return
        if args.command == "breakdown":
            result = breakdown(json.loads(raw), raw, args)
            args.output.mkdir(parents=True, exist_ok=True)
            summary = breakdown_summary(result, args)
            write_snapshot(args.output / "breakdown-tasks.json", result)
            write_snapshot(args.output / "breakdown.json", summary)
            (args.output / "breakdown.md").write_text(breakdown_markdown(summary), encoding="utf-8")
            return
        plan = json.loads(args.compare.read_bytes()) if args.compare else None
        result = count(json.loads(raw), raw, args, plan)
        rendered = markdown(result)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "metrics.json").write_text(
            json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        (args.output / "metrics.md").write_text(rendered, encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError, ArithmeticError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"エラー: 数えられません: {error}\n")


if __name__ == "__main__":
    main()
