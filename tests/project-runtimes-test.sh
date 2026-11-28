#!/usr/bin/env bash
# ZIP のルートから bash tests/project-runtimes-test.sh で実行する。
# この部分は、片方だけへの移し・設計の役のモデルの流し直し・拡張の固定モデルを確認する。
# ランタイムの選び直しと拡張の固定モデル
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

make_completed
make_extension

# 同じエージェントを両方から片方へ移し、以前のランタイムの環境を残さない。
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17
rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
cp -R "$test_dir/completed/db" "$TEST_DB"
cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
jq '.custom_args=["--keep","value"]' "$TEST_DB/agents/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-orchestrator-owner.json"
jq '.+{EXTRA:"keep"}' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/env/agent-demo-orchestrator-owner.json"
for selected in claude codex; do
 export TEST_RUNTIMES="[\"$selected\"]"
 if [[ $selected == claude ]]; then absent=codex; expected=claude-sonnet-5-5; else absent=claude; expected=gpt-6.2-sol; fi
 : >"$TEST_DB/calls"
 run
 grep -qF 'エージェント 14 件の既存設定' "$test_dir/err"
 grep -q '^✔ ' "$test_dir/out"
 ! grep -q '^✔ .*エージェント' "$test_dir/out"
 ! jq -es --arg prefix "agent-demo-$absent-" 'any(.[]; .[0]=="agent" and (.[2] // ""|startswith($prefix)))' "$TEST_DB/calls" >/dev/null
 for role in orchestrator planner designer qa code-reviewer security-reviewer ux-reviewer performance-reviewer ci-monitor usage-monitor dependabot-merger; do
  role_model=$expected
  if [[ $role == planner ]]; then role_model=$(if [[ $selected == claude ]]; then echo claude-fable-5-2; else echo gpt-6.2-astra; fi); fi
  if [[ $role == designer ]]; then role_model=$(if [[ $selected == claude ]]; then echo claude-opus-5-5; else echo gpt-6.2-sol; fi); fi
  jq -e --arg role "$role" --arg model "$role_model" --arg runtime "runtime-$selected" '.id==("agent-demo-"+$role+"-owner") and .model==$model and .runtime_id==$runtime' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
  if [[ $role == planner || $role == designer ]]; then jq -e '.thinking_level=="high"' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null; fi
  # リーダーは Claude で medium、Codex で high。QA は medium のまま。
  if [[ $role == orchestrator ]]; then jq -e --arg want "$(if [[ $selected == claude ]]; then echo medium; else echo high; fi)" '.thinking_level==$want' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null; fi
  if [[ $role == qa ]]; then jq -e '.thinking_level=="medium"' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null; fi
  jq -e --arg selected "$selected" --arg env "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh" 'if $selected=="claude" then .CLAUDE_ENV_FILE==$env else .CLAUDE_ENV_FILE==null end' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  role_args='[]'
  if [[ $role == orchestrator ]]; then role_args='["--keep","value"]'; fi
  jq -e --arg selected "$selected" --arg g "$TEMPLATE_AGENT_HOME/guard" --argjson prefix "$role_args" "$HOOK_ARGS_DEF"'.custom_args==($prefix+(if $selected=="codex" then codex_args($g) else [] end))' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
  jq -e --arg selected "$selected" 'if $selected=="claude" then .mcp_config=={} else .mcp_config==null end' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
 done
 jq -e --arg selected "$selected" --arg model "$(if [[ $selected == claude ]]; then echo claude-fable-5-2; else echo gpt-6.2-astra; fi)" '.model==$model and .runtime_id==("runtime-"+$selected) and .thinking_level=="xhigh"' "$TEST_DB/agents/agent-demo-$selected-principal-owner.json" >/dev/null
 jq -e '.EXTRA=="keep"' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >/dev/null
 if [[ $selected == codex ]]; then
  for role in orchestrator usage-monitor ci-monitor; do
   jq -e '.CLAUDE_CONFIG_DIR==null and .CLAUDE_CODE_SHELL==null and .ENABLE_CLAUDEAI_MCP_SERVERS==null and .CLAUDE_CODE_AUTO_COMPACT_WINDOW==null and .CLAUDE_CODE_DISABLE_BACKGROUND_TASKS==null and .CLAUDE_CODE_DISABLE_CRON==null and .DISABLE_AUTOUPDATER==null' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  done
  ! grep -q 'CLAUDE_CONFIG_DIR=' "$test_dir/out"
  grep -q 'CODEX_HOME=' "$test_dir/out"
 else
  jq -e '.CLAUDE_CONFIG_DIR!=null and .CLAUDE_CODE_SHELL=="/bin/zsh"' "$TEST_DB/env/agent-demo-usage-monitor-owner.json" >/dev/null
  for role in orchestrator planner designer qa code-reviewer security-reviewer ux-reviewer performance-reviewer ci-monitor usage-monitor dependabot-merger; do
   jq -e '.CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=="1" and .CLAUDE_CODE_DISABLE_CRON=="1" and .DISABLE_AUTOUPDATER=="1"' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  done
  ! grep -q 'CODEX_HOME=' "$test_dir/out"
  grep -q 'CLAUDE_CONFIG_DIR=' "$test_dir/out"
 fi
 echo "PASS project runtimes: $selected だけへ同じIDで移し、ない系統を登録せず、環境と完了の案内を合わせる"
