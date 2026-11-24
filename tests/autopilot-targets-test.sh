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

# 5-1、5-2、5-5、6-1: 選択は変えず、対象の設定だけを変えて登録を流し直す。
(
source "$root/tests/project-followup-test-lib.sh"
export TEST_REPOSITORIES='["example/wiki","example/app"]' TEST_EXCLUDED='[]'
phase3_extension=$test_dir/extension
mkdir -p "$phase3_extension"
cp "$root/VERSION" "$phase3_extension/kit-version"
cat >"$phase3_extension/autopilots.md" <<'DEFINITION'
## DAST の結果の確認 {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.security-reviewer.name}}
- 実行: `run_only`
- スケジュール: `0 9 * * 4`（Asia/Tokyo）

指示:

```text
{{repository}} の {{target.branch}} と {{target.artifact}} を確認する。
```
DEFINITION

# 拡張の確認と本体の展開・同期を通す。CLI は既存の DB のスタブを使う。
phase3_targets() {
 local selection=$1 prepared=$test_dir/prepared-$1
 python3 - "$phase3_extension" "$selection" <<'CONFIG'
import json
import sys
from pathlib import Path
extension = Path(sys.argv[1])
selection = sys.argv[2]
repos = ['example/app'] if selection == 'app' else ['example/wiki', 'example/app']
config = {name: {repo: {} for repo in repos} for name in (
    '週 1 回の依存ライブラリの脆弱性チェック', 'Dependabot の PR の週次の確認')}
config['DAST の結果の確認'] = {
    repo: {'branch': 'release' if selection == 'restored' else 'develop',
           'artifact': 'new-report' if selection == 'restored' else 'zap-report'}
    for repo in repos
}
(extension / 'autopilot-targets.json').write_text(json.dumps(config))
CONFIG
 python3 "$root/lib/extensions.py" "$root" "$phase3_extension" "$prepared"
 cp -R "$prepared/common/." "$TEST_PACKAGE/common/"
 cp "$prepared/extension-autopilot-targets.json" "$TEST_PACKAGE/"
}
phase3_triggers_unchanged() {
 local trigger
 for trigger in "$test_dir/before-triggers/"*.json; do cmp "$trigger" "$TEST_DB/${trigger##*/}"; done
}

phase3_targets all
reset_db
run
jq -e 'length==7 and all(.[]; .status=="active")' "$TEST_DB/autopilots.json" >/dev/null
cp -R "$TEST_DB" "$test_dir/completed-unfiltered"
cp "$TEST_DB/autopilots.json" "$test_dir/before-targets"
mkdir -p "$test_dir/before-triggers"
cp "$TEST_DB/"triggers-*.json "$test_dir/before-triggers/"
wiki_titles=$(jq -c '[.[]|select(.title|endswith(" example/wiki"))|.title]|sort' "$TEST_DB/autopilots.json")

# 5-1: Wiki は選んだまま対象から外し、3 つの登録だけを一時停止する。
phase3_targets app
: >"$TEST_DB/calls"
run
jq -e 'length==7 and all(.[]|select(.title|endswith(" example/wiki")); .status=="paused") and all(.[]|select(.title|endswith(" example/wiki")|not); .status=="active")' "$TEST_DB/autopilots.json" >/dev/null
jq -e --slurpfile before "$test_dir/before-targets" 'map(del(.status))==($before[0]|map(del(.status)))' "$TEST_DB/autopilots.json" >/dev/null
jq -e --argjson expected "$wiki_titles" '.==$expected' "$TEST_DB/removed-targets.json" >/dev/null
while IFS= read -r title; do
 grep -F "$title" "$test_dir/err" | grep -q '一時停止'
done < <(jq -r '.[]' <<<"$wiki_titles")
jq -es '([.[]|select(.[0]=="autopilot" and .[1]=="update")]|length)==3 and all(.[]|select(.[0]=="autopilot" and .[1]=="update"); .[3:5]==["--status","paused"]) and all(.[]; index("delete")==null)' "$TEST_DB/calls" >/dev/null
phase3_triggers_unchanged
echo 'PASS autopilot-targets: 選んだまま対象から外した Wiki の登録を止めて名前を表示し、ID・指示・トリガーを残して削除しない'

# 5-2: 対象の app を重ねて作らず、同じ設定の 2 回目は書き込みがない。
cp "$TEST_DB/autopilots.json" "$test_dir/after-targets"
: >"$TEST_DB/calls"
run
no_writes
cmp "$test_dir/after-targets" "$TEST_DB/autopilots.json"
phase3_triggers_unchanged
echo 'PASS autopilot-targets: app の登録を重ねず、同じ対象の設定をもう一度流すと作成も変更も 0 件になる'

# 5-5: 対象に戻すと指示とスケジュールを合わせるが、一時停止は再開しない。
python3 - "$phase3_extension/autopilots.md" <<'SCHEDULE'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('0 9 * * 4', '0 8 * * 5'))
SCHEDULE
phase3_targets restored
: >"$TEST_DB/calls"
run
jq -e --slurpfile before "$test_dir/after-targets" 'map({id,title,status})==($before[0]|map({id,title,status}))' "$TEST_DB/autopilots.json" >/dev/null
jq -e 'all(.[]|select(.title|startswith("DAST の結果の確認 ")); (.description|contains("release と new-report")))' "$TEST_DB/autopilots.json" >/dev/null
while IFS= read -r id; do
 jq -e '.[0].cron_expression=="0 8 * * 5" and .[0].timezone=="Asia/Tokyo"' "$TEST_DB/triggers-$id.json" >/dev/null
