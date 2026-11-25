#!/usr/bin/env bash
# ZIP のルートから bash tests/review-note-table-test.sh で実行する。
# マージの依頼に写す注意の入力の種類（コードの囲み・HTML コメント・その組み合わせ・見出しの位置・注意の節が複数）を、
# 設計（docs/merge-request-reading.md）の「注意の入力の種類と写し方」の表の全行（tests/review-note-table.tsv）で確認する。
# 表の行ごとに 1 件を確認し、結果の行に表の場所を書く。
# 注意の写し方（common/monitor/squad-review-next の NOTE_PY）と、返事の指摘の一覧の読み方（同じ DECIDE_PY の finding_list）に、同じ入力を通す。
# 見張りを実行せず、heredoc の処理だけを取り出して流す（tests/own-review-paths-test.sh と同じ）。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$root" <<'PY'
import ast
import contextlib
import io
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
source = (root / "common/monitor/squad-review-next").read_text(encoding="utf-8")
doc = (root / "docs/merge-request-reading.md").read_text(encoding="utf-8")
TABLE = "tests/review-note-table.tsv、docs/merge-request-reading.md の「注意の入力の種類と写し方」の表"


def extract(variable, marker):
    match = re.search(
        rf"^read -r -d '' {variable} <<'{marker}' \|\| true\n(.*?)^{marker}$",
        source, re.MULTILINE | re.DOTALL,
    )
    assert match, f"{variable} の処理を取り出せない"
    return match[1]


markup = extract("MARKUP_PY", "MARKUPPY")
note_code = compile(markup + "\n" + extract("NOTE_PY", "NOTEPY"), "squad-review-next:NOTE_PY", "exec")

# finding_list が使う定義だけを DECIDE_PY から取り出す（残りは、タスクのファイルを読む処理）。
needed_defs = {"lines_of", "tidy", "finding_list"}
needed_values = {"CONTROL", "LEAD", "MENTION", "LIST_HEAD", "MAX_ITEMS", "MAX_ITEM_CHARS"}
tree = ast.parse(extract("DECIDE_PY", "DECIDEPY"))
picked = []
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in needed_defs:
        picked.append(node)
    elif isinstance(node, ast.Assign) and {n.id for t in node.targets for n in ast.walk(t) if isinstance(n, ast.Name)} & needed_values:
        picked.append(node)
names = {node.name for node in picked if isinstance(node, ast.FunctionDef)}
assert names == needed_defs, f"DECIDE_PY から取り出せない定義: {needed_defs - names}"
list_namespace = {}
exec(compile(markup, "squad-review-next:MARKUP_PY", "exec"), list_namespace)
exec(compile(ast.Module(body=picked, type_ignores=[]), "squad-review-next:DECIDE_PY", "exec"), list_namespace)


def run_note(body):
    output = io.StringIO()
    previous = sys.stdin
    try:
        sys.stdin = io.StringIO(body + "\n")  # decide は printf '%s\n' で渡す
        with contextlib.redirect_stdout(output):
            try:
                exec(note_code, {})
            except SystemExit as error:
                assert error.code == 0, f"NOTE_PY が失敗した: {error.code}"
    finally:
        sys.stdin = previous
    return output.getvalue().rstrip("\n")


def run_list(lines):
    reply = {"content": f"指摘の一覧: {len(lines)} 件\n" + "\n".join("- " + line for line in lines)}
    listed = list_namespace["finding_list"](reply)
    assert listed is not None, "finding_list が None を返した"
    _, items, dropped = listed
    return [items, dropped]


rows = []
for number, line in enumerate((root / "tests/review-note-table.tsv").read_text(encoding="utf-8").splitlines(), 1):
    if not line.strip() or line.startswith("#"):
        continue
    cells = line.split("\t")
    assert len(cells) == 6, f"表の {number} 行目の列が 6 つでない: {len(cells)}"
    rows.append(cells)
assert rows, "表が空"

# 設計の表と、テストの表が、同じ番号を同じ順に持つ。
section = doc.split("### 注意の入力の種類と写し方", 1)
assert len(section) == 2, "設計に「注意の入力の種類と写し方」の節がない"
body = re.split(r"^#{1,3} ", section[1], maxsplit=1, flags=re.MULTILINE)[0]
doc_ids = re.findall(r"^\| ([A-Z][0-9]+) \|", body, re.MULTILINE)
table_ids = [cells[0] for cells in rows]
assert doc_ids == table_ids, f"設計の表の番号とテストの表の番号が違う\n設計: {doc_ids}\n表: {table_ids}"
assert len(set(table_ids)) == len(table_ids), "表に重なった番号がある"

failures = []
for number, kind, label, text, note_expect, list_expect in rows:
    assert kind in ("共通", "本文"), f"{number}: 種類が不明: {kind}"
    given = json.loads(text)
    if kind == "共通":
        assert list_expect != "-", f"{number}: 共通の行に一覧の期待がない"
        note_input = "## 注意\n" + given
    else:
        assert list_expect == "-", f"{number}: 本文の行に一覧の期待がある"
        note_input = given
    problems = []
    got_note = run_note(note_input)
    if got_note != json.loads(note_expect):
        problems.append(f"注意の写し方\n  期待: {json.loads(note_expect)!r}\n  実際: {got_note!r}")
    if kind == "共通":
        got_list = run_list(given.split("\n"))
        if got_list != json.loads(list_expect):
            problems.append(f"指摘の一覧の読み方\n  期待: {json.loads(list_expect)!r}\n  実際: {got_list!r}")
    if problems:
        failures.append(f"FAIL review-note-table: {number} {label}（表: {TABLE}）\n" + "\n".join(problems))
    else:
        print(f"PASS review-note-table: {number} {label}（表: {TABLE}）")