done
unset TEST_RUNTIMES

# 設計の役が別のモデルで登録済みの状態から流し直すと、設計の役のモデルだけが替わる。
for selected in both claude codex; do
 export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17
 rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
 cp -R "$test_dir/completed/db" "$TEST_DB"
 cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
 if [[ $selected == both ]]; then
  unset TEST_RUNTIMES; old_model=claude-fable-5-2; new_model=claude-opus-5-5
 elif [[ $selected == claude ]]; then
  export TEST_RUNTIMES='["claude"]'; old_model=claude-fable-5-2; new_model=claude-opus-5-5
 else
  export TEST_RUNTIMES='["codex"]'; old_model=gpt-6.2-astra; new_model=gpt-6.2-sol
 fi
 # 両方の構成の見本に Codex の設計の役はいない。片方だけの構成は、見本の設計の役を移し先のランタイムの前の値にする。
 jq --arg model "$old_model" '.model=$model' "$TEST_DB/agents/agent-demo-designer-owner.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-designer-owner.json"
 before=$(for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do jq -c '[.name,.model,.thinking_level]' "$f"; done | grep -v '"demo-designer-owner"' | sort)
 names_before=$(for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do jq -r .name "$f"; done | sort)
 : >"$TEST_DB/calls"
 run
 jq -e --arg model "$new_model" '.model==$model and .thinking_level=="high"' "$TEST_DB/agents/agent-demo-designer-owner.json" >/dev/null
 after=$(for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do jq -c '[.name,.model,.thinking_level]' "$f"; done | grep -v '"demo-designer-owner"' | sort)
 # 片方だけへの移しは、ほかの役のモデルも移し先に合わせて替わる（上の確認）。ここでは両方の構成で、ほかの役が変わらないことを見る。
 if [[ $selected == both ]]; then [[ $after == "$before" ]]; fi
 [[ $(for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do jq -r .name "$f"; done | sort) == "$names_before" ]]
 ! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:2]==["autopilot","create"])' "$TEST_DB/calls" >/dev/null
 echo "PASS project runtimes: 設計の役が前のモデルで登録済みの $selected の流し直しで、設計の役のモデルが $new_model になり、エージェントとオートパイロットは作られない"
done
unset TEST_RUNTIMES

# 拡張の固定モデルは、オンラインIDがあっても選んでいないランタイムでは使わない。
mkdir -p "$test_dir/extension/agents"
for selected in claude codex; do
 reset_db
 if [[ $selected == claude ]]; then wrong_model=gpt-6.2-sol; else wrong_model=claude-sonnet-5-5; fi
 printf '%s\n' '---' 'name: "{{project_key}}-helper-{{member_key}}"' "model: $wrong_model" 'thinking_level: high' '---' 'Help.' >"$test_dir/extension/agents/helper.md"
 TEST_RUNTIMES="[\"$selected\"]" TEST_EXTENSION_DIR="$test_dir/extension" deny
 grep -qF '使うランタイムにないモデル' "$test_dir/err"
 ! jq -es 'any(.[]; .[0:2]==["agent","create"])' "$TEST_DB/calls" >/dev/null
done
echo 'PASS extension runtimes: 選ばなかったランタイムのモデルを、全エージェントの作成前に拒否する'
rm "$test_dir/extension/agents/helper.md"

