"""Check the 時間の内訳 of the synthetic snapshot against hand-computed seconds."""

from decimal import Decimal
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT, OUTPUT = map(Path, sys.argv[1:])
sys.path.insert(0, str(ROOT / "scripts"))
import metrics  # noqa: E402

result = json.loads((OUTPUT / "breakdown-tasks.json").read_text())
summary = json.loads((OUTPUT / "breakdown.json").read_text())
groups = summary["groups"]
tasks = {task["identifier"]: task for task in result["tasks"]}


def nonzero(values):
    return {name: seconds for name, seconds in values.items() if seconds}


# 2-1: every task's categories, wait included, add up to its elapsed time.
for task in result["tasks"]:
    assert sum(task["allocation_seconds"].values()) == task["elapsed_seconds"], task["identifier"]
    assert task["elapsed_seconds"] == task["window_end"] - task["window_start"]
assert sum(tasks["DEMO-A"]["allocation_seconds"].values()) == 3400
try:
    metrics.verify_total({"implementation": 1, "wait_other": 1}, 3)
except ValueError:
    pass
else:
    raise AssertionError("合計が 1 秒違っても止まらない")
metrics.verify_total({"implementation": 1, "wait_other": 1}, 2)
print("PASS metrics-breakdown: すべてのタスクで区分の合計（不明・待ちを含む）が経過時間と一致し、1 秒違えば止まる")

# 3-1: overlapping runs are given to one category; execution totals count the overlap.
a = tasks["DEMO-A"]
assert nonzero(a["allocation_seconds"]) == {
    "implementation": 1400, "orchestrator": 300, "code_review_first": 500,
    "other_review_later": 200, "fix": 200, "code_review_later": 200, "wait_other": 600}
assert nonzero(a["execution_seconds"]) == {
    "implementation": 1400, "orchestrator": 500, "code_review_first": 500,
    "other_review_first": 200, "other_review_later": 300, "fix": 200, "code_review_later": 200}
assert sum(a["execution_seconds"].values()) - (3400 - a["allocation_seconds"]["wait_other"]) == 500
assert "execution_seconds" in a and "execution_seconds" not in a["allocation_seconds"]
print("PASS metrics-breakdown: 重なった実行の時間は 1 つの区分にだけ入り、実行時間の合計は別の欄に重ねて出る")

# 6-1: the principal's kinds are separate; rounds split at the leader's request commit.
b = tasks["DEMO-B"]
assert nonzero(b["allocation_seconds"]) == {
    "implementation": 400, "design_review": 100, "final_review_first": 200, "unknown": 250,
    "design_requirements": 100, "e2e": 100, "final_review_later": 100, "wait_other": 50}
# The same commit asked twice is one round; a request nobody trusted starts a new round;
# the final review counts both principals together.
assert a["execution_seconds"]["code_review_first"] == 500
assert a["execution_seconds"]["other_review_first"] == 200
assert a["execution_seconds"]["other_review_later"] == 300
assert b["execution_seconds"]["final_review_later"] == 100
print("PASS metrics-breakdown: 設計の見直し・最終レビュー・不明が分かれ、1 回目と 2 回目以降が依頼のコミットで分かれる")

# 9-1: tasks with no implementer run, not done, or unmeasurable are not targets.
assert sorted(tasks) == [
    "DEMO-A", "DEMO-B", "DEMO-C", "DEMO-H", "DEMO-I", "DEMO-J", "DEMO-K", "DEMO-L", "DEMO-M", "DEMO-N", "DEMO-O",
    "DEMO-P", "DEMO-Q", "DEMO-R", "DEMO-S"]
assert result["excluded"] == {"no_implementer_run": 1, "not_done": 1, "unmeasurable": 2}
c = tasks["DEMO-C"]
assert c["elapsed_seconds"] == 800  # the last of two done moves ends the window
assert nonzero(c["allocation_seconds"]) == {"implementation": 500, "code_review_first": 300}
print("PASS metrics-breakdown: 実装の役の実行がないタスク・done でないタスク・測れないタスクは対象に入らない")

# Marks written by anyone but the leader or `decide` are not read and are counted.
assert result["skipped_marks"] == {
    "ci_wait": 6, "finding_counts": 2, "fix_request": 7, "request_commit": 4, "result_commit": 2,
    "result_mark": 2, "review_kind": 7, "usage_wait": 5}
