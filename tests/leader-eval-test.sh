#!/usr/bin/env bash
# リーダーの評価の場面の形と、流す仕組みを、本物のモデルを呼ばずに確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/leader-eval-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
eval_dir="$root/tests/leader-eval"
scenes_dir="$eval_dir/scenes"
helper=(python3 -I -B "$eval_dir/leader_eval.py")

# 次の依頼の決定と使用率の待ちの 8 場面、原則の 19 場面、最終レビュー・CI 待ちの 9 場面、PR の紐付けの 8 場面、差し戻しの数え方の 7 場面、マークのあるタスクの続行の確認の 9 場面、security-reviewer への依頼の 7 場面、security-reviewer の結果の扱いの 7 場面、自動の依頼の数え方の 7 場面、設計との差の扱いの 3 場面、同じ誤りと同じ部品の診断の 13 場面、新しい手順の 46 場面。まだ置いていないものだけを pending に書く（今はすべて置いてある）。
expected_scenes='1-1 1-2 2-1 2-2 3-1 3-2 4-1 4-2 5-1 5-2 5-3 5-4 5-5 5-6 5-7 5-8 5-9 5-10 5-11 5-12 5-13 5-14 5-15 6-1 6-2 keep-1 keep-2 keep-3 keep-4 keep-5 keep-6 keep-7 keep-8 keep-9 keep-10 keep-11 keep-12 keep-13 keep-14 keep-15 keep-16 keep-17 keep-18 keep-19 keep-20 keep-21 keep-22 keep-23 keep-24 keep-25 keep-26 keep-27 keep-28 keep-29 keep-30 keep-31 keep-32 keep-33 keep-34 keep-35 keep-36 keep-37 keep-38 keep-39 keep-40 keep-41 keep-42 keep-43 keep-44 keep-45 keep-46 keep-47 keep-48 keep-49 keep-50 keep-51 keep-52 keep-53 keep-54 keep-55 keep-56 keep-57 keep-58 keep-59 keep-60 keep-61 keep-62 keep-63 keep-64 keep-65 keep-66 keep-67 keep-68 keep-69 keep-70 keep-71 keep-72 add-1 add-2 add-3 add-4 add-5 add-6 add-7 add-8 add-9 add-10 add-11 add-12 add-13 add-14 add-15 add-16 add-17 add-18 add-19 add-20 add-21 add-22 add-23 add-24 add-25 add-26 add-27 add-28 add-29 add-30 add-31 add-32 add-33 add-34 add-35 add-36 add-37 add-38 add-39 add-40 add-41 add-42 add-43 add-44 add-45 add-46'
pending_scenes=''

# [記録] 以外の文へ数え方の写しを戻さない。行番号は元の文書のまま出す。
check_counting_copy() {
	awk '!/^[0-9]+\. \[記録\]/ && /数え/ {print FILENAME ":" FNR ": [記録] の行の外に数え方があります" > "/dev/stderr"; bad=1} END {exit bad}' "$@"
}

# --- 場面の形 ---
present=
for dir in "$scenes_dir"/*/; do
	id=$(basename "$dir")
	[[ " $expected_scenes " == *" $id "* ]] || { echo "設計にない場面です: $id" >&2; exit 1; }
	[[ " $pending_scenes " != *" $id "* ]] || { echo "置いてある場面が pending に残っています: $id" >&2; exit 1; }
	present="$present $id"
	[[ -f $dir/scene.md && -f $dir/cli.json ]] || { echo "$id: scene.md と cli.json が要ります" >&2; exit 1; }
	jq -e '.commands | type == "array" and all(.[]; has("match") and (.match | type == "string"))' "$dir/cli.json" >/dev/null ||
		{ echo "$id: cli.json の形が違います" >&2; exit 1; }
	jq -e 'all(["ci_monitor", "planner", "security_reviewer"][] as $key | if has($key) then (.[$key] | type == "boolean") else true end; .)' "$dir/cli.json" >/dev/null ||
		{ echo "$id: ci_monitor、planner、security_reviewer は真偽値で指定します" >&2; exit 1; }
	check_counting_copy "$dir/scene.md"
	"${helper[@]}" scene "$dir/scene.md" >"$test_dir/scene.json"
	[[ $(jq -r .id "$test_dir/scene.json") == "$id" ]] || { echo "$id: 場面の ID がディレクトリ名と違います" >&2; exit 1; }
	jq -e '.type | test("^[1-6保新]$")' "$test_dir/scene.json" >/dev/null || { echo "$id: 型が 1〜6・保・新のどれでもありません" >&2; exit 1; }
	[[ $id =~ ^([1-6]|keep|add)-[0-9]+$ ]] || { echo "$id: 場面の ID が <型の数字>-<番号>・keep-<番号>・add-<番号> のどれでもありません" >&2; exit 1; }
	expected_type=${id%%-*}
	[[ $expected_type != keep ]] || expected_type=保
	[[ $expected_type != add ]] || expected_type=新
	[[ $(jq -r .type "$test_dir/scene.json") == "$expected_type" ]] || { echo "$id: 型が ID の先頭と違います" >&2; exit 1; }
	if grep -Eqi '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$dir/scene.md" "$dir/cli.json"; then
		echo "$id: UUID の形の値があります" >&2
		exit 1
	fi
done
for id in $expected_scenes; do
	[[ " $present " == *" $id "* || " $pending_scenes " == *" $id "* ]] || { echo "場面がありません: $id" >&2; exit 1; }
done
for type in 1 2 3 4 5 6; do
	count=0
	for id in $expected_scenes; do [[ ${id%%-*} == "$type" ]] && count=$((count + 1)); done
	((count >= 2)) || { echo "型 $type の場面が 2 つ未満です" >&2; exit 1; }
done
if grep -Eqi '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$eval_dir/values.json"; then
	echo "values.json に UUID の形の値があります" >&2
	exit 1
fi
echo "PASS leader-eval: $(wc -w <<<"$present" | tr -d ' ') 場面の形が決まりどおり（pending: $(wc -w <<<"$pending_scenes" | tr -d ' ') 場面）"

# 検査は元の出来事と採点の写しを拒み、記録の行の説明は許す。
for text in '前の依頼を数え直す。' '3. [採点] 依頼を 1 回目と数えた根拠がある。'; do
	printf '%s\n' "$text" >"$test_dir/counting-copy.md"
	if check_counting_copy "$test_dir/counting-copy.md" 2>"$test_dir/counting-copy.err"; then
		echo '数え方の写しを通しました' >&2; exit 1
	fi
	grep -qF 'counting-copy.md:1:' "$test_dir/counting-copy.err"
done
printf '%s\n' '2. [記録] 同じ部品を 1 回目と数え直した行はない。' >"$test_dir/counting-copy.md"
check_counting_copy "$test_dir/counting-copy.md"
echo 'PASS leader-eval: 元の出来事と採点の数え方の写しを拒み、記録の行は許す'

# 指摘の文が一字も違わない再発だけを見て、次の修正の依頼に同じ部品の行がないことを確認する。
python3 -I -B - "$scenes_dir" <<'PY_REPEATED_FINDINGS'
import copy, json, sys
from pathlib import Path

def comments_of(data):
    for command in data['commands']:
        if command['match'].startswith('multica issue comment list '):
            comments = command['stdout']
            yield json.loads(comments) if isinstance(comments, str) else comments

def repeated_finding_errors(comments):
    previous, repeated, errors = set(), set(), []
    for comment in comments:
        lines = comment['content'].splitlines()
        if any(line.startswith('修正の依頼:') for line in lines):
            for component in sorted(repeated):
                prefix = '同じ部品: ' + component
                if any(line == prefix or line.startswith(prefix + ' ') for line in lines):
                    errors.append((comment['id'], component))
            repeated.clear()
        if '❌' in comment['content']:
            findings = {line for line in lines if line.startswith('- ')}
            repeated.update(line[2:].partition(': ')[0] for line in findings & previous)
            previous.update(findings)
    return errors

scenes = Path(sys.argv[1])
failures = []
paths = sorted(scenes.glob('*/cli.json'))
for path in paths:
    for comments in comments_of(json.loads(path.read_text())):
        for request, component in repeated_finding_errors(comments):
            failures.append(f'{path}: {request}: 同じ文の再発に 同じ部品: {component} の行があります')
assert not failures, '\n'.join(failures)
print(f'PASS leader-eval: 全 {len(paths)} 場面で、同じ文の再発の次の修正に同じ部品の行を置かない')

# 直す前の keep-40 は、c-rev1 と c-rev3 の指摘が同じで、c-req3 に同じ部品の行がある。
before = copy.deepcopy(next(comments_of(json.loads((scenes / 'keep-40/cli.json').read_text()))))
by_id = {comment['id']: comment for comment in before}
by_id['c-rev3']['content'] = by_id['c-rev1']['content']
component = 'src/cart/Badge.tsx:formatCount'
assert repeated_finding_errors(before) == [('c-req3', component)], '直す前の keep-40 を拒んでいない'

# 同じ部品の行がない依頼、別の部品の行、文が違う指摘は検査の範囲を広げずに通す。
for replacement in ('', f'同じ誤り: {component} 1 回目', '同じ部品: src/cart/CartIcon.tsx:CartIcon 1 回目'):
    allowed = copy.deepcopy(before)
    request = next(comment for comment in allowed if comment['id'] == 'c-req3')
    request['content'] = request['content'].replace(f'同じ部品: {component} 2 回目', replacement)
    assert not repeated_finding_errors(allowed), replacement
different = copy.deepcopy(before)
review = next(comment for comment in different if comment['id'] == 'c-rev3')
review['content'] = review['content'].replace('負の数を渡すと `-3` と表示される', '負の値を渡すと負数が表示される')
assert not repeated_finding_errors(different), '文が違う指摘まで拒んでいる'
print('PASS leader-eval: 直す前の keep-40 を拒み、同じ部品の行がない依頼と文が違う指摘は通す')
PY_REPEATED_FINDINGS

# 設計の役を外さない場面の入力に、設計の役がない構成の依頼だけに置く行を残さない。
# 入力は scene.md の ## 入力 と、cli.json の expected_records を除く文字列（JSON として読める文字列は、読んだ結果が文字列でも中まで）。
python3 -I -B - "$eval_dir" "$test_dir" <<'PY_ROLE_CONFIG'
import json, shutil, sys
from pathlib import Path

eval_dir, test_dir = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(eval_dir))
import leader_eval as le

LINE = '設計を用意した人: 人間'

def strings(value):
    if isinstance(value, str):
        yield value
        try:
            inner = json.loads(value)
        except ValueError:
            return
        yield from strings(inner)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)

def leftovers(roots):
    found = []
    for root in roots:
        for scene_md in sorted(Path(root).glob('*/scene.md')):
            scene = le.parse_scene(scene_md)
            if 'designer' in scene['excluded_roles']:
                continue
            if LINE in scene['input']:
                found.append((scene['id'], 'scene.md の ## 入力'))
            cli = json.loads((scene_md.parent / 'cli.json').read_text(encoding='utf-8'))
            cli.pop('expected_records', None)
            if any(LINE in text for text in strings(cli)):
                found.append((scene['id'], 'cli.json'))
    return found

roots = [eval_dir / 'scenes', eval_dir / 'compat-scenes']
found = leftovers(roots)
for scene_id, place in found:
    print(f'{scene_id}: 設計の役を外さない場面の入力に「{LINE}」の行があります（{place}）', file=sys.stderr)
assert not found, found

# 検査が効くことは、add-44 の写しだけを変えて確認する。リポジトリの場面は書き換えない。
base = test_dir / 'role-config'
def copy_scene():
    shutil.rmtree(base, ignore_errors=True)
    shutil.copytree(eval_dir / 'scenes' / 'add-44', base / 'add-44')
    cli_path = base / 'add-44' / 'cli.json'
    return cli_path, json.loads(cli_path.read_text(encoding='utf-8'))

def comment(cli, comment_id):
    for command in cli['commands']:
        if isinstance(command.get('stdout'), list):
            for item in command['stdout']:
                if item.get('id') == comment_id:
                    return command, item
    raise AssertionError(comment_id)

