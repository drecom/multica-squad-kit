#!/usr/bin/env python3
"""人間が読む文書の書き方のうち、機械で判定できる決まりを検査する。

決まりと数え方は docs/doc-style.md の「検査」に従う。
引数がなければ、対象の文書のうち scripts/style-exempt.txt にないものをすべて検査する。
ファイルを引数に渡すと、一覧にあっても検査する。
終了コードは、違反がなければ 0、違反があれば 1、引数や一覧の誤りは 2 とする。
"""
from bisect import bisect_right
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXEMPT = ROOT / 'scripts' / 'style-exempt.txt'
ENTRANCE = ['README.md', 'manual.md', 'CONTRIBUTING.md', 'EXTENSIONS.md', 'skeleton/README.md']
CODE = ''  # インラインコードの代わりに置く 1 字
HIDDEN = '\ue001'  # 非表示の位置。末尾空白を調べてから取り除く

JA = 'ぁ-ゖァ-ヺー々㐀-䶿一-鿿'
ALNUM = f'A-Za-z0-9{CODE}'
PUNCT = '、。，．「」（）？！'
POLITE = re.compile('(です|ます|ください|ません|でした|ました|でしょう|ましょう)$')

TOKEN_RE = re.compile(r'<!--|`+|~{3,}')
BACKTICKS_RE = re.compile(r'`+')
LINK_RE = re.compile(r'!?\[([^\]]*)\]\(((?:[^()]|\([^()]*\))*)\)')
REFLINK_RE = re.compile(r'!?\[([^\]]*)\]\[[^\]]*\]')
FENCE_RE = re.compile(r'^\s*(`{3,}|~{3,})\s*([^`\s]*)')
HEADING_RE = re.compile(r'^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$')
ITEM_RE = re.compile(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$')
QUOTE_RE = re.compile(r'^\s*(?:>\s?)+')
ALERT_RE = re.compile(r'^\s*\[!\w+\]\s*$')
RULE_RE = re.compile(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$')
DEF_RE = re.compile(r'^\s*\[[^\]]+\]:\s')
SEPARATOR_RE = re.compile(r'^\|?[\s:|-]+\|?$')
REPO_URL_RE = re.compile(r'github\.com/[^/\s]+/multica-squad-kit/(?:blob|tree)/')
LABELS = {'こちら', 'ここ', 'リンク'}


def mask_context(text):
    """出現順に文脈を決め、コメントとコードスパンだけを隠す。フェンスは検査へ残す。"""
    lines = text.split('\n')
    starts, contents, depths = [], [], []
    offset = 0
    for line in lines:
        quote = QUOTE_RE.match(line)
        starts.append(offset)
        contents.append(line[quote.end():] if quote else line)
        depths.append(quote.group(0).count('>') if quote else 0)
        offset += len(line) + 1
    masked = list(text)

    def hide(start, end, code=False):
        for index in range(start, end):
            if text[index] != '\n':
                masked[index] = HIDDEN
        if code:
            masked[start] = CODE

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
            marker = fence.group(1)
            closing = re.compile(r'^\s*' + re.escape(marker[0]) + '{' + str(len(marker)) + r',}\s*$')
            stop = row + 1
            while stop < len(lines):
                if depths[stop] < depths[row] and contents[stop].strip():
                    break
                if depths[stop] == depths[row] and closing.fullmatch(contents[stop]):
                    stop += 1
                    break
                stop += 1
            position = starts[stop] if stop < len(starts) else len(text)
            continue
        if not token.group(0).startswith('`'):
            continue
        stop = row + 1
        if not HEADING_RE.match(contents[row]):
            while stop < len(lines):
                content = contents[stop]
                if (not content.strip() or depths[stop] != depths[row]
                        or FENCE_RE.match(content) or HEADING_RE.match(content)
                        or ITEM_RE.match(content) or RULE_RE.match(content)):
                    break
                stop += 1
        end = starts[stop] if stop < len(starts) else len(text)
        for closing in BACKTICKS_RE.finditer(text, position, end):
            if len(closing.group(0)) == len(token.group(0)):
                position = closing.end()
                hide(start, position, code=True)
                break
    return ''.join(masked)


def to_text(masked):
    """インラインコードを置き換えた文字列から、表示される文字列とリンクの先・文字を取り出す。"""
    links = []

    def link(match):
        links.append((match.group(1), match.group(2)))
        return match.group(1)

    text = LINK_RE.sub(link, masked)
    def reference(match):
        links.append((match.group(1), ''))
        return match.group(1)

    text = REFLINK_RE.sub(reference, text)
    text = re.sub(r'</?[A-Za-z][^>]*>', '', text)
    text = text.replace('**', '')
    text = re.sub(r'\\([\\*_{}\[\]()#+.!|<>-])', r'\1', text)
    return text, links


def split_sentences(text):
    sentences, start, depth = [], 0, 0
    for i, ch in enumerate(text):
        if ch in '「（':
            depth += 1
        elif ch in '」）':
            depth = max(0, depth - 1)
        elif ch in '。？！' and depth == 0:
            sentences.append(text[start:i + 1])
            start = i + 1
    sentences.append(text[start:])
    return [s for s in sentences if s.strip()]


def length(sentence):
    """文の字数。半角の空白と、文の終わりの「。」「？」「！」は数えない。"""
    return len(re.sub('[。？！]$', '', sentence.rstrip()).replace(' ', ''))


def check_unit(kind, number, raw, report):
    """段落・項目・表のセル・見出し・引用の 1 つを検査する。"""
    masked = raw
    text, links = to_text(masked)
    text = text.strip()
    if '![' in masked or '<img' in masked:
        report(number, '図', '画像を置かず、図は mermaid のコードブロックにする')
    if REPO_URL_RE.search(masked):
        report(number, 'リンク', 'リポジトリの中のファイルを GitHub の URL で指さない')
    for label, _ in links:
        if label.strip() in LABELS:
            report(number, 'リンク', 'リンクの文字を「こちら」「ここ」「リンク」にしない')
    if not text:
        return
    if re.search('[，．]', text):
        report(number, '句読点', '全角のカンマ「，」とピリオド「．」を使わない')
    if kind in ('item', 'cell', 'heading') and text.endswith('。'):
        report(number, '句読点', '箇条書きの項目・表のセル・見出しの末尾に「。」を付けない')
    if re.search(r'\([^)]*[' + JA + r'][^)]*\)', text):
        report(number, '句読点', '日本語を含む括弧は全角の（）にする')
    if re.search('[Ａ-Ｚａ-ｚ０-９　｡-ﾟ]', text):
        report(number, '全角と半角', '全角の英数字・全角の空白・半角のカタカナを使わない')
    if re.search(f'[{JA}](?! )[{ALNUM}]|[{ALNUM}](?! )[{JA}]|[{JA}] {{2,}}[{ALNUM}]|[{ALNUM}] {{2,}}[{JA}]', text):
        report(number, '全角と半角', '日本語と、半角の英数字・インラインコードの間に、半角の空白を 1 つ置く')
    if re.search(f'[ 　][{PUNCT}]|[{PUNCT}][ 　]', text):
        report(number, '全角と半角', '句読点と括弧の前後に空白を置かない')
    if kind == 'heading':
        return
    sentences = split_sentences(text)
    for sentence in sentences:
        quoteless = re.sub('「[^」]*」', '「」', sentence).rstrip()
        core = re.sub('[。？！）」 ]+$', '', quoteless)
        if POLITE.search(core):
            report(number, '文体', '文末を「です」「ます」にしない')
        if length(sentence) > 80:
            report(number, '文と段落の長さ', f'1 文は 80 字まで（{length(sentence)} 字）')
        if sentence.count('、') > 3:
            report(number, '文と段落の長さ', f'1 文の読点は 3 つまで（{sentence.count("、")} 個）')
    if kind in ('paragraph', 'quote'):
        if len(sentences) > 4:
            report(number, '文と段落の長さ', f'1 段落は 4 文まで（{len(sentences)} 文）')
        total = sum(length(s) for s in sentences)
        if total > 240:
            report(number, '文と段落の長さ', f'1 段落は 240 字まで（{total} 字）')
    elif len(sentences) > 2:
        what = '箇条書きの 1 項目' if kind == 'item' else '表のセル'
        report(number, '文と段落の長さ', f'{what}は 2 文まで（{len(sentences)} 文）')


def check_file(path):
    """違反を (行, 節, 決まり) の並びで返す。"""
    violations = []

    def report(number, section, rule):
        violations.append((number, section, rule))

    lines = mask_context(path.read_text(encoding='utf-8')).split('\n')
    buffer = None  # [kind, 開始行, [行の文字列]]
    fence = None  # (記号, 長さ, 言語, 引用の中か)
    stack = []  # 箇条書きの字下げ
    last_heading = None  # (行, 階層)
    heading_open = False  # 見出しの直後で、まだ本文が来ていない
    h1_count = 0
    first_content = None

    def flush():
        nonlocal buffer
        if buffer:
            kind, number, parts = buffer
            if len(parts) > 1:
                what = '段落' if kind != 'item' else '箇条書きの項目'
                report(number + 1, '改行', f'{what}は途中で改行しない')
            check_unit(kind, number, ''.join(p.strip() for p in parts), report)
        buffer = None

    for index, line in enumerate(lines):
        number = index + 1
        if fence and fence[3] and not QUOTE_RE.match(line):
            fence = None  # 引用が終わると、中のコードブロックも終わる
        if fence:
            content = QUOTE_RE.sub('', line) if fence[3] else line
            stripped = content.strip()
            if stripped.startswith(fence[0] * fence[1]) and set(stripped) == {fence[0]}:
                fence = None
            elif fence[2] in ('bash', 'sh', 'zsh', 'shell') and re.match(r'^\s*\$ ', content):
                report(number, '箇条書き・表・コード・注記', 'コマンドの前に、プロンプトの「$」を付けない')
            continue
        if line != line.rstrip():
            report(number, '改行', '行の末尾に空白を置かない')
        line = line.replace(HIDDEN, '')
        stripped = line.strip()
        if not stripped:
            flush()
            continue
        if first_content is None:
            first_content = number
        fence_match = FENCE_RE.match(line)
        heading = HEADING_RE.match(line)
        item = ITEM_RE.match(line)
        if fence_match:
            flush()
            heading_open = False
            fence = (fence_match.group(1)[0], len(fence_match.group(1)), fence_match.group(2), False)
            if not fence_match.group(2):
                report(number, '箇条書き・表・コード・注記', 'コードブロックには言語を書く')
        elif heading:
            flush()
            if heading_open:
                report(number, '文書の種類ごとの構成', '見出しのすぐ後に見出しを続けず、節の結論を書く')
            level = len(heading.group(1))
            if level == 1:
                h1_count += 1
                if number != first_content or h1_count > 1:
                    report(number, '文書の種類ごとの構成', 'H1 は文書の先頭の 1 つだけにする')
            elif last_heading is None:
                report(number, '文書の種類ごとの構成', 'H1 は文書の先頭の 1 つだけにする')
            elif level > last_heading + 1:
                report(number, '文書の種類ごとの構成', '見出しの階層は 1 つずつ下げる')
            if level > 4:
                report(number, '文書の種類ごとの構成', '見出しは #### までにする')
            last_heading = level
            heading_open = True
            check_unit('heading', number, heading.group(2), report)
        elif stripped.startswith('|'):
            flush()
            heading_open = False
            if not SEPARATOR_RE.match(stripped):
                cells = re.split(r'(?<!\\)\|', stripped)
                for cell in cells[1:-1] if stripped.endswith('|') else cells[1:]:
                    check_unit('cell', number, cell, report)
        elif item:
            flush()
            heading_open = False
            indent = len(item.group(1).expandtabs(4))
            while stack and stack[-1] >= indent:
                stack.pop()
            stack.append(indent)
            if len(stack) > 2:
                report(number, '箇条書き・表・コード・注記', '箇条書きの入れ子は 1 段までにする')
            buffer = ['item', number, [item.group(3)]]
        elif QUOTE_RE.match(line):
            heading_open = False
            content = QUOTE_RE.sub('', line)
            quoted_fence = FENCE_RE.match(content)
            if quoted_fence:
                flush()
                fence = (quoted_fence.group(1)[0], len(quoted_fence.group(1)), quoted_fence.group(2), True)
                if not quoted_fence.group(2):
                    report(number, '箇条書き・表・コード・注記', 'コードブロックには言語を書く')
            elif ALERT_RE.match(content):
                flush()
            elif buffer and buffer[0] == 'quote':
                buffer[2].append(content)
            else:
                flush()
                buffer = ['quote', number, [content]]
        elif RULE_RE.match(line) or DEF_RE.match(line) or stripped.startswith('<'):
            flush()
            heading_open = False
            masked = stripped
            if '<img' in masked:
                report(number, '図', '画像を置かず、図は mermaid のコードブロックにする')
            if REPO_URL_RE.search(masked):
                report(number, 'リンク', 'リポジトリの中のファイルを GitHub の URL で指さない')
        else:
            heading_open = False
            if buffer:
                buffer[2].append(line)
            else:
                if not line.startswith(' ') and not line.startswith('\t'):
                    stack.clear()
                buffer = ['paragraph', number, [line]]
    flush()
    if h1_count == 0:
        report(first_content or 1, '文書の種類ごとの構成', 'H1 は文書の先頭の 1 つだけにする')
    return sorted(violations)


def targets():
    found = [p for p in ENTRANCE if (ROOT / p).is_file()]
    found += sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'docs').rglob('*.md'))
    if (ROOT / 'STYLE.md').is_file():
        found.append('STYLE.md')
    return found