done < <(jq -r '.[]|select(.title|startswith("DAST の結果の確認 "))|.id' "$TEST_DB/autopilots.json")
jq -es 'all(.[]; .[1]!="create" and .[1]!="delete" and index("--status")==null)' "$TEST_DB/calls" >/dev/null
echo 'PASS autopilot-targets: Wiki を対象に戻すと、同じ ID の一時停止を保ち、指示とスケジュールだけを合わせる'

# 6-1: 別の担当・別のプロジェクト・利用者の登録と、人間が止めた状態を保つ。
restore_completed unfiltered
cp "$test_dir/prepared-app/common/autopilots.md" "$TEST_PACKAGE/common/"
cp "$test_dir/prepared-app/extension-autopilot-targets.json" "$TEST_PACKAGE/"
jq 'map(if (.title|startswith("週 1 回の依存ライブラリの脆弱性チェック ")) and (.title|endswith(" example/wiki")) then .assignee_id="foreign-agent"
 elif (.title|startswith("Dependabot の PR の週次の確認 ")) and (.title|endswith(" example/wiki")) then .project_id="other-project"
 elif (.title|startswith("DAST の結果の確認 ")) then .status="paused" else . end) |
 .+[(.[]|select(.title=="DAST の結果の確認 demo example/wiki")|.+{id:"manual",title:"利用者の確認 example/wiki",status:"active"})]' "$TEST_DB/autopilots.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
cp "$TEST_DB/autopilots.json" "$test_dir/protected"
: >"$TEST_DB/calls"
run
no_writes
cmp "$test_dir/protected" "$TEST_DB/autopilots.json"
phase3_triggers_unchanged
! grep -q '保持しました' "$test_dir/err"
echo 'PASS autopilot-targets: 別の担当・別プロジェクト・利用者の登録と、人間が止めた対象内外の登録は変えず、保持の表示を出さない'

# 管理する役のエージェントでも、定義の今の担当と違えば止めない。
jq 'map(if .assignee_id=="foreign-agent" then .assignee_id="agent-dependabot-merger" else . end)' "$TEST_DB/autopilots.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/autopilots.json"
cp "$TEST_DB/autopilots.json" "$test_dir/protected"
: >"$TEST_DB/calls"
run
no_writes
cmp "$test_dir/protected" "$TEST_DB/autopilots.json"
! grep -q '保持しました' "$test_dir/err"
echo 'PASS autopilot-targets: 管理する別の役の担当へ替えた登録も、対象から外しても止めない'
)

