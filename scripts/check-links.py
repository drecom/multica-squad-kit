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
INDENTED_RE = re.compile(r'^(?: {4}| {0,3}\t)')
COMMENT_START_RE = re.compile(r' {0,3}<!--')
ATX_RE = re.compile(r'#{1,6}(?:[ \t]|$)')
THEMATIC_RE = re.compile(r'(?:-[ \t]*){3,}$|(?:_[ \t]*){3,}$|(?:\*[ \t]*){3,}$')
SETEXT_RE = re.compile(r'(?:=+|-+)[ \t]*$')
ITEM_RE = re.compile(r'([-+*]|[0-9]{1,9}[.)])([ \t]+|$)')
TOKEN_RE = re.compile(r'<!--|`+|^[ \t]*~{3,}[^\n]*|^(?: {4}| {0,3}\t)[^\n]*', re.MULTILINE)
BACKTICKS_RE = re.compile(r'`+')
ESCAPE_RE = re.compile(r'\\[\[\]()]')
ANCHOR_RE = re.compile(r'<a\s[^>]*?\b(?:id|name)\s*=\s*"([^"]+)"')
LINK_RE = re.compile(
    r'\[(?:[^\[\]]|\[[^\[\]]*\])*\]'
    r'\(\s*(<[^>\n]*>|(?:[^\s()]|\([^\s()]*\))*)(?:\s+(?:"[^"]*"|\'[^\']*\'))?\s*\)')
# 参照の定義は段落の先頭にだけ置け、行き先は次の行に、題は次の行や複数行に書ける。
DEFINITION_RE = re.compile(
    r'\[(?P<label>[^\[\]^][^\[\]]*)\]:[ \t]*\n?[ \t]*(?P<target><[^>\n]*>|[^\s<]\S*)'
    r'(?:[ \t]*\n?[ \t]*(?:"[^"]*"|\'[^\']*\'|\([^()]*\)))?[ \t]*(?:\n|$)')
NAVIGATION_RE = re.compile(
    r'!?(?:' + LINK_RE.pattern
    + r'|\[(?P<label>[^\[\]]+)\](?:\[(?P<reference>[^\[\]]*)\])?)')
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


def leading(text):
    """行頭の空白の桁数と文字数を返す。タブは次の 4 の倍数の桁まで進む。"""
    column = chars = 0
    for char in text:
        if char == ' ':
            column += 1
        elif char == '\t':
            column += 4 - column % 4
        else:
            break
        chars += 1
    return column, chars


def list_item(rest, paragraph):
    """行がリストの項目の始まりなら、その一致を返す。段落を割れない形は None を返す。"""
    item = ITEM_RE.match(rest)
    if item and paragraph:
        number = item.group(1)[:-1]
        if not rest[item.end():].strip() or (number.isdigit() and int(number) != 1):
            return None
    return item


def ends_paragraph(content):
    """行が、前の段落を終えるブロックの始まり（見出し・区切り線・リストの項目）かを返す。"""
    column, chars = leading(content)
    rest = content[chars:]
    return column < 4 and bool(ATX_RE.match(rest) or THEMATIC_RE.match(rest)
                               or SETEXT_RE.match(rest) or list_item(rest, True))


