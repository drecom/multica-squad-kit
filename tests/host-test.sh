#!/usr/bin/env bash
# この部分は、新しいホストの配置・Claude の共有の設定・入口・標準入力・デーモンの起動の判断・Claude のログインの確認を確認する。
set -euo pipefail
source "$(dirname "$0")/host-test-lib.sh"

set_mode stopped
run
for file in "$root/common/monitor/"squad-*; do
 if [[ ${file##*/} == squad-cli-lib ]]; then
  cmp <(sed '/^SQUAD_CLI_VERIFIED_VERSION=/d' "$file") <(sed '/^SQUAD_CLI_VERIFIED_VERSION=/d' "$TEMPLATE_AGENT_HOME/bin/squad-cli-lib")
  expected_version=$(head -n 1 "$root/tests/fixtures/cli/VERSION")
  actual_version=$(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$TEMPLATE_AGENT_HOME/bin/squad-cli-lib")
  [[ $actual_version == "$expected_version" ]]
 else
  cmp "$file" "$TEMPLATE_AGENT_HOME/bin/${file##*/}"
 fi
 [[ -x $TEMPLATE_AGENT_HOME/bin/${file##*/} ]]
done
cmp "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
for file in git-credential git-ssh pre-tool-use stop shell_split.py; do
 cmp "$root/common/guard/$file" "$TEMPLATE_AGENT_HOME/guard/$file"
 [[ -x $TEMPLATE_AGENT_HOME/guard/$file ]]
done
# 役の GH_CONFIG_DIR に渡す空の置き場。人だけが入れる権限で、中は空である。
[[ -d $TEMPLATE_AGENT_HOME/guard/gh-empty && -z $(ls -A "$TEMPLATE_AGENT_HOME/guard/gh-empty") ]]
[[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$TEMPLATE_AGENT_HOME/guard/gh-empty") == 700 ]]
expected_codex_config
cmp "$test_dir/expected-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
[[ -d $TEMPLATE_AGENT_HOME/claude && ! -e $TEMPLATE_AGENT_HOME/allowed-repos ]]
grep -qx 'daemon start' "$test_dir/calls"
grep -qx 'https://example.test' "$test_dir/started-server"
echo 'PASS host: 新しいホストへ共有ファイルと見張りを配置し、専用環境で一つのデーモンを起動する'

# 人の gh の置き場は、gh 自身が使う順（GH_CONFIG_DIR、XDG_CONFIG_HOME の下、ホームの .config）で決める。
human_gh() { env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME "$@" bash -c 'source "$1"; host_human_gh_dir' -- "$root/lib/host.sh"; }
[[ $(human_gh HOME=/home/h GH_CONFIG_DIR=/set/gh XDG_CONFIG_HOME=/xdg) == /set/gh ]]
[[ $(human_gh HOME=/home/h XDG_CONFIG_HOME=/xdg) == /xdg/gh ]]
[[ $(human_gh HOME=/home/h) == /home/h/.config/gh ]]
[[ $(human_gh HOME=/home/h GH_CONFIG_DIR= XDG_CONFIG_HOME=) == /home/h/.config/gh ]]
echo 'PASS host: 人の gh の置き場を、端末の GH_CONFIG_DIR、XDG_CONFIG_HOME の下、ホームの順で決める'
[[ $(cat "$test_dir/codex-checks") == "$TEMPLATE_AGENT_HOME/codex" ]]
python3 - "$TEMPLATE_AGENT_HOME/codex/config.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as source:
    config = tomllib.load(source)
state = config.pop("hooks")["state"]
assert config == {"allow_login_shell": False, "check_for_update_on_startup": False, "analytics": {"enabled": False}}, config
# 信頼は、hooks/list が返した 2 つのフックの鍵と currentHash である。
assert sorted(state) == ["/<session-flags>/config.toml:pre_tool_use:0:0", "/<session-flags>/config.toml:stop:0:0"], state
assert all(set(value) == {"trusted_hash"} and value["trusted_hash"].startswith("sha256:") for value in state.values()), state
PY
! grep -qF 'マークのない設定に' "$test_dir/err"
echo 'PASS host: 新しいホストで Codex の設定に 2 つのキーを足し、専用の置き場で厳しい検証に 1 回かける'
settings=$TEMPLATE_AGENT_HOME/claude/settings.json
# prepare_host は、共有の settings.json を確認するだけで書かない。書くのは、役の設定を書いたあとである（prepare_project）。
[[ ! -e $settings ]]
cat >"$test_dir/settings-run.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
source "$1/lib/ui.sh"
source "${TEST_SETTINGS_HOST:-$1/lib/host.sh}"
die() { ui_error "$*"; exit 1; }
host_paths
host_claude_settings
RUN
settings_run() { /bin/bash "$test_dir/settings-run.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"; }
settings_run
python3 - "$settings" "$test_dir/kit-settings.json" <<'PY'
import json
import os
from pathlib import Path
import shlex
import sys

settings = Path(sys.argv[1])
actual = json.loads(settings.read_text())
# 置き場の名前にアポストロフィがあるので、フックのコマンドは引用符で囲まれる。
guard = os.path.normpath(os.path.dirname(os.path.dirname(settings))) + "/guard"
pre_tool_use = shlex.quote(guard + "/pre-tool-use")
stop = shlex.quote(guard + "/stop")
assert pre_tool_use.startswith("'") and stop.startswith("'")
home = os.path.normpath(os.environ["HOME"])
kit_reads = [
    "Read(/" + os.path.normpath(os.environ["GH_CONFIG_DIR"]) + "/**)",
    "Read(/" + home + "/.ssh/**)",
    "Read(/" + home + "/.git-credentials)",
    "Read(/" + home + "/.netrc)",
]
assert all(item.startswith("Read(//") for item in kit_reads)
assert actual == {
    "syncClaudeAiSkills": False,
    "syncClaudeAiPlugins": False,
    "pluginConfigs": {"cc-plugin-agents-md@builtin": {"options": {"instructionFiles": "claude-md"}}},
    "disableWorkflows": True,
    "autoMemoryEnabled": False,
    "cleanupPeriodDays": 30,
    "skillOverrides": {key: "off" for key in (
        "batch", "loop", "schedule", "deep-research", "workflow-authoring",
        "design", "design-sync", "dataviz", "debug", "doctor", "update-config",
        "fewer-permission-prompts", "plugin-authoring", "run-skill-generator",
    )},
    "permissions": {
        "deny": ["Monitor", "ScheduleWakeup", "RemoteTrigger", "PushNotification", *kit_reads],
        "blockWritesOutsideWorkingDirectories": True,
    },
    "hooks": {
        "PreToolUse": [{"matcher": "Bash|Write|Edit|NotebookEdit", "hooks": [{"type": "command", "command": pre_tool_use}]}],
        "Stop": [{"hooks": [{"type": "command", "command": stop}]}],
    },
}, actual
assert settings.stat().st_mode & 0o777 == 0o600
Path(sys.argv[2]).write_bytes(settings.read_bytes())
PY
echo 'PASS host: Claude の共有の設定をキットのキーだけで作り、フック・deny・書き込み制限を含め、権限を 600 にする'

python3 - "$settings" <<'PY'
import json
import os
from pathlib import Path
import shlex
import sys

settings = Path(sys.argv[1])
config = json.loads(settings.read_text())
config.update(theme="dark", custom={"nested": [True, None, "人の値"]}, syncClaudeAiSkills=True, cleanupPeriodDays=7)
config["pluginConfigs"]["personal-plugin"] = {"options": {"enabled": True}}
config["pluginConfigs"]["cc-plugin-agents-md@builtin"]["options"]["instructionFiles"] = "agents-md"
config["skillOverrides"].update(batch="on", **{"personal-skill": "on", "code-review": "on"})
config["permissions"] = {"allow": ["Read"], "deny": ["Bash(secret)", "Monitor", "Read(//human/.aws/**)"], "blockWritesOutsideWorkingDirectories": False}
# 人のフックと、キットの置き場のスクリプトを指す項目（matcher の違うもの・人のフックと同じ組・消された Stop）を作る。
guard = os.path.dirname(os.path.dirname(settings)) + "/guard"
kit_pre = shlex.quote(guard + "/pre-tool-use")
config["hooks"] = {
    "PreToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "/human/audit"}]},
        {"matcher": "Bash", "hooks": [{"type": "command", "command": kit_pre}]},
        {"matcher": "Write", "hooks": [{"type": "command", "command": "/human/write"}, {"type": "command", "command": kit_pre}]},
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "/elsewhere/guard/pre-tool-use"}]},
    ],
    "Stop": [{"hooks": [{"type": "command", "command": "/human/stop"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "/human/start"}]}],
}
settings.write_text(json.dumps(config, ensure_ascii=False))
settings.chmod(0o644)
PY
settings_run
for key in syncClaudeAiSkills cleanupPeriodDays pluginConfigs.cc-plugin-agents-md@builtin skillOverrides.batch permissions.blockWritesOutsideWorkingDirectories hooks.PreToolUse; do
 grep -qF "$key" "$test_dir/err"
done
! grep -qF 'hooks.Stop' "$test_dir/err"
grep -q '警告:' "$test_dir/err"
python3 - "$settings" "$test_dir/kit-settings.json" <<'PY'
import json
import os
from pathlib import Path
import shlex
import sys

settings = Path(sys.argv[1])
actual = json.loads(settings.read_text())
expected = json.loads(Path(sys.argv[2]).read_text())
expected.update(theme="dark", custom={"nested": [True, None, "人の値"]})
expected["pluginConfigs"]["personal-plugin"] = {"options": {"enabled": True}}
expected["skillOverrides"].update({"personal-skill": "on", "code-review": "on"})
kit_deny = expected["permissions"]["deny"][1:]
expected["permissions"] = {
    "allow": ["Read"],
    "deny": ["Bash(secret)", "Monitor", "Read(//human/.aws/**)", *[item for item in kit_deny if item != "Monitor"]],
    "blockWritesOutsideWorkingDirectories": True,
}
guard = os.path.dirname(os.path.dirname(settings)) + "/guard"
kit_pre = shlex.quote(guard + "/pre-tool-use")
kit_stop = shlex.quote(guard + "/stop")
expected["hooks"] = {
    "PreToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "/human/audit"}]},
        {"matcher": "Write", "hooks": [{"type": "command", "command": "/human/write"}]},
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "/elsewhere/guard/pre-tool-use"}]},
        {"matcher": "Bash|Write|Edit|NotebookEdit", "hooks": [{"type": "command", "command": kit_pre}]},
    ],
    "Stop": [
        {"hooks": [{"type": "command", "command": "/human/stop"}]},
        {"hooks": [{"type": "command", "command": kit_stop}]},
    ],
    "SessionStart": [{"hooks": [{"type": "command", "command": "/human/start"}]}],
}
assert actual == expected, actual
assert settings.stat().st_mode & 0o777 == 0o600
# 空白とキーの順番だけが違うときも書かない。
settings.write_text(json.dumps(actual, ensure_ascii=False, sort_keys=True))
settings.chmod(0o640)
stat = settings.stat()
Path(str(settings) + ".before").write_text(json.dumps([stat.st_ino, stat.st_mtime_ns, stat.st_mode, settings.read_text()]))
PY
settings_run
[[ ! -s $test_dir/err ]]
python3 - "$settings" <<'PY'
import json
from pathlib import Path
import sys

settings = Path(sys.argv[1])
stat = settings.stat()
assert [stat.st_ino, stat.st_mtime_ns, stat.st_mode, settings.read_text()] == json.loads(Path(str(settings) + ".before").read_text())
assert not list(settings.parent.glob(".settings.*"))
PY
echo 'PASS host: 人のキー・プラグイン・スキル・権限・フックを残し、キットの値を警告して戻し、同じ中身は書かない'

# やめるキーがまだないため、将来その一覧に移した場合を作業用のコピーで確認する。
python3 - "$root/lib/host.sh" "$test_dir/retired-host.sh" "$settings" <<'PY'
import json
from pathlib import Path
import sys

host = Path(sys.argv[1]).read_text()
host = host.replace("retired_keys = ()", 'retired_keys = ("formerKitKey",)')
host = host.replace("retired_items = {}", 'retired_items = {("pluginConfigs",): ("formerKitPlugin",), ("skillOverrides",): ("formerKitSkill",), ("permissions", "deny"): ("FormerKitTool",)}')
Path(sys.argv[2]).write_text(host)
settings = Path(sys.argv[3])
config = json.loads(settings.read_text())
config["formerKitKey"] = True
config["pluginConfigs"]["formerKitPlugin"] = {}
config["skillOverrides"]["formerKitSkill"] = "off"
config["permissions"]["deny"].append("FormerKitTool")
settings.write_text(json.dumps(config))
PY
TEST_SETTINGS_HOST="$test_dir/retired-host.sh" settings_run
python3 - "$settings" <<'PY'
import json
from pathlib import Path
import sys

settings = Path(sys.argv[1])
actual = json.loads(settings.read_text())
expected = json.loads(json.loads(Path(str(settings) + ".before").read_text())[-1])
assert actual == expected, actual
PY
echo 'PASS host: やめたキーとキットの項目だけを消し、人の項目を残す'

for invalid in '{' '[]' 'null' 'true' '"text"' '30' '{"permissions":[]}' '{"permissions":null}' '{"permissions":{"deny":{}}}' '{"permissions":{"deny":null}}' '{"pluginConfigs":[]}' '{"pluginConfigs":null}' '{"skillOverrides":[]}' '{"hooks":[]}' '{"hooks":null}' '{"hooks":{"PreToolUse":{}}}' '{"hooks":{"Stop":null}}'; do
 printf '%s\n' "$invalid" >"$settings"
 cp "$settings" "$test_dir/invalid-settings"
 if settings_run; then exit 1; fi
 cmp "$settings" "$test_dir/invalid-settings"
 grep -qF '設定を直してから流し直してください' "$test_dir/err"
done
# 準備全体でも、形の違いをデーモン操作の前に止める。
set_mode running
deny
[[ ! -s $test_dir/calls ]]
echo 'PASS host: 壊れた JSON と最上位・permissions・deny・pluginConfigs・skillOverrides・hooks と各イベントの形の違いで書かずに止まる'

# 既存の disableAllHooks: true は、フックを無効にするので、役の登録の前に止めて直し方を案内する。
for hooks_off in '{"disableAllHooks":true}' '{"disableAllHooks":true,"permissions":{"deny":["Read(/x)"]}}'; do
 printf '%s\n' "$hooks_off" >"$settings"
 cp "$settings" "$test_dir/hooks-off-settings"
 if settings_run; then exit 1; fi
 cmp "$settings" "$test_dir/hooks-off-settings"
 grep -qF 'disableAllHooks' "$test_dir/err"
 grep -qF '設定を直してから流し直してください' "$test_dir/err"
 set_mode running
 deny
 grep -qF 'disableAllHooks' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
done
printf '{"disableAllHooks":false}\n' >"$settings"
settings_run
echo 'PASS host: disableAllHooks が true の既存設定は、書き換えず、役の登録とデーモンの操作の前に止めて直し方を案内する（false は通す）'

rm "$settings"
for target in "$test_dir/kit-settings.json" "$test_dir/missing-settings.json"; do
 ln -s "$target" "$settings"
 if settings_run; then exit 1; fi
 [[ -L $settings && $(readlink "$settings") == "$target" ]]
 grep -qF 'シンボリックリンクを実体のファイルに置き換えてください' "$test_dir/err"
 rm "$settings"
done
[[ ! -e $test_dir/missing-settings.json ]]
cp "$test_dir/kit-settings.json" "$settings"
settings_run
[[ ! -s $test_dir/err ]]
echo 'PASS host: 実体の有無によらずシンボリックリンクを拒み、リンク先を書き換えない'

cmp "$root/common/host/start-daemon" "$TEMPLATE_AGENT_HOME/start-daemon"
[[ $(sed -n '2p' "$TEMPLATE_AGENT_HOME/start-daemon") == '# multica-squad-kit-managed' ]]
[[ -x $TEMPLATE_AGENT_HOME/start-daemon && ! -e $TEMPLATE_AGENT_HOME/bin/start-daemon ]]
echo 'PASS host: 入口を管理マークと実行権限付きで置き、ガードのディレクトリには置かない'

set_mode running
agent_env
printf '#!/bin/bash\n# multica-squad-kit-managed\nold entry\n' >"$TEMPLATE_AGENT_HOME/start-daemon"
chmod 644 "$TEMPLATE_AGENT_HOME/start-daemon"
run
cmp "$root/common/host/start-daemon" "$TEMPLATE_AGENT_HOME/start-daemon"
[[ -x $TEMPLATE_AGENT_HOME/start-daemon && ! -e $TEMPLATE_AGENT_HOME/bin/start-daemon ]]
! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
echo 'PASS host: 流し直すと管理マークのある古い入口を原本に更新し、実行権限を付ける'

# 新しいガードと分割の部品は、配置先が原本と一致しなければ、役の登録の前に止めて対処を案内する。
for file in git-credential git-ssh pre-tool-use stop shell_split.py; do
 target=$TEMPLATE_AGENT_HOME/guard/$file
 cp "$target" "$test_dir/guard-original"
 # マークのない既存のファイル（人のファイル）は、上書きせず止める。
 printf '#!/bin/sh\nexit 0\n' >"$target"
 cp "$target" "$test_dir/guard-unmarked"
 set_mode running
 agent_env
 deny
 cmp "$target" "$test_dir/guard-unmarked"
 grep -qF "ガードのファイルが原本と一致しません: $target" "$test_dir/err"
 grep -qF '流し直してください' "$test_dir/err"
 # 止まるときは「そのまま使います」の行を出さず、停止エラーに対象と直し方をまとめる。
 if grep -qF 'そのまま使います' "$test_dir/err" "$test_dir/out"; then
  echo "止まるはずのガードのファイルで「そのまま使います」を出した: $file" >&2
  exit 1
 fi
 ! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
 # 管理マークのある古い内容は、原本に戻る。
 printf '#!/bin/sh\n# multica-squad-kit-managed\nexit 0\n' >"$target"
 run
 cmp "$root/common/guard/$file" "$target"
 [[ -x $target ]]
done
echo 'PASS host: 新しいガードと分割の部品は、マークのない既存のファイルを上書きせず役の登録の前に止め、マークのある古い内容は原本に戻す'

printf '#!/bin/bash\nprintf "manual entry\\n"\n' >"$TEMPLATE_AGENT_HOME/start-daemon"
chmod 644 "$TEMPLATE_AGENT_HOME/start-daemon"
cp "$TEMPLATE_AGENT_HOME/start-daemon" "$test_dir/manual-entry"
run
cmp "$test_dir/manual-entry" "$TEMPLATE_AGENT_HOME/start-daemon"
[[ ! -x $TEMPLATE_AGENT_HOME/start-daemon && ! -e $TEMPLATE_AGENT_HOME/bin/start-daemon ]]
grep -qF "マークのない既存のファイルをそのまま使います: $TEMPLATE_AGENT_HOME/start-daemon" "$test_dir/err"
! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
echo 'PASS host: マークのない入口は内容と権限を保持し、配置以外の準備を続ける'
cp "$root/common/host/start-daemon" "$TEMPLATE_AGENT_HOME/start-daemon"

# 入口から /dev/tty を受け継ぐ場合も、ファイルやパイプの場合も同じ確認を通す。
printf 'input for setup\n' >"$test_dir/stdin"
for input in tty pipe file; do
 set_mode running
 agent_env
 rm -f "$test_dir/claude-stdin"
 case $input in
 tty)
  python3 -I "$root/tests/stdin-tty-run.py" tty /dev/null /dev/null "$test_dir/out" "$test_dir/err" -- \
   /bin/bash -c 'exec </dev/tty; [[ -t 0 ]] || exit 93; exec /bin/bash "$@"' -- "$test_dir/run.sh" "$root"
  ;;
 pipe) cat "$test_dir/stdin" | run ;;
 file) run <"$test_dir/stdin" ;;
 esac
 grep -qx 'notty' "$test_dir/claude-stdin"
 grep -qx 'daemon status --output json' "$test_dir/calls"
 ! grep -q 'ログインしてください' "$test_dir/err"
 echo "PASS host: 標準入力が $input でも Claude の確認には端末を渡さず、デーモンの確認へ進む"