# 3-1 の Webhook と起票、5-4: 対象だけに登録し、外したリポジトリの残りは消さずに起票する。
(
phase4_kit=$root
phase4_package=$test_dir/phase4-package
mkdir -p "$phase4_package" "$test_dir/phase4-bin" "$test_dir/phase4-extension"
cp "$root/VERSION" "$phase4_package/"
cp -R "$root/lib" "$root/common" "$phase4_package/"
cp "$root/VERSION" "$test_dir/phase4-extension/kit-version"
printf '%s\n' '{"週 1 回の依存ライブラリの脆弱性チェック":{"example/app":{}},"Dependabot の PR の週次の確認":{"example/app":{}}}' >"$test_dir/phase4-extension/autopilot-targets.json"
python3 "$root/lib/extensions.py" "$root" "$test_dir/phase4-extension" "$test_dir/phase4-prepared"
cp "$test_dir/phase4-prepared/extension-autopilot-targets.json" "$phase4_package/"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/setup-runtime-cli.py" >"$test_dir/phase4-bin/multica"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/webhook-gh.py" >"$test_dir/phase4-bin/gh"
chmod +x "$test_dir/phase4-bin/"*
cat >"$test_dir/phase4-driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
cd "$root"
die() { echo "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/questions.sh"
source "$root/lib/check.sh"
source "$root/lib/workspace.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
source "$root/lib/project-changes.sh"
source "$root/lib/webhooks.sh"
server_url=https://example.test; workspace_id=workspace-a
project_id=project-a; project_key=demo; host_owner_id=actor; squad_id=squad-a
records='{"dependabot-merger":{"id":"dep"}}'
enabled=dependabot-merger
dependabot_webhook=${TEST_WEBHOOK:-true}
selected_repositories='[{"repository":"example/wiki"},{"repository":"example/app"}]'
project_work=$TEST_DB/work
mkdir -p "$project_work"
setup_webhook_rows='[]'; setup_webhook_leftovers='[]'; setup_issue_rows='[]'; setup_issue_failures='[]'
prepare_project_webhooks
prepare_project_issues
project_webhook_completion
project_issue_completion
jq -n --arg summary "${webhook_summary:-}" --argjson rows "$setup_webhook_rows" --argjson leftovers "$setup_webhook_leftovers" '{summary:$summary,rows:$rows,leftovers:$leftovers}' >"$TEST_DB/result.json"
[[ $(jq length <<<"$setup_issue_failures") == 0 ]]
DRIVER
export PATH="$test_dir/phase4-bin:$PATH" TEST_PACKAGE="$phase4_package"
phase4_case() {
 TEST_DB=$test_dir/phase4-$1; export TEST_DB
 mkdir -p "$TEST_DB"
 python3 "$phase4_kit/tests/project-issues-fixture.py" "$phase4_package" "$TEST_DB/db.json"
 jq '.autopilots=[{id:"app",title:"Dependabot の PR の週次の確認 demo example/app",project_id:"project-a",assignee_id:"dep",assignee_type:"agent"}] |
 .triggers={app:[{id:"schedule-app",kind:"schedule",cron_expression:"0 10 * * 2",timezone:"Asia/Tokyo"}]} | .github_hooks=[]' "$TEST_DB/db.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/db.json"
}
phase4_edit() { jq "$1" "$TEST_DB/db.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/db.json"; }
phase4_run() { /bin/bash "$test_dir/phase4-driver" >"$test_dir/out" 2>"$test_dir/err"; }
phase4_no_wiki_registration() {
 ! jq -es 'any(.[]; .[1]|startswith("repos/example/wiki"))' "$TEST_DB/gh-calls.jsonl" >/dev/null
 jq -e 'all(.issues[]|select(.metadata.repository=="example/wiki"); .metadata.squad_kit_task!="dependabot-webhook" and .metadata.squad_kit_task!="dependabot-filter")' "$TEST_DB/db.json" >/dev/null
}
phase4_existing_wiki() {
 phase4_edit '.autopilots+=[{id:"wiki",title:"Dependabot の PR の週次の確認 demo example/wiki",project_id:"project-a",assignee_id:"dep",assignee_type:"agent",status:"paused",fail_secrets:true,canary_on_default_get:true}] |
 .triggers.wiki=[{id:"schedule-wiki",kind:"schedule"},{id:"webhook-wiki",kind:"webhook",enabled:true}] |
 .github_hooks+=[{id:99,repository:"example/wiki",active:true,events:["pull_request"],content_type:"json",destination:"wiki"}]'
}

# 登録に失敗した場合の代わりのタスクも、対象の app だけにする。
phase4_case filtered
phase4_edit '.webhook_cases["example/app"].admin=false'
phase4_run
phase4_no_wiki_registration
jq -e '.issues|([.[]|select(.metadata.squad_kit_task=="dependabot-webhook")]|length)==1 and ([.[]|select(.metadata.squad_kit_task=="dependabot-filter")]|length)==1 and ([.[]|select(.metadata.squad_kit_task=="repository-rules")]|length)==2' "$TEST_DB/db.json" >/dev/null
jq -e '.summary=="1" and (.rows|length)==1 and .rows[0].repository=="example/app" and .leftovers==[]' "$TEST_DB/result.json" >/dev/null
! grep -q '^  ! example/wiki' "$test_dir/out"
echo 'PASS autopilot-targets: Wiki に Webhook・登録を頼むタスク・フィルターのタスクを作らず、ルールのタスクは両リポジトリに残す'

phase4_case registered
phase4_run
phase4_no_wiki_registration
jq -e '.github_hooks|length==1 and .[0].repository=="example/app"' "$TEST_DB/db.json" >/dev/null
echo 'PASS autopilot-targets: Webhook の登録と件数は対象の app だけにし、管理する登録のない Wiki は警告しない'

phase4_case leftover
phase4_existing_wiki
cp "$TEST_DB/db.json" "$test_dir/phase4-leftover-before"
phase4_run
phase4_no_wiki_registration
jq -e '.triggers.wiki==input.triggers.wiki' "$TEST_DB/db.json" "$test_dir/phase4-leftover-before" >/dev/null
jq -e '[.github_hooks[]|select(.repository=="example/wiki")]==[input.github_hooks[]|select(.repository=="example/wiki")]' "$TEST_DB/db.json" "$test_dir/phase4-leftover-before" >/dev/null
jq -e '[.issues[]|select(.metadata.squad_kit_task=="dependabot-webhook-removal")]|length==1 and .[0].metadata.repository=="example/wiki" and (.[0].description|contains("確認の対象から外した設定"))' "$TEST_DB/db.json" >/dev/null
grep -qxF '  ! example/wiki  Dependabot の確認の対象から外しましたが、前の実行で作った Webhook のトリガーが残っています。外すよう起票しました。' "$test_dir/out"
! jq -es 'any(.[]; (.[0:3]==["autopilot","get","wiki"] and index("--show-secrets")!=null) or index("delete")!=null)' "$TEST_DB/calls.jsonl" >/dev/null
cp "$TEST_DB/db.json" "$test_dir/phase4-leftover-after"
: >"$TEST_DB/calls.jsonl"; : >"$TEST_DB/gh-calls.jsonl"
phase4_run
cmp "$test_dir/phase4-leftover-after" "$TEST_DB/db.json"
! jq -es 'any(.[]; .[1]=="create" or .[1]=="update" or .[1]=="metadata" or .[1]=="trigger-add" or .[1]=="delete")' "$TEST_DB/calls.jsonl" >/dev/null
echo 'PASS autopilot-targets: 外した Wiki に残ったトリガーと GitHub の Webhook を消さず、秘密を取得せず、外すタスクを 1 回だけ起票する'

phase4_case no-trigger
phase4_existing_wiki
phase4_edit '.triggers.wiki|=map(select(.kind!="webhook"))'
phase4_run
jq -e '.leftovers==[]' "$TEST_DB/result.json" >/dev/null
jq -e 'all(.issues[]; .metadata.squad_kit_task!="dependabot-webhook-removal")' "$TEST_DB/db.json" >/dev/null
echo 'PASS autopilot-targets: 外した Wiki の登録に Webhook のトリガーがなければ、警告も起票もしない'

for failure in list get malformed; do
 phase4_case "unreadable-$failure"
 phase4_existing_wiki
 case $failure in
 list) printf '%s\n' 'autopilot list' >"$TEST_DB/fail-read" ;;
 get) printf '%s\n' 'autopilot get wiki' >"$TEST_DB/fail-read" ;;
 malformed) printf '%s\n' 'autopilot list' >"$TEST_DB/bad-read" ;;
 esac
 phase4_run
 jq -e '.leftovers|length==1 and .[0].repository=="example/wiki" and .[0].state=="確認できない"' "$TEST_DB/result.json" >/dev/null
 jq -e 'all(.issues[]; .metadata.squad_kit_task!="dependabot-webhook-removal")' "$TEST_DB/db.json" >/dev/null
 grep -q '^  ! example/wiki  .*確認できませんでした' "$test_dir/out"