class Blocks:
    """行ごとにブロックの種類を決める。字下げがコードか、段落の続きかは、前の行までの状態で決まる。

    種類は、blank（空行）、start（段落の始まり）、cont（段落の続き）、code（字下げのコード）、
    other（見出し・区切り線・フェンス・コメントのブロックなど、段落でないもの）のどれか。
    引用の深さごとに、リストの項目の中身の桁を積んで持つ。
    """

    def __init__(self, contents, depths):
        self.contents, self.depths = contents, depths
        self.kinds, self.offsets = [], []
        self.covered = {}  # 行 -> 'fence'（フェンスの中）、'html'（コメントのブロック）、'inline'（段落の中のコメントの続き）
        self.paragraph = False
        self.empty_item = False  # 直前の行が、空の項目の始まりか
        self.depth = 0
        self.stacks = {0: []}

    def kind(self, row):
        while len(self.kinds) <= row:
            self.step(len(self.kinds))
        return self.kinds[row]

    def record(self, kind, offset=0):
        self.kinds.append(kind)
        self.offsets.append(offset)

    def enter(self, depth):
        if depth != self.depth:
            self.paragraph = False
            for deeper in [d for d in self.stacks if d > depth]:
                del self.stacks[deeper]
            if depth > self.depth:
                # 行頭から始まる引用は、外側のリストの項目を閉じる（項目の中の引用は行頭に出ない）。
                for outer in self.stacks:
                    self.stacks[outer] = []
            self.depth = depth

    def step(self, row):
        content, depth = self.contents[row], self.depths[row]
        cover = self.covered.get(row)
        empty, self.empty_item = self.empty_item, False
        if cover == 'inline':
            return self.record('cont')
        if cover or not content.strip():
            self.enter(depth)
            if empty and not cover and self.stacks.get(depth):
                self.stacks[depth].pop()  # 空の項目のあとの空行は、その項目を閉じる。
            self.paragraph = False
            if cover and content.strip():
                # 項目の字下げに足りないコメントやフェンスは、その項目を閉じる。
                stack = self.stacks.setdefault(depth, [])
                column = leading(content)[0]
                while stack and column < stack[-1]:
                    stack.pop()
            return self.record('other' if cover else 'blank')
        column, chars = leading(content)
        rest = content[chars:]
        if depth != self.depth:
            interrupts = ATX_RE.match(rest) or THEMATIC_RE.match(rest) or list_item(rest, True)
            if depth < self.depth and self.paragraph and not interrupts:
                return self.record('cont')  # 引用の外に書いた段落の続き
            self.enter(depth)
        stack = self.stacks.setdefault(depth, [])
        matched = 0
        while matched < len(stack) and column >= stack[matched]:
            matched += 1
        base = stack[matched - 1] if matched else 0
        if column - base >= 4:
            if self.paragraph:
                return self.record('cont')  # 字下げのコードは、段落を割れない。
            del stack[matched:]
            return self.record('code')
        if self.paragraph and matched == len(stack) and SETEXT_RE.match(rest):
            self.paragraph = False
            return self.record('other')
        # 開いている項目より浅い行の項目は、兄弟の項目で、段落を割るための制限を受けない。
        item = None if THEMATIC_RE.match(rest) else list_item(rest, self.paragraph and matched == len(stack))
        block = ATX_RE.match(rest) or THEMATIC_RE.match(rest)
        if self.paragraph and matched < len(stack) and not (block or item):
            return self.record('cont')  # 項目の字下げが足りない段落の続き
        del stack[matched:]
        offset = chars
        if item and not block:
            self.paragraph = False  # 項目の始まりは、前の段落を終える。
        while item and not block:
            end = column + len(item.group(1))
            spaces = leading(item.group(2))[0]
            rest = rest[item.end():]
            if not rest.strip() or spaces > 4:
                stack.append(end + 1)  # 空の項目と、項目の中のコードの始まり
                self.paragraph = False
                self.empty_item = not rest.strip()
                return self.record('other')
            stack.append(end + spaces)
            column = stack[-1]
            offset = len(content) - len(rest)
            block = ATX_RE.match(rest) or THEMATIC_RE.match(rest)
            item = None if block else list_item(rest, False)
        if block:
            self.paragraph = False
            return self.record('other')
        if self.paragraph:
            return self.record('cont')
        # 参照の定義の 1 行だけの段落は、そこで終わり、次の字下げはコードになる。
        definition = DEFINITION_RE.match(rest)
        self.paragraph = not (definition and definition.end() == len(rest))
        return self.record('start', offset)


