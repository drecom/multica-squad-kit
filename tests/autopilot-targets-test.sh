#!/usr/bin/env bash
# autopilot-targets.json の確認を、拡張の読み込み（lib/extensions.py）と、setup.sh の選択済みリポジトリの照合で確かめる。
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest

python3 - "$root" "$test_dir/py" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

kit, work = map(Path, sys.argv[1:])
work.mkdir()
spec = importlib.util.spec_from_file_location('extensions', kit / 'lib/extensions.py')
module = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(module)

PREFIX = 'autopilot-targets.json: '
COMMON = '週 1 回の依存ライブラリの脆弱性チェック'
MEMBER = '使用上限の見張り'
VALUE_ERROR = '1 文字以上 200 文字以下の 1 行の文字列にし、制御文字・バッククォート・{{・}} を含めないでください'
SCAN = '## Scan {{project_key}} {{repository}}\n\n- 範囲: `repository`\n- 実行: `run_only`\n- スケジュール: `0 0 * * 1`（Asia/Tokyo）\n\n```text\nScan {{target.url}} and {{target.path}}.\n```\n'
counter = 0


def attempt(config=None, autopilots=None, raw=None):
    """拡張を読み込み、誤りの行の一覧か、正規化した設定を返す。"""
    global counter
    counter += 1
    ext = work / f'ext{counter}'
    ext.mkdir()
    (ext / 'kit-version').write_text((kit / 'VERSION').read_text())
    if config is not None:
        (ext / 'autopilot-targets.json').write_text(json.dumps(config, ensure_ascii=False))
    if raw is not None:
        (ext / 'autopilot-targets.json').write_text(raw)
    if autopilots is not None:
        (ext / 'autopilots.md').write_text(autopilots)
    out = work / f'out{counter}'
    try:
        module.materialize(kit, ext, out)
    except module.TargetsError as error:
        return error.lines
    return json.loads((out / 'extension-autopilot-targets.json').read_text())


def lines(*messages):
    return [PREFIX + message for message in messages]


# 設定がなければ空のオブジェクトを渡し、あっても使わない定義は今までどおり読める。
assert attempt() == {}
assert attempt(autopilots=SCAN.replace('{{target.url}}', 'x').replace('{{target.path}}', 'y')) == {}
print('PASS autopilot-targets: 設定がなければ、空の設定を渡す')

# 2-1: 誤りは 1 行ずつ全部返す。
config = {
    '未定義の名前': {'example/one': {'a': 'x'}},
    MEMBER: {'example/one': {'a': 'x'}},
    'Scan': {'bad': {'url': 'u'}, 'example/one': {'url': 'u'}, 'Example/One': {'url': 'u', 'path': 'p'}, 'example/two': {'Bad': 'x', 'url': 'a`b', 'path': ''}, 'example/three': []},
    COMMON: 'x',
}
assert attempt(config, SCAN) == lines(
    '未定義の名前: 定義にない名前です',
    f'{MEMBER}: 範囲が repository の定義ではありません',
    'Scan bad: OWNER/REPO の形にしてください',
    'Scan example/one: 値 path がありません',
    'Scan Example/One: example/one と同じリポジトリです',
    'Scan example/two: 値の名前 Bad は英小文字で始め、英小文字・数字・ハイフンだけにしてください',
    f'Scan example/two: 値 url は {VALUE_ERROR}',
    f'Scan example/two: 値 path は {VALUE_ERROR}',
    'Scan example/three: 値はオブジェクトにしてください',
    f'{COMMON}: 対象のリポジトリを 1 つ以上、キーにしたオブジェクトで書いてください',
)
print('PASS autopilot-targets: 誤りを 1 行ずつ全部返す')

