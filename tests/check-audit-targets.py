"""Check that declared dependencies match the targets table in docs/dependency-audit.md."""
import os
from pathlib import Path
import re
import sys

UNKNOWN_DECLARATIONS = ('package.json', 'package-lock.json', 'pyproject.toml', 'Pipfile', 'go.mod',
                        'Cargo.toml', 'Gemfile', '.tool-versions')
SKIPPED_DIRECTORIES = ('.git', 'tmp')


class AuditError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise AuditError(message)


def actions(root):
    directory = root / '.github' / 'workflows'
    require(directory.is_dir(), 'ワークフローのディレクトリがありません')
    paths = sorted([*directory.glob('*.yml'), *directory.glob('*.yaml')])
    require(paths, 'ワークフローがありません')
    names = set()
    for path in paths:
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            uses = re.match(r'^\s*(?:-\s+)?uses:\s*(.*?)\s*$', line)
            if not uses or uses[1].startswith('./'):
                continue
            match = re.match(r'([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[^@\s]*)?@', uses[1])
            require(match, f'{path.relative_to(root)}:{number} の uses を読めません')
            names.add(match[1].lower())
    return names


def packages(root):
    names = set()
    for path in sorted((root / 'tests').rglob('*.txt')):
        if 'requirements' not in path.name:
            continue
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            text = line.strip()
            if not text or text.startswith('#'):
                continue
            match = re.match(r'([A-Za-z0-9][A-Za-z0-9._-]*)==\S', text)
            require(match, f'{path.relative_to(root)}:{number} の行を読めません')
            names.add(match[1].lower())
    return names


def listed(root):
    path = root / 'docs' / 'dependency-audit.md'
    require(path.is_file(), 'docs/dependency-audit.md がありません')
    lines = path.read_text(encoding='utf-8').splitlines()
    require('## 監査の対象' in lines, '「監査の対象」の節がありません')
    names = set()
    for line in lines[lines.index('## 監査の対象') + 1:]:
        if line.startswith('## '):
            break
        if not line.startswith('|'):
            continue
        match = re.match(r'\|\s*`([^`]+)`\s*\|', line)
        if match:
            names.add(match[1].lower())
    require(names, '「監査の対象」の表に依存がありません')
    return names


def unknown_declarations(root):
    found = []
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = sorted(name for name in subdirectories if name not in SKIPPED_DIRECTORIES)
        here = Path(directory)
        for name in sorted(files):
            path = here / name
            relative = path.relative_to(root)
            is_requirements = name.endswith('.txt') and 'requirements' in name and relative.parts[0] != 'tests'
            if name in UNKNOWN_DECLARATIONS or is_requirements:
                found.append(relative.as_posix())
    return found


def main():
    if len(sys.argv) != 2:
        print('ERROR audit-targets: 使い方: check-audit-targets.py <リポジトリのルート>', file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    try:
        declared = actions(root) | packages(root)
        table = listed(root)
    except (AuditError, OSError, UnicodeError) as failure:
        print(f'ERROR audit-targets: {failure}')
        return 2
    problems = [f'不足: {name}（宣言にあるが、正本の表にない）' for name in sorted(declared - table)]
    problems += [f'余り: {name}（正本の表にあるが、宣言にない）' for name in sorted(table - declared)]
    problems += [f'未対応の宣言: {path}（読み方と正本の節を足してください）' for path in unknown_declarations(root)]
    if problems:
        print(f'FAIL audit-targets: 食い違い {len(problems)} 件')
        print('\n'.join(problems))
        return 1
    print(f'PASS audit-targets: 対象 {len(declared)} 件が宣言と合う')
    return 0


if __name__ == '__main__':
    sys.exit(main())