done
echo 'PASS autopilot-targets: 外した登録の一覧や内容を読めない場合は、登録なしと区別して表示し、外すタスクは起票しない'

phase4_case foreign
phase4_existing_wiki
phase4_edit '.autopilots|=map(if .id=="wiki" then .assignee_id="foreign-agent" else . end)'
phase4_run
jq -e '.leftovers==[]' "$TEST_DB/result.json" >/dev/null
jq -e 'all(.issues[]; .metadata.squad_kit_task!="dependabot-webhook-removal")' "$TEST_DB/db.json" >/dev/null
echo 'PASS autopilot-targets: 別の担当の登録は、対象から外しても Webhook を外すタスクの対象にしない'
)

# 7-1、7-2: 確認の表示と、対象を絞った一覧での導入の確認を本体で行う。
(
phase5_kit=$root
mkdir -p "$test_dir/phase5-extension" "$test_dir/phase5-bin"
cp "$root/VERSION" "$test_dir/phase5-extension/kit-version"
cat >"$test_dir/phase5-extension/autopilots.md" <<'DEFINITION'
## App events {{project_key}} {{repository}}

- 範囲: `repository`
- 担当: {{agent.dependabot-merger.name}}
- 実行: `run_only`
- トリガー: `webhook`

```text
{{repository}} のイベントを確認する。
```
DEFINITION
printf '%s\n' '{"週 1 回の依存ライブラリの脆弱性チェック":{"example/app":{}},"Dependabot の PR の週次の確認":{"example/app":{}},"App events":{"example/app":{}}}' >"$test_dir/phase5-extension/autopilot-targets.json"
python3 "$root/lib/extensions.py" "$root" "$test_dir/phase5-extension" "$test_dir/phase5-package"
phase5_package=$test_dir/phase5-package
cp -R "$root/lib" "$phase5_package/"
cp "$root/VERSION" "$phase5_package/"
export TEST_DB=$test_dir/phase5-db TEST_PACKAGE="$phase5_package"
mkdir -p "$TEST_DB"
python3 "$root/tests/project-issues-fixture.py" "$phase5_package" "$TEST_DB/db.json"
python3 "$root/tests/installation-fixture.py" "$TEST_DB"
printf '#!/bin/bash\nexec %q %q "$TEST_DB" "$@"\n' "$(command -v python3)" "$root/tests/setup-runtime-cli.py" >"$test_dir/phase5-bin/multica"
chmod +x "$test_dir/phase5-bin/multica"
export PATH="$test_dir/phase5-bin:$PATH"

# 登録する予定は実際の prepare_autopilots で作る。
(
root=$phase5_package
source "$root/lib/render.sh"
source "$root/lib/autopilots.sh"
die() { echo "$*" >&2; exit 1; }
project_work=$TEST_DB/work
records=$(cat "$project_work/records.json")
enabled='orchestrator codex-implementer ci-monitor dependabot-merger'
selected_repositories='[{"repository":"example/wiki"},{"repository":"example/app"}]'
jq -n --argjson records "$records" '{project_id:"project-a",project_key:"demo",member_key:"owner",squad_id:"squad-a"}|reduce ($records|to_entries[]) as $r (.; .["agent."+$r.key+".name"]=$r.value.name)' >"$project_work/values.json"
prepare_autopilots
jq -e 'length==2 and all(.[]; .repository=="example/app")' "$project_work/autopilots.json" >/dev/null
)
python3 - "$TEST_DB" <<'STATE'
import json
import sys
from pathlib import Path
folder = Path(sys.argv[1])
db = json.loads((folder / 'db.json').read_text())
records = json.loads((folder / 'work/records.json').read_text())
definitions = json.loads((folder / 'work/autopilots.json').read_text())
db['autopilots'], db['triggers'] = [], {}
for n, desired in enumerate(definitions):
    id_ = f'phase5-{n}'
    agent = next(record['id'] for record in records.values() if record['name'] == desired['agent'])
    db['autopilots'].append(dict(id=id_, title=desired['title'], description=desired['instructions'].rstrip('\n'),
        project_id='project-a', status='active', assignee_type='agent', assignee_id=agent, execution_mode=desired['mode']))
    trigger = dict(id=id_ + '-trigger', kind=desired.get('trigger', 'schedule'), enabled=True)
    if trigger['kind'] == 'schedule':
        trigger.update(cron_expression=desired['cron'], timezone=desired['timezone'])
    db['triggers'][id_] = [trigger]
# 外した分は、不一致の内容が残っていても導入の確認の対象にしない。
db['autopilots'].append(dict(id='outside-wiki', title='Dependabot の PR の週次の確認 demo example/wiki',
    description='old', project_id='project-a', status='paused', assignee_type='agent',
    assignee_id='agent-dependabot-merger', execution_mode='run_only'))
db['triggers']['outside-wiki'] = []
db['resources'] = [dict(resource_type='github_repo', resource_ref=dict(url=f'https://github.com/example/{repo}'))
                   for repo in ['wiki', 'app']]
(folder / 'db.json').write_text(json.dumps(db))
STATE
cp "$TEST_DB/db.json" "$test_dir/phase5-baseline"
cat >"$test_dir/phase5-driver" <<'DRIVER'
set -euo pipefail
root=$TEST_PACKAGE
cd "$root"
die() { echo "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/render.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
source "$root/lib/installation.sh"
server_url=https://example.test; workspace_id=workspace-a
project_id=project-a; project_key=demo; member_key=owner; host_owner_id=actor
squad_id=squad-a; squad_name=DEMO-OWNER
member_ids='["actor"]'; runtimes='["codex"]'; codex_runtime_id=runtime-codex
project_work=$TEST_DB/work
records=$(cat "$project_work/records.json")
enabled='orchestrator codex-implementer ci-monitor dependabot-merger'
setup_installation_rows='[]'; setup_issue_rows='[]'; setup_issue_failures='[]'
verify_project_installation
project_installation_completion
printf '%s\n' "$setup_installation_rows" >"$TEST_DB/installation-rows.json"
[[ $(jq length <<<"$setup_issue_failures") == 0 ]]
DRIVER
phase5_run() { /bin/bash "$test_dir/phase5-driver" >"$test_dir/out" 2>"$test_dir/err"; }
phase5_edit() { jq "$1" "$TEST_DB/db.json" >"$TEST_DB/new"; mv "$TEST_DB/new" "$TEST_DB/db.json"; }
phase5_run
jq -e 'all(.[]; .status=="一致") and ([.[]|select(.name|startswith("オートパイロット "))]|length)==2 and all(.[]; (.name|contains("example/wiki")|not))' "$TEST_DB/installation-rows.json" >/dev/null
jq -e '.issues==[]' "$TEST_DB/db.json" >/dev/null
! jq -es 'any(.[]; .[0:3]==["autopilot","get","outside-wiki"])' "$TEST_DB/calls.jsonl" >/dev/null
echo 'PASS autopilot-targets: 対象を絞って全 5 群の導入の確認が通り、外した Wiki の登録は確認も起票もしない'

cat >"$test_dir/phase5-plan" <<'PLAN'
set -euo pipefail
root=$TEST_PACKAGE
die() { echo "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/render.sh"
source "$root/lib/answers.sh"
source "$root/lib/questions.sh"
server_url=https://example.test; workspace_id=workspace-a; project_id=project-a
project_key=demo; member_key=owner; question_actor_id=actor
question_squads=$(jq '.squads' "$TEST_DB/db.json")
question_people=$(jq '.members' "$TEST_DB/db.json")
template_roles='orchestrator security-reviewer dependabot-merger usage-monitor'
runtimes='["codex"]'; excluded_roles=${TEST_EXCLUDED:-[]}
repositories='[{"repository":"example/wiki"},{"repository":"example/app"}]'
link_repositories='[]'; member_ids='["actor"]'
confirmation_plan >"$TEST_DB/plan.json"
confirmation_show "$(cat "$TEST_DB/plan.json")"
for kind in security-reviewer dependabot-merger; do
 role_choice_text "$(jq -c --arg kind "$kind" '.[]|select(.key==$kind)' <<<"$role_choices")" '  ' ''
done >"$TEST_DB/role-text"
PLAN
/bin/bash "$test_dir/phase5-plan" >"$test_dir/out" 2>"$test_dir/err"
jq -e '([.[]|select(.group=="オートパイロット")]|length)==3 and all(.[]|select(.group=="オートパイロット"); (.name|contains("example/wiki")|not))' "$TEST_DB/plan.json" >/dev/null
! grep -qF 'example/wiki' "$TEST_DB/role-text"
grep -qF 'example/app' "$TEST_DB/role-text"
TEST_EXCLUDED='["security-reviewer","dependabot-merger"]' /bin/bash "$test_dir/phase5-plan" >"$test_dir/out" 2>"$test_dir/err"
jq -e 'all(.[]|select(.group=="役" and (.name=="security-reviewer" or .name=="dependabot-merger")); (.value|contains("example/app")) and (.value|contains("example/wiki")|not))' "$TEST_DB/plan.json" >/dev/null
echo 'PASS autopilot-targets: 確認の表示と外す役の 2 種の一覧は、原本の定期確認を対象の app だけにする'

for id in phase5-0 phase5-1; do
 cp "$test_dir/phase5-baseline" "$TEST_DB/db.json"
 phase5_edit ".autopilots|=map(if .id==\"$id\" then .status=\"paused\" else . end)"
 phase5_run
 jq -e '[.[]|select(.status=="要確認")]|length==1 and .[0].reason=="一時停止しています。止めたままでよいか確認し、動かすなら画面で再開してください。"' "$TEST_DB/installation-rows.json" >/dev/null
 phase5_edit ".autopilots|=map(if .id==\"$id\" then .description=\"old\" else . end)"
 phase5_run
 jq -e '[.[]|select(.status=="要確認")]|length==1 and .[0].reason=="定義と一致しません。"' "$TEST_DB/installation-rows.json" >/dev/null
done
echo 'PASS autopilot-targets: スケジュールと Webhook の登録で、状態だけが一時停止なら再開を案内し、ほかの不一致は今の理由を保つ'
)
