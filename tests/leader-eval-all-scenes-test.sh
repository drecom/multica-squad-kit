#!/usr/bin/env bash
# リーダーの評価の場面の形と、流す仕組みを、本物のモデルを呼ばずに確認する。
# この部分は、置いてある全場面をスタブで流し、場面ごとの結果と外した役が指示に残らないことを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/leader-eval-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
eval_dir="$root/tests/leader-eval"
scenes_dir="$eval_dir/scenes"
helper=(python3 -I -B "$eval_dir/leader_eval.py")
present=
for dir in "$scenes_dir"/*/; do present="$present $(basename "$dir")"; done

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
printf '結果を書きます [@member1](mention://member/member1)\n' >tmp/c2.md
squad-task-post issue-shop-1 --status in_review --content-file tmp/c2.md --parent comment-2 >/dev/null
echo '{"type":"result","result":"done","is_error":false,"permission_denials":[]}'
EOF2
chmod +x "$stub_bin/claude"
export STUB_LOG="$test_dir/stub.log"
# テストの一時ディレクトリはリポジトリの tmp/ の下で、スタブの claude は祖先の指示を読まない。祖先の確認は後で別に確認する
export LEADER_EVAL_SKIP_ANCESTOR_CHECK=1

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
