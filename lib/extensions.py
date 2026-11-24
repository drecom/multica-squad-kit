"""Validate additive project extensions and materialize their combined templates."""
import json
import re
import shutil
import sys
import unicodedata
from pathlib import Path


def fail(message):
    raise ValueError(message)


class TargetsError(ValueError):
    """autopilot-targets.json の誤りを、1 行ずつ全部持つ。"""

    def __init__(self, lines):
        super().__init__('\n'.join(lines))
        self.lines = lines


def fields(text):
    if not text.startswith('---\n') or '\n---\n' not in text:
        fail('front matter がありません')
    front, body = text[4:].split('\n---\n', 1)
    result = {}
    for line in front.splitlines():
        if ': ' not in line:
            fail('front matter は一行の値にしてください')
        key, value = line.split(': ', 1)
        if key in result:
            fail('front matter のキーが重複しています')
        result[key] = value
    return result, body


def key(value):
    return bool(re.fullmatch(r'[a-z]+(?:-[a-z]+)*', value))


TARGET_PREFIX = 'autopilot-targets.json: '
TARGET_USE = re.compile(r'\{\{target\.([A-Za-z0-9_.-]+)\}\}')
# {{target. で始まる参照の候補。閉じていないものも拾い、書式の誤りを登録の前に見つける。
TARGET_CANDIDATE = re.compile(r'\{\{target\.[^{}\n]*(?:\}\})?')
ROLE_MARK = re.compile(r'<!-- (?:IF .*|ELSE|ENDIF) -->')
REPOSITORY = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+')


def definitions(text):
    """lib/autopilots.sh の autopilot_sections と同じ規則で、見出しと範囲と指示の外の文を読む。"""
    sections, current, code = [], None, False
    for line in text.split('\n'):
        if ROLE_MARK.fullmatch(line):
            continue
        if code:
            if line == '```':
                code = False
            else:
                current['instruction'].append(line)
        elif line.startswith('## '):
            current = {'title': line[3:], 'scope': None, 'instruction': [], 'outside': [line[3:]]}
            sections.append(current)
        elif current is None:
            continue
        elif line == '```text':
            code = True
        else:
            match = re.fullmatch(r'- 範囲: `([^`]+)`', line)
            if match:
                current['scope'] = match[1]
            current['outside'].append(line)
    for section in sections:
        # 名前は見出しから、空白に続く最初の {{ の前まで。名前の中の空白は残す。
        section['name'] = section['title'].split(' {{', 1)[0]
    return sections


def target_names(lines):
    return list(dict.fromkeys(TARGET_USE.findall('\n'.join(lines))))


def target_malformed(lines):
    """{{target.<値の名前>}} の書式に合わない参照を、書かれたまま返す。"""
    return list(dict.fromkeys(m for m in TARGET_CANDIDATE.findall('\n'.join(lines)) if not TARGET_USE.fullmatch(m)))


def read_targets(path, errors):
    duplicates = []

    def pairs(items):
        keys = [name for name, _ in items]
        duplicates.extend(name for name in dict.fromkeys(keys) if keys.count(name) > 1)
        return dict(items)

    try:
        data = json.loads(path.read_text(), object_pairs_hook=pairs)
    except json.JSONDecodeError:
        errors.append('JSON として読めません')
        return {}
    errors.extend(f'{name}: キーが重なっています' for name in duplicates)
    if not isinstance(data, dict):
        errors.append('定義の名前をキーにしたオブジェクトにしてください')
        return {}
    return data


def valid_value(value):
    return (isinstance(value, str) and 1 <= len(value) <= 200 and '`' not in value and '{{' not in value and '}}' not in value
            and not any(unicodedata.category(char) in ('Cc', 'Zl', 'Zp') for char in value))


