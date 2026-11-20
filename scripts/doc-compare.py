#!/usr/bin/env python3
"""文書の書き直しの前後で、4 つの要素の集合が一致するかを、ファイルごとに比べる。

要素は、コードブロックの中身・図（mermaid）・インラインコードの語・数値・リンク先である。
決まりと出力は docs/doc-style.md の「照合のコマンド」に従う。
--base は比べる前のコミットで、省略できない。--head を省略すると作業ツリーと比べる。
ファイルを省略すると、前と後で違う対象の文書をすべて比べる。
終了コードは、差がなければ 0、差があれば 1、コミットやパスの誤りは 2 とする。
"""
from bisect import bisect_right
import argparse
import hashlib
import posixpath
import re
import subprocess
import sys
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTRANCE = ['README.md', 'manual.md', 'CONTRIBUTING.md', 'EXTENSIONS.md', 'skeleton/README.md']
# 出力の並びは、ファイル、この種類の順、前（-）と後（+）、値の順にする。
SIGNS = ['-', '+']
KINDS = ['数値', 'インラインコード', 'コード', '図', 'リンク先']

QUOTE_RE = re.compile(r'^(?: {0,3}>[ \t]?)+')
ONE_QUOTE_RE = re.compile(r'^ {0,3}>[ \t]?')
FENCE_RE = re.compile(r'^\s*(`{3,}|~{3,})\s*(\S*)')
TOKEN_RE = re.compile(r'<!--|`+|~{3,}')
BACKTICKS_RE = re.compile(r'`+')
HEADING_RE = re.compile(r'^ {0,3}#{1,6}[ \t]')
BLOCK_RE = re.compile(r'^\s*(?:(?:[-+*]|[0-9]+[.)])[ \t]|(?:-{3,}|_{3,}|\*{3,})\s*$)')
LINK_RE = re.compile(
    r'(\[(?:[^\[\]]|\[[^\[\]]*\])*\])'
    r'\(\s*(<[^>\n]*>|(?:[^\s()]|\([^\s()]*\))*)(?:\s+(?:"[^"]*"|\'[^\']*\'))?\s*\)')
DEFINITION_RE = re.compile(r'^( {0,3}\[[^\]^][^\]]*\]:[ \t]*)(<[^>]+>|\S+)')
AUTOLINK_RE = re.compile(r'<((?:https?|mailto):[^>\s]*)>')
LIST_NUMBER_RE = re.compile(r'^\s*[0-9]+[.)]\s+')
NUMBER_RE = re.compile(r'[0-9]+(?:[.\-][0-9]+)*')
EXTERNAL_RE = re.compile(r'^(?:[A-Za-z][A-Za-z0-9+.-]*:|//)')


def is_target(path):
    return path in ENTRANCE or path == 'STYLE.md' or (path.startswith('docs/') and path.endswith('.md'))


def normalize_block(lines):
    stripped = [line.rstrip() for line in lines]
    return textwrap.dedent('\n'.join(stripped))


def normalize_link(target, path):
    if target.startswith('<') and target.endswith('>'):
        target = target[1:-1]
    if EXTERNAL_RE.match(target):
        return target
    location, hash_mark, anchor = target.partition('#')
    if location.startswith('/'):
        resolved = posixpath.normpath(location.lstrip('/'))
    elif location:
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), location))
    else:
        resolved = path
    return resolved + hash_mark + anchor