def write(cli_path, cli):
    cli_path.write_text(json.dumps(cli, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

# 変えない写しは通る
copy_scene()
assert not leftovers([base])

# comment-r1 に行を戻すと落ちる
cli_path, cli = copy_scene()
_, item = comment(cli, 'comment-r1')
item['content'] = item['content'].replace('見直しの種類: 設計の見直し', f'見直しの種類: 設計の見直し\n{LINE}')
write(cli_path, cli)
assert leftovers([base]) == [('add-44', 'cli.json')]

# コメントの一覧の stdout を JSON の文字列に入れ直し、その中の依頼に行を戻すと落ちる
cli_path, cli = copy_scene()
command, item = comment(cli, 'comment-r1')
item['content'] += f'\n{LINE}'
command['stdout'] = json.dumps(command['stdout'], ensure_ascii=False)
write(cli_path, cli)
assert leftovers([base]) == [('add-44', 'cli.json')]

# stdout が JSON の文字列（Unicode エスケープ）で、読んだ結果も文字列のとき、行を戻すと落ちる
cli_path, cli = copy_scene()
command, _ = comment(cli, 'comment-r1')
command['stdout'] = json.dumps(LINE, ensure_ascii=True)
assert '\\u' in command['stdout'] and LINE not in command['stdout']
write(cli_path, cli)
assert leftovers([base]) == [('add-44', 'cli.json')]

# 二重に JSON の文字列にした stdout も、中まで読んで落ちる
cli_path, cli = copy_scene()
command, _ = comment(cli, 'comment-r1')
command['stdout'] = json.dumps(json.dumps(LINE, ensure_ascii=True), ensure_ascii=True)
write(cli_path, cli)
assert leftovers([base]) == [('add-44', 'cli.json')]

# scene.md の ## 入力 に行を足すと落ちる
cli_path, cli = copy_scene()
scene_md = base / 'add-44' / 'scene.md'
text = scene_md.read_text(encoding='utf-8')
scene_md.write_text(text.replace('\n## 合格の基準', f'\n{LINE}\n\n## 合格の基準', 1), encoding='utf-8')
assert leftovers([base]) == [('add-44', 'scene.md の ## 入力')]

# expected_records の見本は見ない
cli_path, cli = copy_scene()
cli['expected_records'] = [{'content': LINE}]
write(cli_path, cli)
assert not leftovers([base])

# 設計の役を外す場面は、入力に行があっても見ない
cli_path, cli = copy_scene()
_, item = comment(cli, 'comment-r1')
item['content'] += f'\n{LINE}'
write(cli_path, cli)
scene_md = base / 'add-44' / 'scene.md'
scene_md.write_text(scene_md.read_text(encoding='utf-8').replace('- 型: 新', '- 型: 新\n- 外す役: designer', 1), encoding='utf-8')
assert not leftovers([base])
print('PASS leader-eval: 設計の役を外さない場面の入力に「設計を用意した人: 人間」の行がなく、検査は行を戻した写しを落とす')
PY_ROLE_CONFIG

# --- 悪い場面を拒む ---
bad="$test_dir/bad"
mkdir -p "$bad"
good="$scenes_dir/keep-2/scene.md"
sed '/^## 入力$/,/^$/d' "$good" >"$bad/no-input.md"
sed 's/^1\. \[記録\]/1. [確認]/' "$good" >"$bad/bad-kind.md"
sed 's/ `判定: posted: mention:\/\/member\/member1`//' "$good" >"$bad/no-predicate.md"
sed 's/^- 型: 保$//' "$good" >"$bad/no-type.md"
for name in no-input bad-kind no-predicate no-type; do
	if "${helper[@]}" scene "$bad/$name.md" >/dev/null 2>&1; then
		echo "悪い場面を通しました: $name" >&2
		exit 1
	fi
done
echo "PASS leader-eval: 見出しの欠け、基準の種類、判定の欠けた場面を拒む"

# 役の構成の値が不正なら、モデルを呼ぶ前に止める。
flag_kit="$test_dir/flags-kit"
flag_eval="$flag_kit/tests/leader-eval"
mkdir -p "$flag_eval/scenes/keep-22" "$flag_kit/lib"
cp "$eval_dir/"{run.sh,leader_eval.py,values.json,runtime-brief.md} "$flag_eval/"
cp "$root/lib/render.sh" "$flag_kit/lib/"
mkdir -p "$flag_kit/common/agents" "$flag_kit/common/skills"
cp "$root/common/agents/orchestrator.md" "$flag_kit/common/agents/"
cp -R "$root/common/skills/squad-handoff" "$flag_kit/common/skills/"
git -C "$flag_kit" init -q
git -C "$flag_kit" add common
git -C "$flag_kit" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
cp "$scenes_dir/keep-22/scene.md" "$flag_eval/scenes/keep-22/scene.md"
for key in ci_monitor planner; do
	for invalid in '"false"' 0 null; do
		jq --arg key "$key" --argjson invalid "$invalid" '.[$key] = $invalid' "$scenes_dir/keep-22/cli.json" >"$flag_eval/scenes/keep-22/cli.json"
		if bash "$flag_eval/run.sh" --scenes keep-22 --only new --runs 1 --out "$test_dir/bad-flags" >"$test_dir/bad-flags.out" 2>"$test_dir/bad-flags.err"; then
			echo "$key: 真偽値でない値を通しました: $invalid" >&2; exit 1
		fi
		grep -qF "$key は真偽値で指定してください" "$test_dir/bad-flags.err"
	done
done
echo "PASS leader-eval: ci_monitor と planner の文字列・数値・null は、実行前に拒む"

for invalid in '"example/shop"' 0 null '{}' '["shop"]' '["example/shop", false]' '["example/shop/extra"]'; do
	jq --argjson invalid "$invalid" '.repositories = $invalid' "$scenes_dir/keep-22/cli.json" >"$flag_eval/scenes/keep-22/cli.json"
	if bash "$flag_eval/run.sh" --scenes keep-22 --only new --runs 1 --out "$test_dir/bad-repositories" >"$test_dir/bad-repositories.out" 2>"$test_dir/bad-repositories.err"; then
		echo "repositories: 不正な値を通しました: $invalid" >&2; exit 1
	fi
	grep -qF 'repositories は OWNER/REPO の文字列の配列で指定してください' "$test_dir/bad-repositories.err"
done
echo "PASS leader-eval: repositories は OWNER/REPO の文字列の配列以外を実行前に拒む"

# --- [記録] の判定 ---
cat >"$test_dir/calls.jsonl" <<'JSON'
{"command": "multica issue pull-requests issue-shop-1 --output json", "kind": "read", "exit": 0}
{"command": "multica issue comment add issue-shop-1 --content-file tmp/c.md", "kind": "write", "exit": 0, "bodies": ["お願いします [@member1](mention://member/member1)"]}
JSON
python3 -I -B - "$eval_dir" "$test_dir/calls.jsonl" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import leader_eval as le
calls = [json.loads(l) for l in open(sys.argv[2])]
def check(predicate, expect):
    ok, reason = le.check_record(predicate, calls)
    assert ok is expect, (predicate, ok, reason)
check("called: issue pull-requests", True)
check("called: issue --help", False)
check("not-called: squad-pr-link", True)
check("not-called: issue pull-requests", False)
check("before: issue pull-requests => issue comment add", True)
check("before: issue comment add => issue pull-requests", False)
check("posted: mention://member/member1", True)
check("not-posted: mention://agent/", True)
check("not-posted: mention://member/", False)
check("called: issue pull-requests && posted: member1 && not-called: cancel-task", True)
check("called: issue pull-requests && not-called: issue comment add", False)
PY
echo "PASS leader-eval: [記録] の判定が呼び出しの記録と投稿した文から決まる"

# Claude が拒否した呼び出しはスタブに届かなくても、未呼び出しの判定に数える。
python3 -I -B - "$eval_dir" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import leader_eval as le
denials = [
    {"tool_name": "Bash", "tool_use_id": "tool-denied-1",
     "tool_input": {"command": "multica issue cancel-task issue-shop-1 task-fixer"}},
    {"tool_name": "Bash", "tool_use_id": "tool-denied-2",
     "tool_input": {"command": "squad-pr-link issue-shop-1 https://github.com/example/shop/pull/7"}},
    {"tool_name": "Read", "tool_use_id": "tool-denied-3", "tool_input": {"file_path": "/outside/file.md"}},
]
response, actual, calls, is_error = le.parse_agent_output(json.dumps({
    "type": "result", "result": "最後の返答", "is_error": False, "permission_denials": denials,
}))
assert response == "最後の返答" and actual == denials and not is_error
assert len(calls) == 3 and all(c["kind"] == "denied" and c["exit"] is None for c in calls)
for command in ("^multica issue cancel-task", "^squad-pr-link"):
    assert not le.check_record("not-called: " + command, calls)[0]
    assert not le.check_record("called: " + command, calls)[0]
assert calls[-1]["tool_input"] == denials[-1]["tool_input"]
for bad in ["not JSON", "[]", '{"type":"result","result":"done"}',
            '{"type":"result","permission_denials":[{}]}']:
    try:
        le.parse_agent_output(bad)
    except ValueError:
        continue
    raise AssertionError(bad)
PY
echo "PASS leader-eval: 拒否された道具の入力を残し、未呼び出しの合格や実行した扱いにしない"

# keep-7 は、通常の依頼を通し、CI・依頼の欠落や対象コミットの違いを落とす。
python3 -I -B - "$eval_dir" <<'PY'
import copy, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
scene = le.parse_scene(Path(sys.argv[1]) / "scenes/keep-7/scene.md")
request = "squad-review-next request issue-shop-1 comment-3 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"
calls = [
    {"command": "squad-pr-watch link-check issue-shop-1"},
    {"command": "squad-pr-watch ci issue-shop-1 agent-ci-monitor comment-3"},
    {"command": request},
]
def passed(records):
    return all(le.check_record(c["predicate"], records)[0] for c in scene["criteria"] if c["kind"] == "記録")
assert passed(calls)
for missing in range(3):
    assert not passed(calls[:missing] + calls[missing + 1:]), missing
for wrong in ("squad-review-next request issue-shop-1 comment-3 0000000", "squad-review-next request issue-shop-1 comment-2 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"):
    assert not passed(calls[:2] + [{"command": wrong}]), wrong
# 役を自分で選んで返事の待ちを入れる、または依頼の本文を自分で書く手順は通さない。
assert not passed(calls + [{"command": "squad-review-wait watch issue-shop-1 comment-3 agent-code-reviewer agent-qa"}])
assert not passed(calls + [{"command": "multica issue comment add issue-shop-1 --content-file tmp/c.md",
                            "bodies": ["返事を待つ役: x"]}])
assert not passed(calls + [{"command": "multica issue comment add issue-shop-1 --content-file tmp/c.md",
                            "bodies": ["確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"]}])
PY
echo "PASS leader-eval: keep-7 は CI の見張りと review-next request の対象コミットを確認する"

# 紐付けの各分岐で、正しい記録を通し、禁止した進め方と要る確認の欠落を落とす。
python3 -I -B - "$eval_dir" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
def command(text):
    return {"command": text}
def post(text):
    return {"command": "multica issue comment add issue-shop-1 --content-file tmp/reply.md", "bodies": [text]}
link = command("squad-pr-watch link-check issue-shop-1")
now = command("squad-pr-watch ci-now issue-shop-1 agent-orchestrator comment-3 agent-ci-monitor")
conflicts = command("squad-pr-watch conflicts-check issue-shop-1")
ci_watch = command("squad-pr-watch ci issue-shop-1 agent-ci-monitor comment-5")
ci_wait = command("squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-5")
conflicts_watch = command("squad-pr-watch conflicts issue-shop-1 agent-orchestrator")
review = command("squad-review-next request issue-shop-1 comment-3 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567")
old_review = command("squad-review-wait watch issue-shop-1 comment-3 agent-code-reviewer agent-qa")
in_review = command("multica issue status issue-shop-1 in_review")
ask_review = post("mention://agent/agent-code-reviewer mention://agent/agent-qa")
human = post("mention://member/member1 https://github.com/example/shop/pull/7 https://github.com/example/shop/pull/8")
cases = {
    "keep-3": [link, post("mention://agent/agent-claude-implementer pr_url を補ってください")],
    "5-2": [link, now, conflicts, review],
    "keep-17": [link, now, conflicts, review],
    "keep-18": [link, conflicts, ci_watch, ci_wait, conflicts_watch,
               command("squad-pr-watch unlinked issue-shop-1 comment-5 agent-ci-monitor"),
               post("mention://member/member1 マージ後 done にしてください\n見張り: 1 時間おき、2026-01-13T10:00Z まで\n紐付けの失敗: 警告"), in_review],
    "keep-19": [link, human, in_review],
    "keep-20": [link, link, post("mention://member/member1 紐付け: 未確認"), in_review],
    "keep-21": [link, human],
    "keep-22": [link, command("squad-pr-watch ci-now issue-shop-1 agent-orchestrator comment-3"), conflicts, review],
    "keep-23": [link, conflicts, ci_watch, conflicts_watch, human, in_review],
    "keep-24": [link, post("mention://member/member1 紐付け: 作業先と違う pr: https://github.com/elsewhere/shop/pull/7 作業先: example/shop metadata の修正をお願いします"), in_review],
}
scenes = {id: le.parse_scene(Path(sys.argv[1]) / "scenes" / id / "scene.md") for id in cases}
def passed(id, calls):
    return all(le.check_record(c["predicate"], calls)[0] for c in scenes[id]["criteria"] if c["kind"] == "記録")
for id, calls in cases.items():
    assert passed(id, calls), id
    if id != "keep-22":
        assert not passed(id, [c for c in calls if c != link]), (id, "判定なし")
# 追加した場面では、一覧と link-check の見本が同じ PR の状態を表す。
for n in range(17, 25):
    id = f"keep-{n}"
    table = json.loads((Path(sys.argv[1]) / "scenes" / id / "cli.json").read_text())["commands"]
    def response(prefix):
        return next(c["stdout"] for c in table if c["match"] == prefix + " issue-shop-1")
    state = response("squad-pr-watch link-check")
    if state.startswith("紐付け: 未確認 "):
        continue
    if state.startswith("紐付け: 作業先と違う "):
        metadata = json.loads(response("multica issue get"))["metadata"]
        assert metadata["pr_url"] in state and "作業先: " + metadata["repository"] in state
        assert "/".join(metadata["pr_url"].split("/")[3:5]).casefold() != metadata["repository"].casefold()
        continue
    prs = json.loads(response("multica issue pull-requests"))["pull_requests"]
    urls = [p["html_url"] for p in prs]
    pr = json.loads(response("multica issue get"))["metadata"]["pr_url"]
    if "紐付け: 紐付いている " in state:
        assert pr in urls, id
    elif "紐付け: 紐付いていない " in state:
        assert urls == [], id
    else:
        assert "紐付け: 食い違い " in state and urls and pr not in urls, id
for id in ("5-2", "keep-17", "keep-18", "keep-22"):
    assert not passed(id, [c for c in cases[id] if c != conflicts]), (id, "コンフリクトの確認なし")
    check = "ci-wait" if id == "keep-18" else "ci-now"
    assert not passed(id, [c for c in cases[id] if check not in c["command"]]), (id, "CI の確認なし")
# 見張り役があるマージ前は ci-now を重ねない。
assert not passed("keep-18", cases["keep-18"] + [now]), "keep-18 の ci-now"
for id in ("keep-3", "keep-17", "keep-22"):
    assert not passed(id, cases[id] + [human]), (id, "紐付けだけで人間を呼ぶ")
for id in ("keep-19", "keep-20", "keep-21", "keep-24"):
    assert not passed(id, cases[id] + [ask_review]), (id, "止まらずレビューへ回す")
for forbidden in (command("multica issue metadata set issue-shop-1 --key pr_url --value wrong"),
                  now, conflicts, review, old_review, command("gh pr view https://github.com/elsewhere/shop/pull/7"),
                  command("multica issue pull-requests issue-shop-1 --output json")):
    assert not passed("keep-24", cases["keep-24"] + [forbidden]), forbidden
for missing in ("https://github.com/elsewhere/shop/pull/7", "作業先: example/shop", "mention://member/member1"):
    import copy
    wrong = copy.deepcopy(cases["keep-24"])
    wrong[1]["bodies"][0] = wrong[1]["bodies"][0].replace(missing, "なし")
    assert not passed("keep-24", wrong), missing
assert not passed("5-2", cases["5-2"] + [in_review])
assert not passed("keep-3", cases["keep-3"] + [review])
assert not passed("keep-3", cases["keep-3"] + [ask_review])
assert not passed("keep-3", cases["keep-3"] + [old_review])
for id in ("keep-17", "keep-22"):
    assert not passed(id, cases[id] + [old_review]), (id, "役を自分で選ぶ返事の待ち")
    assert not passed(id, [c for c in cases[id] if c != review]), (id, "review-next request がない")
assert not passed("keep-22", [c if "ci-now" not in c["command"] else now for c in cases["keep-22"]])
assert not passed("keep-23", cases["keep-23"] + [command("squad-pr-watch unlinked issue-shop-1 comment-5 agent-ci-monitor")])
for missing in ("done", "見張り:", "紐付けの失敗:"):
    import copy
    wrong = copy.deepcopy(cases["keep-18"])
    wrong[-2]["bodies"][0] = wrong[-2]["bodies"][0].replace(missing, "なし")
    assert not passed("keep-18", wrong), missing
PY
echo "PASS leader-eval: 紐付けの判定ごとの進め方、停止、マージへの依頼を記録で区別する"

# 追加した場面の基準は、正しい記録を通し、最終レビューの省略や CI 待ちの欠落を落とす。
python3 -I -B - "$eval_dir" <<'PY_FINAL_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
for n in range(8, 17):
    path = root / f'keep-{n}'
    scene = le.parse_scene(path / 'scene.md')
    records = json.loads((path / 'cli.json').read_text())['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0]
                   for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), (n, '期待する記録が通らない')
    wrong = copy.deepcopy(records)
    if n in (8, 9, 10):
        wrong = [r for r in wrong if 'squad-review-wait watch' not in r['command']]
    elif n == 11:
        wrong[-1]['bodies'][0] = wrong[-1]['bodies'][0].replace('見る範囲:', '範囲なし:')
    elif n in (12, 13, 15):
        wrong[-1]['bodies'][0] += '\n[@Owner](mention://member/member1)'
    elif n == 14:
        wrong[0]['command'] = wrong[0]['command'].replace(' ci-wait-rule', '')
    elif n == 16:
        wrong = [wrong[-1], wrong[0]]
    assert not passed(wrong), (n, '手順を外した記録が通った')
print('PASS leader-eval: 最終レビューと CI 待ちの 9 場面は、期待する記録と手順を外した記録を区別する')
PY_FINAL_SCENES

# 差し戻しの数え方の 7 場面は、期待する記録を通し、数え方や止め方を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_REWORK_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def load(n):
    path = root / f'keep-{n}'
    return le.parse_scene(path / 'scene.md'), json.loads((path / 'cli.json').read_text())['expected_records']
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def body(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['bodies'] = [b.replace(old, new) for b in call.get('bodies', [])]
    return wrong
human = {'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': ['[@Owner](mention://member/member1)']}
in_review = {'command': 'multica issue status issue-shop-1 in_review', 'kind': 'read', 'exit': 0}
for n in range(33, 40):
    scene, records = load(n)
    assert passed(scene, records), (n, '期待する記録が通らない')
cases = {
    33: [body(load(33)[1], '種類単位', '個別'), body(load(33)[1], '2 回目\n頼む', '1 回目\n頼む'), load(33)[1] + [human], load(33)[1] + [in_review]],
    34: [[], [{'command': load(34)[1][0]['command'].replace('3f9a2c1', '0000000')}], load(34)[1] + [{'command': 'squad-review-wait watch issue-shop-1 c-fix2 agent-code-reviewer'}], load(34)[1] + [{'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': ['列挙を頼む部品: src/cart/Badge.tsx:formatCount']}], load(34)[1] + [human]],
    35: [body(load(35)[1], '3 回目の前', '2 回目の前'), load(35)[1][:1], load(35)[1] + [{'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': ['mention://agent/agent-claude-fixer\n修正の依頼: 3 回目']}]],
    36: [body(load(36)[1], '3 回目\n修正', '2 回目\n修正'), load(36)[1][1:], load(36)[1] + [human]],
    37: [body(load(37)[1], '同じ誤り:', '同じ部品:'), load(37)[1] + [in_review], body(load(37)[1], '修正の依頼', '頼む範囲')],
    38: [load(38)[1][:1], load(38)[1][1:], load(38)[1] + [{'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': ['頼む範囲: 種類単位（x）']}]],
    39: [body(load(39)[1], 'CartIcon', 'formatCount'), load(39)[1] + [in_review], body(load(39)[1], '同じ部品:', '頼む範囲:')],
}
for n, wrongs in cases.items():
    scene = load(n)[0]
    for i, wrong in enumerate(wrongs):
        assert not passed(scene, wrong), (n, i, '外した記録が通った')
print('PASS leader-eval: 差し戻しの数え方の 7 場面は、期待する記録と外した記録を区別する')
PY_REWORK_SCENES

# 自動の依頼の数え方の 7 場面は、期待する記録を通し、数え方や止め方を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_AUTO_COUNT_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def load(n):
    path = root / f'keep-{n}'
    return le.parse_scene(path / 'scene.md'), json.loads((path / 'cli.json').read_text())['expected_records']
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def body(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['bodies'] = [b.replace(old, new) for b in call.get('bodies', [])]
    return wrong
def post(text):
    return {'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': [text]}
human = post('[@Owner](mention://member/member1)')
in_review = {'command': 'multica issue status issue-shop-1 in_review', 'kind': 'read', 'exit': 0}
for n in range(63, 70):
    scene, records = load(n)
    assert passed(scene, records), (n, '期待する記録が通らない')
cases = {
    63: [body(load(63)[1], '種類単位', '個別'), body(load(63)[1], '2 回目\n頼む', '1 回目\n頼む'), load(63)[1] + [human], load(63)[1] + [in_review], load(63)[1] + [post('同じ誤り: x 1 回目')]],
    64: [body(load(64)[1], 'CartIcon.tsx:CartIcon 1 回目', 'CartIcon.tsx:CartIcon 2 回目'), body(load(64)[1], '修正の依頼: 2 回目', '頼む範囲: 種類単位（x）'), load(64)[1] + [human], load(64)[1] + [in_review]],
    65: [body(load(65)[1], '同じ誤り:', '同じ部品:'), body(load(65)[1], '1 回目\n修正', '2 回目\n修正'), load(65)[1] + [post('頼む範囲: 種類単位（x）')], load(65)[1] + [human]],
    66: [body(load(66)[1], '種類単位', '個別'), body(load(66)[1], '同じ部品: src/cart/Badge.tsx:formatCount 2 回目', '同じ誤り: src/cart/Badge.tsx:formatCount 1 回目'), load(66)[1] + [human], load(66)[1] + [in_review]],
    67: [load(67)[1][:1], load(67)[1][1:], body(load(67)[1], '自動の依頼の確認: c-auto1', '修正の依頼: 2 回目'), load(67)[1] + [post('同じ部品: x 1 回目')], body(load(67)[1], 'c-auto1', 'c-impl')],
    68: [load(68)[1][:1], load(68)[1][1:], load(68)[1] + [post('頼む範囲: 種類単位（x）')], load(68)[1] + [post('mention://agent/agent-claude-fixer\n修正の依頼: 3 回目')]],
    69: [load(69)[1][:1], load(69)[1][1:], body(load(69)[1], '3 回目の前', '2 回目の前'), load(69)[1] + [post('mention://agent/agent-claude-fixer\n修正の依頼: 3 回目')]],
}
for n, wrongs in cases.items():
    scene = load(n)[0]
    for i, wrong in enumerate(wrongs):
        assert not passed(scene, wrong), (n, i, '外した記録が通った')
print('PASS leader-eval: 自動の依頼の数え方の 7 場面は、期待する記録と外した記録を区別する')
PY_AUTO_COUNT_SCENES

# 設計との差の 3 場面は、差の受け渡しと次の依頼を区別する。
python3 -I -B - "$eval_dir" <<'PY_DESIGN_DIFF_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def load(n):
    path = root / f'keep-{n}'
    return le.parse_scene(path / 'scene.md'), json.loads((path / 'cli.json').read_text())['expected_records']
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def body(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['bodies'] = [b.replace(old, new) for b in call.get('bodies', [])]
    return wrong
def post(text):
    return {'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': [text]}
human = post('[@Owner](mention://member/member1)')
in_review = {'command': 'multica issue status issue-shop-1 in_review'}
review = {'command': 'squad-review-next request issue-shop-1 c-handling 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567'}
change = post('設計の変更: 実装を始めたあと')
for n in range(70, 73):
    scene, records = load(n)
    assert passed(scene, records), (n, '期待する記録が通らない')
    for extra in [human, in_review, change]:
        assert not passed(scene, records + [extra]), (n, extra, '外した記録が通った')
cases = {
    70: [load(70)[1][:1], load(70)[1][1:], body(load(70)[1], '設計との差:', '差の要約:'), body(load(70)[1], '余白の追加が変更の一覧にない', '余白の追加'), load(70)[1] + [review], load(70)[1] + [post('mention://agent/agent-claude-principal')]],
    71: [[], [{'command': 'squad-review-wait watch issue-shop-1 c-handling agent-code-reviewer'}], [{'command': review['command'].replace('3f9a2c1', '0000000')}], load(71)[1] + [{'command': 'multica issue label add issue-shop-1 label-important'}], load(71)[1] + [post('mention://agent/agent-designer')]],
    72: [load(72)[1][:1], load(72)[1][1:], body(load(72)[1], '修正の依頼: 2 回目', '修正の依頼: 1 回目'), load(72)[1] + [review], load(72)[1] + [post('同じ部品: x 1 回目')], load(72)[1] + [post('同じ誤り: x 1 回目')], load(72)[1] + [post('頼む範囲: 種類単位（x）')]],
}
for n, wrongs in cases.items():
    scene = load(n)[0]
    for i, wrong in enumerate(wrongs):
        assert not passed(scene, wrong), (n, i, '外した記録が通った')
print('PASS leader-eval: 設計との差の 3 場面は、期待する記録と受け渡し・依頼の誤りを区別する')
PY_DESIGN_DIFF_SCENES

# マークのあるタスクの続行の確認の 9 場面は、期待する記録を通し、止め方や出し方を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_CONTINUE_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def load(n):
    path = root / f'keep-{n}'
    return le.parse_scene(path / 'scene.md'), json.loads((path / 'cli.json').read_text())['expected_records']
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def body(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['bodies'] = [b.replace(old, new) for b in call.get('bodies', [])]
    return wrong
def post(text):
    return {'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': [text]}
human = '[@Owner](mention://member/member1)'
fixer = '[@Fixer](mention://agent/agent-claude-fixer)'
in_review = {'command': 'multica issue status issue-shop-1 in_review', 'kind': 'read', 'exit': 0}
pick_fix = {'command': 'squad-usage-wait pick issue-shop-1 fix', 'kind': 'read', 'exit': 0}
for n in [*range(40, 48), 62]:
    scene, records = load(n)
    assert passed(scene, records), (n, '期待する記録が通らない')
cases = {
    40: [body(load(40)[1], '修正の続行の確認: 4 回目の前', ''), body(load(40)[1], '同じ部品の確認:', '同じ部品:'), load(40)[1][:1], load(40)[1] + [pick_fix]],
    41: [body(load(41)[1], '4 回目の前', '3 回目の前'), load(41)[1][:1], load(41)[1][1:], load(41)[1] + [post(fixer + '\n修正の依頼: 4 回目')]],
    42: [load(42)[1][1:], body(load(42)[1], '修正の依頼: 4 回目', '修正の依頼: 5 回目'), load(42)[1] + [post(human + '\n修正の続行の確認: 4 回目の前')]],
    43: [load(43)[1] + [post(human + '\n修正の続行の確認: 5 回目の前'), in_review], load(43)[1][1:], body(load(43)[1], '修正の依頼: 5 回目', '修正の依頼: 4 回目')],
    62: [load(62)[1] + [post(human)], load(62)[1] + [post('修正の続行の確認: 6 回目の前')], load(62)[1] + [in_review], load(62)[1][1:], load(62)[1][:1], body(load(62)[1], '修正の依頼: 6 回目', '修正の依頼: 5 回目')],
    44: [body(load(44)[1], '7 回目の前', '6 回目の前'), load(44)[1][:1], load(44)[1][1:], load(44)[1] + [post(fixer + '\n修正の依頼: 7 回目')]],
    45: [load(45)[1][1:], [r for r in load(45)[1] if 'squad-review-wait watch' not in r['command']], body(load(45)[1], '手戻りの見直し: 頼んだ', '手戻りの見直し: 頼まない'), body(load(45)[1], '手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目', '手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更'), load(45)[1] + [{'command': 'multica issue label add issue-shop-1 label-important', 'kind': 'read', 'exit': 0}], load(45)[1] + [post('重要のマーク: 付けた。基準: 共通 4')], load(45)[1] + [post(human + '\n修正の続行の確認: 4 回目の前'), in_review]],
    46: [load(46)[1][1:], [r for r in load(46)[1] if 'proceed' not in r['command']], load(46)[1] + [post(human + '\n修正の続行の確認: 4 回目の前'), in_review], load(46)[1] + [{'command': 'multica issue label add issue-shop-1 label-important', 'kind': 'read', 'exit': 0}], load(46)[1] + [post('重要のマーク: 付けた。基準: 共通 4')]],
    47: [load(47)[1][1:], load(47)[1] + [{'command': 'multica issue label add issue-shop-1 label-important', 'kind': 'read', 'exit': 0}], load(47)[1] + [post(human + '\n修正の続行の確認: 4 回目の前'), in_review], load(47)[1] + [post('重要のマーク: 付けた。')], body(load(47)[1], '手戻りの見直し: 頼まない', '手戻りの見直し: 頼んだ'), body(load(47)[1], '手戻りの見直し: 頼まない。合図: 修正の依頼が 4 回目', ''), load(47)[1] + [{'command': 'squad-usage-wait pick issue-shop-1 principal', 'kind': 'read', 'exit': 0}]],
}
for n, wrongs in cases.items():
    scene = load(n)[0]
    for i, wrong in enumerate(wrongs):
        assert not passed(scene, wrong), (n, i, '外した記録が通った')
print('PASS leader-eval: マークのあるタスクの続行の確認の 9 場面は、期待する記録と外した記録を区別する')
PY_CONTINUE_SCENES

# security-reviewer への依頼の 8 場面は、期待する記録を通し、役の数や判断の行を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_SECURITY_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def load(n):
    path = root / f'keep-{n}'
    return le.parse_scene(path / 'scene.md'), json.loads((path / 'cli.json').read_text())['expected_records']
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def body(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['bodies'] = [b.replace(old, new) for b in call.get('bodies', [])]
    return wrong
def command(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['command'] = call['command'].replace(old, new)
    return wrong
def post(text):
    return {'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'bodies': [text]}
both = 'agent-claude-principal agent-security-reviewer'
security = '[@Security](mention://agent/agent-security-reviewer)'
in_review = {'command': 'multica issue status issue-shop-1 in_review', 'kind': 'read', 'exit': 0}
watch_security = {'command': 'squad-review-wait watch issue-shop-1 comment-3 agent-security-reviewer', 'kind': 'read', 'exit': 0}
label_add = {'command': 'multica issue label add issue-shop-1 label-important', 'kind': 'read', 'exit': 0}
pick_principal = {'command': 'squad-usage-wait pick issue-shop-1 principal', 'kind': 'read', 'exit': 0}
for n in (5, 48, 49, 50, 51, 52, 53, 54):
    scene, records = load(n)
    assert passed(scene, records), (n, '期待する記録が通らない')
def two_roles(n):
    return [command(load(n)[1], both, 'agent-claude-principal'), body(load(n)[1], security, ''), load(n)[1][:1] + load(n)[1][2:], load(n)[1] + [in_review]]
cases = {
    5: two_roles(5),
    48: two_roles(48),
    49: [load(49)[1] + [watch_security], body(load(49)[1], '見直しをお願いします。', security + ' 見直しをお願いします。'), body(load(49)[1], '見直しの種類:', '共通 2 の判断: 当たる。理由: x\n見直しの種類:'), load(49)[1] + [in_review]],
    50: [load(50)[1] + [post(security + ' 見直しをお願いします。')], load(50)[1] + [label_add], [pick_principal] + load(50)[1][1:], load(50)[1] + [in_review]],
    51: [body(load(51)[1], '入力と信頼の表の確認: 頼む', ''), body(load(51)[1], '見直しをお願いします。', security + ' 見直しをお願いします。'), load(51)[1] + [watch_security], load(51)[1] + [in_review]],
    52: [body(load(52)[1], '共通 2 の判断: 当たる', '共通 2 の判断: 当たらない'), command(load(52)[1], both, 'agent-claude-principal'), body(load(52)[1], '共通 2 の判断:', '判断:'), body(load(52)[1], security, '')],
    53: [body(load(53)[1], '共通 2 の判断: 当たらない', '共通 2 の判断: 当たる'), body(load(53)[1], '見直しをお願いします。', security + ' 見直しをお願いします。'), body(load(53)[1], '見直しの種類:', '入力と信頼の表の確認: 頼む\n見直しの種類:'), command(load(53)[1], 'agent-claude-principal', both)],
    54: [load(54)[1][1:], body(load(54)[1], '共通 2（安全の仕組みに触れる）', '共通 3（x）'), body(load(54)[1], '共通 1（外部との契約を変える）、', ''), body(load(54)[1], '、共通 2', '\n重要のマーク: 付けた。基準: 共通 2')],
}
for n, wrongs in cases.items():
    scene = load(n)[0]
    for i, wrong in enumerate(wrongs):
        assert not passed(scene, wrong), (n, i, '外した記録が通った')
print('PASS leader-eval: security-reviewer への依頼の 8 場面は、期待する記録と外した記録を区別する')
PY_SECURITY_SCENES

# security-reviewer の結果の扱いの 7 場面は、期待する記録を通し、人間を呼ぶ場面・返し先の行・見せ直しの行を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_SECURITY_RESULT_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def load(n):
    path = root / f'keep-{n}'
    return le.parse_scene(path / 'scene.md'), json.loads((path / 'cli.json').read_text())['expected_records']
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def body(calls, old, new):
    wrong = copy.deepcopy(calls)
    for call in wrong:
        call['bodies'] = [b.replace(old, new) for b in call.get('bodies', [])]
    assert wrong != calls, (old, '置き換える文がない')
    return wrong
def post(parent, text):
    return {'command': f'multica issue comment add issue-shop-1 --parent {parent} --content-file tmp/reply.md', 'kind': 'write', 'exit': 0, 'bodies': [text]}
def call(text):
    return {'command': text, 'kind': 'read', 'exit': 0}
designer = '[@Designer](mention://agent/agent-designer)'
human = '[@Owner](mention://member/member1)'
fixer = '[@Fixer](mention://agent/agent-claude-fixer)'
security = '[@Security](mention://agent/agent-security-reviewer)'
principal = '[@Principal](mention://agent/agent-claude-principal)'
in_review = call('multica issue status issue-shop-1 in_review')
proceed7 = call('squad-review-wait proceed issue-shop-1 c-7')
back = '\n直したあとの返し先: スクワッド'
rewatch = '見直しの種類: 設計の見直し\n見せ直し: 1 回目\n返事を待つ役: '
for n in range(55, 62):
    scene, records = load(n)
    assert passed(scene, records), (n, '期待する記録が通らない')
cases = {
    55: [load(55)[1] + [in_review], [load(55)[1][0], post('c-7', human + ' 設計の直しをお願いします。')], [load(55)[1][0], post('c-7', designer + ' 設計の直しをお願いします。' + back)], load(55)[1][1:]],
    56: [[load(56)[1][0], post('c-7', designer + ' 設計の直しをお願いします。'), in_review], load(56)[1][:2], [load(56)[1][0], post('c-7', human + ' ' + designer + ' 決めてください。'), in_review], [load(56)[1][0], post('c-7', human + ' 決めてください。' + back), in_review]],
    57: [body(load(57)[1], back.strip(), ''), load(57)[1] + [in_review], [load(57)[1][0], post('c-7', human + ' 設計の直しをお願いします。' + back)], load(57)[1][1:]],
    58: [body(load(58)[1], '直したあとは', '直したあとの返し先: スクワッド\n直したあとは'), load(58)[1] + [call('squad-review-wait watch issue-shop-1 c-7 agent-security-reviewer')], load(58)[1] + [in_review], [proceed7, post('c-7', human + ' 設計の直しをお願いします。')]],
    59: [load(59)[1][1:], [call('squad-review-wait watch issue-shop-1 c-9 agent-claude-principal agent-security-reviewer'), load(59)[1][1]], body(load(59)[1], '見せ直し: 1 回目\n', ''), body(load(59)[1], '見直しの種類: 設計の見直し', '見直しの種類: 設計と PR の見直し'), load(59)[1] + [in_review]],
    60: [[load(60)[1][0], post('c-8', fixer + ' 修正をお願いします。\n\n修正の依頼: 1 回目\n- src/auth/expiry.ts:isExpired: 期限')], body(load(60)[1], '修正の依頼: 1 回目', ''), load(60)[1] + [in_review], load(60)[1][:2] + [post('c-8', human + ' ' + fixer + ' 修正をお願いします。\n\n修正の依頼: 1 回目\n- src/auth/expiry.ts\n- src/auth/session.ts')]],
    61: [[load(61)[1][0], post('c-12', designer + ' 設計の直しをお願いします。'), in_review], load(61)[1][:2], load(61)[1] + [call('squad-review-wait watch issue-shop-1 c-12 agent-security-reviewer')], body(load(61)[1], '見せ直しでも', '\n見せ直し: 2 回目\n見せ直しでも')],
}
for n, wrongs in cases.items():
    scene = load(n)[0]
    for i, wrong in enumerate(wrongs):
        assert not passed(scene, wrong), (n, i, '外した記録が通った')
print('PASS leader-eval: security-reviewer の結果の扱いの 7 場面は、期待する記録と外した記録を区別する')
PY_SECURITY_RESULT_SCENES

# 次の依頼の決定と使用率の待ちの 8 場面は、期待する記録を通し、手順を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_NEXT_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def command(text, kind='read', exit=0):
    return {'command': text, 'kind': kind, 'exit': exit}
def post(text, parent='comment-5'):
    return {'command': f'multica issue comment add issue-shop-1 --parent {parent} --content-file tmp/reply.md',
            'bodies': [text], 'kind': 'write', 'exit': 0}
for n in range(25, 33):
    path = root / f'keep-{n}'
    scene = le.parse_scene(path / 'scene.md')
    records = json.loads((path / 'cli.json').read_text())['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0]
                   for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), (n, '期待する記録が通らない')
    wrongs = []
    if n == 25:
        wrongs = [[command('squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final ci-wait-rule')],
                  [command('squad-review-next decide issue-shop-1 principal-done')],
                  [command('squad-review-next decide issue-shop-1 principal-done ci-wait-rule'),
                   command('squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final ci-wait-rule')],
                  records + [post('マージの依頼: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567', 'comment-final')]]
    elif n == 26:
        wrongs = [records[::-1], records[:1], records[1:],
                  [records[0], copy.deepcopy(records[1])] ,
                  records + [command('squad-dispatch-pick issue-shop-1 fix')]]
        wrongs[3][1]['bodies'] = [records[1]['bodies'][0].replace('mention://agent/agent-claude-fixer', 'mention://member/member1')]
    elif n == 27:
        wrongs = [records[1:], records[::-1], records[:1],
                  [post('使用率の待ちの延長: fix。決めた人: Owner'), records[1]],
                  [post('使用率の答え: 待つ。答えた時刻: 2026-01-11T12:00:00Z'), records[1]],
                  [records[0], command('squad-usage-wait pick issue-shop-1 implement', exit=3)],
                  records + [post('[@fixer](mention://agent/agent-claude-fixer) 直してください')],
                  records + [command('squad-dispatch-pick issue-shop-1 fix')]]
        other = copy.deepcopy(records)
        other[0]['command'] = other[0]['command'].replace(' 待つ ', ' 進める ')
        wrongs.append(other)
    elif n == 28:
        wrongs = [records + [post('使用率の待ちの延長: fix。決めた人: Owner')],
                  records + [command('squad-usage-wait pick issue-shop-1 fix')],
                  records + [command('squad-usage-wait answer issue-shop-1 fix 待つ comment-5')],
                  [post('待ちます。')]]
    elif n == 29:
        wrongs = [records[1:], [records[0], records[1], records[3]],
                  [records[0], records[1], post(records[2]['bodies'][0].replace('pull/8', 'pull/9'), 'comment-6'), records[3]],
                  records + [command('squad-review-next request issue-shop-1 comment-6 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567')],
                  records + [command('multica issue metadata set issue-shop-1 --key pr_url --value x')]]
    elif n == 30:
        human = post('[@Owner](mention://member/member1) マージの判断をお願いします。', 'comment-6')
        swapped = copy.deepcopy(records)
        swapped[2]['bodies'] = [records[2]['bodies'][0].replace('mention://agent/agent-claude-fixer', 'mention://member/member1')]
        wrongs = [records[1:], [records[0], records[2]], records[::-1], swapped, records + [human],
                  records + [command('squad-review-next request issue-shop-1 comment-6 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567')]]
    elif n == 31:
        human = post('[@Owner](mention://member/member1) コンフリクトを確認してください。', 'comment-6')
        swapped = copy.deepcopy(records)
        swapped[3]['bodies'] = [records[3]['bodies'][0].replace('mention://agent/agent-claude-fixer', 'mention://member/member1')]
        wrongs = [records[1:], [records[0], records[2], records[3]], [records[0], records[2], records[1], records[3]],
                  swapped, records + [human]]
    elif n == 32:
        wrongs = [[records[0], records[2]], [records[0], records[2], records[1]], records[:2],
                  records + [post('[@Owner](mention://member/member1) マージの判断をお願いします。', 'comment-5')],
                  records + [command('squad-review-next request issue-shop-1 comment-4 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567')]]
    for wrong in wrongs:
        assert not passed(wrong), (n, wrong)
print('PASS leader-eval: 次の依頼の決定と使用率の待ちの 8 場面は、期待する記録と手順を外した記録を区別する')
PY_NEXT_SCENES

# 使用率の答えの 2 場面は、答えの記録と、pick を流し直したあとの依頼を区別する。
python3 -I -B - "$eval_dir" <<'PY_ANSWER_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def command(text, kind='read', exit=0):
    return {'command': text, 'kind': kind, 'exit': exit}
def post(text, parent='comment-5'):
    return {'command': f'multica issue comment add issue-shop-1 --parent {parent} --content-file tmp/reply.md',
            'bodies': [text], 'kind': 'write', 'exit': 0}
for id in ('add-45', 'add-46'):
    scene = le.parse_scene(root / id / 'scene.md')
    assert scene['type'] == '新', id
    records = json.loads((root / id / 'cli.json').read_text())['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), (id, '期待する記録が通らない')
    for i in range(len(records)):
        assert not passed(records[:i] + records[i + 1:]), (id, i, '記録を 1 つ欠いても通った')
    assert not passed(records[::-1]), (id, '順番を入れ替えても通った')
    request = records[-1]['bodies'][0]
    def with_request(text):
        wrong = copy.deepcopy(records)
        wrong[-1]['bodies'] = [text]
        return wrong
    assert not passed(with_request(request.replace('人間の答えで進める（期限 2026-01-11T14:00:00Z、答えのタスク issue-shop-1）', '人間の答えで進める'))), (id, '期限を欠いても通った')
    assert not passed(with_request(request.replace('修正の依頼: 1 回目\n', ''))), (id, '依頼の回の行を欠いても通った')
    assert not passed(with_request(request.replace('agent-claude-fixer', 'agent-codex-fixer'))), (id, 'pick が選ばない役への依頼が通った')
    assert not passed(records + [post('[@Owner](mention://member/member1) どうしますか。', 'comment-6')]), (id, '人間を呼び直しても通った')
    assert not passed(records + [command('squad-dispatch-pick issue-shop-1 fix')]), (id, '終わった squad-dispatch-pick が通った')
    assert not passed([post('使用率の答え: 進める。答えた時刻: 2026-01-11T12:00:00Z')] + records), (id, '答えの行を手で書いても通った')
    assert not passed(records + [post('使用率の待ちの延長: fix。決めた人: Owner')]), (id, '延長の行を書いても通った')
    wait = copy.deepcopy(records)
    wait[0]['command'] = wait[0]['command'].replace(' 進める ', ' 待つ ')
    assert not passed(wait), (id, '待つの answer が通った')
    if id == 'add-46':
        assert not passed(records + [command('squad-review-next decide issue-shop-1 round-1')]), (id, 'decide の流し直しが通った')
        assert not passed(with_request(request + '\n直す指摘: 1 件')), (id, '直す指摘の行が通った')
        rounded = copy.deepcopy(records)
        for r in rounded:
            if r['command'].startswith('squad-usage-wait pick'):
                r['command'] += ' --round round-1'
        assert not passed(rounded), (id, '--round 付きの pick が通った')
print('PASS leader-eval: 使用率の答えの 2 場面は、期待する記録と手順を外した記録を区別する')
PY_ANSWER_SCENES

# 新しい要件の見直しの場面は、依頼・返事の扱いと本文の値を区別する。
python3 -I -B - "$eval_dir" <<'PY_REQUIREMENTS_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
assert 'Bash(shasum *)' in le.ALLOWED_TOOLS
for n in range(1, 9):
    path = Path(sys.argv[1]) / 'scenes' / f'add-{n}'
    scene = le.parse_scene(path / 'scene.md')
    settings = json.loads((path / 'cli.json').read_text())
    assert settings.get('planner', True) is (n == 4)
    records = settings['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0]
                   for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), (n, '期待する記録が通らない')
    for missing in range(len(records)):
        assert not passed(records[:missing] + records[missing + 1:]), (n, missing)
    wrong = records + [{'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md',
                        'bodies': ['[@Wrong](mention://agent/agent-designer)' if n != 2 else '[@Owner](mention://member/member1)']}]
    assert not passed(wrong), (n, '禁止した役への依頼が通った')
    if n in (1, 5, 6, 8):
        wrong = copy.deepcopy(records)
        wrong[-1]['bodies'] = [wrong[-1]['bodies'][0].replace('タスクの本文 ', 'タスクの本文 0')]
        assert not passed(wrong), (n, '本文の値が違う依頼が通った')
    if n == 2:
        wrong = records + [{'command': 'squad-review-wait watch issue-shop-1 comment-2 agent-codex-principal'}]
        assert not passed(wrong), '指摘なしでの頼み直しが通った'
    if n == 4:
        wrong = records + [{'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md',
                            'bodies': ['見直しの種類: 要件の見直し']}]
        assert not passed(wrong), '要件を決める役がある構成での見直しが通った'
    if n in (6, 7, 8):
        assert settings['repositories'] == ['example/shop', 'example/admin']
        forbidden = ['multica issue create --title wrong --parent issue-shop-1'] if n == 8 else [
            'multica issue assign issue-admin-1 --to squad-shop',
            'multica issue status issue-admin-1 todo',
        ]
        if n == 6:
            forbidden += ['multica issue metadata set issue-shop-1 --key repository --value example/shop']
            for flag in ('--status backlog', '--stage 1'):
                wrong = copy.deepcopy(records)
                wrong[0]['command'] = wrong[0]['command'].replace(flag, '')
                assert not passed(wrong), (n, flag)
            wrong = copy.deepcopy(records)
            wrong[0]['command'] += ' --assignee-id squad-shop'
            assert not passed(wrong), (n, '作成時の担当あり')
            wrong = [records[-2]] + records[:-2] + [records[-1]]
            assert not passed(wrong), (n, '作業先を書く前に見直しを頼んだ')
        if n == 7:
            forbidden += ['squad-review-wait watch issue-shop-1 comment-2 agent-codex-principal']
        for cmd in forbidden:
            assert not passed(records + [{'command': cmd}]), (n, cmd)
print('PASS leader-eval: 要件の見直しの 8 場面は、期待する記録と依頼・本文の値の誤りを区別する')
PY_REQUIREMENTS_SCENES

# --- スタブの claude で流す ---
stub_bin="$test_dir/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/claude" <<'EOF2'
#!/usr/bin/env bash
# LEADER_EVAL_STUB_AGENT: run.sh は、この目印があるスタブのときだけ祖先の確認を飛ばせる
model= effort= format= prev= tools= allowed= mode=
for arg in "$@"; do
	case $arg in --*) mode= ;; esac
	case $mode in tools) tools="$tools $arg" ;; allowed) allowed="$allowed $arg" ;; esac
	case $arg in --tools) mode=tools ;; --allowedTools) mode=allowed ;; esac
	case $prev in --model) model=$arg ;; --effort) effort=$arg ;; --output-format) format=$arg ;; esac
	prev=$arg
done
case "$*" in
*"[leader-eval-scorer]"*)
	echo "scorer $model $effort" >>"$STUB_LOG"
	python3 -I - "$2" <<'PY'
import json, sys
prompt = sys.argv[1]
assert "## エージェントの最後の返答\n" in prompt
response = prompt.split("## エージェントの最後の返答\n", 1)[1].split("\n\n合否と理由を、", 1)[0]
ok = response == "/note\n返事の待ち: 回ごと済み" if "最後の返答にしている" in prompt else True
print(json.dumps({"pass": ok, "reason": "最後の返答で判定"}, ensure_ascii=False))
PY
	exit 0
	;;
esac
echo "leader $model $effort $(basename "$PWD" | cut -c1-4)" >>"$STUB_LOG"
[[ $format == json ]] || exit 4
# 評価の道具が、スキルの参照に届く構成か。満たさなければ、本物のモデルを待たずに失敗で終わる
[[ " $tools " == *" Skill "* ]] || exit 6
[[ " $allowed " == *" Skill(squad-handoff) "* ]] || exit 6
sed -n '/^## Skills$/,/^## /p' CLAUDE.md | grep -q '^- \*\*squad-handoff\*\*$' || exit 7
refs=$(sed -n '/^## 場面と手順$/,/^## 重要の基準$/p' CLAUDE.md | grep -o '`leader-[a-z-]*\.md`' | tr -d '`' | sort -u)
[[ -n $refs ]] || exit 8
for ref in $refs; do [[ -s .claude/skills/squad-handoff/references/$ref ]] || exit 8; done
grep -q 'shop-orchestrator-member1' CLAUDE.md || exit 3
grep -q 'Multica Agent Runtime' CLAUDE.md || exit 3
test -f .claude/skills/squad-handoff/SKILL.md || exit 3
if jq -e 'has("repositories")' "$LEADER_EVAL_CLI" >/dev/null; then
	list=$(jq -r '.repositories | map("`" + . + "`") | join("、")' "$LEADER_EVAL_CLI")
	grep -qxF -- "- プロジェクトのリポジトリの一覧: $list" CLAUDE.md || exit 7
fi
if jq -e '.ci_monitor == false' "$LEADER_EVAL_CLI" >/dev/null; then
	if grep -q 'agent-ci-monitor' CLAUDE.md; then exit 5; fi
else
	grep -q 'agent-ci-monitor' CLAUDE.md || exit 5
fi
if jq -e '.planner == false' "$LEADER_EVAL_CLI" >/dev/null; then
	if grep -q 'agent-planner' CLAUDE.md; then exit 6; fi
else
	grep -q 'agent-planner' CLAUDE.md || exit 6
fi
if [[ $* == *'ほぼ同時に、レビューの役も同じ知らせ'* ]]; then
	squad-review-wait proceed issue-shop-1 comment-6 >tmp/proceed.md
	python3 -I - <<'PY'
import json, os
from pathlib import Path
denials = []
if os.environ.get("STUB_DENIAL"):
    denials = [{"tool_name": "Bash", "tool_use_id": "tool-denied",
                "tool_input": {"command": "multica issue status issue-shop-1 in_review"}}]
print(json.dumps({"type": "result", "is_error": False, "permission_denials": denials,
                  "result": os.environ.get("STUB_RESPONSE", Path("tmp/proceed.md").read_text().strip())}, ensure_ascii=False))
PY
	exit 0
fi
multica issue get issue-shop-1 >/dev/null
multica issue pull-requests issue-shop-1 --output json >/dev/null
multica no-such-command >/dev/null 2>&1 || true
printf '確認します [@member1](mention://member/member1)\n' >tmp/c.md
multica issue comment add issue-shop-1 --parent comment-2 --content-file tmp/c.md >/dev/null
multica issue status issue-shop-1 in_review >/dev/null
echo '{"type":"result","result":"done","is_error":false,"permission_denials":[]}'
EOF2
chmod +x "$stub_bin/claude"
export STUB_LOG="$test_dir/stub.log"
# テストの一時ディレクトリはリポジトリの tmp/ の下で、スタブの claude は祖先の指示を読まない。祖先の確認は後で別に確認する
export LEADER_EVAL_SKIP_ANCESTOR_CHECK=1
out="$test_dir/out"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes 1-1,keep-2 --runs 2 --jobs 2 --out "$out" >"$test_dir/run.out" 2>"$test_dir/run.err" ||
	{ cat "$test_dir/run.err" >&2; exit 1; }

for which in old new; do
	file="$out/instructions/$which/instructions.md"
	[[ -s $file ]] || { echo "$which の指示がありません" >&2; exit 1; }
	grep -q '^## このプロジェクトの値$' "$file"
	grep -qxF -- '- プロジェクトのリポジトリの一覧: `example/shop`' "$file"
	grep -q 'shop-orchestrator-member1' "$file"
	grep -q 'Multica Agent Runtime' "$file"
	if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$file"; then echo "$which: 差し込みが残っています" >&2; exit 1; fi
	grep -q '^## 評価の実行だけの制限$' "$file"
	[[ -f $out/instructions/$which/skills/squad-handoff/SKILL.md ]]
	jq -e '.model | length > 0' "$out/instructions/$which/meta.json" >/dev/null
done
echo "PASS leader-eval: 今と新しい指示を展開し、squad-handoff と一緒に作業ディレクトリへ置く"

# 新しい指示と一緒に配る手順には、判断と受け渡しに使う行の決まりを残す。
refs="$out/instructions/new/skills/squad-handoff/references"
for phrase in '同じ誤り:' '同じ部品:' '同じ部品の確認:' '頼む範囲:' '列挙を頼む部品:' '自動の依頼の確認:' '設計との差:' '設計との差の扱い:'; do
	grep -qF -- "$phrase" "$refs/leader-flow.md"
done
for phrase in '修正の続行の確認:' '共通 2 の判断:' '入力と信頼の表の確認:'; do
	grep -qF -- "$phrase" "$refs/leader-principal.md"
done
for phrase in '設計との差:' '設計との差の扱い:'; do
	grep -qF -- "$phrase" "$refs/leader-dispatch.md"
done
echo 'PASS leader-eval: 配る手順に、同じ誤り・同じ部品・続行と安全の確認・設計との差の行の決まりがある'

[[ $(wc -l <"$out/runs.jsonl" | tr -d ' ') == $((2 * 2 * 2)) ]] || { echo "runs.jsonl の行数が違います" >&2; exit 1; }
jq -e -s 'all(.[]; has("scene") and has("which") and has("n") and has("model") and has("calls") and has("comments") and has("response") and has("criteria"))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; .pass == true)' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; any(.calls[]; .kind == "unmatched" and .exit == 1))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; any(.calls[]; .kind == "write" and (.bodies | length) > 0))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; (.comments | length) > 0 and (.comments[0] | contains("member1")))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; .response == "done" and .exit_code == 0 and (.duration_ms >= 0) and .permission_denials == [])' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; .criteria | all(.[]; has("n") and has("kind") and has("pass") and has("reason")))' "$out/runs.jsonl" >/dev/null
grep -q '^| keep-2 | 保 | 2/2 | 2/2 | - |$' "$out/summary.md"
grep -q '^| 1-1 | 1 | 2/2 | 2/2 | - |$' "$out/summary.md"
echo "PASS leader-eval: スタブのコマンドが呼び出しを記録し、runs.jsonl と summary.md が決まった形で出る"

