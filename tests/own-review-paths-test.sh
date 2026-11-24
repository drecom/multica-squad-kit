#!/usr/bin/env bash
# このリポジトリの .agents/review-paths が、全ファイルを覆い、文書とスクリプトに設計の観点を選ぶことを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
source = (root / "common/monitor/squad-review-next").read_text(encoding="utf-8")


def extract(variable, marker):
    # 見張りを実行せず、既定の対応と当て方の処理の heredoc だけを取り出す。
    match = re.search(
        rf"^read -r -d '' {variable} <<'{marker}' \|\| true\n(.*?)^{marker}$",
        source, re.MULTILINE | re.DOTALL,
    )
    assert match, f"{variable} の処理を取り出せない"
    return match[1]


defaults = extract("DEFAULT_PATHS", "DEFAULTS")
matcher = compile(extract("MATCH_PY", "MATCHPY"), "squad-review-next:MATCH_PY", "exec")
project = (root / ".agents/review-paths").read_text(encoding="utf-8")
valid = ["code-reviewer", "ux-reviewer", "security-reviewer", "performance-reviewer", "qa"]


def select(name):
    data = {"defaults": defaults, "project": project, "files": [{"filename": name}], "valid": valid}
    output = io.StringIO()
    previous_stdin = sys.stdin
    try:
        sys.stdin = io.StringIO(json.dumps(data))
        with contextlib.redirect_stdout(output):
            try:
                exec(matcher, {})
            except SystemExit as error:
                assert error.code == 0, f"当て方の処理が失敗した: {error.code}"
    finally:
        sys.stdin = previous_stdin
    return json.loads(output.getvalue())


parsed = select("MANIFEST")
assert parsed["mode"] == "select", parsed["reason"]
print("PASS own-review-paths: 対応のファイルを読める（形の誤りがない）")

files = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).decode().split("\0")
results = {name: select(name) for name in files if name}
assert results, "git ls-files が空"
unmatched = [f"{name}: {result['reason']}" for name, result in results.items() if result["mode"] != "select"]
assert not unmatched, "\n".join(unmatched)
print(f"PASS own-review-paths: git ls-files の全 {len(results)} ファイルが対応に当たる")

documents = [name for name in results if name.endswith(".md")]
assert documents, "Markdown がない"
for name in documents:
    assert results[name]["roles"] == ["code-reviewer"], f"{name}: {results[name]}"
print("PASS own-review-paths: すべての Markdown はコードの観点だけになる")

for path in ("common/guard/", "common/shell/", "common/codex/", "setup.sh", "install.sh", "lib/"):
    names = [name for name in results if name.startswith(path)] if path.endswith("/") else [path]
    assert names, f"{path} にファイルがない"
    for name in names:
        assert "security-reviewer" in results[name]["roles"], f"{name}: {results[name]}"
print("PASS own-review-paths: 実行するスクリプトとセットアップはセキュリティの観点を含む")

for path in ("common/host/", "common/monitor/", "vm/"):
    names = [name for name in results if name.startswith(path)]
    assert names, f"{path} にファイルがない"
    for name in names:
        assert {"security-reviewer", "performance-reviewer"} <= set(results[name]["roles"]), f"{name}: {results[name]}"
print("PASS own-review-paths: 起動と見張りはセキュリティと性能の観点を含む")
PY