print("PASS metrics-breakdown: リーダーと `decide` 以外が書いたマークを読まず、飛ばした数が種類ごとに出る")

# 4-1: a wait in in_review is a human's, a wait in in_progress is on the agents' side. A run created
# but not started is a startup wait even in in_review; a usage_wait mark does not beat in_review.
h = tasks["DEMO-H"]
assert nonzero(h["allocation_seconds"]) == {
    "implementation": 300, "wait_human": 200, "wait_startup": 200, "code_review_first": 200, "wait_other": 300}
assert h["elapsed_seconds"] == 1200
print("PASS metrics-breakdown: in_review の待ちは人間の返事に、in_progress の待ちはエージェント側に入り、起動の待ちは別に出る")

# 5-1: a failed run with limit_stop and a leader's usage_wait are the usage limit; a leader's ci_wait
# is CI, and usage_wait wins when both are there.
i = tasks["DEMO-I"]
assert nonzero(i["allocation_seconds"]) == {
    "implementation": 1000, "wait_usage_limit": 400, "wait_ci": 200, "wait_other": 400}
print("PASS metrics-breakdown: 上限で止まった実行と使用率の待ちのあとの待ちが使用率の上限に、CI を待つマークのあとの待ちが CI に入る")

# Marks and records nobody trusted do not name a wait: a member's marks, a reviewer's ci_wait, a
# limit_stop on a run that did not fail, a notice a member wrote, and a member's mention fall to "other".
assert i["allocation_seconds"]["wait_other"] == 400
j = tasks["DEMO-J"]
assert nonzero(j["allocation_seconds"]) == {
    "implementation": 1000, "wait_usage_limit": 200, "wait_other": 400, "wait_human": 200, "wait_ci": 200}
print("PASS metrics-breakdown: 信頼できないマーク・上限の通知・メンションは待ちの種類に使わず、エージェントのメンションと上限の通知だけが使われる")

# 7-1: a small implementation is 1,800 s or less of implementer runs; each run's fraction is cut off first.
k, l, m = tasks["DEMO-K"], tasks["DEMO-L"], tasks["DEMO-M"]
assert k["implementation_run_seconds"] == 1800 and k["kinds"]["small_implementation"] is True
assert l["implementation_run_seconds"] == 1801 and l["kinds"]["small_implementation"] is False
assert m["implementation_run_seconds"] == 1800 and m["kinds"]["small_implementation"] is True
assert a["implementation_run_seconds"] == 1399  # 1399.6 s
assert "DEMO-L" not in [t["identifier"] for t in result["tasks"] if t["kinds"]["small_implementation"]]
assert groups["small_implementation"]["task_count"] == 14 and groups["all"]["task_count"] == 15
print("PASS metrics-breakdown: 実装の実行の合計がちょうど 1,800 秒のタスクは小さい実装に入り、1,801 秒のタスクは入らない")

# 8-1: created before the cutoff is "before"; at the cutoff and after it is "after".
cutoff = 1767225600  # 2026-01-01T00:00:00Z
assert (k["created_seconds"], l["created_seconds"], m["created_seconds"]) == (cutoff - 1, cutoff, cutoff + 1)
assert groups["before_cutoff"]["task_count"] == 1
assert groups["before_cutoff"]["elapsed"]["total_seconds"] == k["elapsed_seconds"] == 1900
assert groups["after_cutoff"]["task_count"] == 14
assert groups["after_cutoff"]["elapsed"]["total_seconds"] == sum(
    t["elapsed_seconds"] for t in result["tasks"] if t["identifier"] != "DEMO-K")
print("PASS metrics-breakdown: 区切りの 1 秒前に作られたタスクは前に、ちょうどと 1 秒後に作られたタスクは後に入る")

# 10-1: the time before the implementation starts is a total and a per-task value, with no categories.
for group in groups.values():
    assert sorted(group["before_implementation"]) == ["per_task_seconds", "total_seconds"]
assert groups["all"]["before_implementation"] == {"per_task_seconds": "18046.7", "total_seconds": 270700}
assert k["seconds_before_implementation"] == 80001
assert "before_implementation" not in groups["all"]["allocation"]
assert all("before" not in name for name in groups["all"]["allocation"])
print("PASS metrics-breakdown: 起票から実装の開始までは、合計と 1 タスクあたりの値だけが出て、区分の内訳は出ない")