def check_targets(extension, text, errors):
    """設定を定義の名前・範囲・値と照らし、正規化した設定を返す。誤りは errors に足す。"""
    path = extension / 'autopilot-targets.json'
    configured = read_targets(path, errors) if path.exists() else {}
    sections = definitions(text)
    normalized = {}
    for name, repos in configured.items():
        # 同じ名前の定義は範囲を問わず数える。原本の member の定義と同じ名前の repository の定義で、原本の定義を外せないようにする。
        same = [s for s in sections if s['name'] == name]
        matches = [s for s in same if s['scope'] == 'repository'] if len(same) == 1 else []
        if not same:
            errors.append(f'{name}: 定義にない名前です')
        elif len(same) > 1:
            errors.append(f'{name}: 同じ名前の定義が 2 つ以上あります')
        elif not matches:
            errors.append(f'{name}: 範囲が repository の定義ではありません')
        if not isinstance(repos, dict) or not repos:
            errors.append(f'{name}: 対象のリポジトリを 1 つ以上、キーにしたオブジェクトで書いてください')
            continue
        used = target_names(matches[0]['instruction']) if len(matches) == 1 else []
        seen = {}
        for repo, values in repos.items():
            where = f'{name} {repo}'
            if not REPOSITORY.fullmatch(repo) or repo.split('/')[1] in ('.', '..'):
                errors.append(f'{where}: OWNER/REPO の形にしてください')
                continue
            if repo.lower() in seen:
                errors.append(f'{where}: {seen[repo.lower()]} と同じリポジトリです')
                continue
            seen[repo.lower()] = repo
            if not isinstance(values, dict):
                errors.append(f'{where}: 値はオブジェクトにしてください')
                continue
            for label, value in values.items():
                if not key_name(label):
                    errors.append(f'{where}: 値の名前 {label} は英小文字で始め、英小文字・数字・ハイフンだけにしてください')
                elif not valid_value(value):
                    errors.append(f'{where}: 値 {label} は 1 文字以上 200 文字以下の 1 行の文字列にし、制御文字・バッククォート・{{{{・}}}} を含めないでください')
            errors.extend(f'{where}: 値 {label} がありません' for label in used if label not in values)
            normalized.setdefault(name, {})[repo.lower()] = {f'target.{label}': value for label, value in values.items() if key_name(label) and valid_value(value)}
    for section in sections:
        for raw in target_malformed(section['outside'] + section['instruction']):
            errors.append(f"{section['name']}: {raw} は {{{{target.<値の名前>}}}} の形で書いてください")
        for label in target_names(section['outside']):
            errors.append(f"{section['name']}: target.{label} は指示の中にだけ書けます")
        if section['name'] in configured:
            continue
        for label in target_names(section['instruction']):
            if section['scope'] == 'repository':
                errors.append(f"{section['name']}: target.{label} を使うので、対象のリポジトリと値を書いてください")
            else:
                errors.append(f"{section['name']}: 範囲が repository の定義だけが target.{label} を使えます")
    return normalized


def key_name(value):
    return bool(re.fullmatch(r'[a-z][a-z0-9-]*', value))


