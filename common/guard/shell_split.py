#!/usr/bin/env python3
# multica-squad-kit-managed
"""Bash とシェルの入力を、実行する 1 つずつのコマンドに分ける。PreToolUse のフックが照合する前の手順である。

標準入力のシェルの文を読み、標準出力に JSON を書く。分け方は docs/agent-guards.md の「Bash とシェルの入力は、次の順に読む」に従う。

1. ; & && || | |& ; ;; と改行で分ける。引用符の中の区切りでは分けない
2. シェルが実行する展開の中を、別のコマンドとして同じ順で読む。$( )・バッククォートは引用していない所と二重引用符の中、<( )・>( ) は引用していない所だけを読む
3. 引用していない区切りのヒアドキュメントは、本文の中の展開を読む。単引用符の中と、引用した区切りの本文は、データとして読まない
4. 先頭の NAME=値 は代入として読む。env・command・exec・nice・sudo は飛ばし、その先を実行するコマンドとする
5. bash・sh・zsh の -c と eval の文字列は、同じ順で読む
6. 引用符や展開が閉じないなど、分けられないときは、標準エラーに理由を書いて終了コード 3 で終わる

出力は {"commands": [...]} で、入れ子の中のコマンドも、同じ並びに平らに入れる。1 つのコマンドの欄は次のとおりである。
  assign:    先頭と、env・sudo の後の NAME=値。{name, value, dynamic, wrapper}
  words:     代入のあとの語すべて。env -i のような、飛ばす語も残す。{text, dynamic}
  argv:      飛ばす語を除いた、実行するコマンドと引数。{text, dynamic}。実行しない（command -v など）ときは空
  redirects: リダイレクト。{op, target, dynamic}。op は 2> のように fd を含み、<< と <<< で、ヒアドキュメントと here-string を分ける
tilde は、語が引用していない ~ で始まる、または引用のない語の = の直後が ~ のときだけ true で付く（単引用符と二重引用符の中の ~ は、シェルが展開しない）。
dynamic は、語が展開（$ やバッククォート）・引用していないグロブ・ブレース展開を含み、値が決まらないことを示す。
"""
import json
import os
import re
import shlex
import sys

MAX_DEPTH = 32
EXIT_UNSPLITTABLE = 3

RESERVED = {
    "if", "then", "elif", "else", "fi", "while", "until", "do", "done",
    "{", "}", "!", "time", "for", "select", "function", "coproc", "case",
}
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?\+?=")
GLOB_RE = re.compile(r"[*?]|\[[^\]]+\]|\{[^{}]*(,|\.\.)[^{}]*\}")
REDIR_RE = re.compile(r"&>>|&>|<<<|<<-|<<|<&|<>|<|>>|>&|>\||>")
CASE_SEP_RE = re.compile(r";;&|;;|;&")
ESAC_RE = re.compile(r"esac(?![^\s;&|()<>])")
FUNC_RE = re.compile(r"\(\s*\)")
SHELLS = ("bash", "sh", "zsh")


class Unsplittable(Exception):
    pass


class Word:
    __slots__ = ("text", "raw", "dynamic", "quoted")

    def __init__(self, text, raw, dynamic, quoted):
        self.text = text
        self.raw = raw
        self.dynamic = dynamic
        self.quoted = quoted


def synthetic(text):
    return Word(text, text, "$" in text or "`" in text, False)