done
(
 # 原本の VERSION を変えずに、バージョンを取り直したセットアップを再現する。
 source "$root/lib/host.sh"
 mkdir -p "$test_dir/version-kit/common/monitor" "$test_dir/version-kit/tests/fixtures/cli"
 cp "$root/common/monitor/squad-cli-lib" "$test_dir/version-kit/common/monitor/"
 printf "multica fixture-next (captured 'version')\ngh ignored\n" >"$test_dir/version-kit/tests/fixtures/cli/VERSION"
 root="$test_dir/version-kit"
 agent_home=$TEMPLATE_AGENT_HOME
 die() { echo "$*" >&2; exit 1; }
 host_cli_library
 actual_version=$(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$agent_home/bin/squad-cli-lib")
 [[ $actual_version == "multica fixture-next (captured 'version')" ]]
 [[ -z $(find "$root/tmp" -type f -print) ]]
 # 拡張を足した作業用コピーには tests がない。採取バージョンは原本から読む。
 kit_root=$root
 mkdir -p "$test_dir/combined/common/monitor"
 cp "$root/common/monitor/squad-cli-lib" "$test_dir/combined/common/monitor/"
 root="$test_dir/combined"
 host_cli_library
 [[ $(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$agent_home/bin/squad-cli-lib") == "$actual_version" ]]
)
run
[[ $(bash -c 'source "$1"; printf "%s\n" "$SQUAD_CLI_VERIFIED_VERSION"' -- "$TEMPLATE_AGENT_HOME/bin/squad-cli-lib") == "$expected_version" ]]
echo 'PASS host: 見本のバージョンを取り直すとライブラリの採取バージョンも更新し、先頭行の値をそのまま保持する'
for file in squad-pr-link squad-pr-link-lib; do
 [[ $(PATH="$TEMPLATE_AGENT_HOME/bin:$PATH" command -v "$file") == "$TEMPLATE_AGENT_HOME/bin/$file" ]]
done
echo 'PASS host: 新しい導入で PR の紐付けコマンドと共有関数を bin に置き、名前で解決できる'
set_mode busy
agent_env
run
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
echo 'PASS host: 設定と両ランタイムが一致するデーモンは稼働中でも起動し直さない'
set_mode running
printf wrong >"$test_dir/process-env"
run
[[ $(grep -c '^daemon stop$' "$test_dir/calls") == 1 && $(grep -c '^daemon start$' "$test_dir/calls") == 1 ]]
echo 'PASS host: 設定が違う場合はタスクがないことを確認して停止・起動する'
set_mode busy
printf wrong >"$test_dir/process-env"
deny
grep -q '実行中のタスク' "$test_dir/err"
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
set_mode unknown
deny
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
echo 'PASS host: 実行中のタスクがあるか件数が不明なら停止しない'
set_mode desktop
deny
grep -q 'CLI 以外' "$test_dir/err"
if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
echo 'PASS host: CLI 以外のデーモンへ重ねて起動しない'
set_mode running
agent_env
touch "$test_dir/no-claude-auth"
deny
grep -q 'ログインしてください' "$test_dir/err"
[[ ! -s $test_dir/calls ]]
rm "$test_dir/no-claude-auth"
touch "$test_dir/no-codex-auth"
deny
grep -q 'codex login' "$test_dir/err"
[[ ! -s $test_dir/calls ]]
rm "$test_dir/no-codex-auth"
echo 'PASS host: 専用の認証がなければログインを案内し、デーモン操作をしない'
# 最初の JSON の値と終了コードの組み合わせで、ログインの案内と確認失敗を分ける。
(
 export TEST_CLAUDE_STDOUT="$test_dir/auth-stdout" TEST_CLAUDE_STDERR="$test_dir/auth-stderr"
 for auth_case in false0 false1 crash malformed missing string null array boolean number empty whitespace prefix true1 true1-kqueue suffix stderr invalid-utf8 invalid-suffix control stderr-einval stderr-kqueue; do
  printf '{"loggedIn":true}\n' >"$TEST_CLAUDE_STDOUT"
  : >"$TEST_CLAUDE_STDERR"
  export TEST_CLAUDE_EXIT=0
  expected=failed
  first='JSON として読めない'
  category='CLI の出力を読めない（詳細は省略）'
  case $auth_case in
  false0|false1)
   printf '{"loggedIn":false}\n' >"$TEST_CLAUDE_STDOUT"
   TEST_CLAUDE_EXIT=${auth_case#false}
   expected=login
   ;;
  crash)
   : >"$TEST_CLAUDE_STDOUT"
   printf 'error: EINVAL: invalid argument, kqueue\n      at emitError (node:events:65:13)\nBun v1.4.4 (macOS arm64)\n' >"$TEST_CLAUDE_STDERR"
   TEST_CLAUDE_EXIT=1
   first=空
   category='Claude の CLI の既知の不具合（kqueue）'
   ;;
  malformed) printf 'not JSON' >"$TEST_CLAUDE_STDOUT" ;;
  missing) printf '{}' >"$TEST_CLAUDE_STDOUT"; first='loggedIn が真偽値でない' ;;
  string) printf '{"loggedIn":"true"}' >"$TEST_CLAUDE_STDOUT"; first='loggedIn が真偽値でない' ;;
  null) printf 'null' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  array) printf '[{"loggedIn":true}]' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  boolean) printf 'true' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  number) printf '42' >"$TEST_CLAUDE_STDOUT"; first='オブジェクトでない' ;;
  empty) : >"$TEST_CLAUDE_STDOUT"; first=空 ;;
  whitespace) printf ' \t\r\n' >"$TEST_CLAUDE_STDOUT"; first=空 ;;
  prefix) printf 'warning\n{"loggedIn":true}\n' >"$TEST_CLAUDE_STDOUT" ;;
  true1|true1-kqueue|invalid-suffix)
   TEST_CLAUDE_EXIT=1
   first='loggedIn が true'
   category='CLI がログイン済みと答えたまま失敗した'
   if [[ $auth_case == true1-kqueue ]]; then
    printf 'EINVAL\nkqueue\n' >"$TEST_CLAUDE_STDERR"
    category='Claude の CLI の既知の不具合（kqueue）'
   elif [[ $auth_case == invalid-suffix ]]; then
    printf '\377\033[?1l' >>"$TEST_CLAUDE_STDOUT"
   fi
   ;;
  suffix) printf ' \n{"loggedIn":true}\n\033[?1l{"loggedIn":false}' >"$TEST_CLAUDE_STDOUT"; expected=pass ;;
  stderr) printf 'warning from CLI\n' >"$TEST_CLAUDE_STDERR"; expected=pass ;;
  invalid-utf8) printf '\377{"loggedIn":true}' >"$TEST_CLAUDE_STDOUT" ;;
  control) printf '\033[31m{"loggedIn":true}' >"$TEST_CLAUDE_STDOUT" ;;
  stderr-einval|stderr-kqueue)
   : >"$TEST_CLAUDE_STDOUT"
   printf '%s\n' "${auth_case#stderr-}" >"$TEST_CLAUDE_STDERR"
   if [[ $auth_case == stderr-einval ]]; then printf 'EINVAL\n' >"$TEST_CLAUDE_STDERR"; fi
   first=空
   ;;
  esac
  # ダミーの個人情報・認証値・未知の値を、正常な JSON とその前後にも置く。
  # 失敗の診断は全行を照合し、成功・未ログイン時も両出力への漏れを確認する。
  case $auth_case in
  false0|false1|true1|prefix|suffix|stderr|true1-kqueue|invalid-suffix)
   python3 - "$TEST_CLAUDE_STDOUT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes().replace(
    b'"loggedIn":',
    b'"email":"private-mail@example.test","orgId":"private-org-id",'
    b'"orgName":"private-org-name","unknown-private-key":"private-unknown-value","loggedIn":',
)
path.write_bytes(data + b'\nprivate-after-json\xff\x1b[31m')
PY
   ;;
  malformed) printf 'private-before-json\n{"email":"private-mail@example.test"' >"$TEST_CLAUDE_STDOUT" ;;
  esac
  if [[ $auth_case != empty ]]; then
   printf 'Bearer private-auth-value private-stderr-value\377\033[31m\n' >>"$TEST_CLAUDE_STDERR"
  fi
  set_mode running
  agent_env
  rc=0
  run || rc=$?
  ! grep -aEq 'private-|Bearer|invalid argument|emitError|Bun v|warning from CLI' "$test_dir/out" "$test_dir/err"
  if [[ $expected == pass ]]; then
   [[ $rc == 0 ]]
   grep -qx 'daemon status --output json' "$test_dir/calls"
   ! grep -qE 'ログインしてください|ログインを確認できませんでした|warning from CLI' "$test_dir/err"
  else
   [[ $rc == 1 && ! -s $test_dir/calls ]]
   [[ ! -s $test_dir/out ]]
   if [[ $expected == login ]]; then
    grep -qxF "エラー: エージェント用の Claude にログインしてください: CLAUDE_CONFIG_DIR=$TEMPLATE_AGENT_HOME/claude claude" "$test_dir/err"
    ! grep -q 'ログインを確認できませんでした' "$test_dir/err"
   else
    ! grep -q 'ログインしてください' "$test_dir/err"
    python3 - "$test_dir/err" "$TEST_CLAUDE_STDOUT" "$TEST_CLAUDE_EXIT" "$TEMPLATE_AGENT_HOME" "$first" "$category" "$TEST_CLAUDE_STDERR" <<'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_text()