# Groups: the kinds overlap, the parts of each group add up, and the startup wait is part of "other".
assert sorted(groups) == ["after_cutoff", "all", "before_cutoff", "docs_only", "important", "small_implementation"]
assert groups["all"]["excluded"] == {"no_implementer_run": 1, "not_done": 1, "unmeasurable": 2}
assert all("excluded" not in group for name, group in groups.items() if name != "all")
assert groups["docs_only"]["task_count"] == 1 and groups["important"]["task_count"] == 2
assert groups["all"]["elapsed"] == {"per_task_seconds": "1686.7", "total_seconds": 25300}
for name, group in groups.items():
    elapsed = group["elapsed"]["total_seconds"]
    assert sum(row["seconds"] for row in group["allocation"].values()) == elapsed, name
    assert sum(row["seconds"] for row in group["sides"].values()) == elapsed, name
assert "wait_startup" not in groups["all"]["allocation"]
other = groups["all"]["allocation"]["wait_other"]
assert (other["seconds"], other["startup_seconds"], other["task_count"]) == (5497, 200, 14)
assert groups["all"]["sides"] == {
    "agent": {"seconds": 23950, "share_percent": "94.7"},
    "human_wait": {"seconds": 400, "share_percent": "1.6"},
    "unknown": {"seconds": 950, "share_percent": "3.8"}}
assert groups["all"]["unknown_roles"] == {"claude-principal": {"runs": 8, "seconds": 900}, "その他": {"runs": 1, "seconds": 50}}
assert groups["all"]["skipped_marks"] == result["skipped_marks"]
print("PASS metrics-breakdown: 区切りごとの集計で、区分と側の合計が経過時間と一致し、起動はそのほかの内訳に入り、種類は重なってよい")

# 11-2: a result that led to a fix, an overlapping result and a fix request for one process are counted,
# and a result whose findings cannot be read is never added up as 0 findings.
n, o = tasks["DEMO-N"], tasks["DEMO-O"]
n_findings, o_findings = n["findings"], o["findings"]
assert n_findings["fix_requests"] == {"total": 4, "review": 3, "non_review": 1}
code = n_findings["processes"]["code_review"]
# 3 results (fail, warn, pass); the first led to fix request 1 with the security result (overlap), the
# second to fix request 2 alone; the pass is not a basis. Counts: required 2 | recommended 1 and 2.
assert {key: code[key] for key in ("passed", "results", "with_findings", "without_findings", "unreadable",
                                   "led_to_fix", "overlapping", "only_fix_requests", "blocking",
                                   "non_blocking", "counts_unread")} == {
    "passed": True, "results": 3, "with_findings": 2, "without_findings": 1, "unreadable": 0,
    "led_to_fix": 2, "overlapping": 1, "only_fix_requests": 1, "blocking": 2, "non_blocking": 3,
    "counts_unread": 0}
other_review = n_findings["processes"]["other_review"]
assert (other_review["results"], other_review["with_findings"], other_review["led_to_fix"],
        other_review["overlapping"], other_review["only_fix_requests"]) == (1, 1, 1, 1, 0)
assert (other_review["blocking"], other_review["non_blocking"]) == (1, 3)  # high 1, medium 0 | low 3
assert n_findings["other_review_roles"]["security-reviewer"] == {
    key: value for key, value in other_review.items() if key != "rounds"}
assert n_findings["other_review_roles"]["performance-reviewer"]["results"] == 0
e2e = n_findings["processes"]["e2e"]
# The result has no marks: unreadable, led to fix request 3 alone (the code review's pass is dropped),
# and its counts are unread, not 0.
assert (e2e["results"], e2e["unreadable"], e2e["with_findings"], e2e["without_findings"]) == (1, 1, 0, 0)
assert (e2e["led_to_fix"], e2e["overlapping"], e2e["only_fix_requests"]) == (1, 0, 1)
assert (e2e["blocking"], e2e["non_blocking"], e2e["counts_unread"]) == (0, 0, 1)
# A design review's result is counted but never a basis, even between two fix requests.
design = n_findings["processes"]["design_review"]
assert (design["results"], design["with_findings"], design["led_to_fix"]) == (1, 1, 0)
assert n_findings["processes"]["final_review"]["results"] == 0
all_findings = groups["all"]["findings"]
assert all_findings["fix_requests"] == {"total": 7, "review": 5, "non_review": 2}
assert {key: value for key, value in all_findings["processes"]["code_review"].items() if key != "rounds"} == {
    "task_count": 5, "results": 4, "with_findings": 3, "without_findings": 1, "unreadable": 0, "led_to_fix": 3,
    "overlapping": 1, "only_fix_requests": 2,
    "finding_counts": {"blocking": 3, "non_blocking": 3, "unreadable_results": 0}}
