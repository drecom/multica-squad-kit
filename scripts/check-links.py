#!/usr/bin/env python3
"""Markdown のリンクの行き先（ファイルと見出し）があることを検査する。

決まりは docs/doc-style.md の「リンクの検査」に従う。
引数がなければ、Git が追う Markdown のファイルをすべて検査し、
そのあとで docs/ の直下の文書がすべて索引の docs/README.md に載っているかを検査する。
ファイルを引数に渡すと、そのファイルのリンクだけを検査する。
--index <ファイル> を渡すと、そのファイルを索引として、同じディレクトリの直下の文書だけを検査する。
終了コードは、切れたリンクや索引にない文書がなければ 0、あれば 1、引数や Git の誤りは 2 とする。
"""
from bisect import bisect_right
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent

FENCE_RE = re.compile(r'^\s*(`{3,}|~{3,})')
QUOTE_RE = re.compile(r'^(?: {0,3}>[ \t]?)+')
HEADING_RE = re.compile(r'^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$')
TOKEN_RE = re.compile(r'<!--|`+|^[ \t]*~{3,}[^\n]*', re.MULTILINE)
BACKTICKS_RE = re.compile(r'`+')
BLOCK_RE = re.compile(r'^(?: {0,3}(?:#{1,6}[ \t]|(?:[-+*]|[0-9]+[.)])[ \t]|(?:-{3,}|_{3,}|\*{3,})[ \t]*$))')
ESCAPE_RE = re.compile(r'\\[\[\]()]')
ANCHOR_RE = re.compile(r'<a\s[^>]*?\b(?:id|name)\s*=\s*"([^"]+)"')
LINK_RE = re.compile(
    r'\[(?:[^\[\]]|\[[^\[\]]*\])*\]'
    r'\(\s*(<[^>\n]*>|(?:[^\s()]|\([^\s()]*\))*)(?:\s+(?:"[^"]*"|\'[^\']*\'))?\s*\)')
DEFINITION_RE = re.compile(r'^ {0,3}\[[^\]^][^\]]*\]:[ \t]*(<[^>]+>|\S+)')
SKIPPED_SCHEMES = ('http:', 'https:', 'mailto:', 'mention:')

# 見出しの文字から、文字の飾りを外す。コードの中身は、そのまま残す。
INLINE_RE = re.compile(
    r'(?P<code>(?<!`)(`+)(?!`).+?(?<!`)\2(?!`))'
    r'|(?P<link>!?\[(?P<text>[^\]]*)\](?:\([^)]*\)|\[[^\]]*\]))'
    r'|(?P<tag></?[A-Za-z][A-Za-z0-9-]*(?:\s[^>]*)?/?>)'
    r'|(?P<mark>\*\*|__|~~|\*)')


def render(text):
    def replace(match):
        if match.group('code'):
            return match.group(0).strip('`')
        if match.group('link'):
            return render(match.group('text'))
        return ''
    return INLINE_RE.sub(replace, text)


def slug(text):
    kept = []
    for char in render(text).strip().lower():
        category = unicodedata.category(char)
        if char == ' ':
            kept.append('-')
        elif char == '-' or category[0] in 'LMN' or category == 'Pc':
            kept.append(char)
    return ''.join(kept)


def escaped(text, position):
    start = position
    while start > 0 and text[start - 1] == '\\':
        start -= 1
    return (position - start) % 2 == 1


def scan(path):
    """コメントを除いた原文と、コードも隠した文を、元の行番号とともに返す。"""
    contents, depths, starts = [], [], []
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        quote = QUOTE_RE.match(line)
        contents.append(line[quote.end():] if quote else line)
        depths.append(quote.group(0).count('>') if quote else 0)
    text = '\n'.join(contents)
    offset = 0
    for content in contents:
        starts.append(offset)
        offset += len(content) + 1
    raw, masked = list(text), list(text)

    def hide(start, end, hide_raw=False):
        # 改行と位置を残し、エラーの行番号を変えない。
        for index in range(start, end):
            if text[index] != '\n':
                masked[index] = ' '
                if hide_raw:
                    raw[index] = ' '

    position = 0
    while token := TOKEN_RE.search(text, position):
        start = token.start()
        row = bisect_right(starts, start) - 1
        position = token.end()
        if escaped(text, start):
            continue
        if token.group(0) == '<!--':
            end = text.find('-->', position)
            position = len(text) if end < 0 else end + 3
            hide(start, position, hide_raw=True)
            continue

        # フェンスの中ではコメントもコードスパンも開かない。
        fence = FENCE_RE.match(contents[row])
        if fence and start <= starts[row] + fence.end() and not (
                fence.group(1)[0] == '`' and '`' in contents[row][fence.end():]):
            marker = fence.group(1)
            closing = re.compile(r'^[ \t]*' + re.escape(marker[0]) + '{' + str(len(marker)) + r',}[ \t]*$')
            stop = row + 1
            while stop < len(contents):
                if depths[stop] < depths[row] and contents[stop].strip():
                    break  # 引用の外に出たら、その中のフェンスも終わる。
                if depths[stop] == depths[row] and closing.fullmatch(contents[stop]):
                    stop += 1
                    break
                stop += 1
            position = starts[stop] if stop < len(starts) else len(text)
            hide(starts[row], position, hide_raw=True)
            continue
        if not token.group(0).startswith('`'):
            continue

        # コードスパンは同じ段落の中でだけ、行をまたいで閉じられる。
        stop = row + 1
        if not HEADING_RE.match(contents[row]):
            while stop < len(contents):
                if (not contents[stop].strip() or depths[stop] != depths[row]
                        or FENCE_RE.match(contents[stop]) or BLOCK_RE.match(contents[stop])):
                    break
                stop += 1
        end = starts[stop] if stop < len(starts) else len(text)
        for closing in BACKTICKS_RE.finditer(text, position, end):
            if len(closing.group(0)) == len(token.group(0)):
                position = closing.end()
                hide(start, position)
                break

    raw_lines = ''.join(raw).split('\n')
    masked_lines = ''.join(masked).split('\n')
    return [(number, original, ESCAPE_RE.sub('  ', hidden))
            for number, (original, hidden) in enumerate(zip(raw_lines, masked_lines), 1)]