class Parser:
    def __init__(self, s, out, depth=0):
        if depth > MAX_DEPTH:
            raise Unsplittable("入れ子が深すぎる")
        self.s = s
        self.i = 0
        self.out = out
        self.depth = depth
        self.pending = []

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < len(self.s) else ""

    # --- 空白・コメント・ヒアドキュメントの本文 ---

    def skip_blanks(self, newlines=False):
        while True:
            c = self.peek()
            if c in (" ", "\t") and c:
                self.i += 1
            elif c == "\\" and self.peek(1) == "\n":
                self.i += 2
            elif c == "#":
                while self.peek() not in ("", "\n"):
                    self.i += 1
            elif c == "\n" and newlines:
                self.i += 1
                self.read_heredocs()
            else:
                return

    def read_heredocs(self):
        pending, self.pending = self.pending, []
        s = self.s
        for delim, strip, quoted in pending:
            lines = []
            while self.i < len(s):
                j = s.find("\n", self.i)
                if j < 0:
                    line, self.i = s[self.i:], len(s)
                else:
                    line, self.i = s[self.i:j], j + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            if not quoted:
                Parser("\n".join(lines), self.out, self.depth + 1).scan_dq(False)

    # --- コマンドの並び ---

    def parse_all(self):
        self.parse_commands(None)

    def parse_commands(self, end, case_mode=False):
        s = self.s
        while True:
            self.skip_blanks()
            c = self.peek()
            if c == "":
                if end is not None or case_mode:
                    raise Unsplittable("閉じていない ( か case がある")
                return "eof"
            if c == "\n":
                self.i += 1
                self.read_heredocs()
                continue
            if case_mode:
                m = CASE_SEP_RE.match(s, self.i)
                if m:
                    self.i = m.end()
                    return "sep"
                m = ESAC_RE.match(s, self.i)
                if m:
                    self.i = m.end()
                    return "esac"
            if c == ";":
                self.i += 1
                continue
            if c == "&" and self.peek(1) != ">":
                self.i += 2 if self.peek(1) == "&" else 1
                continue
            if c == "|":
                self.i += 2 if self.peek(1) in ("|", "&") else 1
                continue
            if c == ")":
                if end == ")":
                    self.i += 1
                    return "end"
                raise Unsplittable("対応する ( のない ) がある")
            if c == "(":
                self.parse_group()
                continue
            before = self.i
            self.parse_simple()
            if self.i == before:
                raise Unsplittable("読み進められない文字がある")

    def parse_group(self):
        if self.peek(1) == "(" and self.try_arith(2):
            return
        self.i += 1
        self.parse_commands(")")

    def try_arith(self, offset):
        save = (self.i, len(self.out), list(self.pending))
        self.i += offset
        try:
            self.scan_arith()
            return True
        except Unsplittable:
            self.i, n, self.pending = save
            del self.out[n:]
            return False

    def scan_arith(self):
        depth = 0
        while True:
            c = self.peek()
            if c == "":
                raise Unsplittable("閉じていない (( がある")
            if c == "(":
                depth += 1
                self.i += 1
            elif c == ")":
                if depth == 0:
                    if self.peek(1) == ")":
                        self.i += 2
                        return
                    raise Unsplittable("(( の閉じ方が合わない")
                depth -= 1
                self.i += 1
            elif c == "$":
                self.read_expansion(True)
            elif c == "`":
                self.read_backtick(True)
            elif c == '"':
                self.i += 1
                self.scan_dq(True)
            elif c == "'":
                self.skip_single()
            elif c == "\\":
                self.i += 2
            else:
                self.i += 1

    def skip_single(self):
        j = self.s.find("'", self.i + 1)
        if j < 0:
            raise Unsplittable("単引用符が閉じていない")
        data = self.s[self.i + 1:j]
        self.i = j + 1
        return data

    # --- 1 つずつのコマンド ---

    def parse_simple(self):
        s = self.s
        words, assigns, redirects = [], [], []
        cond = False
        fd = ""
        while True:
            self.skip_blanks()
            c = self.peek()
            if c == "":
                break
            if cond:
                if c == "\n":
                    break
            else:
                if c in "\n;|)":
                    break
                if c == "(":
                    m = FUNC_RE.match(s, self.i)
                    if m and len(words) == 1 and not assigns:
                        self.i = m.end()
                        words = []
                        continue
                    break
                if c == "&" and self.peek(1) != ">":
                    break
                m = REDIR_RE.match(s, self.i) if not (c in "<>" and self.peek(1) == "(") else None
                if m:
                    op = fd + m.group()
                    fd = ""
                    self.i = m.end()
                    while self.peek() in (" ", "\t") and self.peek():
                        self.i += 1
                    target = self.read_word()
                    if target.raw == "":
                        raise Unsplittable("リダイレクト %s の先がない" % op)
                    redirects.append(with_tilde({"op": op, "target": target.text, "dynamic": target.dynamic}, target))
                    if m.group() in ("<<", "<<-"):
                        self.pending.append((target.text, m.group() == "<<-", target.quoted))
                    continue
            w = self.read_word(cond)
            if w.raw == "":
                raise Unsplittable("読み進められない文字がある")
            if (not cond and not w.quoted and w.raw.isdigit()
                    and self.peek() in ("<", ">") and self.peek() and self.peek(1) != "("):
                fd = w.raw
                continue
            if not words and not cond:
                m = ASSIGN_RE.match(w.raw)
                if m:
                    value = w.text[w.text.index("=") + 1:]
                    dynamic = w.dynamic
                    if w.raw.endswith("=") and self.peek() == "(":
                        value, dynamic = self.read_array()
                    assigns.append({"name": m.group(1), "value": value, "dynamic": dynamic, "wrapper": False})
                    continue
                if w.raw in RESERVED and not redirects:
                    if w.raw == "case":
                        self.parse_case()
                    elif w.raw == "function":
                        self.skip_function_head()
                    return
            words.append(w)
            if len(words) == 1 and w.raw == "[[":
                cond = True
            elif cond and w.raw == "]]":
                cond = False
        if not words and not assigns and not redirects:
            return
        self.out.append(self.build(words, assigns, redirects))

    def read_array(self):
        self.i += 1
        parts, dynamic = [], False
        while True:
            self.skip_blanks(True)
            if self.peek() == "":
                raise Unsplittable("閉じていない配列の代入がある")
            if self.peek() == ")":
                self.i += 1
                break
            w = self.read_word()
            if w.raw == "":
                raise Unsplittable("配列の代入を読めない")
            parts.append(w.text)
            dynamic = dynamic or w.dynamic
        return "(" + " ".join(parts) + ")", dynamic

    def skip_function_head(self):
        self.skip_blanks()
        self.read_word()
        self.skip_blanks()
        m = FUNC_RE.match(self.s, self.i)
        if m:
            self.i = m.end()

    def parse_case(self):
        s = self.s
        self.skip_blanks()
        if self.read_word().raw == "":
            raise Unsplittable("case の対象がない")
        self.skip_blanks(True)
        if self.read_word().raw != "in":
            raise Unsplittable("case に in がない")
        while True:
            self.skip_blanks(True)
            m = ESAC_RE.match(s, self.i)
            if m:
                self.i = m.end()
                return
            if self.peek() == "":
                raise Unsplittable("閉じていない case がある")
            if self.peek() == "(":
                self.i += 1
            while True:
                self.skip_blanks()
                if self.read_word().raw == "":
                    raise Unsplittable("case のパターンを読めない")
                self.skip_blanks()
                c = self.peek()
                if c == "|":
                    self.i += 1
                    continue
                if c == ")":
                    self.i += 1
                    break
                raise Unsplittable("case のパターンの閉じ方が合わない")
            if self.parse_commands(None, True) == "esac":
                return

    # --- 語と展開 ---

    def read_word(self, cond=False):
        s = self.s
        start = self.i
        text, unq = [], []
        dynamic = quoted = False
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\n":
                break
            if not cond:
                if c in ";&|()":
                    break
                if c in "<>" and self.peek(1) != "(":
                    break
            if c == "\\":
                nx = self.peek(1)
                if nx == "\n":
                    self.i += 2
                    continue
                quoted = True
                if nx == "":
                    text.append("\\")
                    self.i += 1
                else:
                    text.append(nx)
                    self.i += 2
                unq.append("\0")
            elif c == "'":
                text.append(self.skip_single())
                quoted = True
                unq.append("\0")
            elif c == '"':
                self.i += 1
                t, d = self.scan_dq(True)
                text.append(t)
                dynamic = dynamic or d
                quoted = True
                unq.append("\0")
            elif c == "$" and self.peek(1) == "'":
                self.i += 2
                buf = []
                while True:
                    ch = self.peek()
                    if ch == "":
                        raise Unsplittable("$'' が閉じていない")
                    if ch == "'":
                        self.i += 1
                        break
                    if ch == "\\":
                        buf.append(self.s[self.i:self.i + 2])
                        self.i += 2
                    else:
                        buf.append(ch)
                        self.i += 1
                body = "".join(buf)
                text.append(body)
                dynamic = dynamic or "\\" in body
                quoted = True
                unq.append("\0")
            elif c == "$" and self.peek(1) == '"':
                self.i += 2
                t, d = self.scan_dq(True)
                text.append(t)
                dynamic = dynamic or d
                quoted = True
                unq.append("\0")
            elif c == "$":
                t, d = self.read_expansion(False)
                text.append(t)
                dynamic = dynamic or d
                unq.append("\0")
            elif c == "`":
                text.append(self.read_backtick(False))
                dynamic = True
                unq.append("\0")
            elif c in "<>":
                p = self.i
                self.i += 2
                self.parse_commands(")")
                text.append(s[p:self.i])
                dynamic = True
                unq.append("\0")
            else:
                text.append(c)
                unq.append(c)
                self.i += 1
        if GLOB_RE.search("".join(unq)):
            dynamic = True
        return Word("".join(text), s[start:self.i], dynamic, quoted)

    def read_expansion(self, in_dq):
        s = self.s
        start = self.i
        n1 = self.peek(1)
        if n1 == "(":
            if self.peek(2) == "(" and self.try_arith(3):
                return s[start:self.i], True
            self.i += 2
            self.parse_commands(")")
            return s[start:self.i], True
        if n1 == "{":
            self.i += 2
            self.scan_brace(in_dq)
            return s[start:self.i], True
        if n1 and (n1.isalpha() or n1 == "_"):
            self.i += 2
            while self.peek() and (self.peek().isalnum() or self.peek() == "_"):
                self.i += 1
            return s[start:self.i], True
        if n1 and n1 in "0123456789@*#?$!-":
            self.i += 2
            return s[start:self.i], True
        self.i += 1
        return "$", False

    def scan_brace(self, in_dq):
        while True:
            c = self.peek()
            if c == "":
                raise Unsplittable("閉じていない ${ がある")
            if c == "}":
                self.i += 1
                return
            if c == "\\":
                self.i += 2
            elif c == "'" and not in_dq:
                self.skip_single()
            elif c == '"':
                self.i += 1
                self.scan_dq(True)
            elif c == "$":
                self.read_expansion(True)
            elif c == "`":
                self.read_backtick(in_dq)
            else:
                self.i += 1

    def read_backtick(self, in_dq):
        s = self.s
        start = self.i
        self.i += 1
        buf = []
        while True:
            c = self.peek()
            if c == "":
                raise Unsplittable("バッククォートが閉じていない")
            if c == "\\":
                nx = self.peek(1)
                if nx in ("`", "\\", "$") and nx or (in_dq and nx == '"'):
                    buf.append(nx)
                    self.i += 2
                else:
                    buf.append(c)
                    self.i += 1
            elif c == "`":
                self.i += 1
                break
            else:
                buf.append(c)
                self.i += 1
        Parser("".join(buf), self.out, self.depth + 1).parse_all()
        return s[start:self.i]

    def scan_dq(self, terminated):
        """二重引用符の中（terminated）か、引用していない区切りのヒアドキュメントの本文を読み、展開の中を読む。"""
        buf = []
        dynamic = False
        while True:
            c = self.peek()
            if c == "":
                if terminated:
                    raise Unsplittable("二重引用符が閉じていない")
                return "".join(buf), dynamic
            if terminated and c == '"':
                self.i += 1
                return "".join(buf), dynamic
            if c == "\\":
                nx = self.peek(1)
                if nx and (nx in "$`\\" or (terminated and nx == '"')):
                    buf.append(nx)
                    self.i += 2
                elif nx == "\n":
                    self.i += 2
                else:
                    buf.append(c)
                    self.i += 1
            elif c == "$":
                t, d = self.read_expansion(True)
                buf.append(t)
                dynamic = dynamic or d
            elif c == "`":
                buf.append(self.read_backtick(terminated))
                dynamic = True
            else:
                buf.append(c)
                self.i += 1

    # --- コマンドの組み立て ---

    def build(self, words, assigns, redirects):
        argv, extra = unwrap(words)
        shell_text = shell_string(argv)
        if shell_text is not None:
            Parser(shell_text, self.out, self.depth + 1).parse_all()
        return {
            "assign": assigns + extra,
            "words": [with_tilde({"text": w.text, "dynamic": w.dynamic}, w) for w in words],
            "argv": [with_tilde({"text": w.text, "dynamic": w.dynamic}, w) for w in argv],
            "redirects": redirects,
        }