grep -q '^leader claude-sonnet-5-5 high' "$test_dir/stub.log"
grep -q '^scorer claude-opus-5-5 high' "$test_dir/stub.log"
echo "PASS leader-eval: モデルと思考の深さは展開した front matter から、採点は opus の high で流す"

# keep-6 の最後の返答だけを変え、採点が合格と不合格に分かれることを確認する。
for mode in good bad denied; do
	case $mode in good | denied) reply=$'/note\n返事の待ち: 回ごと済み' ;; bad) reply='別の返答' ;; esac
	denial=
	[[ $mode != denied ]] || denial=1
	mode_out="$test_dir/final-$mode"
	STUB_RESPONSE="$reply" STUB_DENIAL="$denial" PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" \
		--baseline HEAD --scenes keep-6 --only new --runs 1 --jobs 1 --out "$mode_out" >"$test_dir/$mode.out" 2>"$test_dir/$mode.err" ||
		{ cat "$test_dir/$mode.err" >&2; exit 1; }
	done_file="$mode_out/runs.jsonl"
	case $mode in
	good) jq -e '.pass == true and .response == "/note\n返事の待ち: 回ごと済み" and .comments == []' "$done_file" >/dev/null ;;
	bad) jq -e '.pass == false and (.criteria[] | select(.n == 3) | .pass == false)' "$done_file" >/dev/null ;;
	denied)
		jq -e '.pass == false and (.error | contains("拒否")) and (.permission_denials | length) == 1
			and any(.calls[]; .kind == "denied" and .exit == null and .tool_use_id == "tool-denied"
				and .command == "multica issue status issue-shop-1 in_review")
			and (.criteria[] | select(.n == 2) | .pass == false)' "$done_file" >/dev/null
		;;
	esac
done
echo "PASS leader-eval: keep-6 の採点に最後の返答を渡し、拒否された状態の変更を記録と判定に含める"

# 評価の許可は、通信するコマンドと作業ディレクトリの外へ書くコマンドを含まない。足すときはここも変わるので、PR の差分で読める。
python3 -I -B - "$eval_dir" <<'PY_ALLOWED'
import sys
sys.path.insert(0, sys.argv[1])
import leader_eval as le
expected = ["Bash(multica *)", "Bash(gh *)", "Bash(squad-*)",
            "Bash(rm *.md)", "Bash(rm -f *.md)", "Bash(rm tmp/*)", "Bash(rm -f tmp/*)", "Bash(rm ./*)", "Bash(rm -f ./*)",
            "Bash(echo *)", "Bash(printf *)", "Bash(cat *)", "Bash(ls *)", "Bash(head *)", "Bash(tail *)", "Bash(wc *)",
            "Bash(grep *)", "Bash(jq *)", "Bash(sort *)", "Bash(pwd *)", "Bash(which *)", "Bash(test *)", "Bash(shasum *)", "Bash(pwd)",
            "Skill(squad-handoff)", "Read(./**)", "Edit(./**)"]
