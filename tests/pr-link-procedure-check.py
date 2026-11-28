#!/usr/bin/env python3
"""共通スキルの「PR を作る・実装を積む」にある、PR の紐付け手順の契約を検査する。

使い方:
  pr-link-procedure-check.py check <手順のファイル>
      手順の契約を満たすかを見る。満たさなければ理由を標準エラー出力に出して 1 で終わる。
  pr-link-procedure-check.py table <表の TSV> <手順のファイル>
      表（tests/pr-link-procedure-table.tsv）の行ごとに、手順を 1 か所だけ変えた写しを作り、check の結果が期待と合うかを見る。
      合わない行があれば、行と場所を標準エラー出力に出して 1 で終わる。

契約は、機械が読む次の 4 つにする。説明文は固定しない（docs/test-trim.md の「残す 6 種類」）。
  - `squad-pr-link <タスク> <PR の URL> <きっかけのコメントの ID>` の呼び方が手順にあること
  - バッククォートで囲んだ語のうち、鍵の種類のものが、すべて pr_url か branch であり、2 つともあること
  - バッククォートで囲んだ終了コードが 0 と 3 であり、両方あること
  - 失敗の記録の行 `紐付けの失敗: <標準エラーの警告の 1 行目>` が、枠の中にあること

バッククォートの語は、種類に分けて見る。種類の決め方と、見る・見ないの理由は、表の列にある。
  - コマンド: 先頭の語が squad-pr-link か gh
  - 仮置き: < で始まり > で終わる
  - ラベル: 日本語を含み、: で終わる
  - 終了コード: ASCII の数字だけでできた語
  - 鍵: 上のどれでもないもの。綴りに制限を置かない。数字・大文字・ハイフン・前後の文字や空白があっても鍵とみなし、pr_url と branch のどちらでもなければ落とす
"""
import re
import sys

KEYS = ("pr_url", "branch")
EXIT_CODES = {"0", "3"}
CALL = "squad-pr-link <タスク> <PR の URL> <きっかけのコメントの ID>"
RECORD = "紐付けの失敗: <標準エラーの警告の 1 行目>"
SPAN = re.compile(r"`([^`\n]*)`")
TABLE_NAME = "tests/pr-link-procedure-table.tsv"


def kind_of(span):
    if span.startswith(("squad-pr-link ", "gh ")):
        return "コマンド"
    if span.startswith("<") and span.endswith(">"):
        return "仮置き"
    if span.endswith(":") and not span.isascii():
        return "ラベル"
    if span.isascii() and span.isdecimal():
        return "終了コード"
    return "鍵"


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
    """枠の外にある、バッククォートで囲んだ語を (種類, 語) で出現順に返す。"""
    found = []
    for inside, line in split(text):
        if not inside:
            found += [(kind_of(m.group(1)), m.group(1)) for m in SPAN.finditer(line)]
    return found


def check(text):
    """満たさない理由の一覧。空なら満たす。"""
    errors = []
    if CALL not in text:
        errors.append(f"呼び方 `{CALL}` がない")
    keys = set()
    exit_codes = set()
    for kind, span in spans(text):
        if kind == "終了コード":
            exit_codes.add(span)
        if kind != "鍵":
            continue
        if span in KEYS:
            keys.add(span)
        else:
            errors.append(f"鍵とみなした語 `{span}` が pr_url と branch のどちらでもない。鍵でない語を足したときは {TABLE_NAME} に種類の行を足す")
    for key in KEYS:
        if key not in keys:
            errors.append(f"鍵 `{key}` がバッククォートで囲んで書かれていない")
    if exit_codes != EXIT_CODES:
        errors.append("バッククォートで囲んだ終了コードが 0 と 3 の組でない")
    if RECORD not in [line for inside, line in split(text) if inside]:
        errors.append(f"枠の中に記録の行 `{RECORD}` がない")
    return errors


def template(tmpl, original):
    if tmpl == "~":
        return KEYS[1] if original == KEYS[0] else KEYS[0]
    return tmpl.replace("@", original).replace("\\s", " ")


def mutate(text, kind, tmpl, index):
    """kind の index 番目（0 始まり）だけを変えた写し。説明文と記録の行は 1 つしかないので index を見ない。"""
    lines = split(text)
    if kind == "説明文":
        # 枠の外の、バッククォートの外の文字をすべて言い換える。語は変えない。
        words = lambda line: SPAN.sub(lambda m: "\0" + m.group(0) + "\0", line)
        out = []
        for inside, line in lines:
            if inside:
                out.append(line)
                continue
            parts = words(line).split("\0")
            out.append("".join(p if p.startswith("`") else ("言い換えた文" if p else "") for p in parts))
        return "\n".join(out)
    if kind == "記録の行":
        assert any(inside and line == RECORD for inside, line in lines), "記録の行がない"
        return text.replace(RECORD, tmpl, 1)
    seen = [-1]

    def sub(m):
        if kind_of(m.group(1)) != kind:
            return m.group(0)
        seen[0] += 1
        return "`" + template(tmpl, m.group(1)) + "`" if seen[0] == index else m.group(0)

    return "\n".join(line if inside else SPAN.sub(sub, line) for inside, line in lines)


def run_table(table_path, text):
    problems, rows, cases = [], 0, 0
    base = check(text)
    if base:
        problems.append("変える前の手順が契約を満たさない: " + "；".join(base))
    with open(table_path, encoding="utf-8") as f:
        for number, row in enumerate(f, 1):
            row = row.rstrip("\n")
            if not row or row.startswith("#"):
                continue
            cols = row.split("\t")
            assert len(cols) == 6, f"{table_path}:{number}: 列が 6 つでない"
            label, kind, tmpl, expect, _reason = cols[0] + "（" + cols[1] + "）", cols[1], cols[2], cols[3], cols[4]
            assert expect in ("落ちる", "通る"), f"{table_path}:{number}: 期待が落ちる・通るでない"
            rows += 1
            count = 1 if kind in ("説明文", "記録の行") else sum(1 for k, _ in spans(text) if k == kind)
            if count == 0:
                problems.append(f"{table_path}:{number}: 手順に種類「{kind}」の語がなく、行が空振りになる")
            for index in range(count):
                cases += 1
                broken = check(mutate(text, kind, tmpl, index))
                if (expect == "落ちる") != bool(broken):
                    where = f"{index + 1} か所目" if count > 1 else "1 か所"
                    problems.append(f"{table_path}:{number}: {label} {where}を変えた写しが、期待は{expect}のに" + ("通った" if expect == "落ちる" else "落ちた: " + "；".join(broken)))
    return problems, rows, cases


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        text = open(argv[2], encoding="utf-8").read()
        errors = check(text)
        for e in errors:
            print(e, file=sys.stderr)
        return 1 if errors else 0
    if len(argv) == 4 and argv[1] == "table":
        text = open(argv[3], encoding="utf-8").read()
        problems, rows, cases = run_table(argv[2], text)
        for p in problems:
            print(p, file=sys.stderr)
        if problems:
            return 1
        print(f"表 {rows} 行、写し {cases} 件")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
