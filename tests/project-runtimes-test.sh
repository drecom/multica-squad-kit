#!/usr/bin/env bash
# ZIP のルートから bash tests/project-runtimes-test.sh で実行する。
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
  jq -e --arg selected "$selected" --arg env "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh" 'if $selected=="claude" then .CLAUDE_ENV_FILE==$env else .CLAUDE_ENV_FILE==null end' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  role_args='[]'
  if [[ $role == orchestrator ]]; then role_args='["--keep","value"]'; fi
  jq -e --arg selected "$selected" --argjson prefix "$role_args" '.custom_args==($prefix+(if $selected=="codex" then ["-c","allow_login_shell=false","-c","features.shell_snapshot=false"] else [] end))' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
 done
 jq -e --arg selected "$selected" --arg model "$(if [[ $selected == claude ]]; then echo claude-fable-5-2; else echo gpt-6.2-astra; fi)" '.model==$model and .runtime_id==("runtime-"+$selected) and .thinking_level=="xhigh"' "$TEST_DB/agents/agent-demo-$selected-principal-owner.json" >/dev/null
 jq -e '.EXTRA=="keep"' "$TEST_DB/env/agent-demo-orchestrator-owner.json" >/dev/null
 if [[ $selected == codex ]]; then
  for role in orchestrator usage-monitor ci-monitor; do
   jq -e '.CLAUDE_CONFIG_DIR==null and .CLAUDE_CODE_SHELL==null and .ENABLE_CLAUDEAI_MCP_SERVERS==null and .CLAUDE_CODE_AUTO_COMPACT_WINDOW==null' "$TEST_DB/env/agent-demo-$role-owner.json" >/dev/null
  done
  ! grep -q 'CLAUDE_CONFIG_DIR=' "$test_dir/out"
  grep -q 'CODEX_HOME=' "$test_dir/out"
 else
  jq -e '.CLAUDE_CONFIG_DIR!=null and .CLAUDE_CODE_SHELL=="/bin/zsh"' "$TEST_DB/env/agent-demo-usage-monitor-owner.json" >/dev/null
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

# 前の世代の Codex のモデルで登録済みの役は、流し直しで同じ格の新しい ID に替わる。Claude のモデルと思考の深さは替わらない。
agent_snapshot() { for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do jq -c '[.name,.model,.thinking_level,.runtime_id]' "$f"; done | sort; }
old_codex_models() {
 # Codex の役のモデルを、同じ格の前の世代の ID にする。最上位の格は codex-principal と planner である。
 for f in "$TEST_DB"/agents/agent-demo-*-owner.json; do
  jq -e '.model|startswith("gpt-")' "$f" >/dev/null || continue
  jq '.model=(if (.name=="demo-codex-principal-owner" or .name=="demo-planner-owner") then "gpt-6-astra" else "gpt-6.1-sol" end)' "$f" >"$TEST_DB/new"
  mv "$TEST_DB/new" "$f"
 done
}
for selected in both codex; do
 export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17
 rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
 cp -R "$test_dir/completed/db" "$TEST_DB"
 cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
 if [[ $selected == codex ]]; then
  # 完了した見本は両方の構成の登録なので、先に Codex だけへ移してから前の世代の ID に戻す。
  export TEST_RUNTIMES='["codex"]'
  run
 else
  unset TEST_RUNTIMES
 fi
 old_codex_models
 jq -e '.model|startswith("gpt-6.1-sol") or startswith("gpt-6-astra")' "$TEST_DB/agents/agent-demo-codex-principal-owner.json" >/dev/null
 before=$(agent_snapshot)
 : >"$TEST_DB/calls"
 run
 after=$(agent_snapshot)
 # 前の世代の ID の行を新しい ID に読み替えると、流す前と同じになる（Claude のモデルと思考の深さは変わらない）。
 [[ $(sed 's/gpt-6\.1-sol/gpt-6.2-sol/; s/gpt-6-astra/gpt-6.2-astra/' <<<"$before") == "$after" ]]
 ! grep -q 'gpt-6\.1-sol\|gpt-6-astra' <<<"$after"
 while IFS= read -r line; do
  name=$(jq -r '.[0]' <<<"$line"); model=$(jq -r '.[1]' <<<"$line")
  [[ $model == gpt-* ]] || continue
  if [[ $name == demo-codex-principal-owner || $name == demo-planner-owner ]]; then [[ $model == gpt-6.2-astra ]]; else [[ $model == gpt-6.2-sol ]]; fi
 done <<<"$after"
 [[ $(grep -c 'gpt-6.2-astra' <<<"$after") -eq $(if [[ $selected == both ]]; then echo 1; else echo 2; fi) ]]
 ! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:2]==["autopilot","create"])' "$TEST_DB/calls" >/dev/null
 echo "PASS project runtimes: 前の世代の Codex のモデルで登録済みの $selected の流し直しで、Codex の役のモデルが同じ格の新しい ID になり、Claude のモデルと思考の深さは変わらず、エージェントとオートパイロットは作られない"
done
unset TEST_RUNTIMES

# Claude Code だけへ移した登録を流し直しても、エージェントは更新されず、どの役も Claude の決まった ID のままである。
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17 TEST_RUNTIMES='["claude"]'
rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
cp -R "$test_dir/completed/db" "$TEST_DB"
cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
run
before=$(agent_snapshot)
: >"$TEST_DB/calls"
run
after=$(agent_snapshot)
[[ $before == "$after" ]]
! jq -es 'any(.[]; .[0:2]==["agent","update"] or .[0:2]==["agent","create"] or .[0:2]==["autopilot","create"])' "$TEST_DB/calls" >/dev/null
for role in orchestrator planner designer qa code-reviewer security-reviewer ux-reviewer performance-reviewer ci-monitor usage-monitor dependabot-merger claude-principal claude-implementer claude-fixer; do
 case $role in
  planner|claude-principal) role_model=claude-fable-5-2 ;;
  designer) role_model=claude-opus-5-5 ;;
  *) role_model=claude-sonnet-5-5 ;;
 esac
 jq -e --arg model "$role_model" --arg runtime runtime-claude '.model==$model and .runtime_id==$runtime' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null
done
! grep -q 'gpt-6\.2' <(jq -s '.[]|select(.runtime_id=="runtime-claude")|.model' "$TEST_DB"/agents/agent-demo-*-owner.json)
unset TEST_RUNTIMES
echo 'PASS project runtimes: Claude Code だけへ移した登録の流し直しで、エージェントは更新されず、どの役も Claude の決まった ID のままである'

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
