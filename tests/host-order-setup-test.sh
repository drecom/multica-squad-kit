#!/usr/bin/env bash
# 既存プロジェクトの更新を本物の setup.sh から流し、共有ファイルを書き始める前の検査を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

setup_order_snapshot() { "$python" "$root/tests/host-order-snapshot.py" "$TEMPLATE_AGENT_HOME" "${1:-}"; }

check_setup_order() {
 local id state refusal message remain blocked mode status before after installed original_mode rows=0
 local gh_empty="$TEMPLATE_AGENT_HOME/guard/gh-empty"
 local shell_dir="$TEMPLATE_AGENT_HOME/template/shell/projects-1"
 local allowed="$TEMPLATE_AGENT_HOME/allowed-repos.d/projects-1"
 local guard="$TEMPLATE_AGENT_HOME/guard/pre-tool-use"
 local answers="$TEMPLATE_STATE_ROOT/ws-a/demo.json"
 installed=$(setup_order_snapshot)
 while IFS=$'\t' read -r id state refusal message remain; do
  [[ $state == setup ]] || continue
  rows=$((rows + 1))
  printf '# stale\n' >>"$guard"
  printf '%s\n' '# multica-squad-kit-managed' '# stale' >"$shell_dir/.zshenv"
  cp "$shell_dir/.zshenv" "$shell_dir/env.sh"
  printf '%s\n' example/old >"$allowed"
  chmod 750 "$gh_empty"
  blocked=''
  case $refusal in
   shell-parent-readonly) blocked=$shell_dir; mode=555 ;;
   gh-empty-unreadable) blocked=$gh_empty; mode=300; printf '%s\n' saved >"$gh_empty/.hidden" ;;
   project-id-shift) : >"$scenario_dir/project-id-shift" ;;
   gh-empty-readable) ;;
   *) echo "表の止める条件が不明です: $refusal" >&2; exit 1 ;;
  esac
  if [[ $refusal != gh-empty-readable ]]; then
   if [[ -n $blocked ]]; then
    original_mode=$("$python" -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$blocked")
    chmod "$mode" "$blocked"
   fi
   before=$(setup_order_snapshot "$blocked")
   cp "$answers" "$scenario_dir/answer-before"
   : >"$scenario_dir/calls.jsonl"
   status=0
   /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err" || status=$?
   assert_no_rejected_calls
   after=$(setup_order_snapshot "$blocked")
   [[ -z $blocked ]] || chmod "$original_mode" "$blocked"
   [[ $after == "$before" ]] || { echo "止めたのに共有・プロジェクトのファイルや権限が変わった行: $id" >&2; exit 1; }
   [[ $status == 1 ]] || { echo "停止の終了コードが違う行: $id ($status)" >&2; exit 1; }
   grep -qF -- "$message" "$scenario_dir/err"
   [[ -z $blocked ]] || grep -qF -- "$blocked" "$scenario_dir/err"
   if [[ $refusal == project-id-shift ]]; then
    jq -es '[.[] | select(.[0:2]==["project","list"])] | length==3' "$scenario_dir/calls.jsonl" >/dev/null
    rm "$scenario_dir/project-id-shift"
   fi
   if [[ $refusal == gh-empty-unreadable ]]; then
    grep -qF '読み取りと探索の権限' "$scenario_dir/err"
    rm "$gh_empty/.hidden"
   fi
   cmp -s "$answers" "$scenario_dir/answer-before"
   jq -e --slurpfile before "$scenario_dir/first-db.json" '. == $before[0]' "$scenario_dir/db.json" >/dev/null
   ! jq -es 'any(.[]; .[1]=="create" or .[1]=="update" or .[1]=="import" or .[1]=="trigger-add" or .[0:3]==["agent","env","set"] or .[0:3]==["agent","skills","set"] or .[0:3]==["squad","member","add"])' "$scenario_dir/calls.jsonl" >/dev/null
  fi
  /bin/bash "$test_dir/package/setup.sh" <"$scenario_dir/input" >"$scenario_dir/out" 2>"$scenario_dir/err"
  assert_no_rejected_calls
  [[ $(setup_order_snapshot) == "$installed" ]] || { echo "流し直しても全件がそろわない行: $id" >&2; exit 1; }
  jq -e --slurpfile before "$scenario_dir/first-db.json" '. == $before[0]' "$scenario_dir/db.json" >/dev/null
  echo "PASS host: setup.sh の更新順 $id"
 done <"$root/tests/fixtures/host-update-order.tsv"
 [[ $rows == $(awk -F '\t' '$2=="setup" {count++} END {print count+0}' "$root/tests/fixtures/host-update-order.tsv") ]]
}

runtime_selections=claude
runtime_part=host-order
source "$root/tests/setup-runtimes-test-lib.sh"