assert le.ALLOWED_TOOLS == expected, le.ALLOWED_TOOLS
assert le.BUILTIN_TOOLS.split() == ["Bash", "Read", "Write", "Edit", "Skill"], le.BUILTIN_TOOLS
for rule in le.ALLOWED_TOOLS:
    assert not any(w in rule for w in ("curl", "wget", "ssh", "scp", "nc ", "mkdir", "cp ", "mv ", "tee", "WebFetch", "WebSearch")), rule
    assert not rule.startswith(("Read(/", "Edit(/", "Write(/", "Skill(*")), rule
cmd = le.agent_command("claude", "model-x", "high", "入力")
tools = cmd[cmd.index("--tools") + 1:]
assert tools[:5] == ["Bash", "Read", "Write", "Edit", "Skill"]
PY_ALLOWED
echo "PASS leader-eval: 評価の許可の一覧が決めた一覧と一致し、Skill は squad-handoff だけで、通信と外への書き込みがない"

# 評価の前置きは、実際の前置きと同じ Skills の節を持ち、評価の実行だけの制限を知らせる。
grep -q '^## Skills$' "$eval_dir/runtime-brief.md"
grep -q '^- \*\*squad-handoff\*\*$' "$eval_dir/runtime-brief.md"
grep -q '^## 評価の実行だけの制限$' "$eval_dir/runtime-brief.md"
# 制限の節は指示の本文の見出しを置き換えず、その前に足す。
grep -q '^## Agent Instructions$' "$eval_dir/runtime-brief.md"
echo "PASS leader-eval: 前置きの近似に Skills の節と評価の実行だけの制限の節がある"

# 結果のディレクトリの既定は一時ディレクトリの下で、祖先に指示やスキルがあれば流さない。
tmp_root=$(cd "$(mktemp -d "$test_dir/tmp-root.XXXXXX")" && pwd -P)
trap 'rm -rf -- "$test_dir" "$tmp_root"' EXIT
default_out="$tmp_root/default"
mkdir -p "$default_out"
TMPDIR="$default_out" PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 >"$test_dir/default.out" 2>"$test_dir/default.err" ||
	{ cat "$test_dir/default.err" >&2; exit 1; }
result_dir=$(sed -n 's/^結果: //p' "$test_dir/default.out")
[[ $result_dir == "$default_out"/leader-eval.* && -s $result_dir/runs.jsonl ]] || { echo "既定の結果の置き場所が TMPDIR の下ではありません: $result_dir" >&2; exit 1; }
for name in CLAUDE.md AGENTS.md .claude .codex; do
	if [[ -e $result_dir/$name ]]; then echo "結果のディレクトリ自体に指示があります: $name" >&2; exit 1; fi
done
# 祖先の確認を有効にして流すと、テストの一時ディレクトリは原本の AGENTS.md の下にあるので拒否される。
# GNU の mktemp でも macOS の mktemp でも置き場所が同じになるよう、確認だけを補助で、tmp_root で止めて確認する
mkdir -p "$tmp_root/clean/sub"
[[ -z $(python3 -I -B "$eval_dir/leader_eval.py" ancestors "$tmp_root/clean/sub" "$tmp_root") ]] ||
	{ echo "祖先に指示がない一時ディレクトリで、指示を見つけました" >&2; exit 1; }
# シンボリックリンク越しの --out も、解いたパスで使う
mkdir -p "$tmp_root/real"
ln -s "$tmp_root/real" "$tmp_root/link"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$tmp_root/link/out" >"$test_dir/link.out" 2>"$test_dir/link.err" ||
	{ cat "$test_dir/link.err" >&2; exit 1; }
grep -q "^結果: $tmp_root/real/out\$" "$test_dir/link.out" || { echo "シンボリックリンクを解いていません" >&2; exit 1; }
# 祖先の確認を飛ばす指定は、スタブの目印がない評価のコマンドでは効かない。継承した指定で本物の評価の確認は外せない
repo_agents="$(cd "$root" && pwd -P)/AGENTS.md"
real_bin="$test_dir/real-bin"
mkdir -p "$real_bin"
grep -v 'LEADER_EVAL_STUB_AGENT' "$stub_bin/claude" >"$real_bin/claude"
chmod +x "$real_bin/claude"
for skip_value in 1 yes; do
	if LEADER_EVAL_SKIP_ANCESTOR_CHECK=$skip_value PATH="$real_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$test_dir/real-out-$skip_value" >"$test_dir/real.out" 2>"$test_dir/real.err"; then
		echo "目印のない評価のコマンドで、祖先の確認を飛ばして流しました: $skip_value" >&2; exit 1
	fi
	grep -q "$repo_agents" "$test_dir/real.err" || { echo "目印のない評価のコマンドで、祖先の指示のパスを示していません: $skip_value" >&2; exit 1; }
	[[ ! -e $test_dir/real-out-$skip_value/runs.jsonl && ! -d $test_dir/real-out-$skip_value/runs ]] || { echo "祖先の確認が外れて場面を流しました: $skip_value" >&2; exit 1; }
done
# 目印のあるスタブがない評価のコマンド（codex は stub-bin にない）でも、確認は外れない
if LEADER_EVAL_SKIP_ANCESTOR_CHECK=1 PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --runtime codex --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$test_dir/real-out-none" >"$test_dir/real.out" 2>"$test_dir/real.err"; then
	echo "評価のコマンドが見つからないのに、祖先の確認を飛ばして流しました" >&2; exit 1
fi
grep -q "$repo_agents" "$test_dir/real.err" || { echo "評価のコマンドがないとき、祖先の指示のパスを示していません" >&2; exit 1; }
# PATH から目印付きのディレクトリが除かれる経路: 目印付きの claude と squad-preflight を同じ場所に置くと、評価の実行は
# その場所を PATH から除く。確認するファイルと起動するファイルを一致させるため、除かれたあとの claude（目印なし）を確認して拒否する
gate_bin="$test_dir/gate-bin"
mkdir -p "$gate_bin" "$test_dir/after-bin"
cp "$stub_bin/claude" "$gate_bin/claude"
printf '#!/bin/sh\nexit 0\n' >"$gate_bin/squad-preflight"
chmod +x "$gate_bin/squad-preflight"
printf '#!/bin/sh\n: >"%s"\nexit 0\n' "$test_dir/unmarked-ran" >"$test_dir/after-bin/claude"
chmod +x "$test_dir/after-bin/claude"
if LEADER_EVAL_SKIP_ANCESTOR_CHECK=1 PATH="$gate_bin:$test_dir/after-bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$test_dir/gate-out" >"$test_dir/gate.out" 2>"$test_dir/gate.err"; then
	echo "目印付きの場所が PATH から除かれたのに、目印なしの claude を祖先の確認なしで流しました" >&2; exit 1
fi
grep -q "$repo_agents" "$test_dir/gate.err" || { echo "除かれた PATH の経路で、祖先の指示のパスを示していません" >&2; exit 1; }
[[ ! -e $test_dir/unmarked-ran && ! -e $test_dir/gate-out/runs.jsonl ]] || { echo "目印なしの claude が起動しました" >&2; exit 1; }
# 相対パスの PATH でも、確認したファイルをそのまま起動する。起動の作業ディレクトリは別なので、絶対パスで渡していることの確認にもなる
mkdir -p "$test_dir/rel/rel-bin"
cp "$stub_bin/claude" "$test_dir/rel/rel-bin/claude"
(cd "$test_dir/rel" && LEADER_EVAL_SKIP_ANCESTOR_CHECK=1 PATH="rel-bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$test_dir/rel-out" >"$test_dir/rel.out" 2>"$test_dir/rel.err") ||
	{ cat "$test_dir/rel.err" >&2; echo "相対パスの PATH にあるスタブを、絶対パスにして起動できませんでした" >&2; exit 1; }
[[ -s $test_dir/rel-out/runs.jsonl ]] || { echo "相対パスの PATH のスタブで結果が出ていません" >&2; exit 1; }
# 起動のコマンドは、解決した絶対パス（引数の名前ではない）で始まる
python3 -I -B - "$eval_dir" "$gate_bin/claude" <<'PY_EXE'
import sys
sys.path.insert(0, sys.argv[1])
import leader_eval as le
assert le.agent_command("claude", "m", "high", "p", sys.argv[2])[0] == sys.argv[2]
assert le.agent_command("codex", "m", "high", "p", sys.argv[2])[0] == sys.argv[2]
# PATH の相対の項目は絶対パスにし、空の項目は作業ディレクトリを指すので除く
import os
got = le.filtered_path(":/usr/bin::rel-bin:/bin:")
assert got == ["/usr/bin", os.path.abspath("rel-bin"), "/bin"], got
PY_EXE
# 祖先に指示がある場所は、見つけたパスを示して、どの場面も流さず 0 以外で終わる
for name in CLAUDE.md AGENTS.md AGENTS.override.md CLAUDE.local.md .claude .codex; do
	anc="$tmp_root/anc-$name"
	mkdir -p "$anc"
	case $name in .claude | .codex) mkdir "$anc/$name" ;; *) : >"$anc/$name" ;; esac
	if LEADER_EVAL_SKIP_ANCESTOR_CHECK= PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$anc/sub/out" >"$test_dir/anc.out" 2>"$test_dir/anc.err"; then
		echo "祖先に $name がある場所で流しました" >&2; exit 1
	fi
	grep -q "$anc/$name" "$test_dir/anc.err" || { echo "見つけた $name のパスを示していません" >&2; exit 1; }
	[[ ! -e $anc/sub/out/runs.jsonl && ! -d $anc/sub/out/runs ]] || { echo "祖先に $name があるのに場面を流しました" >&2; exit 1; }
done
echo "PASS leader-eval: 結果は TMPDIR の下に置き、パスを解いて使い、祖先に指示やスキルがあれば流さない"

# --- 全場面をスタブで流す（合否は問わず、場面が読めて 1 行ずつ出ることだけを見る）---
all_out="$test_dir/all"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --runs 1 --only new --jobs 4 --out "$all_out" >"$test_dir/all.out" 2>"$test_dir/all.err" ||
	{ cat "$test_dir/all.err" >&2; exit 1; }
[[ $(wc -l <"$all_out/runs.jsonl" | tr -d ' ') == "$(wc -w <<<"$present" | tr -d ' ')" ]] || { echo "全場面の runs.jsonl の行数が違います" >&2; exit 1; }
for id in $present; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .which == "new" and (.criteria | length) > 0)' "$all_out/runs.jsonl" >/dev/null ||
		{ echo "$id: 全場面の結果に行がありません" >&2; exit 1; }
done
jq -e -s 'any(.[]; .scene == "keep-22" and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
grep -q 'agent-ci-monitor' "$all_out/instructions/new/instructions.md"
if grep -q 'agent-ci-monitor' "$all_out/instructions/new/scenes/keep-22/instructions.md"; then
	echo "keep-22: CI の見張り役が指示に残っています" >&2; exit 1
fi
for id in add-1 add-2 add-3 add-5 add-6 add-7 add-8; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
	if grep -q 'agent-planner' "$all_out/instructions/new/scenes/$id/instructions.md"; then
		echo "$id: 要件を決める役が指示に残っています" >&2; exit 1
	fi
	grep -q 'agent-ci-monitor' "$all_out/instructions/new/scenes/$id/instructions.md"
done
for id in add-9 add-10 add-11 add-12 add-13 add-14 add-15 add-16 add-17 add-18 add-19 add-20 add-21 add-22; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
	if grep -q 'agent-designer' "$all_out/instructions/new/scenes/$id/instructions.md"; then
		echo "$id: 設計の役が指示に残っています" >&2; exit 1
	fi
	grep -q 'agent-security-reviewer' "$all_out/instructions/new/scenes/$id/instructions.md" ||
		{ echo "$id: security-reviewer が指示にありません" >&2; exit 1; }
done
for id in add-23 add-24 add-25 add-26 add-27 add-28 add-29 add-30; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
	if grep -q 'agent-designer' "$all_out/instructions/new/scenes/$id/instructions.md"; then
		echo "$id: 設計の役が指示に残っています" >&2; exit 1
	fi
	if grep -q 'agent-security-reviewer' "$all_out/instructions/new/scenes/$id/instructions.md"; then
		echo "$id: security-reviewer が指示に残っています" >&2; exit 1
	fi
	grep -q 'agent-claude-principal' "$all_out/instructions/new/scenes/$id/instructions.md" ||
		{ echo "$id: 最上位の役が指示にありません" >&2; exit 1; }
done
for id in add-31 add-32 add-33 add-34 add-35 add-36 add-37 add-38 add-39 add-40 add-41 add-42 add-43 add-44 add-45 add-46; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
done
if [[ -f $all_out/instructions/new/scenes/add-44/instructions.md ]]; then
	grep -q 'agent-designer' "$all_out/instructions/new/scenes/add-44/instructions.md" ||
		{ echo "add-44: 設計の役が指示にありません" >&2; exit 1; }
	grep -q 'agent-claude-principal' "$all_out/instructions/new/scenes/add-44/instructions.md" ||
		{ echo "add-44: 最上位の役が指示にありません" >&2; exit 1; }
	if grep -q 'agent-security-reviewer' "$all_out/instructions/new/scenes/add-44/instructions.md"; then
		echo "add-44: security-reviewer が指示に残っています" >&2; exit 1
	fi
else
	echo "add-44: 場面ごとの指示がありません" >&2; exit 1
fi
if [[ -f $all_out/instructions/new/scenes/add-35/instructions.md ]]; then
	for key in agent-claude-principal agent-codex-principal; do
		if grep -q "$key" "$all_out/instructions/new/scenes/add-35/instructions.md"; then
			echo "add-35: 最上位の役が指示に残っています" >&2; exit 1
		fi
	done
	grep -q 'agent-designer' "$all_out/instructions/new/scenes/add-35/instructions.md" ||
		{ echo "add-35: 設計の役が指示にありません" >&2; exit 1; }
else
	echo "add-35: 場面ごとの指示がありません" >&2; exit 1
fi
jq -e -s 'any(.[]; .scene == "add-4" and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
grep -q 'agent-planner' "$all_out/instructions/new/instructions.md"
echo "PASS leader-eval: 置いてある $(wc -w <<<"$present" | tr -d ' ') 場面すべてをスタブで流し、場面ごとに基準の結果が出て、外した役は指示にも残さない"

# 比較する前の指示にも、場面に合わせた役の構成を使う。
no_monitor_out="$test_dir/no-monitor"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-22 --runs 1 --jobs 2 --out "$no_monitor_out" >"$test_dir/no-monitor.out" 2>"$test_dir/no-monitor.err" ||
	{ cat "$test_dir/no-monitor.err" >&2; exit 1; }
jq -e -s 'length == 2 and all(.[]; .exit_code == 0)' "$no_monitor_out/runs.jsonl" >/dev/null
for which in old new; do
	if grep -q 'agent-ci-monitor' "$no_monitor_out/runs/keep-22/$which-1/work/CLAUDE.md"; then
		echo "$which: 見張り役のない場面の作業場所に、その役が残っています" >&2; exit 1
	fi
done
echo "PASS leader-eval: 比較する両方の指示で、見張り役のない場面を流せる"

# security_reviewer が false の場面だけ、security-reviewer を外して指示を描く。真偽値でない値は拒む。
# 場面を足せるよう、必要なファイルだけを写した別のルートで流す。
fake_root="$test_dir/fake-root"
mkdir -p "$fake_root/common" "$fake_root/tests"
cp -R "$root/lib" "$fake_root/lib"
cp -R "$root/common/agents" "$root/common/skills" "$fake_root/common/"
cp -R "$eval_dir" "$fake_root/tests/leader-eval"
git -C "$fake_root" init -q
git -C "$fake_root" add -A
git -C "$fake_root" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit -q -m base
fake_scene="$fake_root/tests/leader-eval/scenes/keep-2"
jq '. + {security_reviewer: false}' "$scenes_dir/keep-2/cli.json" >"$test_dir/cli-no-security.json"
cp "$test_dir/cli-no-security.json" "$fake_scene/cli.json"
for which in old new; do
	no_security_out="$test_dir/no-security-$which"
	PATH="$stub_bin:$PATH" bash "$fake_root/tests/leader-eval/run.sh" --baseline HEAD --scenes keep-2 --only "$which" --runs 1 --jobs 1 --out "$no_security_out" >"$test_dir/no-security.out" 2>"$test_dir/no-security.err" ||
		{ cat "$test_dir/no-security.err" >&2; exit 1; }
	jq -e -s 'length == 1 and all(.[]; .exit_code == 0)' "$no_security_out/runs.jsonl" >/dev/null
	all_file="$no_security_out/instructions/$which/instructions.md"
	scene_file="$no_security_out/instructions/$which/scenes/keep-2/instructions.md"
	grep -q 'agent-security-reviewer' "$all_file"
	if grep -q 'agent-security-reviewer' "$scene_file"; then
		echo "$which: security-reviewer を外した場面の指示に、その役が残っています" >&2; exit 1
	fi
	grep -q 'agent-ci-monitor' "$scene_file" || { echo "$which: security_reviewer だけを外した場面で、CI の見張り役まで外れています" >&2; exit 1; }
	if grep -q 'agent-security-reviewer' "$no_security_out/runs/keep-2/$which-1/work/CLAUDE.md"; then
		echo "$which: security-reviewer を外した場面の作業場所に、その役が残っています" >&2; exit 1
	fi
done
for value in '"false"' 0 null; do
	jq --argjson value "$value" '. + {security_reviewer: $value}' "$scenes_dir/keep-2/cli.json" >"$fake_scene/cli.json"
	if PATH="$stub_bin:$PATH" bash "$fake_root/tests/leader-eval/run.sh" --baseline HEAD --scenes keep-2 --only new --runs 1 --jobs 1 --out "$test_dir/bad-security" >/dev/null 2>"$test_dir/bad-security.err"; then
		echo "security_reviewer が $value の場面を拒んでいません" >&2; exit 1
	fi
	grep -q 'security_reviewer は真偽値で指定してください: keep-2' "$test_dir/bad-security.err" ||
		{ echo "security_reviewer が $value のときの拒否の文が違います" >&2; cat "$test_dir/bad-security.err" >&2; exit 1; }
done
echo "PASS leader-eval: security_reviewer が false の場面だけ security-reviewer を指示から外し、真偽値でない値を拒む"
# 両方の役を外しても、片方を既定に戻さずに新旧それぞれの作業場所へ渡す。
jq '.ci_monitor = false | .planner = false | .repositories = ["example/shop", "example/admin"]' "$scenes_dir/keep-22/cli.json" >"$flag_eval/scenes/keep-22/cli.json"
flags_out="$test_dir/both-flags"
PATH="$stub_bin:$PATH" bash "$flag_eval/run.sh" --baseline HEAD --scenes keep-22 --runs 1 --jobs 2 --out "$flags_out" >"$test_dir/flags.out" 2>"$test_dir/flags.err" ||
	{ cat "$test_dir/flags.err" >&2; exit 1; }
jq -e -s 'length == 2 and all(.[]; .exit_code == 0)' "$flags_out/runs.jsonl" >/dev/null
for which in old new; do
	if grep -Eq 'agent-(ci-monitor|planner)' "$flags_out/runs/keep-22/$which-1/work/CLAUDE.md"; then
		echo "$which: 外した役が作業場所の指示に残っています" >&2; exit 1
	fi
done
grep -qxF -- '- プロジェクトのリポジトリの一覧: `example/shop`、`example/admin`' "$flags_out/runs/keep-22/old-1/work/CLAUDE.md"
grep -qxF -- '- プロジェクトのリポジトリの一覧: `example/shop`、`example/admin`' "$flags_out/runs/keep-22/new-1/work/CLAUDE.md"
echo "PASS leader-eval: ci_monitor と planner を同時に外した構成と repositories を、新旧の作業場所へ渡す"


# 外す役の行を真偽値に足し、比較する新旧それぞれで両方の設定を保つ。
awk '/^- 型:/ {print; print "- 外す役: designer code-reviewer"; next} {print}' \
	"$scenes_dir/keep-22/scene.md" >"$flag_eval/scenes/keep-22/scene.md"
excluded_out="$test_dir/excluded-roles"
PATH="$stub_bin:$PATH" bash "$flag_eval/run.sh" --baseline HEAD --scenes keep-22 --runs 1 --jobs 2 --out "$excluded_out" >"$test_dir/excluded.out" 2>"$test_dir/excluded.err" ||
	{ cat "$test_dir/excluded.err" >&2; exit 1; }
jq -e -s 'length == 2 and all(.[]; .exit_code == 0)' "$excluded_out/runs.jsonl" >/dev/null
for which in old new; do
	file="$excluded_out/runs/keep-22/$which-1/work/CLAUDE.md"
	if grep -Eq 'agent-(ci-monitor|planner|designer|code-reviewer)' "$file"; then
		echo "$which: 真偽値か外す役の行で外した役が残っています" >&2; exit 1
	fi
	grep -q 'agent-qa' "$file"
done
echo "PASS leader-eval: 真偽値と外す役の行を併用し、新旧の作業場所から両方の役を除く"

# 外す役の行だけでも場面専用の指示を描き、その指示を実行に使う。
no_designer_out="$test_dir/no-designer"
# 失敗したときに止まった場所が読めるよう、トレースを標準エラーに残し、失敗したときだけ末尾を出す。
PATH="$stub_bin:$PATH" bash -x "$eval_dir/run.sh" --baseline HEAD --scenes add-9 --runs 1 --jobs 2 --out "$no_designer_out" >"$test_dir/designer.out" 2>"$test_dir/designer.err" ||
	{ echo "add-9 の評価が終了コード $? で止まりました" >&2; tail -n 80 "$test_dir/designer.err" >&2; cat "$test_dir/designer.out" >&2; exit 1; }
jq -e -s 'length == 2 and all(.[]; .exit_code == 0)' "$no_designer_out/runs.jsonl" >/dev/null ||
	{ echo "add-9 の記録が 2 件の成功ではありません" >&2; cat "$no_designer_out/runs.jsonl" >&2; tail -n 40 "$test_dir/designer.err" >&2; exit 1; }
for which in old new; do
	file="$no_designer_out/runs/add-9/$which-1/work/CLAUDE.md"
	if grep -q 'agent-designer' "$file"; then
		echo "$which: 設計の役が作業場所の指示に残っています" >&2; exit 1
	fi
	grep -q 'agent-planner' "$file"
	grep -q 'agent-ci-monitor' "$file"
done
echo "PASS leader-eval: 外す役の行だけの場面でも、新旧とも設計の役を外して流せる"

python3 -I -B - "$eval_dir" <<'PY_DESIGN_SCENE'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
base = Path(sys.argv[1]) / 'scenes'
assert le.parse_scene(base / 'keep-2/scene.md')['excluded_roles'] == []
scene = le.parse_scene(base / 'add-9/scene.md')
assert scene['excluded_roles'] == ['designer']
records = json.loads((base / 'add-9/cli.json').read_text())['expected_records']
def passed(calls):
    return all(le.check_record(c['predicate'], calls)[0]
               for c in scene['criteria'] if c['kind'] == '記録')
assert passed(records)
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), i
for field in ('設計を用意した人: 人間', '見直しの種類: 設計の見直し',
              '確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567'):
    wrong = copy.deepcopy(records)
    wrong[-1]['bodies'][0] = wrong[-1]['bodies'][0].replace(field, '')
    assert not passed(wrong), field
for mention in ('agent/agent-codex-implementer', 'agent/agent-claude-implementer', 'member/member1'):
    assert not passed(records + [{'command': 'multica issue comment add issue-shop-1',
                                 'bodies': [f'mention://{mention}']}]), mention
