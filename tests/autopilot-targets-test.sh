#!/usr/bin/env bash
# autopilot-targets.json の確認を、拡張の読み込み（lib/extensions.py）と、setup.sh の選択済みリポジトリの照合で行う。
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

# 書式の崩れた {{target.…}} は、見出し・スケジュール・指示の前後と中のどこにあっても登録の前に止める。
bad_refs = ('{{target.}}', '{{target.branch }}', '{{target./branch}}', '{{target.*}}', '{{target.branch}', '{{target.branch')
placements = {
    '見出し': lambda ref: SCAN.replace('## Scan {{project_key}}', '## Scan ' + ref + ' {{project_key}}'),
    'スケジュール': lambda ref: SCAN.replace('`0 0 * * 1`', '`' + ref + '`'),
    '指示の前': lambda ref: SCAN.replace('\n```text', '\n' + ref + '\n\n```text'),
    '指示の中': lambda ref: SCAN.replace('Scan {{target.url}}', 'Scan ' + ref + ' {{target.url}}'),
    '指示の後': lambda ref: SCAN + '\n補足は ' + ref + '\n',
}
for place, build in placements.items():
    for ref in bad_refs:
        result = attempt(valid, build(ref))
        assert isinstance(result, list) and any(line.startswith(PREFIX + 'Scan: ' + ref.rstrip('}')) and '{{target.<値の名前>}} の形で書いてください' in line for line in result), (place, ref, result)
# 設定がなくても止める。正しい参照は誤りにしない。
assert attempt(autopilots=SCAN.replace('{{target.url}}', '{{target.}}').replace('{{target.path}}', 'y')) == lines('Scan: {{target.}} は {{target.<値の名前>}} の形で書いてください')
assert attempt(valid, SCAN) == {'Scan': {'example/one': {'target.url': 'u', 'target.path': 'p'}}}
print('PASS autopilot-targets: 書式の崩れた {{target.…}} を、どこに書いても登録の前に止める')

# 同じ名前の定義は範囲を問わず数える。原本の member の定義と同名の repository の定義で、原本の定義を外せない。
guard = '## ' + MEMBER + ' {{project_key}} {{repository}}\n\n- 範囲: `repository`\n- 実行: `run_only`\n- スケジュール: `0 0 * * 1`（Asia/Tokyo）\n\n```text\nx\n```\n'
assert attempt({MEMBER: {'example/app': {}}}, guard) == lines(f'{MEMBER}: 同じ名前の定義が 2 つ以上あります')
assert attempt({MEMBER: {'example/app': {}}}) == lines(f'{MEMBER}: 範囲が repository の定義ではありません')
print('PASS autopilot-targets: 原本の member の定義と同名の repository の定義を設定に書くと止める')

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
# 質問は読み取りだけを呼ぶ。登録や保存の呼び出しが 1 つもないことを確認する。
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

# 書式の崩れた {{target.…}} と、原本の member の定義と同名の repository の定義は、登録の前に止まる。
definition='## %s {{project_key}} {{repository}}\n\n- 範囲: `repository`\n- 実行: `run_only`\n- スケジュール: `0 0 * * 1`（Asia/Tokyo）\n\n```text\n%s\n```\n'
for ref in '{{target.}}' '{{target.branch }}' '{{target./branch}}' '{{target.*}}'; do
 printf "$definition" Scan "Scan $ref." >"$ext/autopilots.md"
 printf '{"Scan": {"example/one": {"branch": "main"}}}\n' >"$ext/autopilot-targets.json"
 deny_targets
 grep -qxF "autopilot-targets.json: Scan: ${ref} は {{target.<値の名前>}} の形で書いてください" "$test_dir/err"
done
printf "$definition" '使用上限の見張り' x >"$ext/autopilots.md"
printf '{"使用上限の見張り": {"example/one": {}}}\n' >"$ext/autopilot-targets.json"
deny_targets
grep -qxF 'autopilot-targets.json: 使用上限の見張り: 同じ名前の定義が 2 つ以上あります' "$test_dir/err"
rm -f "$ext/autopilots.md" "$ext/autopilot-targets.json"
echo 'PASS setup: 書式の崩れた target の参照と、原本の member の定義と同名の定義は、保存・登録の前に止まる'

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