def elements(text, path):
    """文書から、種類ごとの要素の集合を取り出す。"""
    found = {kind: set() for kind in KINDS}
    lines = text.split('\n')
    starts, contents, depths = [], [], []
    offset = 0
    for line in lines:
        quote = QUOTE_RE.match(line)
        starts.append(offset)
        contents.append(line[quote.end():] if quote else line)
        depths.append(quote.group(0).count('>') if quote else 0)
        offset += len(line) + 1
    prose = list(text)

    def hide(start, end):
        for index in range(start, end):
            if text[index] != '\n':
                prose[index] = ' '

    def outside_quotes(line, depth):
        # フェンスを開いた外側の引用だけを外し、コード本文の > と >> は残す。
        for _ in range(depth):
            match = ONE_QUOTE_RE.match(line)
            if not match:
                return None if line.strip() else line
            line = line[match.end():]
        return line

    position = 0
    while token := TOKEN_RE.search(text, position):
        start = token.start()
        row = bisect_right(starts, start) - 1
        position = token.end()
        escape = start
        while escape > 0 and text[escape - 1] == '\\':
            escape -= 1
        if (start - escape) % 2:
            continue
        if token.group(0) == '<!--':
            end = text.find('-->', position)
            position = len(text) if end < 0 else end + 3
            hide(start, position)
            continue
        fence = FENCE_RE.match(contents[row])
        prefix = len(lines[row]) - len(contents[row])
        if (fence and start == starts[row] + prefix + fence.start(1)
                and not (fence.group(1)[0] == '`' and '`' in contents[row][fence.end(1):])):
            marker, language = fence.groups()
            closing = re.compile(r'^\s*' + re.escape(marker[0]) + '{' + str(len(marker)) + r',}\s*$')
            block = []
            stop = row + 1
            while stop < len(lines):
                content = outside_quotes(lines[stop], depths[row])
                if content is None:
                    break
                stop += 1
                if closing.fullmatch(content):
                    break
                block.append(content)
            found['図' if language.lower() == 'mermaid' else 'コード'].add(normalize_block(block))
            position = starts[stop] if stop < len(starts) else len(text)
            hide(starts[row], position)
            continue
        if not token.group(0).startswith('`'):
            continue
        stop = row + 1
        if not HEADING_RE.match(contents[row]):
            while stop < len(lines):
                content = contents[stop]
                if (not content.strip() or depths[stop] != depths[row]
                        or FENCE_RE.match(content) or HEADING_RE.match(content) or BLOCK_RE.match(content)):
                    break
                stop += 1
        end = starts[stop] if stop < len(starts) else len(text)
        for closing in BACKTICKS_RE.finditer(text, position, end):
            if len(closing.group(0)) == len(token.group(0)):
                parts = text[position:closing.start()].split('\n')
                value = ' '.join([parts[0]] + [outside_quotes(part, depths[row]) for part in parts[1:]])
                found['インラインコード'].add(value.strip())
                position = closing.end()
                hide(start, position)
                break
    for number, line in enumerate(''.join(prose).splitlines()):
        line = QUOTE_RE.sub('', line)

        def link(match):
            found['リンク先'].add(normalize_link(match.group(2), path))
            return match.group(1)

        def autolink(match):
            found['リンク先'].add(match.group(1))
            return ' '

        definition = DEFINITION_RE.match(line)
        if definition:
            found['リンク先'].add(normalize_link(definition.group(2), path))
            line = definition.group(1)
        line = LINK_RE.sub(link, line)
        line = AUTOLINK_RE.sub(autolink, line)
        # コードを隠した結果、後続の数値を箇条書きの番号と誤認しない。
        if LIST_NUMBER_RE.match(QUOTE_RE.sub('', lines[number])):
            line = LIST_NUMBER_RE.sub('', line)
        found['数値'].update(NUMBER_RE.findall(line))
    return found


def display(kind, value):
    if kind in ('コード', '図'):
        first = value.split('\n', 1)[0]
        return f'{hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]} {first[:40]}'
    return value


class GitError(Exception):
    pass


def git(*args):
    result = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, check=False)
    if result.returncode != 0:
        raise GitError(result.stderr.decode('utf-8', errors='replace').strip())
    return result.stdout


def resolve_commit(rev):
    try:
        return git('rev-parse', '--verify', '--quiet', f'{rev}^{{commit}}').decode().strip()
    except GitError:
        raise GitError(f'コミットがない: {rev}')


def read_at(rev, path):
    """コミットのファイルを読む。作業ツリーなら rev は None。ないファイルは None を返す。"""
    if rev is None:
        file = ROOT / path
        return file.read_text(encoding='utf-8', errors='replace') if file.is_file() else None
    try:
        return git('show', f'{rev}:{path}').decode('utf-8', errors='replace')
    except GitError:
        return None


def changed_targets(base, head):
    args = ['diff', '--name-only', '--no-renames', '-z', base] + ([head] if head else [])
    names = set(git(*args).decode('utf-8').split('\0'))
    if head is None:
        names.update(git('ls-files', '-z', '--others', '--exclude-standard').decode('utf-8').split('\0'))
    return sorted(name for name in names if name and is_target(name))


def to_repo_path(arg):
    path = Path(arg).resolve()
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        raise GitError(f'リポジトリの外のパス: {arg}')


def compare(path, base, head):
    before = read_at(base, path)
    after = read_at(head, path)
    old = elements(before, path) if before is not None else {kind: set() for kind in KINDS}
    new = elements(after, path) if after is not None else {kind: set() for kind in KINDS}
    rows = []
    for index, kind in enumerate(KINDS):
        for sign, values in (('-', old[kind] - new[kind]), ('+', new[kind] - old[kind])):
            for value in values:
                text = display(kind, value)
                rows.append((index, SIGNS.index(sign), text, f'差: {path} {kind} {sign} {text}'))
    return [row[3] for row in sorted(rows, key=lambda row: row[:3])]


def main(argv):
    parser = argparse.ArgumentParser(prog='doc-compare.py', description='書き直しの前後の要素を比べる')
    parser.add_argument('--base', required=True, help='比べる前のコミット')
    parser.add_argument('--head', help='比べる後のコミット。省略すると作業ツリー')
    parser.add_argument('files', nargs='*', help='比べるファイル。省略すると、前と後で違う対象の文書すべて')
    options = parser.parse_args(argv)
    try:
        base = resolve_commit(options.base)
        head = resolve_commit(options.head) if options.head else None
        if options.files:
            paths = [to_repo_path(arg) for arg in options.files]
            for path in paths:
                if read_at(base, path) is None and read_at(head, path) is None:
                    raise GitError(f'前にも後にもないファイル: {path}')
        else:
            paths = changed_targets(base, head)
    except GitError as error:
        print(str(error), file=sys.stderr)
        return 2
    lines = []
    for path in paths:
        lines += compare(path, base, head)
    print(f'照合: {base[:7]} → {head[:7] if head else "作業ツリー"}')
    for line in lines:
        print(line)
    print(f'照合の結果: 差 {len(lines)} 件')
    return 1 if lines else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