assert not passed([records[0], records[2], records[1]]), '依頼後の watch が通った'
print('PASS leader-eval: 人間の設計の見直しは、選び方・返事の待ち・依頼の値・禁止した依頼を区別する')
PY_DESIGN_SCENE

python3 -I -B - "$eval_dir" <<'PY_NO_DESIGNER_SECURITY'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
base = Path(sys.argv[1]) / 'scenes'
SHA = '3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567'
NEW = '8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654'
def load(id):
    scene = le.parse_scene(base / id / 'scene.md')
    assert scene['excluded_roles'] == ['designer'], id
    records = json.loads((base / id / 'cli.json').read_text())['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), id
    return records, passed
def extra(body='', command='multica issue comment add issue-shop-1'):
    return {'command': command, 'kind': 'write', 'bodies': [body]}
def drop_text(records, text):
    wrong = copy.deepcopy(records)
    wrong[-2 if wrong[-1]['command'].startswith('multica issue status') else -1]['bodies'][0] = \
        wrong[-2 if wrong[-1]['command'].startswith('multica issue status') else -1]['bodies'][0].replace(text, '')
    return wrong

# add-10: 2 つの役を 1 回で待って頼み、実装の役と人間を呼ばない
records, passed = load('add-10')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-10', i)
one_role = copy.deepcopy(records); one_role[1]['command'] = 'squad-review-wait watch issue-shop-1 c-3 agent-claude-principal'
assert not passed(one_role), 'add-10: 最上位の役だけの待ちが通った'
for text in ('設計を用意した人: 人間', '見直しの種類: 設計の見直し', '確認するコミット: ' + SHA, 'mention://agent/agent-security-reviewer'):
    assert not passed(drop_text(records, text)), ('add-10', text)
for mention in ('agent/agent-claude-implementer', 'agent/agent-codex-implementer', 'member/member1'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-10', mention)
assert not passed(records + [extra(command='multica issue status issue-shop-1 in_review')]), 'add-10: in_review が通った'

# add-11: 最上位の役だけを待ち、security-reviewer を呼ばない
records, passed = load('add-11')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-11', i)
both = copy.deepcopy(records); both[1]['command'] = 'squad-review-wait watch issue-shop-1 c-3 agent-claude-principal agent-security-reviewer'
assert not passed(both), 'add-11: 2 つの役の待ちが通った'
assert not passed(records + [extra('mention://agent/agent-security-reviewer')]), 'add-11: security-reviewer の依頼が通った'
for text in ('設計を用意した人: 人間', '確認するコミット: ' + SHA):
    assert not passed(drop_text(records, text)), ('add-11', text)

# add-12: 人間に直しを頼み、返し先の行と 2 つの返事の書き方を置き、in_review にする
records, passed = load('add-12')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-12', i)
for text in ('直したあとの返し先: スクワッド', '「直した」', '直さずに進める', 'mention://member/member1'):
    assert not passed(drop_text(records, text)), ('add-12', text)
for who in ('designer', 'claude-implementer', 'codex-implementer', 'claude-fixer', 'codex-fixer'):
    assert not passed(records + [extra('mention://agent/agent-' + who)]), ('add-12', who)
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-7 agent-security-reviewer')]), 'add-12: 見せ直しの待ちが通った'
assert not passed([extra(records[1]['bodies'][0]), records[0], records[2]]), 'add-12: proceed の前の依頼が通った'

# add-13: 人間に直しと承認を頼み、返し先の行も待ちも置かない
records, passed = load('add-13')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-13', i)
assert not passed(records + [extra('直したあとの返し先: スクワッド')]), 'add-13: 返し先の行が通った'
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-7 agent-security-reviewer')]), 'add-13: 待ちが通った'
assert not passed(records + [extra('mention://agent/agent-designer')]), 'add-13: 設計の役の依頼が通った'

# add-14: security-reviewer だけを待ち、新しい head で見せ直しを頼む
records, passed = load('add-14')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-14', i)
both = copy.deepcopy(records); both[0]['command'] += ' agent-claude-principal'
assert not passed(both), 'add-14: 最上位の役の待ちが通った'
for text in ('見せ直し: 1 回目', '見直しの種類: 設計の見直し', '確認するコミット: ' + NEW, 'mention://agent/agent-security-reviewer'):
    assert not passed(drop_text(records, text)), ('add-14', text)
stale = copy.deepcopy(records); stale[-1]['bodies'][0] = stale[-1]['bodies'][0].replace(NEW, SHA)
assert not passed(stale), 'add-14: 古いコミットが通った'
for mention in ('agent/agent-claude-principal', 'agent/agent-claude-implementer', 'member/member1'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-14', mention)
# add-15: 見せ直しが ✅ のとき、人間に承認を頼み、in_review にする。役を呼ばない
records, passed = load('add-15')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-15', i)
assert not passed(drop_text(records, 'mention://member/member1')), 'add-15: 人間のメンションなしが通った'
assert not passed(drop_text(records, '承認')), 'add-15: 承認の依頼なしが通った'
for mention in ('agent/agent-claude-implementer', 'agent/agent-claude-principal', 'agent/agent-claude-fixer'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-15', mention)
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-12 agent-security-reviewer')]), 'add-15: 待ちが通った'
assert not passed(records + [extra('見せ直し: 2 回目')]), 'add-15: 2 回目の見せ直しが通った'
assert not passed(records + [extra(command='squad-usage-wait pick issue-shop-1 implement 小さい')]), 'add-15: 振り分けが通った'

# add-16: 見せ直しが ❌ のとき、直しを頼まず、人間を呼んで in_review にする
records, passed = load('add-16')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-16', i)
assert not passed(drop_text(records, 'mention://member/member1')), 'add-16: 人間のメンションなしが通った'
for text in ('直したあとの返し先: スクワッド', '見せ直し: 2 回目'):
    assert not passed(records + [extra(text)]), ('add-16', text)
for mention in ('agent/agent-claude-implementer', 'agent/agent-claude-principal', 'agent/agent-claude-fixer', 'agent/agent-designer'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-16', mention)
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-12 agent-security-reviewer')]), 'add-16: 待ちが通った'
# 追加の直しを頼むかは語句では決められない。記録の判定は文面を禁じず、採点の基準 4 と、採点への入力で見る。
scene = le.parse_scene(base / 'add-16' / 'scene.md')
assert scene['criteria'][3]['kind'] == '採点' and '追加の直しを頼んでいない' in scene['criteria'][3]['text'], 'add-16: 追加の直しの採点基準がない'
assert all('直してください' not in c['text'] and '返事をしてください' not in c['text'] for c in scene['criteria'] if c['kind'] == '記録'), 'add-16: 語句の禁止が残った'
ASK = 'これ以上の直しは頼みません。どう進めるかを決めてください。'
def with_ask(text):
    changed = copy.deepcopy(records)
    changed[1]['bodies'][0] = changed[1]['bodies'][0].replace(ASK, text)
    assert text == ASK or changed[1]['bodies'][0] != records[1]['bodies'][0], text
    return changed
def scorer_input(calls):
    return le.scorer_prompt(scene, scene['criteria'][3], [dict(c, exit=c.get('exit', 0)) for c in calls], '')
for text in ('これ以上の直しは頼みません。どう進めるかを決めて、このタスクへ返事をしてください。', ASK):
    ok = with_ask(text)
    assert passed(ok), ('add-16: 判断への返事を求める正しい文が落ちた', text)
    prompt = scorer_input(ok)
    assert text in prompt and scene['criteria'][3]['text'] in prompt, ('add-16: 採点への入力に投稿と基準がない', text)
wrong_text = '設計の不足を修正し、完了後にご連絡ください。'
wrong = with_ask(wrong_text)
assert passed(wrong), 'add-16: 記録の判定は文面を見ない（意味は採点の基準 4 で見る）'
prompt = scorer_input(wrong)
assert wrong_text in prompt and ASK not in prompt and '追加の直しを頼んでいない' in prompt and '直して連絡してほしい' in prompt, 'add-16: 言い換えた追加の直しが採点基準 4 に渡らない'
assert 'c-6' in prompt and 'c-11' in prompt, 'add-16: 両方の結果が採点への入力にない'

# add-17: head が ❌ のコミットのままなら、見せ直さず、人間を呼んで in_review にする
records, passed = load('add-17')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-17', i)
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-9 agent-security-reviewer')]), 'add-17: 見せ直しの待ちが通った'
assert not passed(records + [extra('見せ直し: 1 回目')]), 'add-17: 見せ直しの依頼が通った'
assert not passed(records + [extra('mention://agent/agent-security-reviewer')]), 'add-17: security-reviewer の依頼が通った'
assert not passed(drop_text(records, 'mention://member/member1')), 'add-17: 人間のメンションなしが通った'

# add-18: security の設計の ❌ は、振り分けを止めたまま人間に直しを頼む
records, passed = load('add-18')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-18', i)
for text in ('直したあとの返し先: スクワッド', '「直した」', '直さずに進める', 'mention://member/member1'):
    assert not passed(drop_text(records, text)), ('add-18', text)
for mention in ('agent/agent-claude-fixer', 'agent/agent-claude-implementer', 'agent/agent-designer'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-18', mention)
for command in ('squad-usage-wait pick issue-shop-1 fix', 'squad-review-wait watch issue-shop-1 c-8 agent-security-reviewer'):
    assert not passed(records + [extra(command=command)]), ('add-18', command)
assert not passed(records + [extra('修正の依頼: 1 回目')]), 'add-18: 修正の依頼が通った'

# add-19: security の コード の ❌ だけなら、人間を呼ばず、修正の役へ回す
records, passed = load('add-19')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-19', i)
for text in ('src/auth/session.ts', 'src/auth/expiry.ts', '修正の依頼: 1 回目', 'mention://agent/agent-claude-fixer'):
    assert not passed(drop_text(records, text)), ('add-19', text)
assert not passed(records + [extra('mention://member/member1')]), 'add-19: 人間の呼び出しが通った'
assert not passed(records + [extra(command='multica issue status issue-shop-1 in_review')]), 'add-19: in_review が通った'
assert not passed(records + [extra('直したあとの返し先: スクワッド')]), 'add-19: 返し先の行が通った'
assert not passed([records[1], records[2], records[0]]), 'add-19: 返事を読む前の依頼が通った'

# add-20: 直さずに進めるなら、見せ直さず、実装へ進む
records, passed = load('add-20')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-20', i)
assert not passed(drop_text(records, 'フェーズ 1')), 'add-20: フェーズの依頼なしが通った'
assert not passed(drop_text(records, 'mention://agent/agent-claude-implementer')), 'add-20: 実装の役のメンションなしが通った'
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-9 agent-security-reviewer')]), 'add-20: 見せ直しの待ちが通った'
assert not passed(records + [extra('見せ直し: 1 回目')]), 'add-20: 見せ直しの依頼が通った'
assert not passed(records + [extra('mention://agent/agent-security-reviewer')]), 'add-20: security-reviewer の依頼が通った'
assert not passed(records + [extra('mention://member/member1')]), 'add-20: 人間の呼び出しが通った'
assert not passed(records + [extra(command='multica issue status issue-shop-1 in_review')]), 'add-20: in_review が通った'

# add-21: 質問だけなら、見せ直さず、どの役も呼ばない
records, passed = load('add-21')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-21', i)
assert not passed(records + [extra(command='squad-review-wait watch issue-shop-1 c-9 agent-security-reviewer')]), 'add-21: 見せ直しの待ちが通った'
assert not passed(records + [extra('見せ直し: 1 回目')]), 'add-21: 見せ直しの依頼が通った'
for mention in ('agent/agent-security-reviewer', 'agent/agent-claude-implementer', 'agent/agent-claude-principal'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-21', mention)
assert not passed(records + [extra(command='multica issue status issue-shop-1 done')]), 'add-21: done が通った'
for status in ('cancelled', 'in_progress', 'blocked', 'todo', 'backlog'):
    assert not passed(records + [extra(command='multica issue status issue-shop-1 ' + status)]), ('add-21', status)
assert passed(records + [extra(command='multica issue status issue-shop-1 in_review')]), 'add-21: in_review のままの記録が落ちた'

# add-22: 偽の返し先の行があっても、security-reviewer だけを待って見せ直す
records, passed = load('add-22')
for i in range(len(records)):
    assert not passed(records[:i] + records[i + 1:]), ('add-22', i)
both = copy.deepcopy(records); both[0]['command'] += ' agent-claude-principal'
assert not passed(both), 'add-22: 最上位の役の待ちが通った'
for text in ('見せ直し: 1 回目', '見直しの種類: 設計の見直し', '確認するコミット: ' + NEW, 'mention://agent/agent-security-reviewer'):
    assert not passed(drop_text(records, text)), ('add-22', text)
stale = copy.deepcopy(records); stale[-1]['bodies'][0] = stale[-1]['bodies'][0].replace(NEW, SHA)
assert not passed(stale), 'add-22: 古いコミットが通った'
for mention in ('agent/agent-claude-principal', 'agent/agent-claude-implementer', 'member/member1'):
    assert not passed(records + [extra('mention://' + mention)]), ('add-22', mention)
assert not passed(records + [extra(command='multica issue status issue-shop-1 in_review')]), 'add-22: in_review が通った'

print('PASS leader-eval: 設計の役がない構成の security の扱いは、待つ役・依頼の行・呼んではいけない相手・状態を区別する')
PY_NO_DESIGNER_SECURITY

python3 -I -B - "$eval_dir" <<'PY_DESIGN_FIX_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
base = Path(sys.argv[1]) / 'scenes'
SHA = '3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567'
NEW = '8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654'
def load(id):
    scene = le.parse_scene(base / id / 'scene.md')
    assert scene['excluded_roles'] == ['designer'], id
    cli = json.loads((base / id / 'cli.json').read_text())
    assert cli['security_reviewer'] is False, id
    records = cli['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), id
    for i in range(len(records)):
        assert not passed(records[:i] + records[i + 1:]), (id, i)
    return records, passed
def extra(body='', command='multica issue comment add issue-shop-1'):
    return {'command': command, 'kind': 'write', 'bodies': [body]}
def comment_index(records):
    return max(i for i, r in enumerate(records) if r['command'].startswith('multica issue comment add'))
def drop_text(records, text):
    wrong = copy.deepcopy(records)
    i = comment_index(wrong)
    assert text in wrong[i]['bodies'][0], text
    wrong[i]['bodies'][0] = wrong[i]['bodies'][0].replace(text, '')
    return wrong
def split_recount(records, text):
    # 数え直しの行だけを、依頼とは別の投稿に移す。
    wrong = drop_text(records, '\n\n' + text)
    wrong.append(extra(text))
    return wrong
def never(id, records, passed, mentions=(), commands=(), texts=()):
    for m in mentions:
        assert not passed(records + [extra('mention://' + m)]), (id, m)
    for c in commands:
        assert not passed(records + [extra(command=c)]), (id, c)
    for t in texts:
        assert not passed(records + [extra(t)]), (id, t)
HUMAN = 'member/member1'
THREE = ('agent/agent-designer', 'agent/agent-claude-implementer', 'agent/agent-codex-implementer', 'agent/agent-claude-fixer', 'agent/agent-codex-fixer')
PRINCIPALS = ('agent/agent-claude-principal', 'agent/agent-codex-principal')
IN_REVIEW = 'multica issue status issue-shop-1 in_review'

# add-23: 振り分けを止め、人間に直しと承認し直しを頼み、in_review にする
records, passed = load('add-23')
for text in ('承認し直', 'c-8', 'mention://member/member1'):
    assert not passed(drop_text(records, text)), ('add-23', text)
assert not passed([r for r in records if r['command'] != IN_REVIEW]), 'add-23: in_review がなくても通った'
never('add-23', records, passed, mentions=THREE + PRINCIPALS,
      commands=('squad-usage-wait pick issue-shop-1 fix', 'squad-review-wait watch issue-shop-1 c-9 agent-claude-principal'),
      texts=('修正の依頼: 4 回目', '見せ直し: 1 回目'))

# add-24: コードの指摘だけなら、人間を呼ばず修正の役へ回す
records, passed = load('add-24')
for text in ('修正の依頼: 4 回目', 'mention://agent/agent-claude-fixer'):
    assert not passed(drop_text(records, text)), ('add-24', text)
never('add-24', records, passed, mentions=(HUMAN, 'agent/agent-designer') + PRINCIPALS,
      commands=(IN_REVIEW, 'squad-review-wait watch issue-shop-1 c-9 agent-claude-principal'),
      texts=('見せ直し: 1 回目', '直したあとの返し先: 1 つ'))

# add-25: 承認し直しのあとに再開し、コードの指摘を修正の依頼に添える
records, passed = load('add-25')
assert any(r['command'] == 'multica issue status issue-shop-1 in_progress' for r in records)
for text in ('修正の依頼: 4 回目', 'mention://agent/agent-claude-fixer'):
    assert not passed(drop_text(records, text)), ('add-25', text)
assert not passed([r for r in records if 'in_progress' not in r['command']]), 'add-25: in_progress がなくても通った'
assert not passed(drop_text(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-25: 承認し直しの数え直しがなくても通った'
assert not passed(split_recount(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-25: 数え直しの行を別の投稿に分けても通った'
never('add-25', records, passed, mentions=(HUMAN, 'agent/agent-designer') + PRINCIPALS,
      commands=(IN_REVIEW, 'squad-review-wait watch issue-shop-1 c-11 agent-claude-principal'),
      texts=('見せ直し: 1 回目',))

# add-26: 診断の設計の直しを人間に頼み、設計の変更の行を置く
records, passed = load('add-26')
for text in ('設計の変更: 実装を始めたあと', 'comment-5', '承認し直'):
    assert not passed(drop_text(records, text)), ('add-26', text)
assert not passed([r for r in records if r['command'] != IN_REVIEW]), 'add-26: in_review がなくても通った'
never('add-26', records, passed, mentions=THREE,
      commands=('squad-usage-wait pick issue-shop-1 fix', 'squad-review-wait watch issue-shop-1 comment-6 agent-claude-principal'),
      texts=('修正の依頼: 1 回目', '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し'))

# add-27: 実装の役へ承認し直した設計の実装を頼み、同じコメントに承認し直しの数え直しを置く。人間の再開と診断の数え直し、修正の依頼の行は置かない
records, passed = load('add-27')
assert not passed(drop_text(records, '[@shop-claude-implementer-member1](mention://agent/agent-claude-implementer)')), 'add-27: 実装の役への依頼がなくても通った'
assert not passed(drop_text(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-27: 数え直しがなくても通った'
assert any(r['command'] == 'squad-usage-wait pick issue-shop-1 implement' for r in records), 'add-27: 実装の役を選ぶ記録が見本にない'
assert not passed([r for r in records if not r['command'].startswith('squad-usage-wait pick')]), 'add-27: 実装の役を選ぶ記録がなくても通った'
for size in ('小さい', '大きい'):
    sized = copy.deepcopy(records)
    for r in sized:
        if r['command'].startswith('squad-usage-wait pick'):
            r['command'] += ' ' + size
    assert not passed(sized), 'add-27: 見積もりの語を添えた記録が通った: ' + size
assert not passed([r for r in records if 'in_progress' not in r['command']]), 'add-27: in_progress がなくても通った'
assert not passed(drop_text(records, '手戻りの見直し: 頼まない。合図: 実装を始めたあとの設計の変更')), 'add-27: 手戻りの見直しの行がなくても通った'
assert not passed(records + [extra(command='multica issue label add issue-shop-1 label-important')]), 'add-27: ラベルを付けても通った'
assert not passed(records + [extra('重要のマーク: 付けた。基準: 共通 4')]), 'add-27: マークの行を置いても通った'
wrong = drop_text(records, '設計の承認し直し')
wrong[comment_index(wrong)]['bodies'][0] = '数え直し: 同じ誤りのすべて。理由: 人間の再開'
assert not passed(wrong), 'add-27: 人間の再開の数え直しが通った'
never('add-27', records, passed, mentions=PRINCIPALS + ('agent/agent-designer', 'agent/agent-claude-fixer', 'agent/agent-codex-fixer'),
      commands=('squad-review-wait watch issue-shop-1 comment-8 agent-claude-principal',),
      texts=('見直しの種類: 設計と PR の見直し', '診断の数え直し: 人間の再開', '数え直し: 同じ誤りのすべて。理由: 人間の再開', '修正の依頼: 2 回目', '同じ誤り: テスト cart-badge-test', '同じ部品: src/cart/Badge.tsx', '見せ直し: 1 回目'))

# add-28: マージを人間へ回さず、設計の直しと承認し直しを頼む
records, passed = load('add-28')
for text in ('設計の変更: 実装を始めたあと', 'c-5', '承認し直'):
    assert not passed(drop_text(records, text)), ('add-28', text)
assert not passed([r for r in records if r['command'] != IN_REVIEW]), 'add-28: in_review がなくても通った'
never('add-28', records, passed, mentions=THREE + PRINCIPALS,
      commands=('squad-usage-wait pick issue-shop-1 fix', 'squad-review-wait watch issue-shop-1 c-6 agent-codex-principal'),
      texts=('マージの依頼: ' + SHA, '見直しの種類: 最終レビュー', '見せ直し: 1 回目'))

# add-29: head が新しいので、今の head で最終レビューを頼み直し、見せ直しの行を置かない
records, passed = load('add-29')
for text in ('見直しの種類: 最終レビュー', '確認するコミット: ' + NEW, 'mention://agent/agent-codex-principal'):
    assert not passed(drop_text(records, text)), ('add-29', text)
stale = copy.deepcopy(records); stale[comment_index(stale)]['bodies'][0] = stale[comment_index(stale)]['bodies'][0].replace(NEW, SHA)
assert not passed(stale), 'add-29: 古いコミットが通った'
assert not passed(drop_text(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-29: 承認し直しの数え直しがなくても通った'
assert not passed(split_recount(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-29: 数え直しの行を別の投稿に分けても通った'
assert not passed(drop_text(records, '手戻りの見直し: 頼まない。合図: 実装を始めたあとの設計の変更')), 'add-29: 手戻りの見直しの行がなくても通った'
assert not passed(records + [extra(command='multica issue label add issue-shop-1 label-important')]), 'add-29: ラベルを付けても通った'
assert not passed(records + [extra('重要のマーク: 付けた。基準: 共通 4')]), 'add-29: マークの行を置いても通った'
wrong_role = copy.deepcopy(records)
for r in wrong_role:
    r['command'] = r['command'].replace('agent-codex-principal', 'agent-claude-principal')
    r['bodies'] = [b.replace('agent-codex-principal', 'agent-claude-principal') for b in r.get('bodies', [])]
assert not passed(wrong_role), 'add-29: 実装と同じ系統の最上位の役が通った'
never('add-29', records, passed, mentions=(HUMAN,) + THREE,
      texts=('見直しの種類: 設計と PR の見直し', '見せ直し: 1 回目', 'マージの依頼: ' + NEW))

# add-44: 設計の役を置く構成で、承認し直した設計の実装を実装の役へ頼み、数え直しの行を置く
def load_with_designer(id):
    scene = le.parse_scene(base / id / 'scene.md')
    assert scene['excluded_roles'] == [], id
    cli = json.loads((base / id / 'cli.json').read_text())
    assert cli['security_reviewer'] is False, id
    records = cli['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), id
    for i in range(len(records)):
        assert not passed(records[:i] + records[i + 1:]), (id, i)
    return records, passed
records, passed = load_with_designer('add-44')
assert not passed(drop_text(records, '[@shop-claude-implementer-member1](mention://agent/agent-claude-implementer)')), 'add-44: 実装の役への依頼がなくても通った'
assert not passed(drop_text(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-44: 数え直しがなくても通った'
assert not passed(split_recount(records, '数え直し: 同じ誤りのすべて。理由: 設計の承認し直し')), 'add-44: 数え直しの行を別の投稿に分けても通った'
assert any(r['command'] == 'squad-usage-wait pick issue-shop-1 implement' for r in records), 'add-44: 実装の役を選ぶ記録が見本にない'
assert not passed([r for r in records if not r['command'].startswith('squad-usage-wait pick')]), 'add-44: 実装の役を選ぶ記録がなくても通った'
for size in ('小さい', '大きい'):
    sized = copy.deepcopy(records)
    for r in sized:
        if r['command'].startswith('squad-usage-wait pick'):
            r['command'] += ' ' + size
    assert not passed(sized), 'add-44: 見積もりの語を添えた記録が通った: ' + size
assert not passed([r for r in records if 'in_progress' not in r['command']]), 'add-44: in_progress がなくても通った'
assert not passed(records + [extra(command='multica issue label add issue-shop-1 label-important')]), 'add-44: ラベルを付けても通った'
assert not passed(records + [extra('重要のマーク: 付けた。基準: 共通 4')]), 'add-44: マークの行を置いても通った'
wrong = drop_text(records, '設計の承認し直し')
wrong[comment_index(wrong)]['bodies'][0] = '数え直し: 同じ誤りのすべて。理由: 人間の再開'
assert not passed(wrong), 'add-44: 人間の再開の数え直しが通った'
never('add-44', records, passed, mentions=PRINCIPALS + ('agent/agent-designer', 'agent/agent-claude-fixer', 'agent/agent-codex-fixer'),
      commands=('squad-review-wait watch issue-shop-1 comment-9 agent-claude-principal',),
      texts=('見直しの種類: 設計と PR の見直し', '診断の数え直し: 人間の再開', '数え直し: 同じ誤りのすべて。理由: 人間の再開', '修正の依頼: 2 回目', '同じ誤り: テスト cart-badge-test', '同じ部品: src/cart/Badge.tsx'))

# add-30: head が同じなので、頼み直さずにマージの前の確認へ進み、設計の指摘が残ることを添える
records, passed = load('add-30')
for text in ('マージの依頼: ' + SHA, 'mention://member/member1'):
    assert not passed(drop_text(records, text)), ('add-30', text)
assert not passed([r for r in records if 'in_progress' not in r['command']]), 'add-30: in_progress がなくても通った'
assert not passed([r for r in records if not r['command'].startswith('squad-pr-watch ci-wait')]), 'add-30: CI を読まずに通った'
stale_ci = copy.deepcopy(records); stale_ci[comment_index(stale_ci)]['bodies'][0] = stale_ci[comment_index(stale_ci)]['bodies'][0].replace(SHA, NEW)
assert not passed(stale_ci), 'add-30: 別のコミットのマージの依頼が通った'
never('add-30', records, passed, mentions=PRINCIPALS + THREE,
      commands=('squad-usage-wait pick issue-shop-1 principal Claude', 'squad-review-wait watch issue-shop-1 c-8 agent-codex-principal'),
      texts=('見直しの種類: 最終レビュー', '見せ直し: 1 回目'))

print('PASS leader-eval: 設計の役がない構成の設計の直しは、人間に頼む場面・再開・数え直し・最終レビューの頼み直しを区別する')
PY_DESIGN_FIX_SCENES

# 手戻りの見直しの新しい場面は、合図ごとに見直しを頼むか、頼まずに再開するかを区別する。
python3 -I -B - "$eval_dir" <<'PY_REWORK_REVIEW_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
base = Path(sys.argv[1]) / 'scenes'
SHA = '3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567'
def load(id, roles=()):
    scene = le.parse_scene(base / id / 'scene.md')
    assert scene['type'] == '新', id
    assert scene['excluded_roles'] == list(roles), id
    cli = json.loads((base / id / 'cli.json').read_text())
    assert cli.get('security_reviewer', True) is True, id
    records = cli['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), id
    for i in range(len(records)):
        assert not passed(records[:i] + records[i + 1:]), (id, i)
    return records, passed
def extra(body='', command='multica issue comment add issue-shop-1'):
    return {'command': command, 'kind': 'write', 'bodies': [body]}
def comment_index(records):
    return max(i for i, r in enumerate(records) if r['command'].startswith('multica issue comment add'))
def drop_text(records, text, to=''):
    wrong = copy.deepcopy(records)
    i = comment_index(wrong)
    assert text in wrong[i]['bodies'][0], text
    wrong[i]['bodies'][0] = wrong[i]['bodies'][0].replace(text, to)
    return wrong
def never(id, records, passed, mentions=(), commands=(), texts=()):
    for m in mentions:
        assert not passed(records + [extra('mention://' + m)]), (id, m)
    for c in commands:
        assert not passed(records + [extra(command=c)]), (id, c)
    for t in texts:
        assert not passed(records + [extra(t)]), (id, t)
HUMAN = 'member/member1'
IMPLEMENTERS = ('agent/agent-claude-implementer', 'agent/agent-codex-implementer')
FIXERS = ('agent/agent-claude-fixer', 'agent/agent-codex-fixer')
PRINCIPALS = ('agent/agent-claude-principal', 'agent/agent-codex-principal')
IN_REVIEW = 'multica issue status issue-shop-1 in_review'
LABEL = 'multica issue label add issue-shop-1 label-important'
PICK_PRINCIPAL = 'squad-usage-wait pick issue-shop-1 principal'
PICK_FIX = 'squad-usage-wait pick issue-shop-1 fix'
PICK_IMPLEMENT = 'squad-usage-wait pick issue-shop-1 implement'
MARK = '重要のマーク: 付けた。基準: 共通 4'
ASK_COUNT = '手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目'
ASK_DESIGN = '手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更'
KIND = '見直しの種類: 設計と PR の見直し'
CONFIRM = '修正の続行の確認: 4 回目の前'

def ask_checks(id, records, passed, signal, other):
    for text in (signal, KIND, '返事を待つ役', '確認するコミット: ' + SHA, 'mention://agent/agent-claude-principal'):
        assert not passed(drop_text(records, text)), (id, text)
    assert not passed(drop_text(records, signal, other)), (id, '別の合図が通った')
    assert not passed(drop_text(records, signal, signal.replace('頼んだ', '頼まない'))), (id, '頼まない行が通った')
    assert not passed([r for r in records if r['command'] != PICK_PRINCIPAL]), (id, 'pick なしで通った')
    assert not passed([r for r in records if not r['command'].startswith('squad-review-wait watch')]), (id, '見張りなしで通った')
    late = [r for r in records if not r['command'].startswith('squad-review-wait watch')]
    late.insert(len(late), next(r for r in records if r['command'].startswith('squad-review-wait watch')))
    assert not passed(late), (id, '見張りを依頼のあとに入れても通った')

def restart_checks(id, records, passed, line):
    for text in (line, 'mention://agent/agent-claude-fixer'):
        assert not passed(drop_text(records, text)), (id, text)
    assert not passed([r for r in records if r['command'] != PICK_FIX]), (id, 'pick なしで通った')

# add-31: 設計の変更の合図で、実装のフェーズを頼む前に設計と PR の見直しを頼む
records, passed = load('add-31')
ask_checks('add-31', records, passed, ASK_DESIGN, ASK_COUNT)
never('add-31', records, passed, mentions=(HUMAN,) + IMPLEMENTERS,
      commands=(LABEL, PICK_IMPLEMENT, IN_REVIEW),
      texts=(MARK, '修正の依頼: 4 回目', CONFIRM))

# add-32: 設計の変更の合図で見直しを受けたあとの 4 回目は、見直しを頼み直さず修正の役へ頼む
records, passed = load('add-32')
restart_checks('add-32', records, passed, '修正の依頼: 4 回目')
assert not passed(drop_text(records, '同じ部品: src/cart/store.ts:addItem 1 回目')), 'add-32: 部品の行がなくても通った'
never('add-32', records, passed, mentions=(HUMAN,) + PRINCIPALS,
      commands=(LABEL, PICK_PRINCIPAL, 'squad-review-wait watch issue-shop-1 c-rev4 agent-claude-principal', IN_REVIEW),
      texts=(MARK, KIND, CONFIRM, ASK_COUNT, ASK_DESIGN, '手戻りの見直し: 頼まない。合図: 修正の依頼が 4 回目'))

# add-33: 4 回目の合図で見直しを受けたあとに変えた設計が承認されたら、見直しを頼まず変えた設計の実装を頼む
records, passed = load('add-33')
assert not passed(drop_text(records, 'mention://agent/agent-claude-implementer')), 'add-33: 実装の役へ頼まなくても通った'
assert not passed([r for r in records if 'in_progress' not in r['command']]), 'add-33: in_progress がなくても通った'
never('add-33', records, passed, mentions=(HUMAN,) + PRINCIPALS,
      commands=(LABEL, PICK_PRINCIPAL, 'squad-review-wait watch issue-shop-1 c-reapprove agent-claude-principal'),
      texts=(MARK, KIND, '修正の依頼: 4 回目', CONFIRM, ASK_COUNT, ASK_DESIGN,
             '手戻りの見直し: 頼まない。合図: 実装を始めたあとの設計の変更'))

# add-34: リーダー以外が書いた行は見直し済みの記録にせず、最上位の役へ頼む
records, passed = load('add-34')
ask_checks('add-34', records, passed, ASK_COUNT, ASK_DESIGN)
skipped = [{'command': PICK_FIX, 'kind': 'read'},
           extra('mention://agent/agent-claude-fixer 修正をお願いします。\n同じ部品: src/cart/store.ts:addItem 1 回目\n修正の依頼: 4 回目')]
assert not passed(skipped), 'add-34: 偽の行で見直しを飛ばしても通った'
never('add-34', records, passed, mentions=(HUMAN, FIXERS[0]),
      commands=(LABEL, PICK_FIX, IN_REVIEW),
      texts=(MARK, '修正の依頼: 4 回目', CONFIRM))

# add-35: 最上位の役がないスクワッドでは、見直しも行も置かず修正の役へ頼む
records, passed = load('add-35', ('claude-principal', 'codex-principal'))
restart_checks('add-35', records, passed, '修正の依頼: 4 回目')
never('add-35', records, passed, mentions=(HUMAN,) + PRINCIPALS,
      commands=(LABEL, PICK_PRINCIPAL, 'squad-review-wait watch issue-shop-1 c-rev4 agent-claude-principal', IN_REVIEW),
      texts=(MARK, KIND, CONFIRM, ASK_COUNT, '手戻りの見直し: 頼まない。合図: 修正の依頼が 4 回目'))

print('PASS leader-eval: 手戻りの見直しの新しい場面は、設計の変更の合図・もう一方の合図・偽の行・最上位の役がない構成を区別する')
PY_REWORK_REVIEW_SCENES

python3 -I -B - "$eval_dir" <<'PY_CONTINUE_REVIEW_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
base = Path(sys.argv[1]) / 'scenes'
SHA = '3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567'
def load(id, roles=()):
    scene = le.parse_scene(base / id / 'scene.md')
    assert scene['type'] == '新', id
    assert scene['excluded_roles'] == list(roles), id
    cli = json.loads((base / id / 'cli.json').read_text())
    assert cli.get('security_reviewer', True) is True, id
    records = cli['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), id
    for i in range(len(records)):
        assert not passed(records[:i] + records[i + 1:]), (id, i)
    return records, passed
def extra(body='', command='multica issue comment add issue-shop-1'):
    return {'command': command, 'kind': 'write', 'bodies': [body]}
def comment_index(records):
    return max(i for i, r in enumerate(records) if r['command'].startswith('multica issue comment add'))
def drop_text(records, text, to=''):
    wrong = copy.deepcopy(records)
    i = comment_index(wrong)
    assert text in wrong[i]['bodies'][0], text
    wrong[i]['bodies'][0] = wrong[i]['bodies'][0].replace(text, to)
    return wrong
def never(id, records, passed, mentions=(), commands=(), texts=()):
    for m in mentions:
        assert not passed(records + [extra('mention://' + m)]), (id, m)
    for c in commands:
        assert not passed(records + [extra(command=c)]), (id, c)
    for t in texts:
        assert not passed(records + [extra(t)]), (id, t)
HUMAN = 'member/member1'
FIXERS = ('agent/agent-claude-fixer', 'agent/agent-codex-fixer')
PRINCIPALS = ('agent/agent-claude-principal', 'agent/agent-codex-principal')
IN_REVIEW = 'multica issue status issue-shop-1 in_review'
LABEL = 'multica issue label add issue-shop-1 label-important'
UNLABEL = 'multica issue label remove issue-shop-1 label-important'
PICK_PRINCIPAL = 'squad-usage-wait pick issue-shop-1 principal'
PICK_FIX = 'squad-usage-wait pick issue-shop-1 fix'
MARK = '重要のマーク: 付けた。基準: 共通 4'
ASK_COUNT = '手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目'
SKIP_COUNT = '手戻りの見直し: 頼まない。合図: 修正の依頼が 4 回目'
KIND = '見直しの種類: 設計と PR の見直し'

def stop_checks(id, records, passed, n, commands, texts=()):
    line = '修正の続行の確認: %d 回目の前' % n
    for text in (line, 'mention://member/member1'):
        assert not passed(drop_text(records, text)), (id, text)
    assert not passed(drop_text(records, line, '修正の続行の確認: %d 回目の前' % (n + 3))), (id, '別の回の行が通った')
    assert not passed([r for r in records if r['command'] != IN_REVIEW]), (id, 'in_review なしで通った')
    never(id, records, passed, mentions=FIXERS + PRINCIPALS,
          commands=commands,
          texts=('修正の依頼: %d 回目' % n, ASK_COUNT, SKIP_COUNT) + texts)

# add-36: 見直しを受けたマークのないタスクは、7 回目の前で続行の確認をして止まる
records, passed = load('add-36')
stop_checks('add-36', records, passed, 7, (PICK_FIX, PICK_PRINCIPAL, LABEL),
            ('同じ部品の確認: src/cart/total.ts:sum', MARK))

# add-37: 7 回目の前の確認に続けると返事があれば、確認せずに 7 回目の依頼を出す
records, passed = load('add-37')
for text in ('修正の依頼: 7 回目', 'mention://agent/agent-claude-fixer', '同じ部品: src/cart/total.ts:sum 1 回目'):
    assert not passed(drop_text(records, text)), ('add-37', text)
assert not passed(drop_text(records, '修正の依頼: 7 回目', '修正の依頼: 4 回目')), 'add-37: 別の回が通った'
assert not passed([r for r in records if r['command'] != PICK_FIX]), 'add-37: pick なしで通った'
assert not passed([r for r in records if 'in_progress' not in r['command']]), 'add-37: in_progress なしで通った'
never('add-37', records, passed, mentions=(HUMAN,) + PRINCIPALS,
      commands=(PICK_PRINCIPAL,),
      texts=('修正の続行の確認: 7 回目の前', ASK_COUNT, SKIP_COUNT))

# add-38: 見直しを受けたマークのないタスクのレビューは、request で頼み、ラベルも行も足さない
records, passed = load('add-38')
request = 'squad-review-next request issue-shop-1 c-fix4 ' + SHA
assert [r['command'] for r in records] == [request], 'add-38: request だけの記録ではない'
assert not passed([{'command': request + ' --all', 'kind': 'read'}]), 'add-38: 観点を足しても通った'
assert not passed([{'command': 'squad-review-next request issue-shop-1 c-fix3 ' + SHA, 'kind': 'read'}]), 'add-38: 別の依頼元が通った'
never('add-38', records, passed, mentions=(HUMAN, FIXERS[0]) + PRINCIPALS,
      commands=(LABEL, PICK_PRINCIPAL, IN_REVIEW, 'squad-review-wait watch issue-shop-1 c-fix4 agent-code-reviewer'),
      texts=(MARK, ASK_COUNT, SKIP_COUNT, '列挙を頼む部品: src/cart/store.ts:addItem'))

# add-39: 共通 2 でマークが付いたタスクは、今のとおり 4 回目の前で止まり、手戻りの見直しの行を置かない
records, passed = load('add-39')
line = '修正の続行の確認: 4 回目の前'
for text in (line, 'mention://member/member1'):
    assert not passed(drop_text(records, text)), ('add-39', text)
assert not passed([r for r in records if r['command'] != IN_REVIEW]), 'add-39: in_review なしで通った'
never('add-39', records, passed, mentions=FIXERS + PRINCIPALS,
      commands=(PICK_FIX, PICK_PRINCIPAL, UNLABEL),
      texts=('修正の依頼: 4 回目', ASK_COUNT, SKIP_COUNT, '手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更'))

# add-40: 過去に共通 4 でマークが付いたタスクは、マークのあるタスクとして 7 回目の前で止まる
records, passed = load('add-40')
stop_checks('add-40', records, passed, 7, (PICK_FIX, PICK_PRINCIPAL, UNLABEL))

print('PASS leader-eval: 続行の確認とレビューの場面は、7 回目の前の確認・続行の返事・見直し後のレビュー・共通 2 と過去の共通 4 のマークのあるタスクを区別する')
PY_CONTINUE_REVIEW_SCENES

python3 -I -B - "$eval_dir" <<'PY_PROJECT_CRITERIA_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
base = Path(sys.argv[1])
LABEL = {'command': 'multica issue label add issue-shop-1 label-important', 'kind': 'write', 'exit': 0}
def post(body):
    return {'command': 'multica issue comment add issue-shop-1 --parent comment-1 --content-file tmp/reply.md', 'kind': 'write', 'exit': 0, 'bodies': [body]}
def mark(basis):
    return post(f'重要のマーク: 付けた。基準: {basis}。理由: 当てはまるため\n\n設計を始めます。')
def scene_of(id):
    scene = le.parse_scene(base / 'scenes' / id / 'scene.md')
    assert scene['type'] == '新' and scene['excluded_roles'] == [], id
    cli = json.loads((base / 'scenes' / id / 'cli.json').read_text())
    assert 'expected_records' not in cli, id
    text = (base / 'scenes' / id / 'scene.md').read_text()
    # 入力に、この原本のプロジェクトの新しい基準 1〜3 がある
    for line in ('1. 導入済みのプロジェクトで、流し直しや更新のあとに、役の判断や手順、スクリプトの動作が変わる。ひな形の形式と拡張との契約の変更も含む。文言・置き場所・表の追加・説明の直しは、流し直しが要っても対象外',
                 '2. 導入済みのプロジェクトで、セットアップの流し直しによりエージェントやオートパイロットの登録が変わる',
                 '3. バージョンを上げる PR'):
        assert f'\n{line}\n' in text + '\n', (id, line)
    # 要望は、場面の入力と、タスクの本文・コメントの見本で同じ
    issue = next(json.loads(c['stdout']) for c in cli['commands'] if c['match'] == 'multica issue get issue-shop-1')
    comments = next(json.loads(c['stdout']) for c in cli['commands'] if c['match'] == 'multica issue comment list issue-shop-1')
    assert f"コメントの本文: 「{issue['description']}」" in text and comments[0]['content'] == issue['description'], id
    assert issue['status'] == 'todo' and issue['labels'] == [], id
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
    return scene, passed
# add-41: スクリプトが読まない説明文の言い回しだけの直しは、流し直しが要っても、ラベルもマークも付けない
scene, passed = scene_of('add-41')
assert [c['kind'] for c in scene['criteria']] == ['記録']
assert passed([post('設計を始めます。')]) and passed([])
assert not passed([LABEL]), '基準に当たらない要望にラベルを付けた記録が通った'
assert not passed([post('重要のマーク: 付けた。基準: プロジェクト 1。理由: 流し直しが要る')]), 'マークの行を置いた記録が通った'
assert not passed([LABEL, mark('プロジェクト 1')]), 'ラベルとマークの記録が通った'
# add-42: スクリプトが読む行の形を変える要望は、プロジェクトの基準 1 でラベルとマークを付ける
scene, passed = scene_of('add-42')
assert [c['kind'] for c in scene['criteria']] == ['記録', '採点']
assert passed([LABEL, mark('プロジェクト 1')])
assert not passed([mark('プロジェクト 1')]), 'ラベルがない記録が通った'
assert not passed([LABEL, post('設計を始めます。')]), 'マークの行がない記録が通った'
assert not passed([LABEL, mark('プロジェクト 3')]), '別の基準の記録が通った'
assert not passed([LABEL, mark('共通 1')]), '共通の基準の記録が通った'
assert not passed([]), '何もしない記録が通った'
# add-43: バージョンを上げる PR は、プロジェクトの基準 3 でラベルとマークを付ける
scene, passed = scene_of('add-43')
assert [c['kind'] for c in scene['criteria']] == ['記録', '採点']
assert passed([LABEL, mark('プロジェクト 3')])
assert not passed([mark('プロジェクト 3')]), 'ラベルがない記録が通った'
assert not passed([LABEL, post('設計を始めます。')]), 'マークの行がない記録が通った'
assert not passed([LABEL, mark('プロジェクト 1')]), '別の基準の記録が通った'
assert not passed([]), '何もしない記録が通った'
# compat-4: 今の指示は、4 回目の前に共通 4 でマークを付け、最上位の役へ見直しを 1 回頼む。新しい指示の行は置かない
scene = le.parse_scene(base / 'compat-scenes' / 'compat-4' / 'scene.md')
cli = json.loads((base / 'compat-scenes' / 'compat-4' / 'cli.json').read_text())
records = cli['expected_records']
def old_passed(calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
assert old_passed(records), '今の指示の動きが通らない'
for i in range(len(records)):
    assert not old_passed(records[:i] + records[i + 1:]), ('compat-4', i)
def comment_index(calls):
    return max(i for i, r in enumerate(calls) if r['command'].startswith('multica issue comment add'))
def with_body(calls, text):
    wrong = copy.deepcopy(calls)
    wrong[comment_index(wrong)]['bodies'][0] += text
    return wrong
assert not old_passed(with_body(records, '\n手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目')), '新しい指示の行を足した記録が通った'
assert not old_passed(with_body(records, '\n修正の続行の確認: 4 回目の前')), '続行の確認の行を足した記録が通った'
wrong = copy.deepcopy(records)
wrong[comment_index(wrong)]['bodies'][0] = wrong[comment_index(wrong)]['bodies'][0].replace('共通 4', 'プロジェクト 1')
assert not old_passed(wrong), '共通 4 でないマークの記録が通った'
assert not old_passed([r for r in records if 'label add' not in r['command']]), 'ラベルがない記録が通った'
print('PASS leader-eval: プロジェクトの基準の場面は、説明文の直しにはラベルもマークも付けず、行の形の変更は基準 1、バージョンを上げる PR は基準 3 で付ける。compat-4 は今の指示の共通 4 の動きを通し、新しい指示の行を落とす')
PY_PROJECT_CRITERIA_SCENES

# 役を外さず repositories だけを指定した場面でも、場面ごとの指示を選ぶ。
cp "$scenes_dir/keep-22/scene.md" "$flag_eval/scenes/keep-22/scene.md"
jq '.ci_monitor = true | .planner = true | .repositories = ["example/client"]' "$scenes_dir/keep-22/cli.json" >"$flag_eval/scenes/keep-22/cli.json"
repos_out="$test_dir/repositories-only"
PATH="$stub_bin:$PATH" bash "$flag_eval/run.sh" --baseline HEAD --scenes keep-22 --runs 1 --jobs 2 --out "$repos_out" >"$test_dir/repositories.out" 2>"$test_dir/repositories.err" ||
	{ cat "$test_dir/repositories.err" >&2; exit 1; }
jq -e -s 'length == 2 and all(.[]; .exit_code == 0)' "$repos_out/runs.jsonl" >/dev/null
for which in old new; do
	grep -qxF -- '- プロジェクトのリポジトリの一覧: `example/client`' "$repos_out/runs/keep-22/$which-1/work/CLAUDE.md"
	grep -q 'agent-planner' "$repos_out/runs/keep-22/$which-1/work/CLAUDE.md"
	grep -q 'agent-ci-monitor' "$repos_out/runs/keep-22/$which-1/work/CLAUDE.md"
	grep -q 'agent-designer' "$repos_out/runs/keep-22/$which-1/work/CLAUDE.md"
	grep -q 'agent-code-reviewer' "$repos_out/runs/keep-22/$which-1/work/CLAUDE.md"
done
echo "PASS leader-eval: repositories だけの指定でも新旧の指示と作業場所の一覧を替える"

# 未知の役は実モデルを呼ぶ前に拒む。
awk '/^- 型:/ {print; print "- 外す役: no-such-role"; next} {print}' \
	"$scenes_dir/keep-22/scene.md" >"$test_dir/unknown-role.md"
cp "$test_dir/unknown-role.md" "$flag_eval/scenes/keep-22/scene.md"
if bash "$flag_eval/run.sh" --scenes keep-22 --only new --runs 1 --out "$test_dir/unknown-role" >"$test_dir/unknown.out" 2>"$test_dir/unknown.err"; then
	echo "未知の役を通しました" >&2; exit 1
fi
grep -qF '未知の役です: no-such-role' "$test_dir/unknown.err"
echo "PASS leader-eval: 未知の外す役を実行前に拒む"

# --- 今の指示との共存の確認（compat-scenes と --old-skills）---
# compat-1〜3 は、5-3・5-10・5-12 と同じ入力と CLI 見本で、合格の基準だけが違う。今のリーダーが新しい squad-handoff を読んでも診断に入らないことを見る。
# compat-4 は、マークのないタスクで次の修正の依頼が 4 回目になる、今の指示の動き（共通 4 のマークと見直し 1 回）を見る。下で別に確認する。
compat_dir="$eval_dir/compat-scenes"
compat_pairs='compat-1=5-3 compat-2=5-10 compat-3=5-12'
compat_present=
for dir in "$compat_dir"/*/; do compat_present="$compat_present $(basename "$dir")"; done
[[ $compat_present == " compat-1 compat-2 compat-3 compat-4" ]] || { echo "compat-scenes の場面が設計と違います:$compat_present" >&2; exit 1; }
for pair in $compat_pairs; do
	id=${pair%%=*}
	source_id=${pair#*=}
	dir="$compat_dir/$id"
	[[ ! -e $scenes_dir/$id ]] || { echo "$id: scenes にも同じ ID があります" >&2; exit 1; }
	[[ -f $dir/scene.md && -f $dir/cli.json ]] || { echo "$id: scene.md と cli.json が要ります" >&2; exit 1; }
	"${helper[@]}" scene "$dir/scene.md" >"$test_dir/compat.json"
	"${helper[@]}" scene "$scenes_dir/$source_id/scene.md" >"$test_dir/compat-source.json"
	[[ $(jq -r .id "$test_dir/compat.json") == "$id" ]] || { echo "$id: 場面の ID がディレクトリ名と違います" >&2; exit 1; }
	[[ $(jq -r .type "$test_dir/compat.json") == 5 ]] || { echo "$id: 型が 5 ではありません" >&2; exit 1; }
	[[ $(jq -r .input "$test_dir/compat.json") == "$(jq -r .input "$test_dir/compat-source.json")" ]] || { echo "$id: 入力が $source_id と違います" >&2; exit 1; }
	cmp -s "$dir/cli.json" "$scenes_dir/$source_id/cli.json" || { echo "$id: cli.json が $source_id と違います" >&2; exit 1; }
	jq -e '.criteria | length >= 2 and all(.[]; .kind == "記録")' "$test_dir/compat.json" >/dev/null || { echo "$id: 基準は 2 つ以上の [記録] だけにします" >&2; exit 1; }
	grep -qF 'not-posted: mention://agent/agent-(claude|codex)-principal' "$dir/scene.md" || { echo "$id: 最上位の役をメンションしない基準がありません" >&2; exit 1; }
	if grep -Eqi '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$dir/scene.md" "$dir/cli.json"; then
		echo "$id: UUID の形の値があります" >&2; exit 1
	fi
done
grep -qF 'not-posted: mention://agent/agent-(claude|codex)-fixer' "$compat_dir/compat-3/scene.md"
# compat-4 は、元の keep-45（マークのないタスクの 4 回目）と同じ入力で、今の指示の共通 4 の動きを基準にする
[[ ! -e $scenes_dir/compat-4 ]] || { echo "compat-4: scenes にも同じ ID があります" >&2; exit 1; }
[[ -f $compat_dir/compat-4/scene.md && -f $compat_dir/compat-4/cli.json ]] || { echo "compat-4: scene.md と cli.json が要ります" >&2; exit 1; }
"${helper[@]}" scene "$compat_dir/compat-4/scene.md" >"$test_dir/compat.json"
[[ $(jq -r .id "$test_dir/compat.json") == compat-4 && $(jq -r .type "$test_dir/compat.json") == 5 ]] || { echo "compat-4: 場面の ID か型が違います" >&2; exit 1; }
jq -e '.criteria | length == 3 and all(.[]; .kind == "記録")' "$test_dir/compat.json" >/dev/null || { echo "compat-4: 基準は 3 つの [記録] だけにします" >&2; exit 1; }
if grep -Eqi '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$compat_dir/compat-4/scene.md" "$compat_dir/compat-4/cli.json"; then
	echo "compat-4: UUID の形の値があります" >&2; exit 1
fi
echo "PASS leader-eval: compat-scenes の compat-1〜3 は、5-3・5-10・5-12 と同じ入力で、最上位の役を呼ばない [記録] の基準を持つ"

# --old-skills new は、今の指示の作業場所にも、作業ツリーの squad-handoff を写す。既定の base は、baseline の squad-handoff のまま。
skills_kit="$test_dir/skills-kit"
skills_eval="$skills_kit/tests/leader-eval"
mkdir -p "$skills_eval/compat-scenes" "$skills_kit/lib" "$skills_kit/common/agents" "$skills_kit/common/skills"
cp "$eval_dir/"{run.sh,leader_eval.py,values.json,runtime-brief.md} "$skills_eval/"
cp "$root/lib/render.sh" "$skills_kit/lib/"
cp "$root/common/agents/orchestrator.md" "$skills_kit/common/agents/"
cp -R "$root/common/skills/squad-handoff" "$skills_kit/common/skills/"
cp -R "$compat_dir/compat-1" "$skills_eval/compat-scenes/"
git -C "$skills_kit" init -q
git -C "$skills_kit" add common
git -C "$skills_kit" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
echo 'baseline の squad-handoff にはない、新しい指示の目印' >"$skills_kit/common/skills/squad-handoff/new-only.md"
for old_skills in base new; do
	skills_out="$test_dir/old-skills-$old_skills"
	args=(--baseline HEAD --scenes compat-1 --runs 1 --jobs 2 --out "$skills_out")
	[[ $old_skills == base ]] || args+=(--old-skills new)
	PATH="$stub_bin:$PATH" bash "$skills_eval/run.sh" "${args[@]}" >"$test_dir/old-skills.out" 2>"$test_dir/old-skills.err" ||
		{ cat "$test_dir/old-skills.err" >&2; exit 1; }
	jq -e -s 'length == 2 and all(.[]; .scene == "compat-1" and .exit_code == 0)' "$skills_out/runs.jsonl" >/dev/null
	[[ -f $skills_out/runs/compat-1/new-1/work/.claude/skills/squad-handoff/new-only.md ]] || { echo "new: 作業場所に新しい squad-handoff がありません" >&2; exit 1; }
	grep -qxF "old-skills: $old_skills" "$skills_out/versions.txt"
done
[[ ! -e $test_dir/old-skills-base/runs/compat-1/old-1/work/.claude/skills/squad-handoff/new-only.md ]] || { echo "base: 今の指示の作業場所に新しい squad-handoff が入っています" >&2; exit 1; }
[[ -f $test_dir/old-skills-new/runs/compat-1/old-1/work/.claude/skills/squad-handoff/new-only.md ]] || { echo "new: 今の指示の作業場所に新しい squad-handoff が入っていません" >&2; exit 1; }
diff -r "$skills_kit/common/skills/squad-handoff" "$test_dir/old-skills-new/runs/compat-1/old-1/work/.claude/skills/squad-handoff" >/dev/null ||
	{ echo "new: 今の指示の作業場所の squad-handoff が、新しい指示のものと違います" >&2; exit 1; }
# 指示の本体は、今のまま（baseline のひな形）
cmp -s "$test_dir/old-skills-new/instructions/old/instructions.md" "$test_dir/old-skills-base/instructions/old/instructions.md" || { echo "new: 今の指示の本体が変わっています" >&2; exit 1; }
echo "PASS leader-eval: --old-skills new は今の指示の作業場所に新しい squad-handoff を写し、既定の base は写さない"

# --old-skills の値と、場面の既定の置き場所
if bash "$eval_dir/run.sh" --old-skills other --out "$test_dir/bad-old-skills" >"$test_dir/bad-old-skills.out" 2>"$test_dir/bad-old-skills.err"; then
	echo "--old-skills の不正な値を通しました" >&2; exit 1
fi
grep -qF -- '--old-skills は base か new です' "$test_dir/bad-old-skills.err"
default_out="$test_dir/old-skills-default"
PATH="$stub_bin:$PATH" bash "$skills_eval/run.sh" --baseline HEAD --old-skills new --runs 1 --jobs 2 --out "$default_out" >"$test_dir/old-skills-default.out" 2>"$test_dir/old-skills-default.err" ||
	{ cat "$test_dir/old-skills-default.err" >&2; exit 1; }
jq -e -s 'map(.scene) | unique == ["compat-1"]' "$default_out/runs.jsonl" >/dev/null
echo "PASS leader-eval: --old-skills は base か new だけを受け、new で --scenes を省くと compat-scenes を流す"

# compat-scenes の基準は、診断の依頼（最上位の役へのメンション）を落とし、場面ごとの今の指示の動き（頼み直しか人間を呼ぶか）を通す。
python3 -I -B - "$eval_dir" <<'PY_COMPAT_SCENES'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
def post(body):
    return {'command': 'multica issue comment add issue-shop-1 --content-file tmp/reply.md', 'kind': 'write', 'exit': 0, 'bodies': [body]}
human = post('[@Owner](mention://member/member1) 同じ誤りが続くので、判断をお願いします。')
in_review = {'command': 'multica issue status issue-shop-1 in_review', 'kind': 'write', 'exit': 0}
principal = post('[@shop-claude-principal-member1](mention://agent/agent-claude-principal) 診断を頼みます。')
fixer = post('[@shop-claude-fixer-member1](mention://agent/agent-claude-fixer) 直してください。\n\n原因: 表示の判定です。')
fixer_no_cause = post('[@shop-claude-fixer-member1](mention://agent/agent-claude-fixer) 直してください。')
def passed(scene, calls):
    return all(le.check_record(c['predicate'], calls)[0] for c in scene['criteria'] if c['kind'] == '記録')
def scene_of(n):
    return le.parse_scene(Path(sys.argv[1]) / 'compat-scenes' / f'compat-{n}' / 'scene.md')
for n in (1, 2, 3):
    scene = scene_of(n)
    assert not passed(scene, [principal]), (n, '最上位の役への依頼が通った')
    assert not passed(scene, [fixer, principal]), (n, '修正の依頼に診断の依頼を足した記録が通った')
    assert not passed(scene, [human, in_review, principal]), (n, '診断の依頼を足した記録が通った')
    assert not passed(scene, []), (n, '何もしない記録が通った')
# compat-1 は、修正の役へ原因を書いて頼み直す。人間を呼んで止まる記録と、原因のない依頼は通さない
scene = scene_of(1)
assert passed(scene, [fixer]), '原因を書いた頼み直しが通らない'
assert not passed(scene, [fixer_no_cause]), '原因のない頼み直しが通った'
assert not passed(scene, [human, in_review]), '人間を呼んで止まる記録が通った'
# compat-2 は、修正の役へ頼み直すか、人間を呼ぶ
scene = scene_of(2)
assert passed(scene, [fixer]), '頼み直しが通らない'
assert passed(scene, [human, in_review]), '人間を呼んで止まる記録が通らない'
# compat-3 は、人間を呼んで in_review にする。修正の役へは頼まない
scene = scene_of(3)
assert passed(scene, [human, in_review]), '人間を呼んで止まる記録が通らない'
assert not passed(scene, [human]), 'in_review にしない記録が通った'
assert not passed(scene, [fixer, in_review]), '人間を呼ばない記録が通った'
assert not passed(scene, [human, in_review, fixer]), '修正の役への依頼が通った'
print('PASS leader-eval: compat-scenes の基準は、診断の依頼を落とし、compat-1 は原因つきの頼み直し、compat-2 は頼み直しか人間、compat-3 は人間を呼ぶ記録を通す')
PY_COMPAT_SCENES

# --- 最上位の役の使用量の比べ（--role principal、--thinking、usage-table）---
principal_dir="$eval_dir/principal-scenes"
[[ $(find "$principal_dir" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | sort | tr '\n' ' ') == 'diag-1 ' ]] || { echo "principal-scenes の場面が設計と違います" >&2; exit 1; }
"${helper[@]}" scene "$principal_dir/diag-1/scene.md" >"$test_dir/principal-scene.json"
jq -e '.id == "diag-1" and ([.criteria[] | select(.kind == "採点")] | length) == 4 and ([.criteria[] | select(.kind == "記録")] | length) == 0' "$test_dir/principal-scene.json" >/dev/null ||
	{ echo "diag-1 の基準が 4 件の [採点] ではありません" >&2; exit 1; }
jq -e '.commands | map(.match) | any(startswith("multica issue comment list")) and any(startswith("gh pr diff")) and any(startswith("gh run view"))' "$principal_dir/diag-1/cli.json" >/dev/null ||
	{ echo "diag-1 の cli.json に、診断の入力を読むコマンドがありません" >&2; exit 1; }
# 最上位の役の前提（checkout とコミットの照合）を、外へ接続せずに満たす見本を持つ
sha=$(grep -o '[0-9a-f]\{40\}' "$principal_dir/diag-1/scene.md" | head -1)
jq -e --arg sha "$sha" '.git == true
	and (.commands | any(.match == "multica repo checkout https://github.com/example/shop"))
	and (.commands | any(.match == "git rev-parse HEAD" and .stdout == $sha))
	and (.files | has("shop/AGENTS.md"))' "$principal_dir/diag-1/cli.json" >/dev/null ||
	{ echo "diag-1 の cli.json に、checkout とコミット照合の見本・git の許可・checkout の見本のファイルがありません" >&2; exit 1; }
# 待つ役は、実行する系統の最上位の役のメンションにする（固定の系統を書かない）
jq -r '.commands[] | select(.match | startswith("multica issue comment list")) | .stdout' "$principal_dir/diag-1/cli.json" >"$test_dir/diag-comments.txt"
grep -qF '返事を待つ役: @PRINCIPAL_MENTION@' "$test_dir/diag-comments.txt" ||
	{ echo "diag-1 の待つ役が、実行する系統のメンションになっていません" >&2; exit 1; }
! grep -rEq 'claude-principal|codex-principal' "$principal_dir/diag-1" ||
	{ echo "diag-1 に系統を固定した最上位の役の名前があります" >&2; exit 1; }
echo "PASS leader-eval: principal-scenes の diag-1 は、診断の入力を読めるスタブと 4 件の [採点] の基準を持つ"

# 不正な値は、結果のディレクトリを作る前に拒む
for bad in '--role x' '--thinking High' '--role principal --only old' '--role principal --old-skills new'; do
	# shellcheck disable=SC2086
	if bash "$eval_dir/run.sh" $bad --out "$test_dir/principal-bad" >/dev/null 2>&1; then echo "通ってはいけない指定です: $bad" >&2; exit 1; fi
	[[ ! -e $test_dir/principal-bad ]] || { echo "拒む前に結果を作っています: $bad" >&2; exit 1; }
done
echo "PASS leader-eval: --role は orchestrator か principal、--thinking は小文字の英字だけで、principal は新しい指示だけを受ける"

# スタブの claude が、診断の結果を squad-review-wait report で返し、使用量の JSON を出す
principal_bin="$test_dir/principal-bin"
mkdir -p "$principal_bin"
# 最上位の役のスタブは、指示を守る実行の前提をたどる。待つ役のメンション、checkout、HEAD の照合を満たせないと、
# 結果を返さずに終了コードで止まる。前提を通らない固定の出力で通ることを避けるため
cat >"$principal_bin/principal-body" <<'EOF2'
# runtime（claude か codex）と instructions（指示のファイル）は、呼び出し元が決める
sha=7d1e0b34a5c6d7e8f9012345a6b7c8d9e0f1a2b3
grep -q "shop-$runtime-principal-member1" "$instructions" || exit 3
multica issue comment list issue-shop-1 | grep -qF "返事を待つ役: [@shop-$runtime-principal-member1](mention://agent/agent-$runtime-principal)" || exit 5
multica repo checkout https://github.com/example/shop --ref "$sha" >/dev/null || exit 6
test -f shop/AGENTS.md || exit 7
[[ $(git -C shop rev-parse HEAD) == "$sha" ]] || exit 8
gh pr diff 7 >/dev/null
gh run view 1 --log-failed >/dev/null
printf '確認したコミット: %s\n診断: 直せる\n直す役: 修正の役\n' "$sha" >tmp/result.md
squad-review-wait report issue-shop-1 comment-4 tmp/result.md >/dev/null
EOF2
cat >"$principal_bin/claude" <<'EOF2'
#!/usr/bin/env bash
# LEADER_EVAL_STUB_AGENT
prev= effort=
for arg in "$@"; do case $prev in --effort) effort=$arg ;; esac; prev=$arg; done
case "$*" in
*"[leader-eval-scorer]"*) echo '{"pass": true, "reason": "ok"}'; exit 0 ;;
esac
echo "principal $effort" >>"$STUB_LOG"
case "$*" in *'Bash(git *)'*'Bash(cd *)'*) ;; *) exit 4 ;; esac
runtime=claude instructions=CLAUDE.md
source "$(dirname "$0")/principal-body"
echo '{"type":"result","result":"done","is_error":false,"permission_denials":[],"usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":55}}'
EOF2
cat >"$principal_bin/codex" <<'EOF2'
#!/usr/bin/env bash
# LEADER_EVAL_STUB_AGENT
echo "principal codex" >>"$STUB_LOG"
runtime=codex instructions=AGENTS.md
source "$(dirname "$0")/principal-body"
echo "done"
printf 'tokens used\n4,321\n' >&2
EOF2
chmod +x "$principal_bin/claude" "$principal_bin/codex"
export STUB_LOG="$test_dir/principal.log"
for depth in high xhigh; do
	PATH="$principal_bin:$PATH" bash "$eval_dir/run.sh" --role principal --thinking "$depth" --runs 1 --out "$test_dir/principal-$depth" >"$test_dir/principal-$depth.out" 2>"$test_dir/principal-$depth.err" ||
		{ cat "$test_dir/principal-$depth.err" >&2; exit 1; }
	jq -e --arg depth "$depth" '.thinking_level == $depth' "$test_dir/principal-$depth/instructions/new/meta.json" >/dev/null
	jq -e -s --arg depth "$depth" 'length == 1 and all(.[]; .thinking_level == $depth and .pass == true and .usage.total == 3265 and .usage.output == 55 and .usage.source == "claude-json")' "$test_dir/principal-$depth/runs.jsonl" >/dev/null ||
		{ echo "$depth: runs.jsonl の深さと使用量が違います" >&2; exit 1; }
	jq -e -s 'all(.[]; any(.calls[]; .kind == "write" and (.bodies | any(test("診断: 直せる")))))' "$test_dir/principal-$depth/runs.jsonl" >/dev/null ||
		{ echo "$depth: squad-review-wait report の本文を記録していません" >&2; exit 1; }
	grep -q '^\*\*You are: shop-claude-principal-member1\*\*' "$test_dir/principal-$depth/instructions/new/instructions.md" ||
		{ echo "$depth: 前置きの名前が最上位の役ではありません" >&2; exit 1; }
	grep -q "^| claude [a-z0-9.-]* | $depth | 3,265 | 55 | " "$test_dir/principal-$depth/usage.md" ||
		{ echo "$depth: usage.md の行が違います" >&2; exit 1; }
	grep -q "^thinking: $depth$" "$test_dir/principal-$depth/versions.txt"
done
grep -qx 'principal high' "$test_dir/principal.log" && grep -qx 'principal xhigh' "$test_dir/principal.log" ||
	{ echo "claude に --effort の深さが渡っていません" >&2; exit 1; }
echo "PASS leader-eval: --role principal と --thinking で、最上位の役を指定の深さで流し、深さと使用量を runs.jsonl と usage.md に残す"
# 前提をたどった結果が、記録に残る。スタブへの呼び出しは見本どおりに通り、拒否も見本のない呼び出しもない
for depth in high xhigh; do
	jq -e -s 'all(.[]; (.calls | map(select(.command | startswith("multica repo checkout"))) | length) == 1
		and any(.calls[]; .command == "git rev-parse HEAD" and .kind == "read" and .exit == 0)
		and all(.calls[]; .kind != "unmatched" and .kind != "denied"))' "$test_dir/principal-$depth/runs.jsonl" >/dev/null ||
		{ echo "$depth: checkout とコミット照合の呼び出しが見本どおりに記録されていません" >&2; exit 1; }
done
# Codex の最上位の役は、Codex の役のメンションと指示で、同じ前提をたどる
PATH="$principal_bin:$PATH" bash "$eval_dir/run.sh" --role principal --runtime codex --thinking high --runs 1 --out "$test_dir/principal-codex" >"$test_dir/principal-codex.out" 2>"$test_dir/principal-codex.err" ||
	{ cat "$test_dir/principal-codex.err" >&2; exit 1; }
jq -e -s 'length == 1 and all(.[]; .runtime == "codex" and .pass == true and .usage.total == 4321
	and any(.calls[]; .kind == "write" and (.bodies | any(test("診断: 直せる")))))' "$test_dir/principal-codex/runs.jsonl" >/dev/null ||
	{ echo "codex: 前提をたどった結果が runs.jsonl にありません" >&2; exit 1; }
grep -q '^\*\*You are: shop-codex-principal-member1\*\*' "$test_dir/principal-codex/instructions/new/instructions.md" ||
	{ echo "codex: 前置きの名前が Codex の最上位の役ではありません" >&2; exit 1; }
! grep -q 'claude-principal' "$test_dir/principal-codex/scene-dirs/diag-1/cli.json" "$test_dir/principal-codex/scene-dirs/diag-1/scene.md" ||
	{ echo "codex: 場面が Claude の最上位の役を指しています" >&2; exit 1; }
# 前提を満たせない実行は、結果を返さずに止まる（HEAD が違うと照合で止まる）
grep -qx 'principal codex' "$test_dir/principal.log" ||
	{ echo "codex のスタブが呼ばれていません" >&2; exit 1; }

# 使用量の読み取り。Codex は合計だけで、内訳は null のまま「未確認」にし、読めない出力は使用量なしにする
python3 -I -B - "$eval_dir" "$test_dir" <<'PY_USAGE'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
test_dir = Path(sys.argv[2])
u = le.parse_usage("claude", '{"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}', "")
assert u == {"input": 1, "cache_write": 2, "cache_read": 3, "output": 4, "total": 10, "source": "claude-json"}, u
assert le.parse_usage("claude", '{"result":"x"}', "") is None
assert le.parse_usage("claude", '{"usage":{"input_tokens":1}}', "") is None
assert le.parse_usage("claude", "not json", "") is None
c = le.parse_usage("codex", "done", "tokens used\n12,345\n")
assert c == {"input": None, "cache_write": None, "cache_read": None, "output": None, "total": 12345, "source": "codex-tokens-used"}, c
assert le.parse_usage("codex", "done", "") is None
runs = test_dir / "u-runs.jsonl"
rows = [
    {"runtime": "codex", "model": "m", "thinking_level": "xhigh", "duration_ms": 61000, "usage": c, "criteria": [{"pass": True}, {"pass": False}]},
    {"runtime": "claude", "model": "m", "thinking_level": "high", "duration_ms": 1000, "usage": None, "error": "x", "criteria": []},
]
runs.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
le.usage_table(runs, test_dir / "u.md")
lines = (test_dir / "u.md").read_text(encoding="utf-8").splitlines()
assert lines[2] == "| codex m | xhigh | 12,345 | 未確認 | 61 秒 | 1/2 |", lines[2]
assert lines[3] == "| claude m | high | 未確認 | 未確認 | 1 秒 | 0/0（実行の失敗） |", lines[3]
print("PASS leader-eval: 使用量は Claude の usage と Codex の tokens used から読み、読めないものと Codex の内訳は未確認のままにする")
PY_USAGE

# --- コードレビュアーの評価（--role code-reviewer）---
# reviewer-scenes の場面は別のフェーズで置く。ここでは、道具の動作を確認するために、リポジトリの写しと一時の場面を使う。
# 写しは自分の git の履歴を持ち、基準の参照（HEAD）と作業ツリーで code-reviewer.md を変えて、新旧の違いを作る
rr="$test_dir/reviewer-root"
mkdir -p "$rr/tests/leader-eval/reviewer-scenes"
cp -R "$root/lib" "$rr/lib"
cp -R "$root/common" "$rr/common"
for file in run.sh leader_eval.py values.json runtime-brief.md; do cp "$eval_dir/$file" "$rr/tests/leader-eval/$file"; done
git -C "$rr" init -q
git -C "$rr" add -A
git -C "$rr" -c user.name=test -c user.email=test@example.com commit -q -m base
make_reviewer_scene() { # $1=場面の ID
	local dir="$rr/tests/leader-eval/reviewer-scenes/$1"
	mkdir -p "$dir"
	cat >"$dir/scene.md" <<EOF_SCENE
- 場面の ID: $1
- 型: 見逃し

## 元の出来事

評価の道具を確認するための場面である。

## 入力

あなたは、タスク \`issue-shop-1\` で、PR のレビューを頼まれました。

## 合格の基準

1. [採点] 返答がある。
EOF_SCENE
	printf '{"commands": [], "git": true}\n' >"$dir/cli.json"
}
for id in t1 t2 t3 t4; do make_reviewer_scene "$id"; done
# 新しい指示だけを変える。印の行を足し、モデルを替える
sed -i.bak -e 's/claude-sonnet-5-5/claude-opus-5-5/' -e 's/^# コードレビュー$/# コードレビュー\n\n新しい指示の印/' "$rr/common/agents/code-reviewer.md"
rm -f "$rr/common/agents/code-reviewer.md.bak"
rr_run() { # 引数は run.sh へ渡す
	PATH="$reviewer_bin:$PATH" bash "$rr/tests/leader-eval/run.sh" --baseline HEAD "$@"
}
reviewer_bin="$test_dir/reviewer-bin"
mkdir -p "$reviewer_bin"
cat >"$reviewer_bin/claude" <<'EOF2'
#!/usr/bin/env bash
# LEADER_EVAL_STUB_AGENT
model= effort= prev=
for arg in "$@"; do
	case $prev in --model) model=$arg ;; --effort) effort=$arg ;; esac
	prev=$arg
done
case "$*" in
*"[leader-eval-scorer]"*) echo "scorer $model $effort" >>"$STUB_LOG"; echo '{"pass": true, "reason": "ok"}'; exit 0 ;;
esac
# 描いた指示が、コードレビュアーの指示と名前か。新しい指示の印があるかも、記録に残す
grep -q 'shop-code-reviewer-member1' CLAUDE.md || exit 3
if grep -q '新しい指示の印' CLAUDE.md; then mark=new; else mark=old; fi
echo "reviewer $model $effort $mark" >>"$STUB_LOG"
echo '{"type":"result","result":"done","is_error":false,"permission_denials":[]}'
EOF2
chmod +x "$reviewer_bin/claude"
export STUB_LOG="$test_dir/reviewer.log"
: >"$STUB_LOG"
rr_run --role code-reviewer --scenes t1 --runs 2 --jobs 2 --out "$test_dir/reviewer-out" >"$test_dir/reviewer.out" 2>"$test_dir/reviewer.err" ||
	{ cat "$test_dir/reviewer.err" >&2; exit 1; }
ro="$test_dir/reviewer-out/instructions"
# 今の指示は基準の参照の code-reviewer.md、新しい指示は作業ツリーの code-reviewer.md から作る。前置きは code-reviewer の名前にする
! grep -q '新しい指示の印' "$ro/old/instructions.md" || { echo "今の指示に、作業ツリーだけの行があります" >&2; exit 1; }
grep -q '新しい指示の印' "$ro/new/instructions.md" || { echo "新しい指示が、作業ツリーの code-reviewer.md から作られていません" >&2; exit 1; }
for which in old new; do
	grep -q '^# コードレビュー$' "$ro/$which/instructions.md" || { echo "$which: code-reviewer の本文がありません" >&2; exit 1; }
	grep -q '^\*\*You are: shop-code-reviewer-member1\*\*' "$ro/$which/instructions.md" || { echo "$which: 前置きの名前が code-reviewer ではありません" >&2; exit 1; }
	grep -q 'agent-code-reviewer' "$ro/$which/instructions.md" || { echo "$which: 前置きの ID が code-reviewer ではありません" >&2; exit 1; }
	! grep -q 'You are: shop-orchestrator' "$ro/$which/instructions.md" || { echo "$which: 前置きの Agent Identity にリーダーの名前が残っています" >&2; exit 1; }
	[[ -f $ro/$which/skills/squad-handoff/SKILL.md ]] || { echo "$which: squad-handoff がありません" >&2; exit 1; }
done
echo "PASS leader-eval: --role code-reviewer は、今の指示を基準の参照の code-reviewer.md、新しい指示を作業ツリーのものから作り、前置きを code-reviewer の名前にする"

# 流すモデルと思考の深さは、描画した front matter の値。新旧で違うときは、記録に並べる
grep -qx 'reviewer claude-sonnet-5-5 high old' "$STUB_LOG" || { echo "今の指示のモデルと深さがスタブに渡っていません" >&2; exit 1; }
grep -qx 'reviewer claude-opus-5-5 high new' "$STUB_LOG" || { echo "新しい指示のモデルと深さがスタブに渡っていません" >&2; exit 1; }
grep -qx 'scorer claude-opus-5-5 high' "$STUB_LOG" || { echo "採点の役が opus の high ではありません" >&2; exit 1; }
jq -e '.model == "claude-sonnet-5-5" and .thinking_level == "high"' "$ro/old/meta.json" >/dev/null
jq -e '.model == "claude-opus-5-5" and .thinking_level == "high"' "$ro/new/meta.json" >/dev/null
grep -qx 'role: code-reviewer' "$test_dir/reviewer-out/versions.txt"
grep -qx 'model old: claude-sonnet-5-5 high' "$test_dir/reviewer-out/versions.txt"
grep -qx 'model new: claude-opus-5-5 high' "$test_dir/reviewer-out/versions.txt"
grep -qx 'runs: 4 回（上限 18 回）' "$test_dir/reviewer-out/versions.txt"
! grep -q '^over-limit:' "$test_dir/reviewer-out/versions.txt"
jq -e -s 'length == 4 and all(.[]; .pass == true)' "$test_dir/reviewer-out/runs.jsonl" >/dev/null
grep -q '^| t1 | 見逃し | 2/2 | 2/2 | - |$' "$test_dir/reviewer-out/summary.md" || { echo "summary.md の行が違います" >&2; exit 1; }
grep -q '^| 場面 | 型 | 今の指示 | 新しい指示 | ' "$test_dir/reviewer-out/summary.md" || { echo "summary.md の列の見出しが指示の新旧ではありません" >&2; exit 1; }
! grep -q '上限を超えて流した' "$test_dir/reviewer-out/summary.md"
echo "PASS leader-eval: --role code-reviewer は、front matter のモデルと深さで流し、新旧のモデルを記録に並べる"

# 上限: 19 回以上になる指定は、スタブの claude を呼ばず、結果のディレクトリも作らずに終了コード 2 で止まる
reviewer_limit_stop() { # $1=説明 残りは run.sh の引数
	local label=$1 code=0
	shift
	: >"$STUB_LOG"
	rm -rf "$test_dir/reviewer-limit"
	rr_run "$@" --out "$test_dir/reviewer-limit" >"$test_dir/reviewer-limit.out" 2>"$test_dir/reviewer-limit.err" || code=$?
	[[ $code == 2 ]] || { echo "$label: 終了コードが 2 ではありません（$code）" >&2; exit 1; }
	[[ ! -s $STUB_LOG ]] || { echo "$label: 止める前に claude を呼んでいます" >&2; exit 1; }
	[[ ! -e $test_dir/reviewer-limit ]] || { echo "$label: 止める前に結果のディレクトリを作っています" >&2; exit 1; }
	grep -q '上限の 18 回' "$test_dir/reviewer-limit.err" || { echo "$label: 上限の回数を出していません" >&2; exit 1; }
}
reviewer_limit_stop '3 場面 × 4 回 × 新旧（24 回）' --role code-reviewer --scenes t1,t2,t3 --runs 4
grep -q '24 回' "$test_dir/reviewer-limit.err" || { echo "数えた回数を出していません" >&2; exit 1; }
reviewer_limit_stop '1 場面 × 19 回 × 新だけ（19 回）' --role code-reviewer --scenes t1 --runs 19 --only new
reviewer_limit_stop '4 場面 × 3 回 × 新旧（24 回）' --role code-reviewer --scenes t1,t2,t3,t4 --runs 3
# 場面を省くと、reviewer-scenes のすべての場面を数える（4 場面 × 3 回 × 2 = 24 回）
reviewer_limit_stop '場面の省略（24 回）' --role code-reviewer --runs 3
# 18 回ちょうどは流れる
: >"$STUB_LOG"
rr_run --role code-reviewer --scenes t1,t2,t3 --runs 3 --jobs 4 --out "$test_dir/reviewer-18" >"$test_dir/reviewer-18.out" 2>"$test_dir/reviewer-18.err" ||
	{ cat "$test_dir/reviewer-18.err" >&2; exit 1; }
[[ $(grep -c '^reviewer ' "$STUB_LOG") == 18 ]] || { echo "18 回流れていません" >&2; exit 1; }
grep -qx 'runs: 18 回（上限 18 回）' "$test_dir/reviewer-18/versions.txt"
! grep -q '上限を超えて流した' "$test_dir/reviewer-18/summary.md"
# 上限を超えた回数でも、--over-limit があれば流れ、summary.md の先頭にコメントの ID が載る
: >"$STUB_LOG"
rr_run --role code-reviewer --scenes t1,t2,t3,t4 --runs 3 --jobs 4 --over-limit comment-approved-1 --out "$test_dir/reviewer-over" >"$test_dir/reviewer-over.out" 2>"$test_dir/reviewer-over.err" ||
	{ cat "$test_dir/reviewer-over.err" >&2; exit 1; }
[[ $(grep -c '^reviewer ' "$STUB_LOG") == 24 ]] || { echo "上限を超えた承認つきの指定が流れていません" >&2; exit 1; }
[[ $(head -1 "$test_dir/reviewer-over/summary.md") == '上限を超えて流した: 役の実行 24 回（上限 18 回）。承認したコメントの ID: comment-approved-1' ]] ||
	{ echo "summary.md の先頭に、上限を超えたことと承認のコメントの ID がありません" >&2; exit 1; }
grep -qx 'over-limit: comment-approved-1' "$test_dir/reviewer-over/versions.txt"
# 上限以内で --over-limit を付けても、超えたとは書かない（流した回数が上限以内のため）
: >"$STUB_LOG"
rr_run --role code-reviewer --scenes t1 --runs 1 --over-limit comment-approved-2 --out "$test_dir/reviewer-within" >/dev/null 2>"$test_dir/reviewer-within.err" ||
	{ cat "$test_dir/reviewer-within.err" >&2; exit 1; }
! grep -q '上限を超えて流した' "$test_dir/reviewer-within/summary.md"
echo "PASS leader-eval: 上限（18 回）は、19 回以上を流さずに終了コード 2 で止め、18 回ちょうどは流し、--over-limit で流すと summary.md の先頭に承認のコメントの ID を残す"

# 受け付けない指定は、結果のディレクトリを作る前に終了コード 2 で止める
for bad in '--runtime codex' '--old-skills new' '--thinking high' '--over-limit bad/id'; do
	: >"$STUB_LOG"
	code=0
	rm -rf "$test_dir/reviewer-bad"
	# shellcheck disable=SC2086
	rr_run --role code-reviewer --scenes t1 $bad --out "$test_dir/reviewer-bad" >/dev/null 2>"$test_dir/reviewer-bad.err" || code=$?
	[[ $code == 2 ]] || { echo "終了コードが 2 ではありません（$code）: $bad" >&2; exit 1; }
	[[ ! -e $test_dir/reviewer-bad && ! -s $STUB_LOG ]] || { echo "止める前に流しています: $bad" >&2; exit 1; }
	[[ -s $test_dir/reviewer-bad.err ]] || { echo "理由を出していません: $bad" >&2; exit 1; }
done
# --over-limit は code-reviewer だけ。ほかの役では、黙って無視せずに止める
code=0
rr_run --scenes t1 --over-limit comment-x --out "$test_dir/reviewer-bad" >/dev/null 2>&1 || code=$?
[[ $code == 2 ]] || { echo "リーダーの評価で --over-limit が通っています" >&2; exit 1; }
echo "PASS leader-eval: --role code-reviewer は --runtime codex・--old-skills new・--thinking を、--over-limit は code-reviewer 以外を、終了コード 2 で止める"

# --help は、上限の 1 行と文書への案内を出す
help_out=$(bash "$eval_dir/run.sh" --help)
grep -q '^上限: --role code-reviewer は、1 回の評価で役の実行を 18 回まで' <<<"$help_out" || { echo "--help に上限の行がありません" >&2; exit 1; }
grep -q 'docs/review-eval.md の「流す回数の上限」' <<<"$help_out" || { echo "--help に文書への案内がありません" >&2; exit 1; }
grep -q -- '--over-limit ID' <<<"$help_out" || { echo "--help に --over-limit がありません" >&2; exit 1; }
grep -q 'code-reviewer' <<<"$help_out" || { echo "--help に --role code-reviewer がありません" >&2; exit 1; }
echo "PASS leader-eval: --help に、上限 18 回の行と、docs/review-eval.md の節への案内が出る"

# --- コードレビュアーの評価: PR へのコメントの記録と Skill(verify) ---
# 流す役が gh pr comment と gh pr review を呼ぶスタブ。許可の引数も記録する
pr_bin="$test_dir/reviewer-pr-bin"
mkdir -p "$pr_bin"
cat >"$pr_bin/claude" <<'EOF2'
#!/usr/bin/env bash
# LEADER_EVAL_STUB_AGENT
case "$*" in
*"[leader-eval-scorer]"*)
	if [[ $* == *"PR のレビュー本文の印（--body-file）"* ]]; then echo "scorer-saw-pr-comment" >>"$STUB_LOG"; else echo "scorer-missed-pr-comment" >>"$STUB_LOG"; fi
	echo '{"pass": true, "reason": "ok"}'; exit 0 ;;
esac
if [[ $* == *"Skill(verify)"* ]]; then echo "verify-allowed" >>"$STUB_LOG"; else echo "verify-not-allowed" >>"$STUB_LOG"; fi
printf 'PR のレビュー本文の印（--body-file）\n' >tmp/review.md
code=0
gh pr comment 15 --body-file tmp/review.md >/dev/null 2>&1 || code=$?
echo "gh-pr-comment exit=$code" >>"$STUB_LOG"
code=0
gh pr review 15 --comment --body 'PR のレビュー本文の印（--body）' >/dev/null 2>&1 || code=$?
echo "gh-pr-review exit=$code" >>"$STUB_LOG"
echo '{"type":"result","result":"done","is_error":false,"permission_denials":[]}'
EOF2
chmod +x "$pr_bin/claude"
rr_pr() { # 引数は run.sh へ渡す
	PATH="$pr_bin:$PATH" bash "$rr/tests/leader-eval/run.sh" --baseline HEAD "$@"
}
: >"$STUB_LOG"
rr_pr --role code-reviewer --scenes t1 --only new --runs 1 --out "$test_dir/reviewer-pr" >"$test_dir/reviewer-pr.out" 2>"$test_dir/reviewer-pr.err" ||
	{ cat "$test_dir/reviewer-pr.err" >&2; exit 1; }
grep -qx 'verify-allowed' "$STUB_LOG" || { echo "code-reviewer の実行で Skill(verify) が許可されていません" >&2; exit 1; }
grep -qx 'gh-pr-comment exit=0' "$STUB_LOG" || { echo "gh pr comment が成功を返していません" >&2; exit 1; }
grep -qx 'gh-pr-review exit=0' "$STUB_LOG" || { echo "gh pr review が成功を返していません" >&2; exit 1; }
grep -qx 'scorer-saw-pr-comment' "$STUB_LOG" || { echo "PR へのコメントの本文が採点の役に渡っていません" >&2; exit 1; }
pr_result="$test_dir/reviewer-pr/runs/t1/new-1/result.json"
jq -e '(.comments | length) == 2
	and (.comments[0] | contains("PR のレビュー本文の印（--body-file）"))
	and (.comments[1] | contains("PR のレビュー本文の印（--body）"))' "$pr_result" >/dev/null ||
	{ echo "PR へのコメントの本文が投稿として記録されていません" >&2; exit 1; }
jq -e '[.calls[] | select(.command | startswith("gh pr")) | .kind] == ["write", "write"]' "$pr_result" >/dev/null ||
	{ echo "gh pr comment と gh pr review が書き込みとして記録されていません" >&2; exit 1; }
echo "PASS leader-eval: --role code-reviewer は gh pr comment と gh pr review の本文を投稿として記録して採点の役に渡し、Skill(verify) を許可する"

# リーダーの評価では、見本にない gh pr comment は今のとおり失敗を返し、投稿として記録せず、Skill(verify) も許可しない
mkdir -p "$rr/tests/leader-eval/scenes"
cp -R "$rr/tests/leader-eval/reviewer-scenes/t1" "$rr/tests/leader-eval/scenes/t1"
: >"$STUB_LOG"
rr_pr --scenes t1 --only new --runs 1 --out "$test_dir/leader-pr" >"$test_dir/leader-pr.out" 2>"$test_dir/leader-pr.err" ||
	{ cat "$test_dir/leader-pr.err" >&2; exit 1; }
grep -qx 'verify-not-allowed' "$STUB_LOG" || { echo "リーダーの評価で Skill(verify) が許可されています" >&2; exit 1; }
grep -qx 'gh-pr-comment exit=1' "$STUB_LOG" || { echo "リーダーの評価で gh pr comment が失敗を返していません" >&2; exit 1; }
grep -qx 'gh-pr-review exit=1' "$STUB_LOG" || { echo "リーダーの評価で gh pr review が失敗を返していません" >&2; exit 1; }
grep -qx 'scorer-missed-pr-comment' "$STUB_LOG" || { echo "リーダーの評価で PR へのコメントが採点の役に渡っています" >&2; exit 1; }
jq -e '(.comments | length) == 0 and ([.calls[] | select(.command | startswith("gh pr")) | .kind] == ["unmatched", "unmatched"])' \
	"$test_dir/leader-pr/runs/t1/new-1/result.json" >/dev/null ||
	{ echo "リーダーの評価の gh pr comment の扱いが変わっています" >&2; exit 1; }
echo "PASS leader-eval: リーダーの評価では、見本にない gh pr comment は失敗を返し、投稿として記録せず、Skill(verify) も許可しない"

# --- コードレビュアーの評価: 要約の見出しと「今の指示でも通る場面」---
cat >"$test_dir/summary-runs.jsonl" <<'EOF_RUNS'
{"scene": "r-a", "type": "見逃し", "which": "old", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-a", "type": "見逃し", "which": "old", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-a", "type": "見逃し", "which": "new", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-a", "type": "見逃し", "which": "new", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-b", "type": "見逃し", "which": "old", "pass": false, "criteria": [{"n": 1, "pass": false}]}
{"scene": "r-b", "type": "見逃し", "which": "old", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-b", "type": "見逃し", "which": "new", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-b", "type": "見逃し", "which": "new", "pass": true, "criteria": [{"n": 1, "pass": true}]}
{"scene": "r-c", "type": "見逃し", "which": "new", "pass": true, "criteria": [{"n": 1, "pass": true}]}
EOF_RUNS
"${helper[@]}" summary "$test_dir/summary-runs.jsonl" "$test_dir/summary-reviewer.md" code-reviewer
"${helper[@]}" summary "$test_dir/summary-runs.jsonl" "$test_dir/summary-leader.md"
"${helper[@]}" summary "$test_dir/summary-runs.jsonl" "$test_dir/summary-principal.md" orchestrator
{
	echo '| 場面 | 型 | 今の指示 | 新しい指示 | 落ちた基準 |'
	echo '| --- | --- | --- | --- | --- |'
	echo '| r-a | 見逃し | 2/2 | 2/2 | - |'
	echo '| r-b | 見逃し | 1/2 | 2/2 | - |'
	echo '| r-c | 見逃し | - | 1/1 | - |'
	echo
	echo '今の指示でも通る場面: r-a'
} >"$test_dir/summary-reviewer.expected"
diff "$test_dir/summary-reviewer.expected" "$test_dir/summary-reviewer.md" ||
	{ echo "code-reviewer の summary.md が、見出しと「今の指示でも通る場面」の決まりと違います" >&2; exit 1; }
for leader_summary in "$test_dir/summary-leader.md" "$test_dir/summary-principal.md"; do
	grep -qx '| 場面 | 型 | 今のリーダー | 新しいリーダー | 落ちた基準 |' "$leader_summary" ||
		{ echo "リーダーの評価の summary.md の見出しが変わっています" >&2; exit 1; }
	! grep -q '今の指示' "$leader_summary" || { echo "リーダーの評価の summary.md に、新旧の指示の語が入っています" >&2; exit 1; }
	(( $(wc -l <"$leader_summary") == 5 )) || { echo "リーダーの評価の summary.md に行が増えています" >&2; exit 1; }
done
# 今の指示を流していない（--only new）記録だけのときは、この節を出さない
grep -v '"which": "old"' "$test_dir/summary-runs.jsonl" >"$test_dir/summary-new-only.jsonl"
"${helper[@]}" summary "$test_dir/summary-new-only.jsonl" "$test_dir/summary-new-only.md" code-reviewer
! grep -q '今の指示でも通る場面' "$test_dir/summary-new-only.md" || { echo "今の指示を流していないのに、通る場面を挙げています" >&2; exit 1; }
# run.sh から流した code-reviewer の summary.md にも、同じ決まりで出る（t1 は新旧とも合格）
grep -qx '今の指示でも通る場面: t1' "$test_dir/reviewer-out/summary.md" || { echo "run.sh の summary.md に、今の指示でも通る場面がありません" >&2; exit 1; }
echo "PASS leader-eval: code-reviewer の summary.md は、見出しを役の名前に替え、今の指示も全回で合格した場面を表の下に挙げる。リーダーの評価の summary.md は今のまま"