# 1-1、3-1 の定期確認、4-1: 登録に渡す一覧を、本体の展開で確認する。
(
kit=$root
source "$kit/lib/render.sh"
source "$kit/lib/autopilots.sh"
die() { echo "$*" >&2; exit 1; }
project_work=$test_dir/expansion
mkdir -p "$project_work"
enabled='security-reviewer dependabot-merger usage-monitor'
selected_repositories='[{"repository":"example/wiki"},{"repository":"example/app"}]'
records=$(jq -n --arg roles "$template_roles" 'reduce ($roles|split(" ")[]) as $role ({}; .[$role]={id:("id-"+$role),name:("demo-"+$role+"-owner")})')
jq -n --argjson records "$records" '{project_id:"project-a",project_key:"demo",member_key:"owner",squad_id:"squad-a"} | reduce ($records|to_entries[]) as $r (.; .["agent."+$r.key+".name"]=$r.value.name)' >"$project_work/values.json"

# 変更前の、ファイル全体をリポジトリごとに展開する手順で期待値を作る。
legacy_expansion() {
 local repo first=yes
 template_filter "$enabled" "$root/common/autopilots.md" >"$project_work/legacy.filtered"
 printf '[]\n' >"$project_work/legacy.json"
 while IFS= read -r repo; do
  jq --arg repo "$repo" '.repository=$repo' "$project_work/values.json" >"$project_work/legacy.values"
  template_apply "$project_work/legacy.values" "$project_work/legacy.filtered" >"$project_work/legacy.rendered"
  autopilot_sections "$project_work/legacy.rendered" >"$project_work/legacy.sections"
  jq --arg repo "$repo" --arg first "$first" --slurpfile sections "$project_work/legacy.sections" '.+[$sections[0][] | select(.scope=="repository" or $first=="yes") | .+{repository:(if .scope=="repository" then $repo else null end)}]' "$project_work/legacy.json" >"$project_work/legacy.new"
  mv "$project_work/legacy.new" "$project_work/legacy.json"
  first=no
 done < <(jq -r '.[].repository' <<<"$selected_repositories")
}
legacy_expansion
prepare_autopilots
cmp "$project_work/legacy.json" "$project_work/autopilots.json"
echo 'PASS autopilot-targets: 拡張がなければ、名前・指示・スケジュールが変更前の展開と一致する'

exp_ext=$test_dir/exp-extension
mkdir -p "$exp_ext"
cp "$kit/VERSION" "$exp_ext/kit-version"
cat >"$exp_ext/autopilots.md" <<'DEFINITION'
## Extra check {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.security-reviewer.name}}
- 実行: `run_only`
- スケジュール: `0 9 * * 3`（Asia/Tokyo）

指示:

```text
{{repository}} の追加の確認。
## 指示の中の見出し
```
DEFINITION
python3 "$kit/lib/extensions.py" "$kit" "$exp_ext" "$test_dir/no-targets"
root=$test_dir/no-targets
legacy_expansion
prepare_autopilots
cmp "$project_work/legacy.json" "$project_work/autopilots.json"
jq -e 'length==7 and ([.[]|select(.scope=="member")]|length)==1' "$project_work/autopilots.json" >/dev/null
echo 'PASS autopilot-targets: 設定のない拡張も、追加の定義を含めて変更前の展開と一致する'

# 同じリポジトリの同名の値でも、定義ごとに違う値を差し込む。
python3 - "$exp_ext" <<'CONFIG'
import json
import sys
from pathlib import Path
ext = Path(sys.argv[1])
scan = """## DAST の結果の確認 {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.security-reviewer.name}}
- 実行: `run_only`
- スケジュール: `0 9 * * 4`（Asia/Tokyo）

指示:

```text
{{repository}} の {{target.branch}} と {{target.artifact}} を確認する。
## 指示の見出し {{target.branch}}
```
"""
with (ext / 'autopilots.md').open('a') as f:
    f.write('\n' + scan + '\n' + scan.replace('DAST の結果の確認', '別の DAST の確認'))
(ext / 'autopilot-targets.json').write_text(json.dumps({
    'DAST の結果の確認': {'Example/App': {'branch': 'develop', 'artifact': 'zap-report'}},
    '別の DAST の確認': {'example/app': {'branch': 'release/$name "v" {one}', 'artifact': 'other-report'}},
    '週 1 回の依存ライブラリの脆弱性チェック': {'example/app': {}},
    'Dependabot の PR の週次の確認': {'example/app': {}},
}))
CONFIG
python3 "$kit/lib/extensions.py" "$kit" "$exp_ext" "$test_dir/with-targets"
root=$test_dir/with-targets
prepare_autopilots
jq -e 'length==7 and ([.[]|select(.title|startswith("DAST の結果の確認 "))] | length==1 and .[0].repository=="example/app" and .[0].instructions=="example/app の develop と zap-report を確認する。\n## 指示の見出し develop\n" and .[0].cron=="0 9 * * 4" and .[0].timezone=="Asia/Tokyo")' "$project_work/autopilots.json" >/dev/null
jq -e '[.[]|select(.title|startswith("別の DAST の確認 "))] | length==1 and (.[0].instructions|contains("release/$name \"v\" {one} と other-report"))' "$project_work/autopilots.json" >/dev/null
echo 'PASS autopilot-targets: app だけの拡張の定期確認に、定義ごとのブランチと成果物を差し込む'
jq -e '([.[]|select(.title|startswith("週 1 回の依存ライブラリの脆弱性チェック "))]|length)==1 and ([.[]|select(.title|startswith("Dependabot の PR の週次の確認 "))]|length)==1 and all(.[]|select(.title|startswith("週 1 回の依存ライブラリの脆弱性チェック ") or startswith("Dependabot の PR の週次の確認 ")); .repository=="example/app")' "$project_work/autopilots.json" >/dev/null
echo 'PASS autopilot-targets: 原本の 2 つを app に絞ると、Wiki の定期確認がない'
jq -e '([.[]|select(.title|startswith("Extra check "))]|length)==2 and ([.[]|select(.scope=="member")]|length)==1' "$project_work/autopilots.json" >/dev/null
echo 'PASS autopilot-targets: 設定にない定義は全リポジトリに展開し、member の定義は 1 回だけ展開する'
# 設定に member の定義の名前があっても、展開では絞り込みも値の追加もしない。
cp "$root/extension-autopilot-targets.json" "$project_work/targets.keep"
jq '. + {"使用上限の見張り": {"example/app": {"branch": "x"}}}' "$project_work/targets.keep" >"$root/extension-autopilot-targets.json"
prepare_autopilots
jq -e '([.[]|select(.scope=="member")]|length)==1 and ([.[]|select(.title|startswith("使用上限の見張り"))]|length)==1' "$project_work/autopilots.json" >/dev/null
cp "$project_work/targets.keep" "$root/extension-autopilot-targets.json"
echo 'PASS autopilot-targets: 設定に member の定義の名前があっても、member の定義は絞らない'

# 見出し前の文は展開せず、member の指示には最初のリポジトリの値を使う。
python3 - "$root/common/autopilots.md" <<'MEMBER'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text('{{missing}}\n' + path.read_text() + """
## Member check {{member_key}}

- 範囲: `member`
- 担当: {{agent.usage-monitor.name}}
- 実行: `run_only`
- スケジュール: `0 1 * * 1`（Asia/Tokyo）

```text
{{repository}}
```
""")
MEMBER
prepare_autopilots
jq -e '[.[]|select(.title=="Member check owner")]|length==1 and .[0].repository==null and .[0].instructions=="example/wiki\n"' "$project_work/autopilots.json" >/dev/null
echo 'PASS autopilot-targets: 見出し前の文は展開せず、member の指示には最初のリポジトリを使う'
)
