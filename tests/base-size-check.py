#!/usr/bin/env python3
"""毎回読む文の大きさと、分ける前の本文の行が残っていることを確認する。

使い方: base-size-check.py (size|lines|normalize) <原本の根> <フィクスチャのディレクトリ>

size: tests/fixtures/base-size/baseline.tsv の行ごとに、大きさが上限以下かを見る。
  skill 行は common/skills/squad-handoff/SKILL.md のバイト数、role 行は
  common/agents/<役>.md と SKILL.md のバイト数の和、scene 行は
  common/agents/orchestrator.md の「場面と手順」の表の行が読む参照のバイト数の和である。
  表にあるのにフィクスチャにない場面の行があれば落ちる。
lines: rule-lines.txt の行（分ける前の本文）が、SKILL.md と references/*.md に同じ数だけ
  残っているかを見る。減った行と増えた行は rule-lines-changed.tsv に理由を添えて載せる。
normalize: 根の SKILL.md と references/*.md を整えた行を 1 行ずつ出す（フィクスチャを作り直すとき用）。

失敗は標準エラーに FAIL の行で出し、終了コード 1 で終わる。
"""
import collections
import re
import sys
from pathlib import Path

SKILL = Path('common/skills/squad-handoff/SKILL.md')
REFS = Path('common/skills/squad-handoff/references')
AGENTS = Path('common/agents')
TREATMENTS = ('適用', '対象外', '未適用')


def normalize(text):
    """本文の行を整える。空の行・コードの囲みの行・表の区切りの行を除き、見出しの `#` と行末の空白を落とす。"""
    out = []
    for raw in text.split('\n'):
        line = raw.rstrip()
        stripped = line.lstrip()
        if not stripped:
            continue
        if stripped.startswith('```'):
            continue
        if re.fullmatch(r'\|?[\s:|-]+\|?', stripped) and '-' in stripped and '|' in stripped:
            continue
        line = re.sub(r'^#+ ', '', line)
        out.append(line)
    return out


def after_lines(root):
    files = [root / SKILL] + sorted((root / REFS).glob('*.md'))
    lines = []
    for f in files:
        lines.extend(normalize(f.read_text()))
    return lines


def read_tsv(path):
    rows = []
    for no, line in enumerate(path.read_text().split('\n'), 1):
        if not line or line.startswith('#'):
            continue
        rows.append((no, line.split('\t')))
    return rows


def scene_table(root):
    """orchestrator の「場面と手順」の表の行を、(場面, 読む参照の一覧) で返す。"""
    text = (root / AGENTS / 'orchestrator.md').read_text().split('\n')
    start = text.index('## 場面と手順')
    rows = []
    for line in text[start + 1:]:
        if line.startswith('## '):
            break
        if not line.startswith('|'):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if cells[0] in ('場面', '---') or len(cells) < 3:
            continue
        rows.append((cells[0], re.findall(r'`([^`]+\.md)`', cells[2])))
    return rows