assert all_findings["processes"]["e2e"]["finding_counts"] == {
    "blocking": 0, "non_blocking": 0, "unreadable_results": 1}
assert all_findings["processes"]["design_review"] == {"task_count": 2, "results": 1, "with_findings": 1}
assert groups["before_cutoff"]["findings"]["processes"]["code_review"]["results"] == 0
print("PASS metrics-breakdown: 修正につながった結果、重なる結果、その工程だけの修正の依頼が数えられ、件数を読めない結果が 0 件にならない")

# The rounds: the first round and the later rounds are counted apart, as well as in the process total.
# DEMO-N's code review has one first-round result (it led to a fix with the security result) and two
# later-round results (a warning that led to a fix alone, and a pass).
rounds = code["rounds"]
assert {name: {key: row[key] for key in ("passed", "results", "with_findings", "without_findings", "led_to_fix",
                                         "overlapping", "only_fix_requests", "blocking", "non_blocking")}
        for name, row in rounds.items()} == {
    "first": {"passed": True, "results": 1, "with_findings": 1, "without_findings": 0, "led_to_fix": 1,
              "overlapping": 1, "only_fix_requests": 0, "blocking": 2, "non_blocking": 1},
    "later": {"passed": True, "results": 2, "with_findings": 1, "without_findings": 1, "led_to_fix": 1,
              "overlapping": 0, "only_fix_requests": 1, "blocking": 0, "non_blocking": 2}}
assert "rounds" not in e2e and "rounds" not in design and "rounds" not in n_findings["processes"]["unknown"]
all_rounds = all_findings["processes"]["code_review"]["rounds"]
assert (all_rounds["first"]["results"], all_rounds["later"]["results"]) == (2, 2)
assert (all_rounds["first"]["task_count"], all_rounds["later"]["task_count"]) == (5, 2)
assert (all_rounds["first"]["only_fix_requests"], all_rounds["later"]["only_fix_requests"]) == (1, 1)
assert "rounds" not in all_findings["processes"]["design_review"]
assert "コードレビュー 2 回目以降" in (OUTPUT / "breakdown.md").read_text()


def result(time, role, process, round_name, state="with", counts=None):
    return {"time": Decimal(time), "role": role, "process": process, "round": round_name, "state": state,
            "counts": counts}


def count(results, fixes, rounds=(("code_review", "first"), ("code_review", "later"),
                                  ("other_review", "first"), ("other_review", "later"))):
    return metrics.count_findings(
        results, [{"time": Decimal(time)} for time in fixes], 0, {process for process, _ in rounds},
        {"security-reviewer", "ux-reviewer"}, set(rounds))


def figures(row):
    return tuple(row[key] for key in ("results", "led_to_fix", "overlapping", "only_fix_requests"))


# Findings only in the first round: the later round has no result and no fix of its own.
first_only = count([result(10, "code-reviewer", "code_review", "first"),
                    result(20, "code-reviewer", "code_review", "later", "without", {"required": 0})],
                   [15])["processes"]["code_review"]
assert figures(first_only["rounds"]["first"]) == (1, 1, 0, 1)
assert figures(first_only["rounds"]["later"]) == (1, 0, 0, 0)
assert first_only["rounds"]["later"]["without_findings"] == 1 and first_only["rounds"]["first"]["without_findings"] == 0
assert figures(first_only) == (2, 1, 0, 1)
# Findings only in the later round: the first round passed, and the fix request is the later round's own.
later_only = count([result(10, "code-reviewer", "code_review", "first", "without"),
                    result(20, "code-reviewer", "code_review", "later")],
                   [25])["processes"]["code_review"]