# 置き場に空白と単引用符があっても、Codex はフックのコマンドをシェルで実行するので、役の引数のコマンドは 1 つのパスとして読まれ、2 つのフックのスクリプトが起動する。
export TEMPLATE_AGENT_HOME="$test_dir/ho st's home"
export TEST_RUNTIMES='["codex"]' TEST_COMPLETE=yes TEST_ROLE_COUNT=14
export TEST_REPOSITORIES='[{"url":"https://github.com/example/project","repository":"example/project"}]'
reset_db
cp "$root/common/guard/pre-tool-use" "$root/common/guard/stop" "$root/common/guard/shell_split.py" "$TEMPLATE_AGENT_HOME/guard/"
chmod +x "$TEMPLATE_AGENT_HOME/guard/pre-tool-use" "$TEMPLATE_AGENT_HOME/guard/stop"
run
guard_env_dir="$test_dir/guard-env"
mkdir -p "$guard_env_dir/bin" "$guard_env_dir/state"
ln -sf "$(command -v python3)" "$guard_env_dir/bin/python3"
# ガードは MULTICA_TASK_ID がないと何もせずに通す。実行の環境（エージェントの中か CI か）に左右されないよう、値と PATH（multica なし）と状態の置き場を固定する。
python3 - "$TEST_DB/agents/agent-demo-codex-implementer-owner.json" "$TEMPLATE_AGENT_HOME" "$guard_env_dir" <<'PY'
import json
import subprocess
import sys

args = json.load(open(sys.argv[1], encoding="utf-8"))["custom_args"]
guard = sys.argv[2] + "/guard"
guard_env = {"PATH": sys.argv[3] + "/bin:/usr/bin:/bin", "HOME": sys.argv[3], "MULTICA_TASK_ID": "task-test", "SQUAD_KIT_STATE_DIR": sys.argv[3] + "/state"}
commands = {}
for value in args:
    for name in ("PreToolUse", "Stop"):
        if value.startswith("hooks.%s=" % name):
            # 引数の値は TOML の文字列（JSON と同じ書き方）で、コマンドを 1 つ持つ。
            start = value.index('command="') + len("command=")
            commands[name] = json.loads(value[start:value.index('"}', start) + 1])
assert set(commands) == {"PreToolUse", "Stop"}, args
assert commands["PreToolUse"].startswith("'") and commands["PreToolUse"].endswith("'"), commands
pre = subprocess.run(["/bin/sh", "-c", commands["PreToolUse"]], input='{"tool_name":"Bash","tool_input":{"command":"ls"}}', capture_output=True, text=True, env=guard_env)
assert pre.returncode == 2 and "PreToolUse のガード" in pre.stderr, (pre.returncode, pre.stderr)
stop = subprocess.run(["/bin/sh", "-c", commands["Stop"]], input='{"hook_event_name":"Stop"}', capture_output=True, text=True, env=guard_env)
assert stop.returncode == 0 and "decision" in stop.stdout, (stop.returncode, stop.stdout, stop.stderr)
# 引用しないと、同じパスは空白で割れて 127、単引用符で閉じずに 2 で終わる。
bare = subprocess.run(["/bin/sh", "-c", guard + "/pre-tool-use"], input="{}", capture_output=True, text=True, env=guard_env)
assert bare.returncode != 2 or "PreToolUse のガード" not in bare.stderr, bare
PY
echo 'PASS project runtimes: 置き場に空白と単引用符があっても、役の引数のコマンドをシェルで実行すると 2 つのフックのスクリプトが起動する'

# 更新が途中で止まっても、共有の settings.json は書き換わらず（フックと deny は最後に書く）、登録済みの役はそのまま動く。
agent_snapshot() { for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do jq -c '[.name,.model,.thinking_level,.runtime_id]' "$f"; done | sort; }
snapshot_shared() { { cat "$TEMPLATE_AGENT_HOME/claude/settings.json"; agent_snapshot; } | shasum | cut -d' ' -f1; }
unset TEST_COMPLETE TEST_REPOSITORIES
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17 TEST_RUNTIMES='["claude","codex"]'
for stop in env_set; do
 rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
 cp -R "$test_dir/completed/db" "$TEST_DB"
 cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
 mkdir -p "$TEMPLATE_AGENT_HOME/claude"
 printf '%s\n' '{"theme":"dark","permissions":{"allow":["Bash(ls)"]}}' >"$TEMPLATE_AGENT_HOME/claude/settings.json"
 before=$(snapshot_shared)
 : >"$TEST_DB/calls"
 # 役の custom_env を書いている途中で止まる。
 TEST_FAIL='agent env set' deny
 [[ $(snapshot_shared) == "$before" ]]
 if grep -q 'hooks' "$TEMPLATE_AGENT_HOME/claude/settings.json"; then echo '止まったのにフックが書かれた' >&2; exit 1; fi
 # 止まったあとに流し直すと、フックと deny がそろって書かれる。
 run
 grep -q 'hooks' "$TEMPLATE_AGENT_HOME/claude/settings.json"
done
echo 'PASS project runtimes: 更新が custom_env の書き込みの途中で止まっても、共有の settings.json は変わらず、流し直すと書かれる'