home = sys.argv[4]
message = f"エラー: エージェント用の Claude のログインを確認できませんでした。ログインが切れているとは限りません。端末から CLAUDE_CONFIG_DIR={home}/claude claude auth status を流して、ログインの状態を確認してから流し直してください。問い合わせるときは、下の診断の行だけを添えてください。\n"
message += f"  診断（claude auth status）:\n    分類: {sys.argv[6]}\n    終了コード: {sys.argv[3]}\n    標準出力の最初の値: {sys.argv[5]}\n"
message += "    標準出力: " + ("あり（内容は省略）" if Path(sys.argv[2]).stat().st_size else "なし") + "\n"
message += "    標準エラー: " + ("あり（内容は省略）" if Path(sys.argv[7]).stat().st_size else "なし") + "\n"
assert actual == message, actual
PY
   fi
  fi
  while IFS= read -r work; do [[ ! -e $work ]]; done <"$test_dir/auth-work"
  echo "PASS host: Claude の確認 $auth_case は $expected に分け、生出力を表示せず、一時ファイルを残さない"
 done
 # 読み取りの失敗で入力を含む例外が出ても、固定文だけで止まる。
 set_mode running
 TEST_AUTH_READER_FAIL=yes deny
 [[ ! -s $test_dir/calls && ! -s $test_dir/out ]]
 grep -qx 'エラー: Claude のログインの確認の出力を読めませんでした。' "$test_dir/err"
 ! grep -aEq 'private-|reader exception|診断（' "$test_dir/err"
 while IFS= read -r work; do [[ ! -e $work ]]; done <"$test_dir/auth-work"
 echo 'PASS host: 出力を読む処理が失敗しても、生出力や例外を表示せず固定文で止まる'
 # 作る間の一覧を使う場合も、失敗した手順、エラー、診断の順に出す。
 : >"$TEST_CLAUDE_STDOUT"
 printf 'CLI failure\n' >"$TEST_CLAUDE_STDERR"
 export TEST_CLAUDE_EXIT=7 TEST_HOST_STEPS=yes
 set_mode running
 deny
 [[ ! -s $test_dir/calls && ! -s $test_dir/out ]]
 python3 - "$test_dir/err" <<'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_text()