def with_tilde(entry, word):
    """語が引用していない ~ で始まるとき、または引用のない語の = の直後が ~ のとき（シェルや、渡された先のプログラムが ~ を展開しうるとき）だけ、tilde を足す。"""
    if word.raw.startswith("~") or (not word.quoted and "=~" in word.raw):
        entry["tilde"] = True
    return entry


# --- 飛ばすコマンド ---

def base_name(w):
    return None if w.dynamic else os.path.basename(w.text)


def skip_options(work, i, short_arg, long_arg):
    n = len(work)
    while i < n:
        t = work[i].text
        if t == "--":
            return i + 1
        if t.startswith("--"):
            i += 1
            if "=" not in t and t in long_arg:
                i += 1
        elif len(t) > 1 and t[0] == "-":
            body = t[1:]
            i += 1
            if not body.isdigit():
                for idx, ch in enumerate(body):
                    if ch in short_arg:
                        if idx == len(body) - 1:
                            i += 1
                        break
        else:
            return i
    return i


def take_assignments(work, i, extra):
    while i < len(work) and not work[i].quoted and ASSIGN_RE.match(work[i].raw):
        w = work[i]
        extra.append({"name": ASSIGN_RE.match(w.raw).group(1), "value": w.text[w.text.index("=") + 1:],
                      "dynamic": w.dynamic, "wrapper": True})
        i += 1
    return i


