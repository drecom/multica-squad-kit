#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# 評価用の人間の表示名を架空名に固定し、実在する人の名前を持ち込まない。
python3 - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
paths = [root / 'tests/leader-eval-test.sh',
         *sorted((root / 'tests/leader-eval/scenes').rglob('cli.json'))]
for path in paths:
    for line, text in enumerate(path.read_text().splitlines(), 1):
        names = re.findall(r'\[@([^\]]+)\]\(mention://member/member1\)', text)
        if any(name not in {'Owner', 'member1'} for name in names):
            sys.exit(f'FAIL leader-eval-identities: {path.relative_to(root)}:{line}: 表示名を架空名にしてください（値は非表示）')
print('PASS leader-eval-identities: 人間の表示名は架空名で、メンション先の ID は保持する')
PY