assert actual.index("  ✖ ホストを準備") < actual.index("エラー: エージェント用の Claude のログインを確認できませんでした") < actual.index("  診断（claude auth status）:"), actual
assert actual.endswith("  診断（claude auth status）:\n    分類: CLI の出力を読めない（詳細は省略）\n    終了コード: 7\n    標準出力の最初の値: 空\n    標準出力: なし\n    標準エラー: あり（内容は省略）\n"), actual
assert "ログインしてください" not in actual and "CLI failure" not in actual, actual
PY
 echo 'PASS host: 一覧を書き換えない画面も、手順の失敗、エラー、固定の診断の順に出す'
 source "$root/tests/terminal-stub-fixture.sh"
 env -u NO_COLOR TERM=xterm-256color bash "$root/tests/draw-terminal.sh" err "$test_dir/out" "$test_dir/err" --ui "$draw_root/lib/ui.sh" -- \
  /bin/bash -c '/bin/bash "$1" "$2"; printf "%s\n" "$?" >"$3"' -- "$test_dir/run.sh" "$root" "$test_dir/auth-exit"
 grep -qx '1' "$test_dir/auth-exit"
 [[ ! -s $test_dir/calls && ! -s $test_dir/out ]]
 python3 - "$test_dir/err" <<'PY'
from pathlib import Path
import re
import sys

raw = Path(sys.argv[1]).read_text()
assert re.search(r"\x1b\[\d+A", raw), raw
actual = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", raw).replace("\r", "")
assert actual.index("  ✖ ホストを準備") < actual.index("エラー: エージェント用の Claude のログインを確認できませんでした") < actual.index("  診断（claude auth status）:"), actual
assert actual.endswith("  診断（claude auth status）:\n    分類: CLI の出力を読めない（詳細は省略）\n    終了コード: 7\n    標準出力の最初の値: 空\n    標準出力: なし\n    標準エラー: あり（内容は省略）\n"), actual
assert "ログインしてください" not in actual and "CLI failure" not in actual, actual
PY
 echo 'PASS host: 一覧を書き換える端末でも、手順の失敗のあとにエラーと固定の診断を出す'
)