assert attempt(raw='{') == lines('JSON として読めません')
assert attempt(raw='') == lines('JSON として読めません')
assert attempt([COMMON]) == lines('定義の名前をキーにしたオブジェクトにしてください')
assert attempt(raw='{"Scan": {"example/one": {"url": "u", "path": "p"}}, "Scan": {"example/one": {"url": "u", "path": "p"}}}', autopilots=SCAN) == lines('Scan: キーが重なっています')
assert attempt({COMMON: {}}) == lines(f'{COMMON}: 対象のリポジトリを 1 つ以上、キーにしたオブジェクトで書いてください')
for repo in ('one', 'example/', '/one', 'a/b/c', 'example/..', 'example/.', 'https://github.com/example/one', 'example/one\n'):
    assert attempt({COMMON: {repo: {}}}) == lines(f'{COMMON} {repo}: OWNER/REPO の形にしてください'), repo
print('PASS autopilot-targets: JSON の形・キーの重なり・リポジトリの書き方の誤りを返す')

# 値の名前と値。
for label in ('Url', '1a', 'a_b', 'a.b', '', '-a'):
    assert attempt({'Scan': {'example/one': {label: 'x', 'url': 'u', 'path': 'p'}}}, SCAN) == lines(f'Scan example/one: 値の名前 {label} は英小文字で始め、英小文字・数字・ハイフンだけにしてください'), label
for value in ('', 'a' * 201, 'a\nb', 'a\rb', 'a\tb', 'a\x00b', 'a b', 'a`b', 'a{{b', 'a}}b', 1, None, ['a'], {'a': 'b'}):
    assert attempt({'Scan': {'example/one': {'url': value, 'path': 'p'}}}, SCAN) == lines(f'Scan example/one: 値 url は {VALUE_ERROR}'), repr(value)
ok = {'url': 'a' * 200, 'path': '日本語 の値 {x} $y "z"'}
assert attempt({'Scan': {'example/one': ok}}, SCAN) == {'Scan': {'example/one': {'target.url': ok['url'], 'target.path': ok['path']}}}
assert attempt({'Scan': {'example/one': {'url': 'u', 'path': 'p', 'a-1': 'x'}}}, SCAN) == {'Scan': {'example/one': {'target.url': 'u', 'target.path': 'p', 'target.a-1': 'x'}}}
print('PASS autopilot-targets: 値の名前と値の書き方の誤りを返し、使える値は通す')

# 2-3: target.* は指示の中にだけ書ける。
valid = {'Scan': {'example/one': {'url': 'u', 'path': 'p'}}}
heading = SCAN.replace('## Scan {{project_key}}', '## Scan {{target.url}} {{project_key}}')
assert attempt(valid, heading) == lines('Scan: target.url は指示の中にだけ書けます')
schedule = SCAN.replace('`0 0 * * 1`', '`{{target.url}}`')
assert attempt(valid, schedule) == lines('Scan: target.url は指示の中にだけ書けます')
scope = SCAN.replace('- 範囲: `repository`', '- 範囲: `repository`\n- 補足: {{target.path}}')
assert attempt(valid, scope) == lines('Scan: target.path は指示の中にだけ書けます')
before = SCAN.replace('\n```text', '\n{{target.url}}\n\n```text')
assert attempt(valid, before) == lines('Scan: target.url は指示の中にだけ書けます')
after = SCAN + '\n補足は {{target.path}}\n'
assert attempt(valid, after) == lines('Scan: target.path は指示の中にだけ書けます')
# 指示の外の誤りは、設定がなくても返す。
assert attempt(autopilots=heading) == lines('Scan: target.url は指示の中にだけ書けます', 'Scan: target.url を使うので、対象のリポジトリと値を書いてください', 'Scan: target.path を使うので、対象のリポジトリと値を書いてください')
member = SCAN.replace('`repository`', '`member`')
assert attempt(autopilots=member) == lines('Scan: 範囲が repository の定義だけが target.url を使えます', 'Scan: 範囲が repository の定義だけが target.path を使えます')
assert attempt({'Scan': {'example/one': {'url': 'u', 'path': 'p'}}}, member) == lines('Scan: 範囲が repository の定義ではありません')
# 指示の中の使い方は通す。
assert attempt(valid, SCAN) == {'Scan': {'example/one': {'target.url': 'u', 'target.path': 'p'}}}
print('PASS autopilot-targets: target.* を見出し・スケジュール・範囲・指示の外に書くと誤りにする')

