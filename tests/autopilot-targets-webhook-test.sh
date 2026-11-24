#!/usr/bin/env bash
# autopilot-targets.json の対象の設定で、Webhook の登録と外すタスクの起票、導入の確認を本体で行う。拡張の読み込みと setup.sh の確認は autopilot-targets-test.sh、登録の流し直しは autopilot-targets-registration-test.sh。
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest

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
