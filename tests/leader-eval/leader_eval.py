"""リーダーの評価の補助。場面の読み取り、スタブの CLI、1 回の実行、採点、集計を持つ。

run.sh が `python3 -I` で呼ぶ。サブコマンド:
  scene <scene.md>                      場面を JSON にして出す（形が不正なら 1 で終わる）
  picks <scenes> <values.json>           pick の見本の欠けと例外を確認する
  stub <名前> <引数...>                 スタブの CLI。bin の中の shim が呼ぶ
  run-one --out DIR --scene ID --which old|new --n N ...
                                        1 回の実行。結果を DIR/result.json に書く
  run-all --out DIR --scene-ids A,B --versions old,new --runs N --jobs N ...
                                        場面と回の全部を、並列数 jobs で流す
  summary <runs.jsonl> <summary.md>     場面ごとの表を書く
  usage-table <runs.jsonl> <usage.md>   最上位の役の比べの表（使用量・時間・採点）を書く
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCORER_MARK = "[leader-eval-scorer]"
SCORER_MODEL = "claude-opus-5-5"
SCORER_EFFORT = "high"
KINDS = ("記録", "採点")
HEADINGS = ("## 元の出来事", "## 入力", "## 合格の基準")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

# 成功を返して中身を記録する書き込み。cli.json に同じ前方一致があれば、そちらを先に使う。
WRITE_PREFIXES = [
    "multica issue comment add",
    "multica issue status",
    "multica issue assign",
    "multica issue update",
    "multica issue create",
    "multica issue label add",
    "multica issue label remove",
    "multica issue metadata set",
    "multica issue cancel-task",
    "multica issue rerun",
    "multica issue wakeup create",
    "multica issue wakeup update",
    "multica issue wakeup disable",
    "multica issue wakeup delete",
    "multica issue wakeup trigger",
    "multica issue wakeup checkin",
    "squad-review-wait report",
]
FILE_FLAGS = ("--content-file", "--description-file")
VALUE_FLAGS = ("--content", "--description")


class SceneError(Exception):
    pass


def parse_scene(path):
    text = Path(path).read_text(encoding="utf-8")
    sections = {}
    current = None
    for line in text.splitlines():
        if line.startswith("## "):
            current = line.strip()
            sections.setdefault(current, [])
        elif current is not None:
            sections[current].append(line)
    head = {}
    for line in text.splitlines():
        m = re.match(r"^- (場面の ID|型|外す役): (.*)$", line)
        if m:
            if m.group(1) in head:
                raise SceneError(f"{path}: {m.group(1)} が重複しています")
            head[m.group(1)] = m.group(2).strip()
        if line.startswith("## "):
            break
    for key in ("場面の ID", "型"):
        if not head.get(key):
            raise SceneError(f"{path}: 先頭に `- {key}: …` がありません")
    excluded_roles = re.split(r"[\s,、]+", head["外す役"]) if head.get("外す役") else []
    if "外す役" in head and not excluded_roles:
        raise SceneError(f"{path}: 外す役が空です")
    if any(not re.fullmatch(r"[a-z][a-z0-9-]*", role) for role in excluded_roles):
        raise SceneError(f"{path}: 外す役は役のキーで指定してください")
    for heading in HEADINGS:
        if heading not in sections or not "\n".join(sections[heading]).strip():
            raise SceneError(f"{path}: 見出し {heading} がないか、中身が空です")
    criteria = []
    for line in sections["## 合格の基準"]:
        m = re.match(r"^(\d+)\. \[(記録|採点)\] (.+)$", line)
        if not m:
            if line.strip():
                raise SceneError(f"{path}: 合格の基準の行が `N. [記録|採点] …` の形ではありません: {line}")
            continue
        n, kind, body = int(m.group(1)), m.group(2), m.group(3)
        predicate = None
        pm = re.search(r"`判定: (.+)`\s*$", body)
        if kind == "記録":
            if not pm:
                raise SceneError(f"{path}: [記録] の基準 {n} に `判定: …` がありません")
            predicate = pm.group(1)
            try:
                parse_predicate(predicate)
            except SceneError as e:
                raise SceneError(f"{path}: 基準 {n}: {e}")
            body = body[: pm.start()].strip()
        elif pm:
            raise SceneError(f"{path}: [採点] の基準 {n} に `判定:` は付けません")
        criteria.append({"n": n, "kind": kind, "text": body, "predicate": predicate})
    if not criteria:
        raise SceneError(f"{path}: 合格の基準が 1 つもありません")
    if [c["n"] for c in criteria] != list(range(1, len(criteria) + 1)):
        raise SceneError(f"{path}: 合格の基準の番号が 1 から続いていません")
    return {
        "id": head["場面の ID"],
        "type": head["型"],
        "excluded_roles": excluded_roles,
        "event": "\n".join(sections["## 元の出来事"]).strip(),
        "input": "\n".join(sections["## 入力"]).strip(),
        "criteria": criteria,
    }


def parse_predicate(text):
    """`called: RE && not-called: RE && before: RE => RE && posted: RE && not-posted: RE`。"""
    terms = []
    for part in text.split(" && "):
        m = re.match(r"^(called|not-called|before|posted|not-posted): (.+)$", part.strip())
        if not m:
            raise SceneError(f"判定の項目が読めません: {part}")
        op, arg = m.group(1), m.group(2)
        if op == "before":
            pair = arg.split(" => ")
            if len(pair) != 2:
                raise SceneError(f"before は `A => B` の形です: {arg}")
            args = pair
        else:
            args = [arg]
        for a in args:
            try:
                re.compile(a)
            except re.error as e:
                raise SceneError(f"正規表現が不正です（{a}）: {e}")
        terms.append((op, args))
    return terms


def check_record(predicate, calls):
    """記録から判定する。返り値は (合否, 理由)。"""
    # 呼んだことの確認には、実行できた記録だけを使う。呼ばなかったことの確認には拒否も含める。
    lines = [c["command"] for c in calls if c.get("kind") != "denied"]
    attempted = [c["command"] for c in calls]
    bodies = [b for c in calls for b in c.get("bodies", [])]

    def first(rx):
        for i, line in enumerate(lines):
            if re.search(rx, line):
                return i
        return None

    for op, args in parse_predicate(predicate):
        if op == "called" and first(args[0]) is None:
            return False, f"呼んでいない: {args[0]}"
        if op == "not-called":
            for line in attempted:
                if re.search(args[0], line):
                    return False, f"呼んでいる（拒否も含む）: {line}"
        if op == "before":
            a, b = first(args[0]), first(args[1])
            if a is None:
                return False, f"呼んでいない: {args[0]}"
            if b is not None and b < a:
                return False, f"{args[1]} が {args[0]} より先にある"
        if op == "posted" and not any(re.search(args[0], b, re.M) for b in bodies):
            return False, f"投稿した文に当たらない: {args[0]}"
        if op == "not-posted" and any(re.search(args[0], b, re.M) for b in bodies):
            return False, f"投稿した文に当たる: {args[0]}"
    return True, "記録が基準を満たす"


# ---- pick の見本 ----

PICK_PROCESSES = {"planner", "designer", "implement", "fix", "principal"}
ROLE_PROCESSES = {
    "planner": "planner", "designer": "designer",
    "claude-implementer": "implement", "codex-implementer": "implement",
    "claude-fixer": "fix", "codex-fixer": "fix",
    "claude-principal": "principal", "codex-principal": "principal",
}


def mention_id_pattern(text):
    """空白か、対応する開き括弧のない閉じ括弧の手前まで読む。"""
    depth, escaped, in_class = 0, False, False
    for i, char in enumerate(text):
        if char.isspace():
            return text[:i]
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
        elif char == "[":
            in_class = True
        elif char == "]":
            in_class = False
        elif not in_class and char == "(":
            depth += 1
        elif not in_class and char == ")":
            if depth == 0:
                return text[:i]
            depth -= 1
    return text


def pick_requirements(criterion, values):
    # 値は「回す先の項があるか」。両種の項があれば選んだ応答を求める。
    required, errors = {}, []
    predicate = criterion["predicate"]
    for source, (op, args) in zip(predicate.split(" && "), parse_predicate(predicate)):
        processes = set()
        try:
            if op == "posted":
                for mention in re.finditer("mention://agent/", args[0]):
                    pattern = mention_id_pattern(args[0][mention.end():])
                    matched = {ROLE_PROCESSES.get(key[6:-3]) for key, value in values.items()
                               if key.startswith("agent.") and key.endswith(".id")
                               and re.fullmatch(pattern, value)}
                    if len(matched) != 1:
                        raise ValueError("回す先を決められない")
                    process = matched.pop()
                    if process is not None:
                        processes.add(process)
            elif op in ("called", "before") and "squad-usage-wait pick" in args[0]:
                match = re.search(r"squad-usage-wait pick\s+\S+\s+([a-z]+)", args[0])
                if not match or match[1] not in PICK_PROCESSES:
                    raise ValueError("工程を読めない")
                processes.add(match[1])
        except (ValueError, re.error):
            errors.append(source)
            continue
        for process in processes:
            required[process] = required.get(process, False) or op == "posted"
    return required, errors


def pick_fixture_problem(commands, process, selected):
    entries = []
    for entry in commands:
        words = entry["match"].split()
        if len(words) >= 4 and words[:2] == ["squad-usage-wait", "pick"] and words[3] == process:
            entries.append(entry)
    if not entries:
        return "の pick の見本がない"
    if selected and not any(entry.get("exit", 0) == 0
                            and isinstance(entry.get("stdout"), str)
                            and re.search(r"^振り分け:", entry["stdout"], re.M)
                            for entry in entries):
        return "の pick の見本に、終了コード 0 で振り分けの行のある応答がない"
    return None


def check_scene_picks(directory, values):
    scene = parse_scene(directory / "scene.md")
    cli = json.loads((directory / "cli.json").read_text(encoding="utf-8"))
    commands = cli["commands"]
    requirements, diagnostics = {}, []
    for criterion in scene["criteria"]:
        if criterion["kind"] != "記録":
            continue
        n = criterion["n"]
        required, errors = pick_requirements(criterion, values)
        requirements[n] = required
        for term in errors:
            diagnostics.append((n, f"基準 {n}: 回す先を決められない: {term}"))

    exceptions = cli.get("pick_exceptions", [])
    exempt, seen = set(), set()
    if not isinstance(exceptions, list):
        diagnostics.append((0, "pick_exceptions 0: 配列ではない"))
        exceptions = []
    for i, entry in enumerate(exceptions):
        reason = None
        n = entry.get("criterion") if isinstance(entry, dict) else None
        process = entry.get("process") if isinstance(entry, dict) else None
        if not isinstance(entry, dict):
            reason = "オブジェクトではない"
        elif type(n) is not int or n not in requirements:
            reason = "criterion が [記録] の基準の番号ではない"
        elif not isinstance(process, str) or process not in PICK_PROCESSES:
            reason = "process が工程ではない"
        elif not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
            reason = "reason が空でない文字列ではない"
        elif (n, process) in seen:
            reason = "criterion と process の組が重複している"
        elif process not in requirements[n]:
            reason = "基準からその工程を集めないので例外は要らない"
        elif pick_fixture_problem(commands, process, requirements[n][process]) is None:
            reason = "見本が足りているので例外は要らない"
        else:
            exempt.add((n, process))
        if type(n) is int and isinstance(process, str):
            seen.add((n, process))
        if reason:
            diagnostics.append((n if type(n) is int else 0, f"pick_exceptions {i}: {reason}"))
    for n, required in requirements.items():
        for process, selected in sorted(required.items()):
            if (n, process) not in exempt:
                problem = pick_fixture_problem(commands, process, selected)
                if problem:
                    diagnostics.append((n, f"基準 {n}: {process} {problem}"))
    return [f"{directory.name}: {message}" for _, message in sorted(diagnostics, key=lambda d: d[0])]


def check_picks(argv):
    try:
        if len(argv) != 2:
            raise ValueError("picks は場面のディレクトリと values.json を指定してください")
        directory, values_path = map(Path, argv)
        values = json.loads(values_path.read_text(encoding="utf-8"))
        scenes = [p for p in sorted(directory.iterdir()) if p.is_dir()
                  and (p / "scene.md").is_file() and (p / "cli.json").is_file()]
        diagnostics = [line for scene in scenes for line in check_scene_picks(scene, values)]
    except (OSError, ValueError, TypeError, KeyError, AttributeError, SceneError) as e:
        print(f"pick の見本: {e}", file=sys.stderr)
        return 2
    if diagnostics:
        print("\n".join(diagnostics))
        return 1
    print(f"pick の見本: {len(scenes)} 場面を確認した")
    return 0


# ---- スタブ ----

def command_line(name, argv):
    return " ".join([name] + argv)


def match_command(table, line):
    best, best_len = None, -1
    for entry in table:
        m = entry["match"]
        if line == m or line.startswith(m + " "):
            if len(m) > best_len:
                best, best_len = entry, len(m)
    return best


def stub(name, argv):
    cli_path = os.environ["LEADER_EVAL_CLI"]
    calls_path = os.environ["LEADER_EVAL_CALLS"]
    table = json.loads(Path(cli_path).read_text(encoding="utf-8")).get("commands", [])
    if name == "git":
        # `git -C <作業先> ...` は、作業先を除いて照らす。見本は作業先のパスに依らない
        while len(argv) >= 2 and argv[0] == "-C":
            argv = argv[2:]
    line = command_line(name, argv)
    bodies = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in FILE_FLAGS and i + 1 < len(argv):
            p = Path(argv[i + 1])
            bodies.append(p.read_text(encoding="utf-8") if p.is_file() else "")
            i += 2
            continue
        if a in VALUE_FLAGS and i + 1 < len(argv):
            bodies.append(argv[i + 1])
            i += 2
            continue
        i += 1
    if name == "squad-review-wait" and len(argv) >= 4 and argv[0] == "report":
        # report <タスク> <きっかけのコメント> <結果のファイル>。最上位の役の結果は、このファイルに書く
        p = Path(argv[3])
        bodies.append(p.read_text(encoding="utf-8") if p.is_file() else "")
    entry = match_command(table, line)
    if entry is not None:
        kind, code = "read", int(entry.get("exit", 0))
        out = entry.get("stdout", "")
        err = entry.get("stderr", "")
        if not isinstance(out, str):
            out = json.dumps(out, ensure_ascii=False, indent=2)
        if any(line == p or line.startswith(p + " ") for p in WRITE_PREFIXES):
            kind = "write"
    elif any(line == p or line.startswith(p + " ") for p in WRITE_PREFIXES):
        kind, code, err = "write", 0, ""
        out = json.dumps({"id": "comment-new"}) if "--output json" in line else "ok"
    else:
        kind, code, out = "unmatched", 1, ""
        err = f"leader-eval stub: 見本のない呼び出しです: {line}"
    record = {"command": line, "kind": kind, "exit": code}
    if bodies:
        record["bodies"] = bodies
    with open(calls_path, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    if out:
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
    if err:
        sys.stderr.write(err if err.endswith("\n") else err + "\n")
    return code


# ---- 1 回の実行 ----

SHIMS = ["multica", "gh", "squad-preflight", "squad-pr-link", "squad-pr-watch", "squad-review-wait",
         "squad-dispatch-pick", "squad-usage-read", "squad-review-next", "squad-usage-wait", "git"]
# 使える道具は、スタブのコマンドの Bash と、作業ディレクトリの中の読み書きに、次の 2 つを足したものにする。
# - エージェントは `cmd; echo "exit=$?"` や `cmd | head` のようにコマンドをつなぐ。dontAsk では、つないだ
#   部分が許可に無いと全体が拒否されるので、読むだけの標準のコマンドも許可する（書き込みや通信はできない）
# - コメントの一時ファイルの片付けのため、`rm` は `.md` のファイルと、tmp/ と ./ の下だけ許可する。
#   Claude Code の許可の書き方では、絶対パスを除けない。作業ディレクトリは使い捨てなので、この幅で足りるとする
SHELL_READERS = ["echo", "printf", "cat", "ls", "head", "tail", "wc", "grep", "jq", "sort", "pwd", "which", "test", "shasum"]
ALLOWED_TOOLS = ["Bash(multica *)", "Bash(gh *)", "Bash(squad-*)", "Bash(rm *.md)", "Bash(rm -f *.md)", "Bash(rm tmp/*)", "Bash(rm -f tmp/*)", "Bash(rm ./*)", "Bash(rm -f ./*)",
                 *[f"Bash({c} *)" for c in SHELL_READERS], "Bash(pwd)",
                 "Skill(squad-handoff)",  # スキルの本文と置き場所を読み込むだけ。ほかのスキルは拒否される
                 "Read(./**)", "Edit(./**)"]  # Edit の規則は Write も覆う
# 最上位の役は、指定のコミットを手元に用意して HEAD を照合する。外へ接続しないよう、git もスタブにして、
# 見本のある呼び出しだけを通す。cd は `cd <dir> && git ...` のため。場面の CLI 見本の "git": true のときだけ許可する
GIT_TOOLS = ["Bash(git *)", "Bash(cd *)"]
BUILTIN_TOOLS = "Bash Read Write Edit Skill"


def build_workdir(instr_dir, run_dir, runtime, files=None):
    work = run_dir / "work"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    if runtime == "claude":
        shutil.copy(instr_dir / "instructions.md", work / "CLAUDE.md")
        skills = work / ".claude" / "skills"
    else:
        shutil.copy(instr_dir / "instructions.md", work / "AGENTS.md")
        skills = work / ".codex" / "skills"
    skills.mkdir(parents=True)
    shutil.copytree(instr_dir / "skills" / "squad-handoff", skills / "squad-handoff")
    (work / "tmp").mkdir()
    # 場面の CLI 見本の "files" は、checkout したリポジトリの見本。作業ディレクトリの下の相対パスだけを置く
    for rel, text in (files or {}).items():
        target = (work / rel).resolve()
        if work.resolve() not in target.parents:
            raise ValueError(f"files の置き場所が作業ディレクトリの外です: {rel}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    bin_dir = run_dir / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name in SHIMS:
        shim = bin_dir / name
        shim.write_text(
            "#!/bin/sh\n"
            f'exec python3 -I -B "{Path(__file__).resolve()}" stub "{name}" "$@"\n'
        )
        shim.chmod(0o755)
    return work, bin_dir


# Multica の実行は、シェルの起動で本物の gh と squad- の見張りの置き場（ガード）を PATH の先頭に足す。
# それではスタブより先に本物が呼ばれ、評価の呼び出しが本物の GitHub やタスクへ届くので、
# 評価の実行ではその仕組みを外し、スタブの置き場だけを先頭に置く
# 利用者のシェルの設定（`alias rm='rm -i'` など）も読み込まれないよう、ZDOTDIR は空のディレクトリにする
GATE_ENV = ["BASH_ENV", "CLAUDE_ENV_FILE", "SQUAD_KIT_ALLOWED_REPOS"]


def filtered_path(path_value):
    """ガード（squad-preflight か squad-pr-link のある場所）と空の要素を除いた PATH の、絶対パスの並びを返す。

    相対パスは、解決する側の作業ディレクトリで意味が変わるので、ここで絶対パスにそろえる。
    空の要素は、作業ディレクトリを指して意味が変わるので、絶対パスにせず除く。
    """
    return [os.path.abspath(d) for d in path_value.split(":")
            if d and not any(Path(d, n).exists() for n in ("squad-preflight", "squad-pr-link"))]


def stub_env(bin_dir):
    env = {k: v for k, v in os.environ.items() if k not in GATE_ENV}
    zdotdir = Path(bin_dir).parent / "zdotdir"
    zdotdir.mkdir(exist_ok=True)
    env["ZDOTDIR"] = str(zdotdir)
    env["PATH"] = ":".join([str(bin_dir)] + filtered_path(env.get("PATH", "")))
    return env


# スタブの評価のコマンドの先頭に置く目印。祖先の確認を飛ばせるのは、この目印があるときだけ
STUB_MARK = b"LEADER_EVAL_STUB_AGENT"


def resolve_command(name, path_value):
    """評価の実行と同じ除外をした PATH で、name の実行ファイルを 1 回だけ絶対パスに解決する。"""
    for d in filtered_path(path_value):
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def has_stub_mark(path):
    try:
        with open(path, "rb") as f:
            return STUB_MARK in f.read(8192)
    except OSError:
        return False


def resolve_agents(runtime, path_value):
    """(エージェントの絶対パス, 採点の claude の絶対パス, 両方がスタブか) を返す。

    run.sh はこの値で目印を確認し、同じ絶対パスを run-all に渡して起動に使う。名前では引き直さない。
    """
    agent = resolve_command(runtime, path_value)
    scorer = resolve_command("claude", path_value)
    stub = bool(agent and scorer and has_stub_mark(agent) and has_stub_mark(scorer))
    return agent, scorer, stub


def run_command(cmd, cwd, env, timeout, stdin_text=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, input=stdin_text, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", f"時間切れ（{timeout} 秒）"
    return p.returncode, p.stdout, p.stderr


def agent_command(runtime, model, thinking, prompt, executable=None, extra_tools=()):
    exe = executable or runtime
    if runtime == "claude":
        return [exe, "-p", prompt, "--model", model, "--effort", thinking,
                "--setting-sources", "project", "--tools", *BUILTIN_TOOLS.split(),
                "--allowedTools", *ALLOWED_TOOLS, *extra_tools, "--permission-mode", "dontAsk",
                "--no-session-persistence", "--strict-mcp-config", "--output-format", "json"]
    return [exe, "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-m", model,
            "-c", f'model_reasoning_effort="{thinking}"', prompt]


def posted_comments(calls):
    posts = ("multica issue comment add", "squad-review-wait report")
    return [b for c in calls if c["command"].startswith(posts) for b in c.get("bodies", [])]


USAGE_KEYS = ("input", "cache_write", "cache_read", "output")


def parse_usage(runtime, stdout, stderr):
    """実行の使用量を {input, cache_write, cache_read, output, total, source} で返す。読めなければ None。

    Claude は --output-format json の usage から、入力・キャッシュの作成・キャッシュの読み出し・出力を分けて読む。
    Codex は実行の出力の `tokens used` の合計だけが読める。内訳は null にし、読めたふりをしない。
    """
    if runtime == "claude":
        try:
            usage = json.loads(stdout).get("usage")
        except (ValueError, AttributeError):
            return None
        if not isinstance(usage, dict):
            return None
        fields = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
        values = [usage.get(f) for f in fields]
        if not all(isinstance(v, int) and not isinstance(v, bool) for v in values):
            return None
        return {**dict(zip(USAGE_KEYS, values)), "total": sum(values), "source": "claude-json"}
    m = re.search(r"tokens used\s*:?\s*([0-9][0-9,]*)", f"{stderr}\n{stdout}", re.I)
    if not m:
        return None
    return {"input": None, "cache_write": None, "cache_read": None, "output": None,
            "total": int(m.group(1).replace(",", "")), "source": "codex-tokens-used"}


def scorer_prompt(scene, criterion, calls, response):
    commands = "\n".join(f"- {c['command']}（{c['kind']}、終了コード {c['exit']}）" for c in calls) or "（なし）"
    comments = "\n\n".join(f"--- 投稿 {i + 1} ---\n{b}" for i, b in enumerate(posted_comments(calls))) or "（なし）"
    return (
        f"{SCORER_MARK}\n"
        "あなたは採点の役です。エージェントの 1 回の実行が、次の合格の基準 1 項目を満たすかだけを判定してください。"
        "ファイルは変えず、コマンドも流さないでください。基準にない観点は見ません。\n\n"
        f"## 合格の基準\n{criterion['text']}\n\n"
        f"## エージェントに渡した入力\n{scene['input']}\n\n"
        f"## エージェントが呼んだコマンド\n{commands}\n\n"
        f"## エージェントが投稿したコメント\n{comments}\n\n"
        f"## エージェントの最後の返答\n{response}\n\n"
        '合否と理由を、次の形の JSON だけで返してください。{"pass": true か false, "reason": "1〜2 文"}\n'
    )


def parse_agent_output(text):
    """Claude の JSON の最終結果から、返答とスタブに届かなかった拒否を取り出す。"""
    data = json.loads(text)
    if not isinstance(data, dict) or data.get("type") != "result":
        raise ValueError("type が result ではありません")
    response, denials = data.get("result", ""), data.get("permission_denials")
    if not isinstance(response, str) or not isinstance(denials, list):
        raise ValueError("result または permission_denials の形が違います")
    calls = []
    for denial in denials:
        if not isinstance(denial, dict) or not isinstance(denial.get("tool_input"), dict):
            raise ValueError("拒否された道具の入力が読めません")
        name, tool_input = denial.get("tool_name"), denial["tool_input"]
        if not isinstance(name, str) or (name == "Bash" and not isinstance(tool_input.get("command"), str)):
            raise ValueError("拒否された道具の名前またはコマンドが読めません")
        command = tool_input["command"] if name == "Bash" else f"{name} {json.dumps(tool_input, ensure_ascii=False)}"
        calls.append({**denial, "command": command, "kind": "denied", "exit": None})
    return response, denials, calls, bool(data.get("is_error"))


def parse_score(text):
    for m in re.finditer(r"\{[^{}]*\}", text, re.S):
        try:
            data = json.loads(m.group(0))
        except ValueError:
            continue
        if isinstance(data.get("pass"), bool):
            return data["pass"], str(data.get("reason", ""))
    return None


def run_one(args):
    run_dir = Path(args["out"])
    run_dir.mkdir(parents=True, exist_ok=True)
    scene = parse_scene(Path(args["scenes"]) / args["scene"] / "scene.md")
    instr_dir = Path(args["instructions"]) / args["which"]
    settings = json.loads((Path(args["scenes"]) / args["scene"] / "cli.json").read_text())
    if (
        scene["excluded_roles"]
        or settings.get("ci_monitor", True) is False
        or settings.get("planner", True) is False
        or settings.get("security_reviewer", True) is False
        or "repositories" in settings
    ):
        instr_dir = instr_dir / "scenes" / args["scene"]
    meta = json.loads((instr_dir / "meta.json").read_text(encoding="utf-8"))
    files = settings.get("files", {})
    if not (isinstance(files, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in files.items())):
        raise ValueError("files は、パスと本文の文字列の組で指定してください")
    work, bin_dir = build_workdir(instr_dir, run_dir, args["runtime"], files)
    calls_path = run_dir / "calls.jsonl"
    calls_path.write_text("")
    env = stub_env(bin_dir)
    env["LEADER_EVAL_CLI"] = str(Path(args["scenes"]) / args["scene"] / "cli.json")
    env["LEADER_EVAL_CALLS"] = str(calls_path)
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    timeout = int(args["timeout"])
    result = {"scene": scene["id"], "type": scene["type"], "which": args["which"], "n": int(args["n"]), "runtime": args["runtime"],
              "model": meta["model"], "thinking_level": meta["thinking_level"]}
    started = time.monotonic()
    # 確認した絶対パスをそのまま起動に使う。名前では引き直さない
    agent_path, scorer_path = args["agent-path"], args["scorer-path"]
    if not (os.path.isabs(agent_path) and os.path.isabs(scorer_path)):
        raise ValueError("評価のコマンドは絶対パスで渡してください")
    code, out, err = run_command(
        agent_command(args["runtime"], meta["model"], meta["thinking_level"], scene["input"], agent_path,
                      GIT_TOOLS if settings.get("git") is True else ()),
        work, env, timeout)
    result.update({"exit_code": code, "duration_ms": round((time.monotonic() - started) * 1000),
                   "usage": parse_usage(args["runtime"], out, err)})
    (run_dir / "agent-output.txt").write_text(out)
    calls = [json.loads(line) for line in calls_path.read_text().splitlines() if line.strip()]
    response = out
    if args["runtime"] == "claude":
        try:
            response, denials, denied_calls, is_error = parse_agent_output(out)
            calls.extend(denied_calls)
            result["permission_denials"] = denials
            if denials or is_error:
                result["error"] = f"道具の呼び出しが {len(denials)} 件拒否されたか、実行が失敗した"
        except (ValueError, TypeError) as e:
            response = ""
            result["error"] = f"実行の JSON が読めなかった: {e}"
    (run_dir / "response.txt").write_text(response)
    result.update({"calls": calls, "comments": posted_comments(calls), "response": response.strip()})
    if code != 0:
        result["error"] = f"実行が終了コード {code} で終わった: {err.strip()[:300]}"
    scorer_env = dict(os.environ)
    graded = []
    for c in scene["criteria"]:
        if c["kind"] == "記録":
            ok, reason = check_record(c["predicate"], calls)
        elif "error" in result:
            ok, reason = False, "実行が失敗したので採点しない"
        else:
            scode, sout, serr = run_command(
                [scorer_path, "-p", scorer_prompt(scene, c, calls, result["response"]), "--model", SCORER_MODEL,
                 "--effort", SCORER_EFFORT, "--setting-sources", "", "--tools", "",
                 "--no-session-persistence", "--strict-mcp-config", "--output-format", "text"],
                str(run_dir), scorer_env, timeout)
            parsed = parse_score(sout) if scode == 0 else None
            if parsed is None:
                ok, reason = False, f"採点の応答が読めなかった（終了コード {scode}）: {(sout or serr).strip()[:200]}"
                result.setdefault("scorer_errors", []).append(c["n"])
            else:
                ok, reason = parsed
        graded.append({"n": c["n"], "kind": c["kind"], "pass": ok, "reason": reason})
    result["criteria"] = graded
    result["pass"] = "error" not in result and all(g["pass"] for g in graded)
    (run_dir / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return 0


# ---- 集計 ----

def summary(runs_path, out_path):
    runs = [json.loads(l) for l in Path(runs_path).read_text(encoding="utf-8").splitlines() if l.strip()]
    scenes = {}
    for r in runs:
        s = scenes.setdefault(r["scene"], {"type": r.get("type", ""), "old": [], "new": []})
        s[r["which"]].append(r)
    rows = ["| 場面 | 型 | 今のリーダー | 新しいリーダー | 落ちた基準 |", "| --- | --- | --- | --- | --- |"]

    def cell(items):
        return f"{sum(1 for r in items if r['pass'])}/{len(items)}" if items else "-"

    for sid in sorted(scenes):
        s = scenes[sid]
        # 落ちた基準は新しいリーダーのもの。新しい側を流していない記録（今のリーダーだけ）は、今のリーダーのものを出す
        failed = sorted({g["n"] for r in (s["new"] or s["old"]) for g in r["criteria"] if not g["pass"]})
        rows.append(f"| {sid} | {s['type']} | {cell(s['old'])} | {cell(s['new'])} | "
                    f"{', '.join(map(str, failed)) if failed else '-'} |")
    Path(out_path).write_text("\n".join(rows) + "\n", encoding="utf-8")


def usage_table(runs_path, out_path):
    """最上位の役の比べの表。使用率の前後と差、ほかの実行の有無は、別の記録から手で足す。"""
    runs = [json.loads(l) for l in Path(runs_path).read_text(encoding="utf-8").splitlines() if l.strip()]
    rows = ["| 系統 | 深さ | 処理したトークン | 出力 | 実行の時間 | 採点の合否 |", "| --- | --- | --- | --- | --- | --- |"]
    for r in runs:
        usage = r.get("usage")
        total = "未確認" if not usage else f"{usage['total']:,}"
        output = "未確認" if not usage or usage["output"] is None else f"{usage['output']:,}"
        passed = sum(1 for g in r.get("criteria", []) if g["pass"])
        verdict = f"{passed}/{len(r.get('criteria', []))}" + ("" if "error" not in r else "（実行の失敗）")
        rows.append(f"| {r['runtime']} {r['model']} | {r['thinking_level']} | {total} | {output} | "
                    f"{r['duration_ms'] / 1000:.0f} 秒 | {verdict} |")
    Path(out_path).write_text("\n".join(rows) + "\n", encoding="utf-8")


def run_all(args):
    from concurrent.futures import ThreadPoolExecutor

    out = Path(args["out"])
    jobs = []
    for sid in args["scene-ids"].split(","):
        for which in args["versions"].split(","):
            for n in range(1, int(args["runs"]) + 1):
                jobs.append((sid, which, n))

    def one(job):
        sid, which, n = job
        opts = dict(args, scene=sid, which=which, n=str(n), out=str(out / "runs" / sid / f"{which}-{n}"))
        run_one(opts)
        verdict = json.loads((Path(opts["out"]) / "result.json").read_text())["pass"]
        print(f"{sid} {which} #{n}: {'合格' if verdict else '不合格'}", file=sys.stderr, flush=True)

    with ThreadPoolExecutor(max_workers=max(1, int(args["jobs"]))) as pool:
        list(pool.map(one, jobs))
    with open(out / "runs.jsonl", "w", encoding="utf-8") as f:
        for sid, which, n in jobs:
            result = (out / "runs" / sid / f"{which}-{n}" / "result.json").read_text()
            f.write(json.dumps(json.loads(result), ensure_ascii=False) + "\n")
    return 0


# AGENTS.override.md は、Codex が AGENTS.md より先に読む上書き用の指示。Claude は読まないが、Codex で流した評価の入力が変わる
INSTRUCTION_NAMES = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", "AGENTS.override.md", ".claude", ".codex")


def instruction_ancestors(directory, stop=None):
    """directory とその祖先にある、エージェントが読む指示やスキルのパスを返す。

    stop があれば、そこまでで止める（テストだけが使う。run.sh は渡さず、根まで調べる）。
    """
    found = []
    d = Path(directory).resolve()
    stop = Path(stop).resolve() if stop else None
    while True:
        for name in INSTRUCTION_NAMES:
            if os.path.lexists(d / name):
                found.append(str(d / name))
        if d == d.parent or d == stop:
            return found
        d = d.parent


def parse_options(argv):
    opts = {}
    it = iter(argv)
    for k in it:
        opts[k.lstrip("-")] = next(it)
    return opts


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "picks":
        return check_picks(argv[1:])
    if cmd == "scene":
        try:
            print(json.dumps(parse_scene(argv[1]), ensure_ascii=False))
        except SceneError as e:
            print(e, file=sys.stderr)
            return 1
        return 0
    if cmd == "stub":
        return stub(argv[1], argv[2:])
    if cmd == "run-one":
        return run_one(parse_options(argv[1:]))
    if cmd == "run-all":
        return run_all(parse_options(argv[1:]))
    if cmd == "summary":
        summary(argv[1], argv[2])
        return 0
    if cmd == "usage-table":
        usage_table(argv[1], argv[2])
        return 0
    if cmd == "agent-paths":
        agent, scorer, is_stub = resolve_agents(argv[1], os.environ.get("PATH", ""))
        print(agent or "")
        print(scorer or "")
        print("stub" if is_stub else "real")
        return 0
    if cmd == "ancestors":
        for path in instruction_ancestors(argv[1], argv[2] if len(argv) > 2 else None):
            print(path)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