# 2-4: 名前は見出しの ## のあと、最初の {{ の前まで。名前の中の空白は残す。
assert attempt({COMMON: {'Example/One': {}}}) == {COMMON: {'example/one': {}}}
for name in (COMMON + ' ', COMMON.replace(' ', ''), COMMON.replace(' 1 ', ' １ '), COMMON.replace('週 1 回の', '')):
    assert attempt({name: {'example/one': {}}}) == lines(f'{name}: 定義にない名前です'), name
spaced = '## Scan with  spaces {{project_key}}\n\n- 範囲: `repository`\n- 実行: `run_only`\n- スケジュール: `0 0 * * 1`（Asia/Tokyo）\n\n```text\nScan {{target.url}}.\n```\n'
assert attempt({'Scan with  spaces': {'example/one': {'url': 'u'}}}, spaced) == {'Scan with  spaces': {'example/one': {'target.url': 'u'}}}
assert attempt({'Scan with spaces': {'example/one': {'url': 'u'}}}, spaced) == lines('Scan with spaces: 定義にない名前です', 'Scan with  spaces: target.url を使うので、対象のリポジトリと値を書いてください')
twice = SCAN + '\n' + SCAN.replace('{{repository}}', '{{member_key}}')
assert attempt({'Scan': {'example/one': {'url': 'u', 'path': 'p'}}}, twice) == lines('Scan: 同じ名前の定義が 2 つ以上あります')
assert attempt(autopilots=twice) == lines(*['Scan: target.%s を使うので、対象のリポジトリと値を書いてください' % label for label in ('url', 'path')] * 2)
print('PASS autopilot-targets: 名前は見出しの最初の {{ の前までを空白ごと読み、同じ名前の定義が 2 つあると誤りにする')

# リポジトリは大文字小文字を区別せず、渡す設定は小文字にそろえる。
mixed = {'Scan': {'Example/One': {'url': 'U', 'path': 'p'}, 'EXAMPLE/two': {'url': 'u', 'path': 'p'}}}
assert attempt(mixed, SCAN) == {'Scan': {'example/one': {'target.url': 'U', 'target.path': 'p'}, 'example/two': {'target.url': 'u', 'target.path': 'p'}}}
print('PASS autopilot-targets: リポジトリを小文字にそろえて、target.<値の名前> のキーで渡す')

# 範囲の定義を持たない定義と、ロールの印が付いた行も読める。
roles = '## Scan {{project_key}}\n\n- 範囲: `repository`\n<!-- IF claude -->\n- 実行: `run_only`\n<!-- ELSE -->\n- 実行: `run_only`\n<!-- ENDIF -->\n- スケジュール: `0 0 * * 1`（Asia/Tokyo）\n\n```text\n<!-- IF claude -->\nScan {{target.url}}.\n<!-- ELSE -->\nScan {{target.url}}.\n<!-- ENDIF -->\n```\n'
assert attempt({'Scan': {'example/one': {'url': 'u'}}}, roles) == {'Scan': {'example/one': {'target.url': 'u'}}}
print('PASS autopilot-targets: 役の印を挟んだ定義も読める')
PY

# setup.sh から使う。拡張のディレクトリを引数で渡す。
run_extension() { (cd "$test_dir" && /bin/bash "$test_dir/package/setup.sh" --extension "$1" <"$test_dir/input" >"$test_dir/out" 2>"$test_dir/err"); }
ext="$test_dir/ext"
mkdir -p "$ext"
cp "$root/VERSION" "$ext/kit-version"
base_input yes
# 質問は読み取りだけを呼ぶ。登録や保存の呼び出しが 1 つもないことを確かめる。
no_registration() {
 [[ ! -e $test_dir/state ]]
 ! grep -vE '\|(config show|auth status|user profile get --output json|(squad|agent|skill|autopilot|workspace|project|repo) list --output json|workspace member list --output json|project resource list .*)$' "$TEST_CALLS"
 [[ -z $(find "$test_dir/package/tmp" -mindepth 1 -print) ]]
}
deny_targets() {
 : >"$TEST_CALLS"
 if run_extension "$ext"; then cat "$test_dir/out" "$test_dir/err"; exit 1; fi
 grep -qF '何も登録していません' "$test_dir/err"
 no_registration
}