def check_size(root, fixture):
    fails = []
    base = read_tsv(fixture / 'baseline.tsv')
    skill_size = (root / SKILL).stat().st_size
    scenes = {}
    for no, c in base:
        if len(c) != 6:
            fails.append(f'FAIL フィクスチャ baseline.tsv:{no}: 列が 6 つでない')
            continue
        kind, name, baseline, limit, treat, reason = c
        if treat not in TREATMENTS:
            fails.append(f'FAIL フィクスチャ baseline.tsv:{no}: 扱いが {"、".join(TREATMENTS)} のどれでもない')
            continue
        if treat != '適用' and not reason:
            fails.append(f'FAIL フィクスチャ baseline.tsv:{no}: 扱いが {treat} の行に理由がない')
        if kind in ('role', 'scene') and int(limit) != int(baseline) // 2:
            fails.append(f'FAIL フィクスチャ baseline.tsv:{no}: {name} の上限が基準の半分（切り捨て）でない')
        if kind == 'scene':
            scenes[name] = (int(limit), treat)
        if treat != '適用':
            continue
        if kind == 'skill':
            size = skill_size
        elif kind == 'role':
            path = root / AGENTS / f'{name}.md'
            if not path.is_file():
                fails.append(f'FAIL 役 {name}: 役の指示がない')
                continue
            size = path.stat().st_size + skill_size
        elif kind == 'scene':
            continue
        else:
            fails.append(f'FAIL フィクスチャ baseline.tsv:{no}: 種類が skill・role・scene のどれでもない')
            continue
        if size > int(limit):
            fails.append(f'FAIL {kind} {name}: 今の大きさ {size}、上限 {limit}')
    for scene, refs in scene_table(root):
        if scene not in scenes:
            fails.append(f'FAIL 場面 {scene}: フィクスチャにない場面が、リーダーの場面と手順の表にある')
            continue
        limit, treat = scenes[scene]
        if treat != '適用':
            continue
        size = 0
        for ref in refs:
            path = root / REFS / ref
            if not path.is_file():
                fails.append(f'FAIL 場面 {scene}: 読む参照 {ref} がない')
                break
            size += path.stat().st_size
        else:
            if size > limit:
                fails.append(f'FAIL scene {scene}: 今の大きさ {size}、上限 {limit}')
    return fails


def check_lines(root, fixture):
    fails = []
    # フィクスチャの行は、作るときに整えてある。読むときは空の行だけを除く。
    before = collections.Counter(
        l for l in (fixture / 'rule-lines.txt').read_text().split('\n') if l)
    after = collections.Counter(after_lines(root))
    rows = []
    for no, c in read_tsv(fixture / 'rule-lines-changed.tsv'):
        where = f'変えた行の一覧 rule-lines-changed.tsv:{no}'
        if len(c) != 3:
            fails.append(f'FAIL {where}: 列が 3 つでない（前の行・後の行・理由）')
            continue
        old, new, reason = c
        if not reason:
            fails.append(f'FAIL {where}: 理由がない')
        elif not old and not new:
            fails.append(f'FAIL {where}: 前の行も後の行も空である')
        elif new and new not in after:
            fails.append(f'FAIL {where}: 後の行が分けたあとにない: {new}')
        elif old and old not in before:
            fails.append(f'FAIL {where}: 前の行が分ける前にない: {old}')
        elif not old and new not in before:
            fails.append(f'FAIL {where}: 写した行が分ける前にない: {new}')
        else:
            rows.append((no, old, new))
    # 前の行ごとに数を比べる。足した行（前にない行）は数えない。
    deleted = {old for _, old, _ in rows if old}
    copied = {new for _, old, new in rows if not old}
    for line, count in before.items():
        now = after[line]
        if now < count and line not in deleted:
            fails.append(f'FAIL 本文の行: 分ける前 {count} 回、分けたあと {now} 回に減ったが、変えた行の一覧にない: {line}')
        elif now > count and line not in copied:
            fails.append(f'FAIL 本文の行: 分ける前 {count} 回、分けたあと {now} 回に増えたが、変えた行の一覧にない: {line}')
    for no, old, new in rows:
        key = old or new
        moved = after[key] < before[key] if old else after[key] > before[key]
        if not moved:
            fails.append(f'FAIL 変えた行の一覧 rule-lines-changed.tsv:{no}: 数が変わっていない行を載せている: {key}')
    return fails


def main(argv):
    if len(argv) != 4 or argv[1] not in ('size', 'lines', 'normalize'):
        print(__doc__, file=sys.stderr)
        return 2
    mode, root, fixture = argv[1], Path(argv[2]), Path(argv[3])
    if mode == 'normalize':
        sys.stdout.write('\n'.join(after_lines(root)) + '\n')
        return 0
    fails = check_size(root, fixture) if mode == 'size' else check_lines(root, fixture)
    for f in fails:
        print(f, file=sys.stderr)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
