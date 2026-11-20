#!/usr/bin/env python3
"""役の参照（common/skills/squad-handoff/references/）が持つ、コマンド形の契約を検査する。

使い方:
  command-forms-check.py check <表の TSV> <リポジトリの根>
      表の行どおりに、参照にコマンド形があるかを見る。満たさなければ理由を標準エラー出力に出して 1 で終わる。
  command-forms-check.py table <表の TSV> <リポジトリの根>
      表の行ごとに、参照を 1 か所だけ変えた写しを作り、check の結果が期待と合うかを見る。
      合わない行があれば、行と場所を標準エラー出力に出して 1 で終わる。

契約は、機械（Multica の CLI、jq、shasum）が読むコマンド形だけにする。説明文は固定しない（docs/test-trim.md の「残す 6 種類」）。
  - 名前: バッククォートで囲んだコマンドのうち、表の「名前」の行と同じ系統（形の最後の語を除いた前の部分）で始まるものは、
    その参照の「名前」の行のどれかで始まる。表にない名前は、綴りを誤ったものとみなして落とす。
  - 形: 表の行の形で始まるコマンドが、参照に 1 つ以上ある。引数やパイプの形を変えると落ちる。
  - 説明文: バッククォートの外は見ない。

表の列は tests/command-forms-table.tsv の先頭のコメントにある。
"""
import os
import re
import sys

SPAN = re.compile(r"`([^`\n]*)`")
TABLE_NAME = "tests/command-forms-table.tsv"


def split(text):
    """行ごとに (枠の中か, 行) を返す。枠は ``` で始まる行から次の ``` の行まで。"""
    out, inside = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            out.append((True, line))
            inside = not inside
        else:
            out.append((inside, line))
    return out


def spans(text):
    found = []
    for inside, line in split(text):
        if not inside:
            found += [m.group(1) for m in SPAN.finditer(line)]
    return found


def starts(span, form):
    """語の切れ目まで合う。`multica issue run` は `multica issue runs` で始まらない。"""
    return span == form or span.startswith(form + " ")


def load(table_path):
    rows = []
    with open(table_path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            assert len(cols) == 7, f"{table_path}:{number}: 列が 7 つでない"
            kind, path, form, tmpl, expect, look, _reason = cols
            assert expect in ("落ちる", "通る"), f"{table_path}:{number}: 期待が落ちる・通るでない"
            assert look in ("見る", "見ない"), f"{table_path}:{number}: 検査が見る・見ないでない"
            rows.append({"line": number, "kind": kind, "path": path, "form": form, "tmpl": tmpl, "expect": expect, "look": look})
    return rows


def check(text, rows):
    """満たさない理由の一覧。rows は、この参照の行だけ。空なら満たす。"""
    errors = []
    found = spans(text)
    names = [r["form"] for r in rows if r["kind"] == "名前"]
    families = {" ".join(n.split()[:-1]) for n in names}
    for span in found:
        for family in families:
            if span.startswith(family + " ") and not any(starts(span, n) for n in names):
                errors.append(f"`{span}` の名前が表にない。綴りの誤りか、新しい名前なら {TABLE_NAME} に名前の行を足す")
    for r in rows:
        if r["kind"] in ("名前", "形") and r["look"] == "見る" and not any(starts(s, r["form"]) for s in found):
            errors.append(f"`{r['form']}` で始まるコマンドが参照にない")
    return errors


def mutate(text, row, index):
    """行の形で始まるコマンドの index 番目（0 始まり）だけを変えた写し。説明文の行は、バッククォートの外をすべて言い換える。"""
    lines = split(text)
    if row["kind"] == "説明文":
        out = []
        for inside, line in lines:
            if inside:
                out.append(line)
                continue
            parts = SPAN.sub(lambda m: "\0" + m.group(0) + "\0", line).split("\0")
            out.append("".join(p if p.startswith("`") else ("言い換えた文" if p else "") for p in parts))
        return "\n".join(out)
    seen = [-1]

    def sub(m):
        span = m.group(1)
        if not starts(span, row["form"]):
            return m.group(0)
        seen[0] += 1
        if seen[0] != index:
            return m.group(0)
        return "`" + row["tmpl"] + span[len(row["form"]):] + "`"

    return "\n".join(line if inside else SPAN.sub(sub, line) for inside, line in lines)


def run(table_path, root, with_table):
    rows = load(table_path)
    problems, cases = [], 0
    by_path = {}
    for r in rows:
        by_path.setdefault(r["path"], []).append(r)
    texts = {}
    for path, group in by_path.items():
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            problems.append(f"{path} がない")
            continue
        texts[path] = open(full, encoding="utf-8").read()
        for e in check(texts[path], group):
            problems.append(f"{path}: {e}")
    if with_table and not problems:
        for r in rows:
            text = texts[r["path"]]
            count = 1 if r["kind"] == "説明文" else sum(1 for s in spans(text) if starts(s, r["form"]))
            if count == 0:
                problems.append(f"{TABLE_NAME}:{r['line']}: {r['path']} に `{r['form']}` で始まるコマンドがなく、行が空振りになる")
            for index in range(count):
                cases += 1
                broken = check(mutate(text, r, index), by_path[r["path"]])
                if (r["expect"] == "落ちる") != bool(broken):
                    where = f"{index + 1} か所目" if count > 1 else "1 か所"
                    problems.append(
                        f"{TABLE_NAME}:{r['line']}: {r['path']} の {r['kind']}「{r['form']}」の{where}を変えた写しが、期待は{r['expect']}のに"
                        + ("通った" if r["expect"] == "落ちる" else "落ちた: " + "；".join(broken))
                    )
    return problems, len(rows), cases


def main(argv):
    if len(argv) == 4 and argv[1] in ("check", "table"):
        problems, rows, cases = run(argv[2], argv[3], argv[1] == "table")
        for p in problems:
            print(p, file=sys.stderr)
        if problems:
            return 1
        print(f"表 {rows} 行、写し {cases} 件" if argv[1] == "table" else f"表 {rows} 行")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
