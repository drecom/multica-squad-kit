#!/usr/bin/env bash
# autopilot-targets.json の対象の設定で、登録の流し直しを本体で行う。拡張の読み込みと setup.sh の確認は autopilot-targets-test.sh、Webhook と導入の確認は autopilot-targets-webhook-test.sh。
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest

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