assert figures(later_only["rounds"]["first"]) == (1, 0, 0, 0)
assert figures(later_only["rounds"]["later"]) == (1, 1, 0, 1)
assert later_only["rounds"]["first"]["without_findings"] == 1 and later_only["rounds"]["later"]["with_findings"] == 1
# A fix request whose basis is a first-round and a later-round result is neither round's own.
mixed = count([result(10, "security-reviewer", "other_review", "first"),
               result(11, "ux-reviewer", "other_review", "later")], [15])["processes"]["other_review"]
assert figures(mixed) == (2, 2, 0, 1)
assert figures(mixed["rounds"]["first"]) == (1, 1, 1, 0) and figures(mixed["rounds"]["later"]) == (1, 1, 1, 0)
# A round that was not passed stays unpassed.
assert count([], [], (("code_review", "first"),))["processes"]["code_review"]["rounds"]["later"]["passed"] is False

# The security and UX results on one fix request: the other reviews as a whole are the fix's own, but each
# role overlaps with the other role; a code review result overlaps with both roles and the whole.
both = count([result(10, "security-reviewer", "other_review", "first"),
              result(11, "ux-reviewer", "other_review", "first")], [15])
assert figures(both["processes"]["other_review"]) == (2, 2, 0, 1)
assert figures(both["other_review_roles"]["security-reviewer"]) == (1, 1, 1, 0)
assert figures(both["other_review_roles"]["ux-reviewer"]) == (1, 1, 1, 0)
assert figures(both["other_review_roles"]["performance-reviewer"]) == (0, 0, 0, 0)
assert figures(both["processes"]["other_review"]["rounds"]["first"]) == (2, 2, 0, 1)
alone = count([result(10, "security-reviewer", "other_review", "first"),
               result(11, "ux-reviewer", "other_review", "first", "without")], [15])
assert figures(alone["other_review_roles"]["security-reviewer"]) == (1, 1, 0, 1)
assert figures(alone["other_review_roles"]["ux-reviewer"]) == (1, 0, 0, 0)
with_code = count([result(10, "security-reviewer", "other_review", "first"),
                   result(11, "code-reviewer", "code_review", "first")], [15])
assert figures(with_code["processes"]["other_review"]) == (1, 1, 1, 0)
assert figures(with_code["other_review_roles"]["security-reviewer"]) == (1, 1, 1, 0)
assert figures(with_code["processes"]["code_review"]) == (1, 1, 1, 0)
print("PASS metrics-breakdown: 初回と 2 回目以降の指摘と修正が分かれ、役ごとの重なりが別の役と別の工程の根拠で数えられる")

# The rounds and the process total: which columns add up is decided by the tables in the design document.
# The tests take those tables as their input, one test for each row, so a column or a case that is added to
# a table without a test fails here.
DOC = ROOT / "docs" / "time-breakdown.md"
COLUMN_TABLE = "「回の行と工程の合計」の表"
CASE_TABLE = "「回の行と工程の合計」の節の場合の表"


def doc_rows(first_cells):
    lines = DOC.read_text().splitlines()
    start = next(index for index, line in enumerate(lines) if line.startswith(first_cells))
    rows = []
    for line in lines[start + 2:]:
        if not line.startswith("|"):
            break
        rows.append([cell.strip().strip("`") for cell in line.strip().strip("|").split(" | ")])
    return rows


def pick(row, key):
    value = row
    for part in key.split("."):
        value = value[part]
    return value


def task(results, fixes, passed=("first", "later"), process="code_review"):
    """One task's findings: the results and the fix requests of one process, and the rounds it passed."""
    return count(results, fixes, tuple((process, name) for name in passed))


def total_of(tasks, process="code_review"):
    return metrics.findings_process([one["processes"][process] for one in tasks], process)


