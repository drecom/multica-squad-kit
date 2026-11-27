#!/usr/bin/env bash
# ZIP のルートから bash tests/project-runtimes-rerun-test.sh で実行する。
# この部分は、前の世代の Codex のモデルと、思考の深さと、Claude Code だけへ移した登録の流し直しを確認する。
# ランタイムの選び直しと拡張の固定モデル
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

make_completed
make_extension

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

# 思考の深さが high で登録済みの Claude のリーダーと修正の役は、流し直しで medium になり、Codex の役の思考の深さは変わらない。
export TEST_EXCLUDED='[]' TEST_ROLE_COUNT=17
unset TEST_RUNTIMES
rm -rf "$TEST_DB" "$TEMPLATE_AGENT_HOME"
cp -R "$test_dir/completed/db" "$TEST_DB"
cp -R "$test_dir/completed/host" "$TEMPLATE_AGENT_HOME"
for role in orchestrator claude-fixer; do
 jq '.thinking_level="high"' "$TEST_DB/agents/agent-demo-$role-owner.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/agents/agent-demo-$role-owner.json"
done
before_codex=$(for role in codex-implementer codex-fixer; do jq -c '[.name,.thinking_level]' "$TEST_DB/agents/agent-demo-$role-owner.json"; done)
: >"$TEST_DB/calls"
run
for role in orchestrator claude-fixer; do jq -e '.thinking_level=="medium"' "$TEST_DB/agents/agent-demo-$role-owner.json" >/dev/null; done
jq -e '.thinking_level=="medium"' "$TEST_DB/agents/agent-demo-qa-owner.json" >/dev/null
[[ $(for role in codex-implementer codex-fixer; do jq -c '[.name,.thinking_level]' "$TEST_DB/agents/agent-demo-$role-owner.json"; done) == "$before_codex" ]]
! jq -es 'any(.[]; .[0:2]==["agent","create"] or .[0:2]==["autopilot","create"])' "$TEST_DB/calls" >/dev/null
echo 'PASS project runtimes: 思考の深さが high で登録済みの Claude のリーダーと修正の役が、流し直しで medium になり、Codex の役と QA は変わらない'

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
