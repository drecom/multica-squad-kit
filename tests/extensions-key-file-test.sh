#!/usr/bin/env bash
# 拡張の文書の「鍵を渡す」の手順を、表（tests/extensions-key-file-table.tsv）の行ごとに bash か zsh で流し、
# 鍵のファイルの権限と、最後の行まで流したあとに鍵が残らないことを確認する。
# multica と jq は固定の JSON を返す関数に置き換え、実際の鍵や環境変数は使わない。
# 手順は、人間が 1 行ずつ貼るのと同じく、シェルの -c に -e を付けずに流す。TMPDIR は検証の領域の中に向ける。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/key-file.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
have_zsh=0
if command -v zsh >/dev/null; then
	have_zsh=1
else
	echo 'zsh がないので、zsh の行を飛ばします（CI では両 OS に zsh がある）'
fi
python3 -I - "$root" "$test_dir" "$have_zsh" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

root, work = map(Path, sys.argv[1:3])
have_zsh = sys.argv[3] == '1'
SECRET = 'SECRET-VALUE'
table = root / 'tests/extensions-key-file-table.tsv'

doc = (root / 'EXTENSIONS.md').read_text(encoding='utf-8')
section = doc.split('### 鍵を渡す', 1)[1].split('\n### ', 1)[0]
blocks = re.findall(r'```bash\n(.*?)```', section, re.S)
assert len(blocks) == 1, '鍵を渡す手順の bash のコードブロックが 1 つではない'
block = blocks[0]
assert 'trap' not in block, '手順に trap がある'
assert not any(l.lstrip().startswith('#') for l in block.splitlines()), '手順にコメントの行がある'
assert 'squad-custom-env.*' in section and 'ls ' in section, '節に、squad-custom-env. を探して消す案内がない'
procedure = block.replace('<エージェントの ID>', 'agent-1')

SHELLS = ['bash', 'zsh']
STATES = ['なし', '既存644', '既存600', 'リンク644', '共有の一時']
UMASKS = ['022', '077']
FLOWS = {'通常', '反映の失敗'}
rows = []
for n, line in enumerate(table.read_text(encoding='utf-8').splitlines(), 1):
    if line.startswith('#') or not line.strip():
        continue
    cols = line.split('\t')
    assert len(cols) == 9, f'{table.name}:{n} 9 列ではない'
    if cols[0] == '行':
        continue
    name, shell, state, umask, flow, mode, existing, leftover, _ = cols
    assert shell in SHELLS and state in STATES and umask in UMASKS and flow in FLOWS, f'{table.name}:{n} 未知の値'
    assert mode == '600' and existing in {'なし', '変わらない'} and leftover == '残らない', f'{table.name}:{n} 期待の値が未知'
    rows.append((name, shell, state, umask, flow, existing))

assert len({r[0] for r in rows}) == len(rows), '行の名前が重なる'
covered = {(r[1], r[2], r[3]) for r in rows if r[4] == '通常'}
missing = {(s, st, u) for s in SHELLS for st in STATES for u in UMASKS} - covered
assert not missing, f'通常の流れの組が表にない: {sorted(missing)}'
failed = {(r[1], r[2]) for r in rows if r[4] == '反映の失敗'}
missing = {(s, st) for s in SHELLS for st in ('なし', '既存644')} - failed
assert not missing, f'反映の失敗の組が表にない: {sorted(missing)}'

PRELUDE = r'''
mode_of() { python3 -I -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }
jq() { cat > /dev/null; printf '{"K":"%s"}\n' "$SECRET"; }
multica() {
  case "$1 $2 $3" in
    "agent env get") printf '{"custom_env":{"K":"%s"}}\n' "$SECRET" ;;
    "agent env set")
      file=$6
      printf '%s\t%s\t%s\n' "$file" "$(mode_of "$file")" "$(grep -c "$SECRET" "$file")" >> "$LOG"
      if [ "$FLOW" = fail ]; then return 1; fi ;;
  esac
}
'''

def snapshot(p):
    st = p.lstat()
    link = os.readlink(p) if p.is_symlink() else None
    body = None if p.is_symlink() else p.read_text()
    return (st.st_mode & 0o7777, body, link)

def secret_in(base):
    for p in base.rglob('*'):
        if p.is_file() and not p.is_symlink() and SECRET.encode() in p.read_bytes():
            return str(p)
    return None

skipped = 0
ran = 0
for name, shell, state, umask, flow, existing in rows:
    if shell == 'zsh' and not have_zsh:
        skipped += 1
        continue
    row = work / name
    cwd, tmp = row / 'cwd', row / 'tmp'
    cwd.mkdir(parents=True)
    tmp.mkdir()
    tmp.chmod(0o1777 if state == '共有の一時' else 0o700)
    old = tmp / 'squad-custom-env.OLDOLD'
    link_target = row / 'target.json'
    if state in ('既存644', '既存600'):
        old.write_text('OLD\n')
        old.chmod(0o644 if state == '既存644' else 0o600)
    elif state == 'リンク644':
        link_target.write_text('OLD\n')
        link_target.chmod(0o644)
        old.symlink_to(link_target)
    before = {p: snapshot(p) for p in (old, link_target) if os.path.lexists(p)}
    log = row / 'log'
    log.write_text('')
    script = PRELUDE + f'umask {umask}\n' + procedure
    env = {'PATH': os.environ['PATH'], 'HOME': str(row), 'TMPDIR': str(tmp), 'LOG': str(log),
           'SECRET': SECRET, 'FLOW': 'fail' if flow == '反映の失敗' else 'ok'}
    subprocess.run([shell, '-c', script], cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    calls = [l.split('\t') for l in log.read_text().splitlines()]
    assert len(calls) == 1, f'{name}: 反映の呼び出しが {len(calls)} 回（期待 1）: {calls}'
    path, mode, hits = calls[0]
    assert mode == '600', f'{name}: 反映時の権限が {mode}（期待 600）: {path}'
    assert hits == '1', f'{name}: 反映するファイルに鍵がない: {path}'
    assert Path(path).parent == tmp and Path(path).name.startswith('squad-custom-env.') and Path(path) != old, \
        f'{name}: 置き場の新しいファイルではない: {path}'
    after = {p: snapshot(p) for p in before}
    assert after == before, f'{name}: 前からあるファイルが変わった: {before} → {after}'
    left = secret_in(row)
    assert left is None, f'{name}: 最後の行まで流したあとに鍵が残った: {left}'
    assert sorted(p.name for p in tmp.iterdir()) == sorted(p.name for p in before if p.parent == tmp), \
        f'{name}: 置き場にファイルが残った: {sorted(p.name for p in tmp.iterdir())}'
    ran += 1
note = f'（zsh の {skipped} 行は飛ばした）' if skipped else ''
print(f'PASS extensions-key-file: 表 tests/extensions-key-file-table.tsv の {ran} 行で、鍵のファイルは 0600 の新しいファイルで、前からあるファイルを変えず、最後の行まで流したあとに残らない{note}')
PY