def materialize(kit, extension, target):
    if any(p.is_symlink() for p in extension.rglob('*')):
        fail('拡張にシンボリックリンクがあります')
    if (extension / 'kit-version').read_text().strip() != (kit / 'VERSION').read_text().strip():
        fail('拡張が求める原本のバージョンと、流しているバージョンが違います')
    allowed = {'kit-version', 'agents', 'additions.json', 'instructions', 'autopilots.md', 'monitor', 'skills', 'link-repositories.json', 'autopilot-targets.json'}
    if any(p.name not in allowed for p in extension.iterdir()):
        fail('未知の拡張の項目です')
    links_path = extension / 'link-repositories.json'
    links = json.loads(links_path.read_text()) if links_path.exists() else []
    if not isinstance(links, list) or any(
        not isinstance(repo, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+', repo)
        or repo.split('/')[1] in ('.', '..') for repo in links
    ):
        fail('link-repositories.json は OWNER/REPO の配列にしてください')
    for name in ('common', 'skeleton'):
        shutil.copytree(kit / name, target / name)
    (target / 'extension-link-repositories.json').write_text(json.dumps(list(dict.fromkeys(repo.lower() for repo in links))))
    extra_roles = []
    for p in sorted((extension / 'agents').glob('*.md')):
        if not key(p.stem) or (kit / 'common/agents' / p.name).exists():
            fail('原本の役は置き換えられません')
        text = p.read_text()
        # Common templates also allow conditional front matter; validate at rendering.
        if '{{project_key}}-' + p.stem + '-{{member_key}}' not in text:
            fail('拡張の役の名前が規則と違います')
        shutil.copy2(p, target / 'common/agents' / p.name)
        extra_roles.append(p.stem)
    (target / 'extension-roles').write_text(' '.join(extra_roles))
    additions_path = extension / 'additions.json'
    additions = json.loads(additions_path.read_text()) if additions_path.exists() else {}
    if not isinstance(additions, dict):
        fail('additions.json はオブジェクトにしてください')
    mcp = {}
    for role, patch in additions.items():
        p = target / 'common/agents' / (role + '.md')
        if not key(role) or not p.is_file() or not isinstance(patch, dict):
            fail('追記する役がありません')
        if set(patch) - {'skills', 'mcp_config', 'max_concurrent_tasks', 'instructions_file'}:
            fail('追記で原本の指示やモデルを置き換えることはできません')
        text = p.read_text()
        # Edit individual scalar lines without interpreting conditional blocks.
        if 'skills' in patch:
            skills = patch['skills']
            if not isinstance(skills, list) or any(not isinstance(s, str) or not key(s) for s in skills):
                fail('追加スキルの名前が不正です')
            text, count = re.subn(r'^skills: (.*)$', lambda m: 'skills: ' + ', '.join(dict.fromkeys(m[1].split(', ') + skills)), text, flags=re.M)
            if count != 1:
                fail('追記先の skills は一行にしてください')
        if 'max_concurrent_tasks' in patch:
            limit = patch['max_concurrent_tasks']
            if type(limit) is not int or not 1 <= limit <= 50:
                fail('同時実行の上限が不正です')
            if re.search(r'^max_concurrent_tasks: ', text, flags=re.M):
                text = re.sub(r'^max_concurrent_tasks: .*$', f'max_concurrent_tasks: {limit}', text, flags=re.M)
            else:
                text = text.replace('\n---\n', f'\nmax_concurrent_tasks: {limit}\n---\n', 1)
        if 'mcp_config' in patch:
            if not isinstance(patch['mcp_config'], dict):
                fail('MCP の設定はオブジェクトにしてください')
            mcp[role] = patch['mcp_config']
        if 'instructions_file' in patch:
            name = patch['instructions_file']
            if not isinstance(name, str):
                fail('追記のファイル名が不正です')
            instruction = extension / name
            if not instruction.resolve().is_relative_to((extension / 'instructions').resolve()) or not instruction.is_file():
                fail('追記は instructions の下のファイルにしてください')
            text += '\n' + instruction.read_text() + '\n'
        p.write_text(text)
    (target / 'extension-mcp.json').write_text(json.dumps(mcp))
    if (extension / 'autopilots.md').exists():
        p = target / 'common/autopilots.md'
        p.write_text(p.read_text() + '\n' + (extension / 'autopilots.md').read_text())
    for p in (extension / 'monitor').glob('*'):
        if not re.fullmatch(r'squad-[a-z]+(?:-[a-z]+)*', p.name) or not p.is_file() or (kit / 'common/monitor' / p.name).exists():
            fail('原本の見張りは置き換えられません')
        if '# multica-squad-kit-managed' not in p.read_text().splitlines():
            fail('拡張の見張りに管理のマークがありません')
        shutil.copy2(p, target / 'common/monitor' / p.name)
    for p in (extension / 'skills').glob('*'):
        if not key(p.name) or p.name.startswith('squad-') or not p.is_dir():
            fail('プロジェクトのスキルの置き場所が不正です')
        front, _ = fields((p / 'SKILL.md').read_text())
        if front.get('name') != p.name:
            fail('プロジェクトのスキル名が置き場所と違います')
        destination = target / 'skeleton/.agents/skills' / p.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(p, destination)
    (target / 'extension-skills').write_text('\n'.join(p.name for p in (extension / 'skills').glob('*')))
    errors = []
    targets = check_targets(extension, (target / 'common/autopilots.md').read_text(), errors)
    if errors:
        raise TargetsError([TARGET_PREFIX + line for line in errors])
    (target / 'extension-autopilot-targets.json').write_text(json.dumps(targets, ensure_ascii=False))


if __name__ == '__main__':
    try:
        materialize(*(Path(p).resolve() for p in sys.argv[1:]))
    except TargetsError as error:
        print('\n'.join(error.lines), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError) as error:
        print(f'拡張: {error}', file=sys.stderr)
        sys.exit(1)