def unwrap_env(work, i, extra):
    n = len(work)
    while i < n:
        t = work[i].text
        if t == "--":
            i += 1
            break
        if t == "-":
            i += 1
            continue
        if t.startswith("--"):
            name, eq, val = t.partition("=")
            i += 1
            if name in ("--unset", "--chdir", "--argv0", "--split-string") and not eq:
                if i >= n:
                    break
                val = work[i].text
                i += 1
            if name == "--split-string":
                work[i:i] = [synthetic(x) for x in split_string(val)]
        elif len(t) > 1 and t[0] == "-":
            body = t[1:]
            i += 1
            for idx, ch in enumerate(body):
                if ch in "uCSaP":
                    val = body[idx + 1:]
                    if not val and i < n:
                        val = work[i].text
                        i += 1
                    if ch == "S":
                        work[i:i] = [synthetic(x) for x in split_string(val)]
                    break
        else:
            break
    return take_assignments(work, i, extra)


def split_string(value):
    try:
        return shlex.split(value)
    except ValueError:
        raise Unsplittable("env -S の文字列が閉じていない")


def unwrap(words):
    work = list(words)
    extra = []
    i = 0
    while i < len(work):
        base = base_name(work[i])
        if base == "env":
            i = unwrap_env(work, i + 1, extra)
        elif base == "command":
            j = skip_options(work, i + 1, "", ())
            flags = "".join(w.text for w in work[i + 1:j] if w.text.startswith("-") and w.text != "--")
            if "v" in flags or "V" in flags:
                return [], extra
            i = j
        elif base == "exec":
            i = skip_options(work, i + 1, "a", ())
        elif base == "nice":
            i = skip_options(work, i + 1, "n", ("--adjustment",))
        elif base == "sudo":
            i = skip_options(work, i + 1, "ughpCDRTUrt",
                             ("--user", "--group", "--host", "--prompt", "--close-from", "--chdir", "--chroot",
                              "--command-timeout", "--other-user", "--role", "--type"))
            i = take_assignments(work, i, extra)
        else:
            break
    return work[i:], extra