def read_exempt(candidates):
    """対象外の一覧を読む。誤りは (行, 内容) の並びで返す。"""
    if not EXEMPT.is_file():
        return set(), []
    errors, paths, previous = [], [], None
    lines = EXEMPT.read_text(encoding='utf-8').split('\n')
    if lines[-1] == '':
        lines.pop()
    for number, line in enumerate(lines, 1):
        if not line.strip():
            errors.append((number, '空の行がある'))
            continue
        if line not in candidates:
            errors.append((number, f'対象の文書でないか、ファイルがない: {line}'))
        if previous is not None and line == previous:
            errors.append((number, f'重なっている: {line}'))
        elif previous is not None and line < previous:
            errors.append((number, f'名前順でない: {line}'))
        previous = line
        paths.append(line)
    return set(paths), errors


def main(argv):
    candidates = targets()
    exempt, errors = read_exempt(set(candidates))
    if errors:
        for number, message in errors:
            print(f'scripts/style-exempt.txt:{number}: {message}', file=sys.stderr)
        return 2
    if argv:
        files = []
        for arg in argv:
            path = Path(arg).resolve()
            if not path.is_file():
                print(f'{arg}: ファイルがない', file=sys.stderr)
                return 2
            files.append(path)
    else:
        files = [ROOT / p for p in candidates if p not in exempt]
    count = 0
    for path in files:
        try:
            shown = path.relative_to(ROOT).as_posix()
        except ValueError:
            shown = str(path)
        for number, section, rule in check_file(path):
            print(f'{shown}:{number}: {section}: {rule}', file=sys.stderr)
            count += 1
    print(f'検査: {len(files)} ファイル、違反 {count} 件')
    return 1 if count else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
