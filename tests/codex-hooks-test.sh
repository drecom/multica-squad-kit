#!/usr/bin/env bash
# lib/codex-hooks.py が受ける入力の種類を、表を入力にして行ごとに確認する。
# 表は tests/fixtures/codex-hooks-forms.tsv（hooks/list の形）と tests/fixtures/codex-hooks-paths.tsv（パスの文字）。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/codex-hooks-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home"
cp "$root/tests/codex-hooks-stub.py" "$test_dir/codex-hooks-stub.py"
cat >"$test_dir/bin/codex" <<STUB
#!/usr/bin/env bash
exec python3 "$test_dir/codex-hooks-stub.py" "$test_dir" "\$@"
STUB
chmod +x "$test_dir/bin/codex"
export PATH="$test_dir/bin:$PATH"
source "$root/lib/project.sh"
python3 - "$root" "$test_dir" <<'PY'
import importlib.util
import json
import os
import subprocess
import sys
import tomllib

root, test_dir = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("codex_hooks", root + "/lib/codex-hooks.py")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)


def rows(name):
    with open(root + "/tests/fixtures/" + name, encoding="utf-8") as source:
        return [line.rstrip("\n").split("\t") for line in source if line.strip() and not line.startswith("#")]


def run(guard, mode, config=None):
    with open(test_dir + "/codex-hooks", "w") as handle:
        handle.write(mode)
    argv = ["python3", root + "/lib/codex-hooks.py", test_dir + "/home", guard, "1" if mode == "hang" else "10"]
    if config:
        argv.append(config)
    done = subprocess.run(argv, capture_output=True, text=True, check=True)
    return done.stdout.split("\n")


forms = rows("codex-hooks-forms.tsv")
assert len(forms) >= 20, forms
for ident, mode, status, detail, disabled, note in forms:
    lines = run("/tmp/guard", mode)
    assert lines[0] == status, (ident, lines)
    if status in ("missing", "ambiguous"):
        assert lines[1] == detail, (ident, lines)
    if status == "ok":
        assert json.loads(lines[2]) == json.loads(disabled), (ident, lines)
        assert "\n".join(lines[3:]).count("[hooks.state.") == 2, (ident, lines)
    else:
        assert lines[2] == "[]" and lines[3:] == [""], (ident, lines)
print("PASS codex-hooks: hooks/list の形の表 %d 行を、行ごとに確認した" % len(forms))

# 信頼を読む設定は、行の出力をそのまま書いて読める。
lines = run("/tmp/guard", "same-user+pre-disabled")
config = test_dir + "/config.toml"
open(config, "w").write("\n".join(lines[3:]) + "\n")
assert run("/tmp/guard", "ok", config)[1] == "trusted"
assert run("/tmp/guard", "same-user", config)[1] == "trusted"
open(config, "w").write("")
assert run("/tmp/guard", "ok", config)[1] == "untrusted"
print("PASS codex-hooks: 人の設定の信頼は、役のフックの値だけで決まる")

paths = rows("codex-hooks-paths.tsv")
assert len(paths) >= 10, paths
for ident, quoted, note in paths:
    guard = json.loads(quoted)
    expected = ["'" + (guard + "/" + script).replace("'", "'\\''") + "'" for script in ("pre-tool-use", "stop")]
    # lib/codex-hooks.py の引数が TOML として読め、コマンドがシェルの引用を経て元のパスに戻る。
    python_args = hooks.hook_args(guard)
    values = {}
    for item in python_args[python_args.index("-c") + 1::2]:
        parsed = tomllib.loads(item)["hooks"]
        for event, groups in parsed.items():
            values[event] = groups[0]["hooks"][0]["command"]
    assert values == {"PreToolUse": expected[0], "Stop": expected[1]}, (ident, values)
    for command, script in zip(expected, ("pre-tool-use", "stop")):
        out = subprocess.run(["bash", "-c", "printf '%s' " + command], capture_output=True, text=True).stdout
        assert out == guard + "/" + script, (ident, out)
    # 役の引数（project_desired_args の jq）も、同じ値を作る。
    script = 'source "%s/lib/project.sh"; agent_home=$(dirname "$TEST_GUARD"); project_desired_args gpt-x <<<\'[]\'' % root
    done = subprocess.run(["bash", "-c", script], env=dict(os.environ, TEST_GUARD=guard), capture_output=True, text=True)
    assert done.returncode == 0, (ident, done.stderr)
    role_values = {}
    for item in json.loads(done.stdout):
        if item.startswith("hooks."):
            for event, groups in tomllib.loads(item)["hooks"].items():
                role_values[event] = groups[0]["hooks"][0]["command"]
    assert role_values == values, (ident, role_values, values)
    assert [item for item in json.loads(done.stdout) if item.startswith("hooks.")] == [item for item in python_args if item.startswith("hooks.")], ident
    # hooks/list を読み、状態が ok で、信頼の行が読める TOML になる。
    lines = run(guard, "ok")
    assert lines[0] == "ok", (ident, lines)
    tomllib.loads("\n".join(lines[3:]))
print("PASS codex-hooks: ガードのパスの文字の表 %d 行を、TOML・シェル・役の引数と照らして確認した" % len(paths))
PY