first_with = result(10, "code-reviewer", "code_review", "first")
first_pass = result(10, "code-reviewer", "code_review", "first", "without", {"required": 0})
later_with = result(20, "code-reviewer", "code_review", "later")
later_pass = result(20, "code-reviewer", "code_review", "later", "without", {"required": 0})
first_only_task = task([first_with, later_pass], [15])
later_only_task = task([first_pass, later_with], [25])
both_task = task([first_with, later_with], [15, 25])
cases = {
    "固定見本（全件）のコードレビュー": groups["all"]["findings"]["processes"]["code_review"],
    "1 回目だけに指摘があるタスク": total_of([first_only_task]),
    "2 回目以降だけに指摘があるタスク": total_of([later_only_task]),
    "両方の回に指摘があるタスク": total_of([both_task]),
    "上の 3 つのタスクを合わせたもの": total_of([first_only_task, later_only_task, both_task]),
    "1 回目だけを通ったタスク": total_of([task([first_with], [15], ("first",))]),
    "1 回目と 2 回目以降の結果が同じ修正の依頼の根拠（そのほかのレビュー）": total_of([task([
        result(10, "security-reviewer", "other_review", "first"),
        result(11, "ux-reviewer", "other_review", "later")], [15], process="other_review")], "other_review"),
}
rounded = [(f"{group} の {process}", rows["findings"]["processes"][process])
           for group, rows in groups.items() for process in metrics.ROUNDED_PROCESSES]
observed = rounded + list(cases.items())
assert len(rounded) == 18 and all("rounds" in row for _, row in observed)

column_rows = doc_rows("| 列 | 出力のキー |")
case_rows = doc_rows("| 場合 | 通ったタスク |")
assert [row[1] for row in column_rows] == [
    "task_count", "results", "with_findings", "without_findings", "unreadable", "led_to_fix", "overlapping",
    "only_fix_requests", "finding_counts.blocking", "finding_counts.non_blocking",
    "finding_counts.unreadable_results"]
assert {row[2] for row in column_rows} == {"足せる", "足せない"}
for label, key, adds, _ in column_rows:
    sums = [(name, sum(pick(part, key) for part in row["rounds"].values()), pick(row, key))
            for name, row in observed]
    if adds == "足せる":
        # A column that adds up: the rounds make the process's value in every group and case.
        wrong = [name for name, rounds_sum, whole in sums if rounds_sum != whole]
        assert not wrong, (label, wrong)
    else:
        # A column that does not: some group or case has rounds that do not make the process's value.
        assert any(rounds_sum != whole for _, rounds_sum, whole in sums), label
    print(f"PASS metrics-breakdown: 列「{label}」は回の行を{adds}（{COLUMN_TABLE}、`{key}`）")
# The tasks passed are counted once for each task: the process's value lies between its largest round and
# the rounds added up.
for name, row in observed:
    rounds_task_counts = [part["task_count"] for part in row["rounds"].values()]
    assert max(rounds_task_counts) <= row["task_count"] <= sum(rounds_task_counts), name

assert [row[0] for row in case_rows] == list(cases)
for label, *expected in case_rows:
    row = cases[label]
    actual = [" / ".join(str(pick(part, key)) for part in (*row["rounds"].values(), row))
              for key in ("task_count", "results", "led_to_fix", "overlapping", "only_fix_requests")]
    assert actual == expected, (label, actual, expected)
    print(f"PASS metrics-breakdown: 場合「{label}」の回の行と工程の全体の値が表と合う（{CASE_TABLE}）")
assert case_rows[0][1] == "5 / 2 / 5"
report = (OUTPUT / "breakdown.md").read_text()
assert "通ったタスク（重複を除く）" in report
assert all(f"「{label}」" in report for label, _, adds, _ in column_rows if adds == "足せない")
assert "足せる列だけ" in report
print(f"PASS metrics-breakdown: breakdown.md の注記が足せない列を挙げ、通ったタスクの見出しに「重複を除く」と書く（{COLUMN_TABLE}）")

# 12-1: marks nobody trusts are not read and are counted; comments outside the window are not read.
assert o["skipped_marks"] == {"ci_wait": 0, "finding_counts": 2, "fix_request": 1, "request_commit": 0,
                              "result_commit": 2, "result_mark": 2, "review_kind": 0, "usage_wait": 0}