# 2-1: 設定の誤りは、質問より前に全部表示して止まる。
printf '{"未定義": {"example/one": {}}, "Dependabot の PR の週次の確認": {"example/one": {"a": ""}}}\n' >"$ext/autopilot-targets.json"
deny_targets
grep -qxF 'autopilot-targets.json: 未定義: 定義にない名前です' "$test_dir/err"
grep -q '^autopilot-targets.json: Dependabot の PR の週次の確認 example/one: 値 a は 1 文字以上' "$test_dir/err"
! grep -qF '? ワークスペース' "$test_dir/err"
printf '{' >"$ext/autopilot-targets.json"
deny_targets
grep -qxF 'autopilot-targets.json: JSON として読めません' "$test_dir/err"
echo 'PASS setup: 設定の誤りは全部表示し、質問・保存・登録の前に止まる'

# 2-2: 選んだリポジトリにない設定は、質問のあとの確認で止まる。base_input は example/two だけを選ぶ。
export TEST_REPOS_FILE="$test_dir/repos.json"
printf '%s\n' '[{"url":"https://github.com/example/one"},{"url":"https://github.com/example/two"},{"url":"https://github.com/example/three"},{"url":"https://github.com/example/four"}]' >"$TEST_REPOS_FILE"
printf '{"%s": {"Example/Two": {}}, "Dependabot の PR の週次の確認": {"example/two": {}}}\n' '週 1 回の依存ライブラリの脆弱性チェック' >"$ext/autopilot-targets.json"
: >"$TEST_CALLS"
TEMPLATE_STATE_ROOT="$test_dir/ext-state" run_extension "$ext"
jq -e '.project_key=="demo"' "$test_dir/ext-state/ws-a/demo.json" >/dev/null
echo 'PASS setup: 選んだリポジトリだけを設定に書くと、通常どおり保存する'
rm -rf "$test_dir/ext-state"
printf '{"%s": {"example/two": {}, "Example/Three": {}}, "Dependabot の PR の週次の確認": {"example/four": {}}}\n' '週 1 回の依存ライブラリの脆弱性チェック' >"$ext/autopilot-targets.json"
deny_targets
grep -qxF 'autopilot-targets.json: 週 1 回の依存ライブラリの脆弱性チェック example/three: セットアップで選んでいないリポジトリです' "$test_dir/err"
grep -qxF 'autopilot-targets.json: Dependabot の PR の週次の確認 example/four: セットアップで選んでいないリポジトリです' "$test_dir/err"
! grep -qF 'example/two: セットアップで選んでいない' "$test_dir/err"
echo 'PASS setup: 選んでいないリポジトリを設定に書くと、全部表示して保存・登録の前に止まる'

# 紐付けだけのリポジトリは、選んだことにならない。
printf '["example/three"]\n' >"$ext/link-repositories.json"
printf '{"%s": {"example/three": {}}}\n' '週 1 回の依存ライブラリの脆弱性チェック' >"$ext/autopilot-targets.json"
deny_targets
grep -qxF 'autopilot-targets.json: 週 1 回の依存ライブラリの脆弱性チェック example/three: セットアップで選んでいないリポジトリです' "$test_dir/err"
echo 'PASS setup: 紐付けだけのリポジトリを設定に書くと、選んでいないものとして止まる'

# 設定がなければ、今までどおり通る。
rm -f "$ext/autopilot-targets.json" "$ext/link-repositories.json"
TEMPLATE_STATE_ROOT="$test_dir/ext-state" run_extension "$ext"
jq -e '.project_key=="demo"' "$test_dir/ext-state/ws-a/demo.json" >/dev/null
echo 'PASS setup: 設定がなければ、今までどおり保存する'