def shell_string(argv):
    """argv が bash・sh・zsh の -c か eval なら、渡す文字列を返す。"""
    if not argv:
        return None
    base = base_name(argv[0])
    if base == "eval":
        args = [w.text for w in argv[1:]]
        if args and args[0] == "--":
            args = args[1:]
        return " ".join(args) if args else None
    if base not in SHELLS:
        return None
    has_c = False
    j = 1
    while j < len(argv):
        a = argv[j].text
        if a == "--":
            j += 1
            break
        if a.startswith("--"):
            j += 2 if a in ("--rcfile", "--init-file") else 1
        elif len(a) > 1 and a[0] in "-+":
            if a[0] == "-" and "c" in a[1:]:
                has_c = True
            j += 1
            if "o" in a[1:] or "O" in a[1:]:
                j += 1
        else:
            break
    if has_c and j < len(argv):
        return argv[j].text
    return None


def split_script(text):
    out = []
    Parser(text, out).parse_all()
    return {"commands": out}


def main():
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    sys.setrecursionlimit(5000)
    try:
        result = split_script(text)
    except Unsplittable as e:
        sys.stderr.write("分けられない: %s\n" % e)
        return EXIT_UNSPLITTABLE
    except RecursionError:
        sys.stderr.write("分けられない: 入れ子が深すぎる\n")
        return EXIT_UNSPLITTABLE
    sys.stdout.write(json.dumps(result, ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