assert n["skipped_marks"] == dict.fromkeys(n["skipped_marks"], 0)
assert o_findings["fix_requests"] == {"total": 1, "review": 1, "non_review": 0}
# Only the 120490 result counts: a member's pass, the leader's pass and a stray agent's counts are skipped;
# the results at 119990 (before the implementer run) and 121100 (after done) are outside the window.
assert o_findings["processes"]["code_review"]["results"] == 1
assert o_findings["processes"]["code_review"]["with_findings"] == 1
assert o_findings["processes"]["code_review"]["blocking"] == 1
# The 120300 pass is before the author's first run, so it has no process.
assert (o_findings["processes"]["unknown"]["results"], o_findings["processes"]["unknown"]["without_findings"]) == (1, 1)
assert groups["all"]["skipped_marks"] == {
    "ci_wait": 6, "finding_counts": 2, "fix_request": 7, "request_commit": 4, "result_commit": 2,
    "result_mark": 2, "review_kind": 7, "usage_wait": 5}
assert sorted(groups["all"]["skipped_marks"]) == sorted(metrics.SKIPPED_MARKS)
print("PASS metrics-breakdown: リーダー以外が書いたマークと、結果の役以外が書いた結果のマークを読まず、窓の外のコメントも読まず、飛ばした数が出る")

# 6-2: what `decide` wrote is read: a review role, qa or a principal wrote the request, with previous_round
# and no result_round. The final review it asked for is not "unknown", and the same commit asked again is
# the same round (the leader's request and the security reviewer's re-request make one round).
p = tasks["DEMO-P"]
assert nonzero(p["allocation_seconds"]) == {
    "implementation": 400, "other_review_first": 200, "final_review_first": 200, "final_review_later": 100,
    "wait_other": 600}
assert "unknown" not in nonzero(p["allocation_seconds"]) and p["unknown_roles"] == {}
assert p["skipped_marks"] == dict.fromkeys(p["skipped_marks"], 0)
print("PASS metrics-breakdown: `decide` が書いた最終レビューの依頼が不明でなく最終レビューに入り、同じコミットの頼み直しが同じ回になる")

# 6-3: a first fix request that `decide` wrote is counted, and the result before it led to the fix.
q = tasks["DEMO-Q"]
assert q["findings"]["fix_requests"] == {"total": 1, "review": 1, "non_review": 0}
other_q = q["findings"]["processes"]["other_review"]
assert (other_q["results"], other_q["with_findings"], other_q["led_to_fix"], other_q["only_fix_requests"]) == (1, 1, 1, 1)
assert (other_q["blocking"], other_q["non_blocking"]) == (1, 1)
assert q["skipped_marks"] == dict.fromkeys(q["skipped_marks"], 0)
print("PASS metrics-breakdown: `decide` が書いた 1 回目の修正の依頼が数えられ、根拠の結果が修正につながった結果になり、飛ばしたマークに入らない")

# 5-2: a usage_wait and a ci_wait that `decide` wrote name the wait after them, in a security reviewer's,
# a principal's and qa's comments; a wait with no record stays "other".
r = tasks["DEMO-R"]
assert nonzero(r["allocation_seconds"]) == {
    "implementation": 400, "other_review_first": 200, "unknown": 200, "e2e": 200,
    "wait_usage_limit": 200, "wait_ci": 400, "wait_other": 400}
assert r["skipped_marks"] == dict.fromkeys(r["skipped_marks"], 0)
print("PASS metrics-breakdown: `decide` が書いた使用率の待ちと CI の待ちの記録のあとの待ちが、それぞれの待ちの種類に入る")

# 6-4: the marks of comments that are neither the leader's nor `decide`'s are not read and are counted,
# and nothing they name changes: the runs stay "unknown", no fix request counts, and the waits stay "other".
# The previous_round and result_round marks themselves are not counted as skipped.
s = tasks["DEMO-S"]
assert nonzero(s["allocation_seconds"]) == {"implementation": 200, "unknown": 500, "wait_other": 1000}
assert s["unknown_roles"] == {"claude-principal": {"runs": 5, "seconds": 500}}
assert nonzero(s["skipped_marks"]) == {
    "ci_wait": 3, "fix_request": 5, "request_commit": 3, "review_kind": 5, "usage_wait": 3}
assert "previous_round" not in s["skipped_marks"] and "result_round" not in s["skipped_marks"]
assert s["findings"]["fix_requests"] == {"total": 0, "review": 0, "non_review": 0}
print("PASS metrics-breakdown: メンバー・実装・修正・設計の役、`前の回:` の行がない役、結果のコメントのマークを読まず、飛ばした数に出る")