def analyze(path):
    """コメントを除いた原文と、コードも隠した文を、元の行番号とともに返す。

    あわせて、リンクを読む段落（ブロックの種類が段落の始まりと続きの行）の一覧を返す。
    """
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
    blocks = Blocks(contents, depths)

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
        if start == starts[row] and INDENTED_RE.match(contents[row]):
            if blocks.kind(row) == 'code':
                hide(start, position, hide_raw=True)
                continue
            position = start + len(contents[row]) - len(contents[row].lstrip(' \t'))
            continue
        if escaped(text, start):
            continue
        if token.group(0) == '<!--':
            end = text.find('-->', position)
            position = len(text) if end < 0 else end + 3
            hide(start, position, hide_raw=True)
            last = bisect_right(starts, max(position - 1, start)) - 1
            leader = contents[row][:start - starts[row]]
            if not leader.strip() and leading(leader)[0] < 4:
                blocks.covered.update(dict.fromkeys(range(row, last + 1), 'html'))
            else:
                blocks.covered.update(dict.fromkeys(range(row + 1, last + 1), 'inline'))
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
            blocks.covered.update(dict.fromkeys(range(row, stop), 'fence'))
            continue
        if not token.group(0).startswith('`'):
            continue

        # コードスパンは同じ段落の中でだけ、行をまたいで閉じられる。
        stop = row + 1
        if not HEADING_RE.match(contents[row]):
            while stop < len(contents):
                if (not contents[stop].strip() or depths[stop] != depths[row]
                        or FENCE_RE.match(contents[stop]) or ends_paragraph(contents[stop])
                        or COMMENT_START_RE.match(contents[stop])):
                    break
                stop += 1
        end = starts[stop] if stop < len(starts) else len(text)
        for closing in BACKTICKS_RE.finditer(text, position, end):
            if len(closing.group(0)) == len(token.group(0)):
                position = closing.end()
                hide(start, position)
                break

    raw_lines = ''.join(raw).split('\n')
    masked_lines = [ESCAPE_RE.sub('  ', hidden) for hidden in ''.join(masked).split('\n')]
    rows = [(number, original, hidden)
            for number, (original, hidden) in enumerate(zip(raw_lines, masked_lines), 1)]
    paragraphs = []
    if contents:
        blocks.kind(len(contents) - 1)
    for row, kind in enumerate(blocks.kinds):
        if kind == 'blank':
            continue
        line = masked_lines[row][blocks.offsets[row]:] if kind == 'start' else masked_lines[row]
        if kind == 'cont' and paragraphs:
            paragraphs[-1].append((row + 1, line.lstrip(' \t')))
        else:
            paragraphs.append([(row + 1, line.lstrip(' \t'))])
    return rows, [Paragraph(lines) for lines in paragraphs]


class Paragraph:
    """段落の中の行をつなげた文と、文の位置から元の行番号を引く表を持つ。"""

    def __init__(self, lines):
        self.text = '\n'.join(line for _, line in lines)
        self.numbers = [number for number, _ in lines]
        self.starts = []
        offset = 0
        for _, line in lines:
            self.starts.append(offset)
            offset += len(line) + 1

    def number(self, position):
        return self.numbers[bisect_right(self.starts, position) - 1]

    def definitions(self):
        """段落の先頭から続く参照の定義の一致と、そのあとの本文の始まりの位置を返す。"""
        found, position = [], 0
        while match := DEFINITION_RE.match(self.text, position):
            found.append(match)
            position = match.end()
        return found, position


def scan(path):
    return analyze(path)[0]


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
    """検査するリンクの行き先を、始まりの行の番号とともに返す。画像の先と、使っていない参照の定義も含む。"""
    for paragraph in analyze(path)[1]:
        definitions, position = paragraph.definitions()
        for definition in definitions:
            yield paragraph.number(definition.start()), definition.group('target')
        for match in LINK_RE.finditer(paragraph.text, position):
            yield paragraph.number(match.start()), match.group(1)


def navigation_targets(path):
    """本文から進めるリンクだけを返し、画像と未使用の参照定義を除く。"""
    paragraphs = analyze(path)[1]
    definitions = {}

    def label_key(label):
        return ' '.join(label.split()).casefold()

    parsed = []
    for paragraph in paragraphs:
        found, position = paragraph.definitions()
        parsed.append(position)
        for definition in found:
            definitions.setdefault(label_key(definition.group('label')), definition.group('target'))
    for paragraph, position in zip(paragraphs, parsed):
        for match in NAVIGATION_RE.finditer(paragraph.text, position):
            if match.group(0).startswith('!') and not escaped(paragraph.text, match.start()):
                continue
            number = paragraph.number(match.start())
            if match.group(1) is not None:
                yield number, match.group(1)
            else:
                label = match.group('reference') or match.group('label')
                target = definitions.get(label_key(label))
                if target is not None:
                    yield number, target


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
    for _, written in navigation_targets(index):
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