# 表にない書き方を、包みと見本の位置と本物の注意の中身の組み合わせで確認する（設計: 「「なし」と書く条件」）。
# 見本の `## 注意` と本物の `## 注意` で、注意の見出しの形の行が 2 つになる本文は、包み方が何でも「なし」の行を出さない。
# 包みは、見分ける規則が読み違えるものを含む（HTML ブロックの開始・宣言・記号つきの囲みの閉じ・字下げ）。
UNREADABLE = "マージの前に人間がすること: 読めない（PR の本文に注意の見出しの形の行が "
NONE_LINE = "マージの前に人間がすること: なし"


def prefixed(prefix, lines):
    return [prefix + line for line in lines]


wrappers = {
    "包みなし": lambda s: s,
    "逆引用符の囲み": lambda s: ["```md"] + s + ["```"],
    "チルダの囲み": lambda s: ["~~~"] + s + ["~~~"],
    "閉じていない囲み": lambda s: ["```md"] + s,
    "コメント": lambda s: ["<!--"] + s + ["-->"],
    "閉じていないコメント": lambda s: ["<!--"] + s,
    "引用の中の囲み": lambda s: ["> ```"] + prefixed("> ", s) + ["> ```"],
    "箇条書きの中の囲み": lambda s: ["- ```"] + prefixed("  ", s) + ["  ```"],
    "字下げした囲み": lambda s: ["   ```"] + s + ["   ```"],
    "囲みの中の引用つきの閉じ": lambda s: ["```text", "> ```"] + s,
    "囲みの中の箇条書きつきの閉じ": lambda s: ["```text", "- ```"] + s,
    "囲みの中の字下げした閉じ": lambda s: ["```text", "    ```"] + s,
    "囲みの中の引用と箇条書きつきの閉じ": lambda s: ["```text", "> - ```"] + s,
    "空白 3 個で字下げした見出し": lambda s: ["```", *prefixed("   ", s[:1]), *s[1:], "```"],
    "引用つきの見出し": lambda s: ["> " + s[0], *s[1:]],
    "箇条書きと引用つきの見出し": lambda s: ["> - " + s[0], *s[1:]],
    "宣言 DOCTYPE": lambda s: ["<!DOCTYPE html>"] + s,
    "宣言 処理命令": lambda s: ['<?xml version="1.0"?>'] + s,
    "宣言 CDATA": lambda s: ["<![CDATA["] + s + ["]]>"],
}
for tag in ("pre", "script", "style", "textarea", "div", "table", "details", "section", "blockquote", "p"):
    wrappers[f"HTML ブロック {tag}"] = lambda s, tag=tag: [f"<{tag}>"] + s + [f"</{tag}>"]
    wrappers[f"閉じていない HTML ブロック {tag}"] = lambda s, tag=tag: [f"<{tag}>"] + s

samples = {"なしの見本": ["## 注意", "なし"], "作業のある見本": ["## 注意", "- 偽の作業"]}
reals = {"なしの本物": ["## 注意", "なし"], "作業のある本物": ["## 注意", "- 本物の作業"]}
positions = {
    "本物の前": lambda sample, real: ["## 概要", "変更"] + sample + real,
    "本物の節の中": lambda sample, real: real + sample + ["- 続き", "## 確認", "確認した"],
    "本物の後": lambda sample, real: ["## 概要", "変更"] + real + ["## 確認", "確認した"] + sample,
}
combined = 0
for wrap_name, wrap in wrappers.items():
    for sample_name, sample in samples.items():
        for real_name, real in reals.items():
            for position_name, place in positions.items():
                combined += 1
                lines = place(wrap(sample), real)
                text = "\n".join(lines)
                label = f"{wrap_name}、{sample_name}、{real_name}、{position_name}"
                got = run_note(text)
                if got == NONE_LINE:
                    failures.append(f"FAIL review-note-table: 組み合わせで「なし」になった: {label}\n  本文: {text!r}")
                elif got.startswith(UNREADABLE) and not got.endswith(" 個ある）"):
                    failures.append(f"FAIL review-note-table: 数の行の形が違う: {label}\n  実際: {got!r}")
# 見出しの形の行が 1 つだけのときは、「なし」の節を「なし」と書く。
for text in ("## 注意\nなし", "## 概要\n変更\n## 注意\nなし。\n## 確認\n確認した", "<div>\n## 注意\nなし\n## 確認\nOK\n</div>"):
    if run_note(text) != NONE_LINE:
        failures.append(f"FAIL review-note-table: 見出しの形の行が 1 つの本文が「なし」にならない: {text!r}")
# 「なし」だけの節で、見出しの形の行が 2 つ以上なら、数を行に書く。
for count in (2, 3, 5):
    text = "```\n" + "\n".join(["## 注意"] * (count - 1)) + "\n```\n## 注意\nなし"
    expected = UNREADABLE + f"{count} 個ある）"
    if run_note(text) != expected:
        failures.append(f"FAIL review-note-table: 見出しの形の行 {count} 個の数の行が違う: {run_note(text)!r}")
print(f"PASS review-note-table: 包み・見本の位置・本物の注意の中身の組み合わせ {combined} 件で、見出しの形の行が 2 つ以上の本文が「なし」にならない")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print(f"PASS review-note-table: 表の全 {len(rows)} 行を確認した（表: {TABLE}）")
PY
