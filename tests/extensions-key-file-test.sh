#!/usr/bin/env bash
# 拡張の文書の「鍵を渡す」の手順を、表（tests/extensions-key-file-table.tsv）の行ごとに流し、
# 鍵を入れるファイルの権限と、流し終えたあとに鍵が残らないことを確かめる。
# multica と jq は固定の JSON を返す関数に置き換え、実際の鍵や環境変数は使わない。
# macOS の mktemp は TMPDIR を見ず、利用者ごとの一時の置き場に作る。置き場の場所は確かめず、
# 渡されたファイルの権限と、流し終えたあとにそのファイルがないことを確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/key-file.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 -I - "$root" "$test_dir" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

root, work = map(Path, sys.argv[1:])
SECRET = 'SECRET-VALUE'
table = root / 'tests/extensions-key-file-table.tsv'

doc = (root / 'EXTENSIONS.md').read_text(encoding='utf-8')
section = doc.split('### 鍵を渡す', 1)[1].split('\n### ', 1)[0]
blocks = re.findall(r'```bash\n(.*?)```', section, re.S)
assert len(blocks) == 1, '鍵を渡す手順の bash のコードブロックが 1 つではない'
procedure = blocks[0].replace('<エージェントの ID>', 'agent-1')
assert 'custom-env.json' not in procedure, '手順が、決まった名前のファイルを使っている'

STATES = {'なし', '既存644', '既存600', 'リンク644', '共有の一時'}
UMASKS = {'022', '077'}
FLOWS = {'通常', '反映の失敗', '中断', '再実行'}
rows = []
for n, line in enumerate(table.read_text(encoding='utf-8').splitlines(), 1):
    if line.startswith('#') or not line.strip():
        continue
    cols = line.split('\t')
    assert len(cols) == 8, f'{table.name}:{n} 8 列ではない'
    if cols[0] == '行':
        continue
    name, state, umask, flow, mode, existing, leftover, _ = cols
    assert state in STATES and umask in UMASKS and flow in FLOWS, f'{table.name}:{n} 未知の値'
    assert mode == '600' and existing in {'なし', '変わらない'} and leftover == '残らない', f'{table.name}:{n} 期待の値が未知'
    rows.append((name, state, umask, flow, existing))

assert len({r[0] for r in rows}) == len(rows), '行の名前が重なる'
covered = {(r[1], r[2]) for r in rows if r[3] == '通常'}
missing = {(s, u) for s in STATES for u in UMASKS} - covered
assert not missing, f'通常の流れの組が表にない: {sorted(missing)}'

PRELUDE = r'''
mode_of() { python3 -I -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }
jq() { cat > /dev/null; printf '{"K":"%s"}\n' "$SECRET"; }
multica() {
  case "$1 $2 $3" in
    "agent env get") printf '{"custom_env":{"K":"%s"}}\n' "$SECRET" ;;
    "agent env set")
      file=$6
      printf '%s\t%s\t%s\n' "$file" "$(mode_of "$file")" "$(grep -c "$SECRET" "$file")" >> "$LOG"
      case "$FLOW" in
        反映の失敗) return 1 ;;
        中断) kill -TERM $$ ;;
      esac ;;
  esac
}
'''

def tree_has_secret(base):
    for p in base.rglob('*'):
        if p.is_file() and not p.is_symlink() and SECRET.encode() in p.read_bytes():
            if p.name not in ('log',):
                return str(p)
    return None

made = []
def cleanup():
    for p in made:
        if os.path.lexists(p):
            os.remove(p)
import atexit
atexit.register(cleanup)

for name, state, umask, flow, existing in rows:
    row = work / name
    cwd, tmp = row / 'cwd', row / 'tmp'
    cwd.mkdir(parents=True)
    tmp.mkdir()
    tmp.chmod(0o1777 if state == '共有の一時' else 0o700)
    saved = cwd / 'custom-env.json'
    target = row / 'target.json'
    if state in ('既存644', '既存600'):
        saved.write_text('OLD\n')
        saved.chmod(0o644 if state == '既存644' else 0o600)
    elif state == 'リンク644':
        target.write_text('OLD\n')
        target.chmod(0o644)
        saved.symlink_to(target)
    before = None
    if state != 'なし' and state != '共有の一時':
        probe = target if state == 'リンク644' else saved
        before = (probe.stat().st_mode & 0o777, probe.read_text(), os.readlink(saved) if saved.is_symlink() else None)
    log = row / 'log'
    log.write_text('')
    script = PRELUDE + f'umask {umask}\n' + procedure
    env = {'PATH': os.environ['PATH'], 'HOME': str(row), 'TMPDIR': str(tmp), 'LOG': str(log), 'SECRET': SECRET, 'FLOW': flow}
    runs = 2 if flow == '再実行' else 1
    for _ in range(runs):
        subprocess.run(['bash', '-c', script], cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    calls = [l.split('\t') for l in log.read_text().splitlines()]
    assert len(calls) == runs, f'{name}: 反映の呼び出しが {len(calls)} 回（期待 {runs}）: {calls}'
    for path, mode, hits in calls:
        assert mode == '600', f'{name}: 反映時の権限が {mode}（期待 600）: {path}'
        assert hits == '1', f'{name}: 反映するファイルに鍵がない: {path}'
        made.append(path)
        assert Path(path).parent != cwd and Path(path) != saved, f'{name}: 前からある保存先を使った: {path}'
    if before is not None:
        probe = target if state == 'リンク644' else saved
        after = (probe.stat().st_mode & 0o777, probe.read_text(), os.readlink(saved) if saved.is_symlink() else None)
        assert after == before, f'{name}: 前からある保存先が変わった: {before} → {after}'
    left = tree_has_secret(row) or next((p for p in made if os.path.lexists(p)), None)
    assert left is None, f'{name}: 流し終えたあとに鍵が残った: {left}'
print(f'PASS extensions-key-file: 表 tests/extensions-key-file-table.tsv の {len(rows)} 行で、鍵のファイルは 0600 の新しいファイルで、前の保存先を変えず、流し終えたあとに残らない')
PY