anchor_cache = {}


def anchors_of(path):
    if path not in anchor_cache:
        found = set()
        seen = {}
        for _, raw, masked in scan(path):
            heading = HEADING_RE.match(raw)
            if heading:
                base = slug(heading.group(1))
                count = seen.get(base, 0)
                seen[base] = count + 1
                found.add(base if count == 0 else f'{base}-{count}')
            found.update(a.lower() for a in ANCHOR_RE.findall(masked))
        anchor_cache[path] = found
    return anchor_cache[path]


def exists_exact(path):
    """大文字小文字も含めて、ファイルかディレクトリがあるかを返す。"""
    parts = path.resolve().relative_to(Path(path.anchor)).parts
    current = Path(path.anchor)
    for part in parts:
        try:
            if part not in os.listdir(current):
                return False
        except OSError:
            return False
        current = current / part
    return True


def link_targets(path):
    for number, _, masked in scan(path):
        for match in LINK_RE.finditer(masked):
            yield number, match.group(1)
        definition = DEFINITION_RE.match(masked)
        if definition:
            yield number, definition.group(1)


def resolve(path, written):
    """リンクの先を、書いたファイルから解く。検査しない先は None を返す。"""
    target = written[1:-1] if written.startswith('<') else written
    if not target or target.lower().startswith(SKIPPED_SCHEMES):
        return None
    location, _, anchor = target.partition('#')
    location = unquote(location.partition('?')[0])
    if location.startswith('/'):
        resolved = ROOT / location.lstrip('/')
    elif location:
        resolved = path.parent / location
    else:
        resolved = path
    return Path(os.path.normpath(resolved)), anchor


def check_file(path):
    problems = []
    count = 0
    for number, written in link_targets(path):
        found = resolve(path, written)
        if found is None:
            continue
        resolved, anchor = found
        count += 1
        if not exists_exact(resolved):
            problems.append((number, written, 'のファイルがない'))
        elif anchor and resolved.is_file() and resolved.suffix.lower() == '.md':
            if unquote(anchor).lower() not in anchors_of(resolved):
                problems.append((number, written, 'の見出しがない'))
    return count, problems


def check_index(index):
    """索引に載っていない文書の名前と、検査した文書の数を返す。"""
    listed = set()
    for _, written in link_targets(index):
        found = resolve(index, written)
        if found and found[0].parent == index.parent:
            listed.add(found[0].name)
    documents = sorted(p.name for p in index.parent.glob('*.md')
                       if p.is_file() and p.name != 'README.md')
    return [name for name in documents if name not in listed], len(documents)


def report_index(index):
    """索引を検査し、結果を出して、見つけた数を返す。"""
    if not index.is_file():
        print(f'{show(index)}: 索引: ファイルがない', file=sys.stderr)
        return 1
    missing, total = check_index(index)
    for name in missing:
        print(f'{show(index)}: 索引: {name} が載っていない', file=sys.stderr)
    print(f'検査: 設計の文書 {total} 本、索引にない文書 {len(missing)} 本')
    return len(missing)


def tracked_markdown():
    result = subprocess.run(
        ['git', '-C', str(ROOT), 'ls-files', '-z', '--', '*.md'],
        capture_output=True, check=False)
    if result.returncode != 0:
        print('git ls-files が失敗した', file=sys.stderr)
        sys.exit(2)
    names = result.stdout.decode('utf-8').split('\0')
    return [ROOT / name for name in names if name and (ROOT / name).is_file()]


def show(path):
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def main(argv):
    index = None
    if '--index' in argv:
        position = argv.index('--index')
        if len(argv) != position + 2 or position != 0:
            print('--index は、索引のファイルを 1 つだけ渡す', file=sys.stderr)
            return 2
        index = Path(argv[1])
        if not index.is_file():
            print(f'{argv[1]}: ファイルがない', file=sys.stderr)
            return 2
        return 1 if report_index(index.resolve()) else 0
    files = []
    for arg in argv:
        path = Path(arg)
        if not path.is_file():
            print(f'{arg}: ファイルがない', file=sys.stderr)
            return 2
        files.append(path.resolve())
    if not argv:
        files = tracked_markdown()
    total = 0
    broken = 0
    for path in files:
        count, problems = check_file(path)
        total += count
        for number, written, reason in problems:
            print(f'{show(path)}:{number}: リンク: {written} {reason}', file=sys.stderr)
        broken += len(problems)
    print(f'検査: {len(files)} ファイル、リンク {total} 件、切れ {broken} 件')
    if not argv:
        broken += report_index(ROOT / 'docs' / 'README.md')
    return 1 if broken else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
