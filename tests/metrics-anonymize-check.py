"""Exercise anonymize through the CLI using only synthetic snapshots."""

import copy
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT, WORK = map(Path, sys.argv[1:])
sys.path.insert(0, str(ROOT / "scripts"))
import metrics  # noqa: E402

source = ROOT / "tests/fixtures/metrics/breakdown/snapshot.json"
original_bytes = source.read_bytes()
snapshot = json.loads(original_bytes)


def cli(*args, succeeds=True):
    result = subprocess.run([sys.executable, str(ROOT / "scripts/metrics.py"), *map(str, args)],
                            capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stderr
    return result


def anonymize(path, output, mapping, succeeds=True):
    return cli("anonymize", path, "--project-key", "demo", "--member-key", "x",
               "--output", output, "--map", mapping, succeeds=succeeds)


output, mapping = WORK / "anonymous.json", WORK / "mapping.json"
anonymize(source, output, mapping)
anonymize(source, WORK / "repeat.json", WORK / "repeat-map.json")
assert output.read_bytes() == (WORK / "repeat.json").read_bytes()
assert mapping.read_bytes() == (WORK / "repeat-map.json").read_bytes()
assert source.read_bytes() == original_bytes
anonymous = json.loads(output.read_bytes())
identities = json.loads(mapping.read_bytes())
substitutions = {key: value for group in identities.values() for key, value in group.items()}


def replaced(value):
    if isinstance(value, dict):
        return {substitutions.get(key, key): replaced(item) for key, item in value.items()}
    if isinstance(value, list):
        return [replaced(item) for item in value]
    return substitutions.get(value, value) if isinstance(value, str) else value


assert replaced(snapshot) == anonymous
assert identities["task"][sorted(identities["task"])[0]] == "task-0001"
assert identities["identifier"][next(row["identifier"] for row in snapshot["issues"]
                                       if row["id"] == sorted(identities["task"])[0])] == "TASK-1"
assert "example-code-reviewer-anonymous" in identities["agent_name"].values()
assert "other-agent-001" in identities["agent_name"].values()
for group in ("task", "comment", "run", "agent", "member", "project", "commit"):
    assert [identities[group][key] for key in sorted(identities[group])] == sorted(identities[group].values())
for row in anonymous["runs"]:
    assert row["trigger_comment_id"] is None or row["trigger_comment_id"] in identities["comment"].values()
print("PASS metrics-anonymize: 種類ごとの ID の順と参照を保ち、名前とコミットを置き換え、2 回のコピーと対応表が一致する")

for label, path, project, member in (("original", source, "demo", "x"),
                                     ("anonymous", output, "example", "anonymous")):
    cli("breakdown", path, "--cutoff", "2026-01-01T00:00:00Z", "--project-key", project,
        "--member-key", member, "--output", WORK / label)
    humans = [value for key in sorted(identities["member"])
              for value in ("--human", identities["member"][key] if label == "anonymous" else key)]
    cli("count", path, "--cutoff", "2026-01-02T00:00:00Z", "--truncate", "2026-01-02T00:00:00Z",
        "--project-key", project, "--member-key", member, *humans, "--output", WORK / label)

for name in ("breakdown-tasks.json", "breakdown.json", "metrics.json"):
    before = json.loads((WORK / "original" / name).read_bytes())
    after = json.loads((WORK / "anonymous" / name).read_bytes())
    for result in (before, after):
        result["input"].pop("snapshot_sha256")
        result["input"].pop("project_key", None)
        result["input"].pop("member_key", None)
    assert replaced(before) == after, name
for name in ("breakdown.md", "metrics.md"):
    # Rendering is also checked after normalizing the documented input differences.
    before = (WORK / "original" / name).read_text()
    for key, value in sorted(substitutions.items(), key=lambda pair: -len(pair[0])):
        before = before.replace(key, value)
    lines = lambda text: [line for line in text.splitlines()
                          if not any(key in line for key in ("snapshot_sha256", "project_key", "member_key"))]
    assert lines(before) == lines((WORK / "anonymous" / name).read_text()), name
for path in [output, *(WORK / "anonymous").iterdir()]:
    text = path.read_text()
    assert not any(key in text for key in substitutions), path.name
print("PASS metrics-anonymize: コピーの breakdown と count は入力のハッシュと別名を除いて同じで、コピーと結果に元の名前と識別子が残らない")

# Tied timestamps select tasks by ID, including when count limits the selection.
tied = copy.deepcopy(snapshot)
for row in tied["issues"]:
    row["created_at"] = "2026-01-01T00:00:00Z"
tied_path = WORK / "tied.json"
metrics.write_snapshot(tied_path, tied)
anonymize(tied_path, WORK / "tied-anonymous.json", WORK / "tied-map.json")
for label, path, project, member, human in (
        ("tied-before", tied_path, "demo", "x", next(iter(identities["member"]))),
        ("tied-after", WORK / "tied-anonymous.json", "example", "anonymous",
         identities["member"][next(iter(identities["member"]))])):
    cli("count", path, "--from", "2026-01-01T00:00:00Z", "--limit", "10",
        "--cutoff", "2026-01-02T00:00:00Z", "--truncate", "2026-01-02T00:00:00Z",
        "--project-key", project, "--member-key", member, "--human", human, "--output", WORK / label)
before = json.loads((WORK / "tied-before/metrics.json").read_bytes())
after = json.loads((WORK / "tied-after/metrics.json").read_bytes())
assert replaced(before["issues"]) == after["issues"]
assert replaced(before["totals"]) == after["totals"]
print("PASS metrics-anonymize: 同じ時刻のタスクを ID で選ぶ順序が 10 件以上でも変わらない")

for label, residual in (("name", snapshot["agents"][0]["name"]),
                        ("identifier", snapshot["issues"][0]["identifier"]),
                        ("id", snapshot["comments"][0]["id"])):
    dirty = copy.deepcopy(snapshot)
    dirty["unexpected"] = {"text": "残り: " + residual}
    dirty_path = WORK / f"dirty-{label}.json"
    metrics.write_snapshot(dirty_path, dirty)
    stopped, stopped_map = WORK / f"stopped-{label}.json", WORK / f"stopped-map-{label}.json"
    error = anonymize(dirty_path, stopped, stopped_map, succeeds=False)
    assert "残っています" in error.stderr and residual not in error.stderr
    assert not stopped.exists() and not stopped_map.exists()
    stopped.write_text("previous copy")
    stopped_map.write_text("previous map")
    anonymize(dirty_path, stopped, stopped_map, succeeds=False)
    assert stopped.read_text() == "previous copy" and stopped_map.read_text() == "previous map"
print("PASS metrics-anonymize: 元の名前・識別子・ID が未知の欄に残れば、コピーと対応表を書かず既存の出力も守る")

def stops_without_writing(dirty, label, residual):
    dirty_path = WORK / f"dirty-{label}.json"
    metrics.write_snapshot(dirty_path, dirty)
    stopped, stopped_map = WORK / f"stopped-{label}.json", WORK / f"stopped-map-{label}.json"
    error = anonymize(dirty_path, stopped, stopped_map, succeeds=False)
    assert "残っています" in error.stderr and residual not in error.stderr
    assert not stopped.exists() and not stopped_map.exists()
    stopped.write_text("previous copy")
    stopped_map.write_text("previous map")
    anonymize(dirty_path, stopped, stopped_map, succeeds=False)
    assert stopped.read_text() == "previous copy" and stopped_map.read_text() == "previous map"


residuals = (("name", snapshot["agents"][0]["name"]),
             ("identifier", snapshot["issues"][0]["identifier"]),
             ("id", snapshot["comments"][0]["id"]))
for label, residual in residuals:
    dirty = copy.deepcopy(snapshot)
    dirty["unexpected"] = {"キー " + residual: 1}
    stops_without_writing(dirty, "key-" + label, residual)
print("PASS metrics-anonymize: 元の名前・識別子・ID が未知の欄のキーに残れば止まる")

residual = snapshot["comments"][0]["id"]
filler = "あ" * 1200
for label, text in (("head", residual + filler), ("middle", filler + residual + filler),
                    ("tail", filler + residual)):
    dirty = copy.deepcopy(snapshot)
    dirty["unexpected"] = {"text": text}
    stops_without_writing(dirty, "long-" + label, residual)
print("PASS metrics-anonymize: 元の値が長い文字列の先頭・途中・末尾のどこにあっても止まる")

nested = copy.deepcopy(snapshot)
for index, name in enumerate(("abcd", "bc")):
    agent = copy.deepcopy(nested["agents"][0])
    agent.update(id=f"nested-agent-{index}", name=name)
    nested["agents"].append(agent)
nested["unexpected"] = {"text": "xabce"}
stops_without_writing(nested, "nested", "bc")
del nested["unexpected"]
nested_path = WORK / "nested-clean.json"
metrics.write_snapshot(nested_path, nested)
anonymize(nested_path, WORK / "nested-clean-anonymous.json", WORK / "nested-clean-map.json")
print("PASS metrics-anonymize: ある元の値の途中まで一致したあとに別の元の値が現れる文字列でも止まり、外すと止まらない")


anonymize(source, source, mapping, succeeds=False)
anonymize(source, output, output, succeeds=False)
assert source.read_bytes() == original_bytes
print("PASS metrics-anonymize: 入力・コピー・対応表に同じファイルを指定すると止まる")
