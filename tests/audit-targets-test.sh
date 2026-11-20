#!/usr/bin/env bash
# 依存の宣言と docs/dependency-audit.md の対象の表が合うことと、正本の Pillow のコマンドの読み方を、gh のスタブで確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/audit-targets.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 -I - "$root" "$test_dir" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
checker = root / 'tests/check-audit-targets.py'
document = 'docs/dependency-audit.md'


def check(repository):
    return subprocess.run(['python3', '-I', str(checker), str(repository)], capture_output=True, text=True)


def copy(name):
    target = scratch / name
    shutil.copytree(root / '.github', target / '.github')
    for relative in (document, 'tests/release-screens-requirements.txt'):
        (target / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target / relative)
    return target


result = check(root)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
print('PASS audit-targets: 今のリポジトリで、宣言と正本の対象が合う')

added = copy('added-action')
(added / '.github/workflows/probe.yml').write_text(
    'name: Probe\non:\n  workflow_dispatch:\njobs:\n  probe:\n    runs-on: ubuntu-24.04\n    steps:\n'
    '      - uses: actions/download-artifact@' + '0' * 40 + ' # v4.1.3\n', encoding='utf-8')
result = check(added)
assert result.returncode == 1 and 'actions/download-artifact' in result.stdout, (result.returncode, result.stdout)
added_package = copy('added-package')
with (added_package / 'tests/release-screens-requirements.txt').open('a', encoding='utf-8') as output:
    output.write('Requests==2.32.0\n')
result = check(added_package)
assert result.returncode == 1 and 'requests' in result.stdout, (result.returncode, result.stdout)
print('PASS audit-targets: 依存を足して正本を直さないと、1 で終わり、足した名前が出る（アクションと requirements）')

removed = copy('removed-row')
text = (removed / document).read_text(encoding='utf-8')
(removed / document).write_text(re.sub(r'^\| `Pillow` \|.*\n', '', text, flags=re.M), encoding='utf-8')
result = check(removed)
assert result.returncode == 1 and 'pillow' in result.stdout, (result.returncode, result.stdout)
unknown = copy('unknown-declaration')
(unknown / 'package.json').write_text('{}\n', encoding='utf-8')
result = check(unknown)
assert result.returncode == 1 and 'package.json' in result.stdout, (result.returncode, result.stdout)
unreadable = copy('missing-document')
(unreadable / document).unlink()
assert check(unreadable).returncode == 2
print('PASS audit-targets: 正本の行を消す・知らない宣言を置くと 1、正本が読めないと 2 で終わる')

markdown = (root / document).read_text(encoding='utf-8')
section = markdown.split('### Pillow のコマンド\n', 1)[1]
command = re.match(r'\s*```bash\n(.*?)\n```', section, re.S)[1]
bin_dir = scratch / 'bin'
bin_dir.mkdir()
stub = bin_dir / 'gh'
stub.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
required = ['api', '-X', 'GET', '/advisories', 'ecosystem=pip', 'type=reviewed', 'is_withdrawn=false',
            os.environ['AUDIT_EXPECTED_AFFECTS'], 'per_page=100', '--paginate', '--slurp']
if os.environ['AUDIT_MODE'] == 'failure':
    sys.exit(1)
if not all(value in args for value in required):
    sys.exit(2)
sys.stdout.write(os.environ['AUDIT_RESPONSE'])
''', encoding='utf-8')
stub.chmod(0o755)
workdir = copy('pillow')
advisory = {'ghsa_id': 'GHSA-aaaa-bbbb-cccc', 'cve_id': 'CVE-2026-0001', 'severity': 'high', 'summary': '画像の読み込みで落ちる'}
no_cve = {'ghsa_id': 'GHSA-dddd-eeee-ffff', 'cve_id': None, 'severity': 'low', 'summary': '別の問題'}


def pillow(mode, response='', repository=workdir):
    requirement = next(line for line in (repository / 'tests/release-screens-requirements.txt').read_text(
        encoding='utf-8').splitlines() if line.startswith('Pillow=='))
    environment = {**os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
                   'AUDIT_MODE': mode, 'AUDIT_RESPONSE': response,
                   'AUDIT_EXPECTED_AFFECTS': 'affects=Pillow@' + requirement.split('==', 1)[1]}
    return subprocess.run(['bash', '-c', command], cwd=repository, env=environment, capture_output=True, text=True)


result = pillow('ok', json.dumps([[]]))
assert result.returncode == 0 and result.stdout.splitlines()[0] == '検出 0 件', (result.returncode, result.stdout, result.stderr)
result = pillow('ok', json.dumps([[advisory], [no_cve]]))
lines = result.stdout.splitlines()
assert result.returncode == 0 and lines[0] == '検出 2 件' and len(lines) == 3, (result.returncode, result.stdout, result.stderr)
assert lines[1].split('\t') == ['GHSA-aaaa-bbbb-cccc', 'CVE-2026-0001', 'high', '画像の読み込みで落ちる'], lines
assert lines[2].split('\t')[:3] == ['GHSA-dddd-eeee-ffff', 'CVE なし', 'low'], lines
for name, mode, response in (('gh の失敗', 'failure', ''), ('配列でない応答', 'ok', '{"message": "Bad credentials"}'),
                             ('ページが配列でない応答', 'ok', '[{}]'), ('空の配列', 'ok', '[]')):
    result = pillow(mode, response)
    assert result.returncode != 0 and not any(line.startswith('検出') for line in result.stdout.splitlines()), \
        (name, result.returncode, result.stdout, result.stderr)
print('PASS audit-targets: 正本の Pillow のコマンドが、検出なし・検出あり・取得失敗を終了コードと出力で分ける')

updated = copy('pillow-version-update')
requirements = updated / 'tests/release-screens-requirements.txt'
requirements.write_text(re.sub(r'^Pillow==.*$', 'Pillow==99.8.7', requirements.read_text(encoding='utf-8'),
                               flags=re.M), encoding='utf-8')
assert check(updated).returncode == 0
result = pillow('ok', json.dumps([[]]), repository=updated)
assert result.returncode == 0 and result.stdout.splitlines()[0] == '検出 0 件', (result.returncode, result.stdout, result.stderr)
print('PASS audit-targets: Pillow のバージョンだけを変えても、宣言したバージョンを監査できる')
PY
