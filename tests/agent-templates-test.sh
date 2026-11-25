#!/usr/bin/env bash
# ひな形の契約だけを、全構成で確認する。確認するのは、構成ごとに残る役、役の欄、差し込みとマーク、大きさ、機械やほかのファイルが読む文字列、構成による出し分けである。
# 役の指示・共通スキル・参照の文や句は、固定の文字列で確認しない。役が文に従うかは tests/leader-eval/ の範囲である。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/agent-templates.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
roles='orchestrator planner designer claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal code-reviewer ux-reviewer security-reviewer performance-reviewer qa ci-monitor usage-monitor dependabot-merger'

# 無いことの確認。`! grep` は set -e では失敗にならないので、見つかったら自分で止める。
absent() {
	if grep "$@" >/dev/null; then
		echo "あってはならない語句があります: $*" >&2
		exit 1
	fi
}

source "$root/lib/render.sh"
render() {
 template_filter "$1" "$3" >"$test_dir/filter" || return
 if [[ ${4:-0} == 1 ]]; then cat "$test_dir/filter"; return; fi
 jq -Rn '[inputs | split("\t") | {(.[0]): (.[1:]|join("\t"))}] | add' <"$2" >"$test_dir/values.json"
 template_apply "$test_dir/values.json" "$test_dir/filter"
}

# 構成による出し分けの表。ひな形の条件の塊（IF から ELSE か ENDIF まで、ELSE から ENDIF まで）ごとに 1 行を置く。入れ子の IF だけを包む枝は数えない。
# 1 行は「展開したファイル|条件」である。展開したファイルは、役の名前か squad・autopilots。
# 条件は、塊を包む IF を外側から順に読んだまとまりを ' & ' でつなぐ。まとまりは役かランタイムのマーク（runtime-claude・runtime-codex）の並びで、どれかが有効なら成り立ち、先頭の ! で反転する。ELSE の側は、その IF のまとまりに ! を付ける。
# 同じファイルに同じ条件の塊が 2 つ以上あれば、その数だけ行を置く。塊の中の文言は見ない。新しい出し分けを足したら、ここに行を足す。
cat >"$test_dir/branch-table" <<'BRANCH_TABLE'
ci-monitor|runtime-codex
ci-monitor|!runtime-codex
ci-monitor|orchestrator
ci-monitor|orchestrator
claude-fixer|orchestrator
claude-implementer|orchestrator
claude-principal|!planner
claude-principal|!designer
claude-principal|planner
claude-principal|!planner
claude-principal|!planner
claude-principal|!security-reviewer
claude-principal|!planner
claude-principal|orchestrator
code-reviewer|runtime-codex & codex-implementer
code-reviewer|runtime-codex & !codex-implementer
code-reviewer|!runtime-codex
code-reviewer|orchestrator
codex-fixer|orchestrator
codex-implementer|orchestrator
codex-principal|!planner
codex-principal|!designer
codex-principal|planner
codex-principal|!planner
codex-principal|!planner
codex-principal|!security-reviewer
codex-principal|!planner
codex-principal|orchestrator
dependabot-merger|runtime-codex
dependabot-merger|!runtime-codex
dependabot-merger|orchestrator
designer|runtime-claude
designer|!runtime-claude
designer|planner
designer|!planner
designer|orchestrator
designer|planner
orchestrator|runtime-claude
orchestrator|!runtime-claude
orchestrator|claude-principal codex-principal
orchestrator|!claude-principal codex-principal
orchestrator|planner
orchestrator|!planner
orchestrator|designer
orchestrator|!designer
orchestrator|!designer & claude-principal codex-principal
orchestrator|!designer & !claude-principal codex-principal
orchestrator|claude-implementer & codex-implementer
orchestrator|claude-implementer & !codex-implementer
orchestrator|!claude-implementer
orchestrator|claude-implementer
orchestrator|codex-implementer
orchestrator|claude-fixer
orchestrator|codex-fixer
orchestrator|claude-principal codex-principal
orchestrator|claude-principal codex-principal & claude-principal
orchestrator|claude-principal codex-principal & codex-principal
orchestrator|!claude-principal codex-principal
orchestrator|code-reviewer ux-reviewer security-reviewer performance-reviewer qa
orchestrator|code-reviewer ux-reviewer security-reviewer performance-reviewer qa & code-reviewer
orchestrator|code-reviewer ux-reviewer security-reviewer performance-reviewer qa & ux-reviewer
orchestrator|code-reviewer ux-reviewer security-reviewer performance-reviewer qa & security-reviewer
orchestrator|code-reviewer ux-reviewer security-reviewer performance-reviewer qa & performance-reviewer
orchestrator|code-reviewer ux-reviewer security-reviewer performance-reviewer qa & qa
orchestrator|!code-reviewer ux-reviewer security-reviewer performance-reviewer qa
orchestrator|qa
orchestrator|ci-monitor
orchestrator|!ci-monitor
orchestrator|planner
orchestrator|designer
orchestrator|claude-implementer
orchestrator|codex-implementer
orchestrator|claude-fixer
orchestrator|codex-fixer
orchestrator|claude-principal
orchestrator|codex-principal
orchestrator|code-reviewer
orchestrator|ux-reviewer
orchestrator|security-reviewer
orchestrator|performance-reviewer
orchestrator|qa
orchestrator|ci-monitor
orchestrator|usage-monitor
orchestrator|dependabot-merger
performance-reviewer|runtime-codex & codex-implementer
performance-reviewer|runtime-codex & !codex-implementer
performance-reviewer|!runtime-codex
performance-reviewer|orchestrator
planner|runtime-claude
planner|!runtime-claude
planner|orchestrator
qa|runtime-claude
qa|!runtime-claude
qa|orchestrator
security-reviewer|runtime-codex & codex-implementer
security-reviewer|runtime-codex & !codex-implementer
security-reviewer|!runtime-codex
security-reviewer|orchestrator
usage-monitor|runtime-codex
usage-monitor|!runtime-codex
usage-monitor|runtime-claude & runtime-codex
usage-monitor|runtime-claude & !runtime-codex
usage-monitor|!runtime-claude
usage-monitor|orchestrator
ux-reviewer|runtime-codex & codex-implementer
ux-reviewer|runtime-codex & !codex-implementer
ux-reviewer|!runtime-codex
ux-reviewer|orchestrator
squad|orchestrator
squad|planner
squad|!planner & claude-principal codex-principal
squad|designer
squad|!designer & claude-principal codex-principal & security-reviewer
squad|!designer & claude-principal codex-principal & !security-reviewer
squad|claude-implementer
squad|codex-implementer
squad|orchestrator
squad|orchestrator
squad|orchestrator & claude-principal
squad|orchestrator & codex-principal
squad|code-reviewer
squad|qa ux-reviewer security-reviewer performance-reviewer
squad|qa
squad|ux-reviewer
squad|security-reviewer
squad|performance-reviewer
squad|dependabot-merger
squad|claude-principal codex-principal
squad|code-reviewer
squad|dependabot-merger
squad|orchestrator
autopilots|security-reviewer
autopilots|dependabot-merger
autopilots|usage-monitor
autopilots|usage-monitor & runtime-codex
autopilots|usage-monitor & !runtime-codex
autopilots|usage-monitor & runtime-claude
autopilots|usage-monitor & runtime-claude & runtime-codex
autopilots|usage-monitor & runtime-claude & !runtime-codex
autopilots|usage-monitor & !runtime-claude
BRANCH_TABLE
# 形の照合: ひな形のマークを読み、塊ごとに条件を出す（list）。または塊の直下の行を、塊の番号を持つ 1 行に替える（mark）。
branch_scan() {
	awk -v mode="$1" '
		function cond_of(d,   i, s) {s=cond[1]; for(i=2;i<=d;i++) s=s " & " cond[i]; return s}
		/^<!-- IF .* -->$/ {
			g=$0; sub(/^<!-- IF /,"",g); sub(/ -->$/,"",g)
			depth++; group[depth]=g; cond[depth]=g; seen[depth]=0
			if (mode=="mark") print
			next
		}
		/^<!-- ELSE -->$/ {cond[depth]="!" group[depth]; seen[depth]=0; if (mode=="mark") print; next}
		/^<!-- ENDIF -->$/ {depth--; if (mode=="mark") print; next}
		depth==0 {if (mode=="mark") print; next}
		!seen[depth] {seen[depth]=1; n++; if (mode=="list") print cond_of(depth); else print "@@BLOCK " n "@@"}
	' "$2"
}
branch_template() {
	case $1 in squad|autopilots) echo "$root/common/$1.md" ;; *) echo "$root/common/agents/$1.md" ;; esac
}
group_holds() {
	local cond=$1 invert=0 word hold=0
	case $cond in '!'*) invert=1; cond=${cond#!} ;; esac
	for word in $cond; do
		case $word in
		runtime-claude) if [[ $runtimes == *'"claude"'* ]]; then hold=1; fi ;;
		runtime-codex) if [[ $runtimes == *'"codex"'* ]]; then hold=1; fi ;;
		*) if [[ $enabled == *" $word "* ]]; then hold=1; fi ;;
		esac
	done
	[[ $hold -eq $((1 - invert)) ]]
}
cond_holds() {
	local rest=$1 group
	while :; do
		group=${rest%% & *}
		group_holds "$group" || return 1
		[[ $rest != "$group" ]] || return 0
		rest=${rest#* & }
	done
}
# 表の行を読み込み、ファイルと条件の書き方を照合する。
table_file=(); table_cond=(); table_yes=(); table_no=()
while IFS='|' read -r file cond; do
	case " $roles squad autopilots " in *" $file "*) ;; *) echo "出し分けの表のファイルが不正です: $file|$cond" >&2; exit 1 ;; esac
	rest=$cond
	while :; do
		group=${rest%% & *}
		[[ -n ${group#!} ]] || { echo "出し分けの表の条件が空です: $file|$cond" >&2; exit 1; }
		for word in ${group#!}; do
			case " $roles runtime-claude runtime-codex " in *" $word "*) ;; *) echo "出し分けの表の条件が不正です: $file|$cond" >&2; exit 1 ;; esac
		done
		[[ $rest != "$group" ]] || break
		rest=${rest#* & }
	done
	table_file+=("$file"); table_cond+=("$cond"); table_yes+=(0); table_no+=(0)
done <"$test_dir/branch-table"
# 形の照合: 表とひな形の塊が、ファイルと条件の組と、その数まで一致する。
for name in $roles squad autopilots; do
	branch_scan list "$(branch_template "$name")" | sed "s/^/$name|/"
done | LC_ALL=C sort >"$test_dir/branch-template"
LC_ALL=C sort "$test_dir/branch-table" >"$test_dir/branch-table-sorted"
if ! cmp -s "$test_dir/branch-table-sorted" "$test_dir/branch-template"; then
	echo '出し分けの表とひな形の塊が一致しません。' >&2
	echo '表にない塊（ひな形にあり、表にない。足した人が表に行を足す）:' >&2
	LC_ALL=C comm -13 "$test_dir/branch-table-sorted" "$test_dir/branch-template" | sed 's/^/  /' >&2
	echo 'ひな形にない行（表にあり、ひな形にない）:' >&2
	LC_ALL=C comm -23 "$test_dir/branch-table-sorted" "$test_dir/branch-template" | sed 's/^/  /' >&2
	exit 1
fi
echo "PASS templates: 出し分けの表が、ひな形の塊 ${#table_file[@]} とファイル・条件・数まで一致する"
# 展開の照合: 塊の直下の行を番号の行に替えた写しを展開し、表の読み方で条件が成り立つ塊だけが出る。展開したファイルがその構成にないときは飛ばす。
check_branches() {
	local name i cond
	for name in $roles squad autopilots; do
		[[ -f $test_dir/$scenario/$name ]] || continue
		branch_scan mark "$(branch_template "$name")" >"$test_dir/branch-marked"
		template_filter "$enabled" "$test_dir/branch-marked" | grep -E '^@@BLOCK [0-9]+@@$' >"$test_dir/branch-got" || true
		i=0
		: >"$test_dir/branch-want"
		while IFS= read -r cond; do
			i=$((i + 1))
			if cond_holds "$cond"; then echo "@@BLOCK $i@@" >>"$test_dir/branch-want"; fi
		done < <(branch_scan list "$(branch_template "$name")")
		if ! cmp -s "$test_dir/branch-want" "$test_dir/branch-got"; then
			echo "$scenario の $name の展開が、出し分けの表の条件と合いません。" >&2
			diff "$test_dir/branch-want" "$test_dir/branch-got" >&2 || true
			exit 1
		fi
	done
	for i in "${!table_file[@]}"; do
		[[ -f $test_dir/$scenario/${table_file[$i]} ]] || continue
		if cond_holds "${table_cond[$i]}"; then table_yes[$i]=$((${table_yes[$i]} + 1)); else table_no[$i]=$((${table_no[$i]} + 1)); fi
	done
}
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	enabled=" $roles "
	runtimes='["claude","codex"]'
	case $scenario in
	no-planner) enabled=${enabled/ planner / } ;;
	no-designer) enabled=${enabled/ designer / } ;;
	no-planning) enabled=${enabled/ planner / }; enabled=${enabled/ designer / } ;;
	claude-only) enabled=${enabled/ codex-implementer / }; enabled=${enabled/ codex-fixer / } ;;
	codex-only) enabled=${enabled/ claude-implementer / }; enabled=${enabled/ claude-fixer / } ;;
	runtime-claude-only) enabled=${enabled/ codex-implementer / }; enabled=${enabled/ codex-fixer / }; enabled=${enabled/ codex-principal / } ;;
	runtime-codex-only) enabled=${enabled/ claude-implementer / }; enabled=${enabled/ claude-fixer / }; enabled=${enabled/ claude-principal / } ;;
	no-reviews) for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa; do enabled=${enabled/ $role / }; done ;;
	minimum) enabled=' orchestrator codex-implementer codex-fixer ' ;;
	esac
	case $scenario in runtime-claude-only) runtimes='["claude"]' ;; runtime-codex-only) runtimes='["codex"]' ;; esac
	mkdir "$test_dir/$scenario"
	cat >"$test_dir/values" <<'EOF'
project_key	demo
member_key	member-a
member_name	Owner
project_name	Demo & literal $HOME
project_id	project-a
repository	example/project
repositories	`example/project`、`example/client`
squad_id	squad-a
squad_mention	[@Squad](mention://squad/squad-a)
owner_mention	[@Owner](mention://member/member-a)
EOF
	for role in $enabled; do
		printf 'agent.%s.name\tdemo-%s-member-a\nagent.%s.id\tagent-%s\nagent.%s.mention\t[@Role](mention://agent/agent-%s)\n' "$role" "$role" "$role" "$role" "$role" "$role" >>"$test_dir/values"
	done
	[[ $scenario != all ]] || cp "$test_dir/values" "$test_dir/all-values"
	for file in "$root/common/agents/"*.md; do
		role=$(basename "$file" .md)
		[[ $enabled == *" $role "* ]] || continue
		cp "$test_dir/values" "$test_dir/file-values"
		render "$enabled" "$test_dir/file-values" "$file" 1 >"$test_dir/filtered"
		awk -F': ' '$1=="model" {print "model\t" $2} $1=="thinking_level" {print "thinking_level\t" $2}' "$test_dir/filtered" >>"$test_dir/file-values"
		render "$enabled" "$test_dir/file-values" "$file" >"$test_dir/$scenario/$role"
		grep -qx "name: \"demo-$role-member-a\"" "$test_dir/$scenario/$role"
		grep -qF 'Demo & literal $HOME' "$test_dir/$scenario/$role"
		grep -q '^## このプロジェクトの値$' "$test_dir/$scenario/$role"
		grep -qx -- '- プロジェクトのリポジトリの一覧: `example/project`、`example/client`' "$test_dir/$scenario/$role"
		if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$test_dir/$scenario/$role"; then exit 1; fi
	done
	for config in squad autopilots; do
		render "$enabled" "$test_dir/values" "$root/common/$config.md" >"$test_dir/$scenario/$config"
		if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$test_dir/$scenario/$config"; then exit 1; fi
	done
	grep -qx -- '- プロジェクトのリポジトリの一覧: `example/project`、`example/client`' "$test_dir/$scenario/squad"
	for role in $roles; do
		[[ $enabled != *" $role "* ]] || continue
		if grep -RFq "demo-$role-member-a" "$test_dir/$scenario"; then exit 1; fi
	done
	check_branches
	echo "PASS templates: $scenario の有効な役だけが残り、値を文字列のまま差し込み、出し分けた塊が表の条件に合う"
done
# 10 構成で成り立たないか外れない入れ子の枝のための補助の構成。a〜e は確認せず、その枝を持つ squad だけを展開して、出し分けの表を照合する。
scenario=no-designer-no-security
enabled=" $roles "
enabled=${enabled/ designer / }; enabled=${enabled/ security-reviewer / }
runtimes='["claude","codex"]'
mkdir "$test_dir/$scenario"
render "$enabled" "$test_dir/all-values" "$root/common/squad.md" >"$test_dir/$scenario/squad"
check_branches
# & を含む行は、条件が成り立つ構成と外れる構成を、補助の構成を含めて 1 つ以上ずつ通す。
for i in "${!table_file[@]}"; do
	[[ ${table_cond[$i]} == *' & '* ]] || continue
	[[ ${table_yes[$i]} -ge 1 && ${table_no[$i]} -ge 1 ]] || {
		echo "出し分けの表の条件を通す構成が足りません: ${table_file[$i]}|${table_cond[$i]}（成り立つ ${table_yes[$i]}、外れる ${table_no[$i]}）" >&2
		exit 1
	}
done
echo "PASS templates: 出し分けの表の & を含む行のすべてが、成り立つ構成と外れる構成を持つ"
# 原則・索引・人間の待ちは、役の構成によらず残る。
for dir in "$test_dir/"*/; do
	file=$dir/orchestrator
	[[ -f $file ]] || continue
	[[ $(wc -c <"$file") -le 12288 ]]
	awk '/^## 判断の優先の原則$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/principles"
	[[ $(grep -cE '^[1-7]\. \*\*' "$test_dir/principles") -eq 7 ]]
	# 原則 7 に数え方の行は書かない。数え方は参照のファイルだけに書く。
	absent -qF '往復' "$test_dir/principles"
	absent -qF '同じ失敗' "$test_dir/principles"
	awk '/^## / {print}' "$file" >"$test_dir/headings"
	printf '%s\n' '## 判断の優先の原則' '## 受け取ったら確認すること' '## 場面と手順' '## 重要の基準' '## このスクワッドの役' '## 人間を待つところ' '## このプロジェクトの値' >"$test_dir/want-headings"
	cmp "$test_dir/headings" "$test_dir/want-headings"
	awk '/^## 場面と手順$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/index"
	for ref in $(grep -oE 'leader-[a-z-]+\.md' "$test_dir/index" | sort -u); do
		[[ -s $root/common/skills/squad-handoff/references/$ref ]]
	done
done
echo 'PASS templates: 全構成のリーダーは見出しの並び・索引の参照先・12KB 以内を保つ'
# 思考の深さ: Claude で動くリーダーと修正の役は medium、Codex で動くリーダーは high、QA は medium、Codex の修正の役は high のまま。
for dir in "$test_dir/"*/; do
	scenario=$(basename "$dir")
	[[ -f $dir/orchestrator ]] || continue
	if [[ $scenario == runtime-codex-only ]]; then want=high; else want=medium; fi
	[[ $(template_field "$dir/orchestrator" thinking_level) == "$want" ]]
	[[ $(template_field "$dir/orchestrator" model) == "$(if [[ $want == high ]]; then echo gpt-6.2-sol; else echo claude-sonnet-5-5; fi)" ]]
	[[ ! -f $dir/claude-fixer ]] || [[ $(template_field "$dir/claude-fixer" thinking_level) == medium ]]
	[[ ! -f $dir/codex-fixer ]] || [[ $(template_field "$dir/codex-fixer" thinking_level) == high ]]
	[[ ! -f $dir/qa ]] || [[ $(template_field "$dir/qa" thinking_level) == medium ]]
done
echo 'PASS templates: 思考の深さは Claude のリーダーと claude-fixer が medium、Codex のリーダーと codex-fixer が high、QA が medium'
runtimes='["claude","codex"]'

# 全分岐で長い方を足した上限を測る。役の相関を無視するので、すべての組み合わせを上回る。
python3 - "$root/common/agents/orchestrator.md" "$root/tests/leader-eval/values.json" <<'PY_SIZE'
import json, re, sys
from pathlib import Path
values = json.loads(Path(sys.argv[2]).read_text())
text = re.sub(r"\{\{([^}]+)\}\}", lambda m: values[m[1]], Path(sys.argv[1]).read_text())
stack = [[0]]
for line in text.splitlines(keepends=True):
    if line.startswith("<!-- IF "):
        stack.append([0])
    elif line.strip() == "<!-- ELSE -->":
        stack[-1].append(0)
    elif line.strip() == "<!-- ENDIF -->":
        size = max(stack.pop())
        stack[-1][-1] += size
    else:
        stack[-1][-1] += len(line.encode())
assert len(stack) == 1
assert stack[0][0] <= 12288, stack[0][0]
print(f"PASS templates: 全分岐の大きさの上限 {stack[0][0]} bytes <= 12KB")
PY_SIZE

# 上限の余白: 役のメンションのリンクは「このスクワッドの役」だけに置き、「このプロジェクトの値」には名前と ID の行、スクワッドと呼ぶ人間のリンク、見張りの 3 役のリンクだけを残す。
for dir in "$test_dir/"*/; do
	file=$dir/orchestrator
	[[ -f $file ]] || continue
	awk '/^## このプロジェクトの値$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/project-values"
	grep -qF '「このスクワッドの役」' "$test_dir/project-values"
	for role in planner designer claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal code-reviewer ux-reviewer security-reviewer performance-reviewer qa; do
		if grep -qE -- "^- $role のメンションのリンク:" "$test_dir/project-values"; then
			echo "$role のメンションのリンクの行が「このプロジェクトの値」に戻っています" >&2; exit 1
		fi
	done
done
for role in ci-monitor usage-monitor dependabot-merger; do
	grep -qE -- "^- $role のメンションのリンク:" "$test_dir/all/orchestrator"
done
echo 'PASS templates: 13 の役のメンションのリンクの行は「このプロジェクトの値」に戻らず、見張りの 3 役のリンクは残る'

# 画像の添付の手順の見出しと、添付のコマンドの形。読む側は、「squad-handoff の「画像を載せる」」と名前で指す qa・実装・修正の役の指示。
image_skill="$root/common/skills/squad-handoff/SKILL.md"
grep -qxF '## 画像を載せる' "$image_skill"
grep -qxF '## 人間に操作を頼む前に' "$image_skill"
awk '/^## 画像を載せる$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$image_skill" >"$test_dir/image-section"
for text in 'gh pr comment' --attach 'multica issue comment add' --attachment; do
	grep -qF -- "$text" "$test_dir/image-section"
done
echo 'PASS image templates: 共通スキルの画像の節の見出しと、添付のコマンドの形を保つ'

# 開始時の確認の見出しと呼び方。読む側は、見出しを名前で指す orchestrator・usage-monitor・ci-monitor・dependabot-merger の指示と、SKILL.md の「実行の始めの確認」。
preflight_section() {
	awk '/^## 実行の始めの確認$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$1"
}
assert_preflight() {
	preflight_section "$1" >"$test_dir/preflight"
	grep -qF -- squad-preflight "$test_dir/preflight"
}
assert_preflight "$root/common/skills/squad-handoff/SKILL.md"
grep -qF 'squad-preflight <タスク>' "$test_dir/preflight"
for dir in "$test_dir/"*/; do
	[[ -f $dir/orchestrator ]] || continue
	first_check=$(awk '/^## 受け取ったら確認すること$/ {inside=1; next} inside && /^- / {print; exit}' "$dir/orchestrator")
		[[ $first_check == *'squad-handoff の「実行の始めの確認」'* ]]
	[[ $first_check == *'squad-preflight <タスク>'* ]]
	for role in ci-monitor dependabot-merger usage-monitor; do
		file=$dir/$role
		[[ -f $file ]] || continue
		assert_preflight "$file"
		grep -qF '[@Owner](mention://member/member-a)' "$test_dir/preflight"
		preflight_line=$(awk '/^## 実行の始めの確認$/ {print NR; exit}' "$file")
		watch_line=$(awk '/squad-(pr-watch|dependabot-merge|usage-check)/ {print NR; exit}' "$file")
		[[ $preflight_line -lt $watch_line ]]
		if [[ $role == ci-monitor ]]; then
			grep -qF -- '--content-file' "$test_dir/preflight"
			grep -qF 'squad-pr-watch unlinked-check <タスク> agent-orchestrator agent-ci-monitor' "$file"
			grep -qF 'squad-pr-watch ci-check <タスク> agent-orchestrator agent-ci-monitor' "$file"
		fi
	done
done
echo 'PASS preflight templates: 共通スキルと全構成のリーダー・見張りに、開始時の確認の見出しと呼び方を残す'

for runtime in claude codex; do
	if [[ $runtime == claude ]]; then expected=claude-sonnet-5-5; else expected=gpt-6.2-sol; fi
	for file in "$test_dir/runtime-$runtime-only/"*; do
		case ${file##*/} in squad|autopilots) continue ;; esac
		role=${file##*/}
		model=$(template_field "$file" model)
		if [[ $role == *-principal ]]; then
			[[ $model == "$(template_field "$test_dir/all/$role" model)" ]]
		elif [[ $role == planner ]]; then
			if [[ $runtime == claude ]]; then [[ $model == claude-fable-5-2 ]]; else [[ $model == gpt-6.2-astra ]]; fi
			[[ $(template_field "$file" thinking_level) == high ]]
		elif [[ $role == designer ]]; then
			if [[ $runtime == claude ]]; then [[ $model == claude-opus-5-5 ]]; else [[ $model == gpt-6.2-sol ]]; fi
			[[ $(template_field "$file" thinking_level) == high ]]
		else [[ $model == "$expected" ]]; fi
		for field in thinking_level max_concurrent_tasks skills; do
			# Codex だけの構成のリーダーは high。Claude を使う構成の medium とは別の値で、上の思考の深さの確認が見る。
			[[ $role == orchestrator && $field == thinking_level && $runtime == codex ]] && continue
			[[ $(template_field "$file" "$field") == "$(template_field "$test_dir/all/$role" "$field")" ]]
		done
	done
done
echo 'PASS templates: 片方だけのランタイムでは設計表のモデルへ移し、思考の深さ（Codex のリーダーを除く）・同時実行数・スキルを保つ'

# 要件を決める役は、Claude を使う構成では Fable 5.2、Codex だけでは GPT-6.2 Astra で、どの構成でも high にする。
for scenario in all no-designer claude-only codex-only no-reviews runtime-claude-only; do
	[[ $(template_field "$test_dir/$scenario/planner" model) == claude-fable-5-2 ]]
	[[ $(template_field "$test_dir/$scenario/planner" thinking_level) == high ]]
done
[[ $(template_field "$test_dir/runtime-codex-only/planner" model) == gpt-6.2-astra ]]
[[ $(template_field "$test_dir/runtime-codex-only/planner" thinking_level) == high ]]
echo 'PASS templates: 要件を決める役は Claude を使う構成で Fable 5.2、Codex だけで GPT-6.2 Astra の high にする'

# 設計の役は、Claude を使う構成では Opus 5.5、Codex だけでは GPT-6.2 Sol で、どの構成でも high にする。
for scenario in all no-planner claude-only codex-only no-reviews runtime-claude-only; do
	[[ $(template_field "$test_dir/$scenario/designer" model) == claude-opus-5-5 ]]
	[[ $(template_field "$test_dir/$scenario/designer" thinking_level) == high ]]
done
[[ $(template_field "$test_dir/runtime-codex-only/designer" model) == gpt-6.2-sol ]]
[[ $(template_field "$test_dir/runtime-codex-only/designer" thinking_level) == high ]]
[[ $(template_field "$test_dir/all/qa" model) == claude-sonnet-5-5 ]]
[[ $(template_field "$test_dir/all/orchestrator" model) == claude-sonnet-5-5 ]]
echo 'PASS templates: 設計の役は Claude を使う構成で Opus 5.5、Codex だけで GPT-6.2 Sol の high にし、ほかの役のモデルは変えない'

printf '<!-- IF runtime-claude -->\nclaude\n<!-- ELSE -->\ncodex\n<!-- ENDIF -->\n<!-- IF planner runtime-codex -->\neither\n<!-- ENDIF -->\n' >"$test_dir/runtime-conditions"
runtimes='["codex"]' template_filter '' "$test_dir/runtime-conditions" >"$test_dir/runtime-result"
printf 'codex\neither\n' >"$test_dir/runtime-want"
cmp "$test_dir/runtime-result" "$test_dir/runtime-want"
echo 'PASS templates: ランタイムのマークを役とは別に評価し、ELSEと役とのOR条件を展開する'

# 読む側: common/monitor/squad-usage-check が、環境変数 USAGE_CHECK_RUNTIMES と CLAUDE_CONFIG_DIR を読む。
# 使用上限の役とオートパイロットの指示が、ランタイムと、Claude を使うときだけの CLAUDE_CONFIG_DIR を渡す。
for scenario in all runtime-claude-only runtime-codex-only; do
	case $scenario in all) expected='claude codex' ;; runtime-claude-only) expected=claude ;; runtime-codex-only) expected=codex ;; esac
	for file in usage-monitor autopilots; do
		grep -qE "USAGE_CHECK_RUNTIMES.*\"$expected\"" "$test_dir/$scenario/$file"
	done
	sed -n '/^## 使用上限の見張り /,$p' "$test_dir/$scenario/autopilots" >"$test_dir/usage-pilot"
	if [[ $scenario == runtime-codex-only ]]; then
		! grep -q 'CLAUDE_CONFIG_DIR' "$test_dir/usage-pilot"
	else grep -q 'CLAUDE_CONFIG_DIR' "$test_dir/usage-pilot"; fi
done
echo 'PASS templates: 使用上限の役とオートパイロットに、選択したランタイムの値と環境だけを残す'

# 読む側: common/monitor/squad-pr-watch の conflicts-check・conflicts・unlinked を、リーダーが leader-pr-checks.md の手順で呼ぶ。
# コンフリクトの状態の確認と規則の入れ直しは別の節で、呼び方を持つ。
pr_ref="$root/common/skills/squad-handoff/references/leader-pr-checks.md"
check_section=$(awk '/^## コンフリクトの状態の確認$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$pr_ref")
rearm_section=$(awk '/^## 規則の入れ直し$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$pr_ref")
grep -qF 'squad-pr-watch conflicts-check <タスク>' <<<"$check_section"
if grep -qF 'squad-pr-watch conflicts <タスク>' <<<"$check_section"; then exit 1; fi
# 手でマージへ回す経路（decide が止まり、解消の引き継ぎのあとに戻る経路）から、conflicts と unlinked を登録できる。
# 最上位の役の有無で分けず、conflicts を unlinked より先に流す。
grep -qF 'squad-pr-watch conflicts <タスク>' <<<"$rearm_section"
grep -qF 'squad-pr-watch unlinked <タスク>' <<<"$rearm_section"
if grep -qF 'squad-pr-watch conflicts-check' <<<"$rearm_section"; then exit 1; fi
before_conflicts=${rearm_section%%squad-pr-watch conflicts <タスク>*}
before_unlinked=${rearm_section%%squad-pr-watch unlinked <タスク>*}
((${#before_conflicts} < ${#before_unlinked}))
state_skill="$root/common/skills/squad-handoff/SKILL.md"
grep -qxF '## PR の状態を書く' "$state_skill"
state_section=$(awk '/^## PR の状態を書く$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$state_skill")
grep -qF 'コンフリクト:' <<<"$state_section"
echo 'PASS templates: 参照は状態の確認と規則の入れ直しを分け、squad-handoff は PR の状態の節を持つ'

# 読む側: リーダーが leader-pr-checks.md の手順どおりに、common/monitor/squad-pr-watch link-check を呼ぶ。
# 紐付けの確認の節が持つ link-check の呼び方と、展開後のリーダーがこの手順へ向く語。
link_section=$(awk '/^## PR の紐付けの確認$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$pr_ref")
grep -qF 'squad-pr-watch link-check <タスク>' <<<"$link_section"
! grep -qF 'multica issue pull-requests' <<<"$link_section"
for dir in "$test_dir/"*/; do
	[[ -f $dir/orchestrator ]] || continue
	grep -qF 'link-check' "$dir/orchestrator"
done
echo 'PASS templates: 紐付けの確認の節に link-check の呼び方を残し、全構成のリーダーがこの手順へ向く'

# 読む側: リーダーが leader-pr-checks.md の手順どおりに、common/monitor/squad-pr-watch の ci-now・conflicts-check と、common/monitor/squad-pr-link の `紐付け:` の判定を読む。
now_section=$(awk '/^## 紐付いていない PR のその場の確認$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$pr_ref")
for phrase in 'squad-pr-watch ci-now <タスク> <リーダーの ID> <きっかけのコメント> [<見張り役の ID>]' 'squad-pr-watch conflicts-check <タスク>' '`紐付け:`'; do
	grep -qF "$phrase" <<<"$now_section"
done
ci_section=$(awk '/^## CI$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$pr_ref")
grep -qF 'squad-pr-watch ci-held <タスク>' <<<"$ci_section"
grep -qF 'squad-pr-watch unlinked <タスク> <きっかけのコメント> [<見張り役の ID>]' <<<"$rearm_section"

periodic_section=$(awk '/^## マージ待ちの定期確認で起きたとき$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$pr_ref")
for phrase in 'squad-pr-watch unlinked-check <タスク> <リーダーの ID>' 'CI <SHA>: 失敗あり'; do
	grep -qF "$phrase" <<<"$periodic_section"
done
# 読む側: 書くのは common/monitor/squad-pr-watch の unlinked。読むのは common/monitor/squad-review-next の decide と、行をコメントに写すリーダー。
# `見張り:` の名前は、同じ語がほかの節にもあるので、行を写す 3 つの節に絞って探す。1 つ目は ### の見出しなので、次の # の行で区切る。
decide_section=$(awk '/^### decide が流すマージの前の確認$/ {inside=1; next} inside && /^#/ {exit} inside {print}' "$pr_ref")
comment_section=$(awk '/^## 人間を呼ぶコメントに添える行$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$pr_ref")
for section in "$decide_section" "$rearm_section" "$comment_section"; do
	grep -qF '`見張り:`' <<<"$section"
done
echo 'PASS templates: 見張り役なしの確認・保留の取得・定期確認に、squad-pr-watch の呼び方と記録の行を残し、見張り: の行を写す 3 つの節が名前を持つ'

for role in code-reviewer security-reviewer performance-reviewer ux-reviewer; do
	grep -qx 'model: claude-sonnet-5-5' "$test_dir/claude-only/$role"
	grep -qx 'model: gpt-6.2-sol' "$test_dir/all/$role"
	grep -qx 'model: gpt-6.2-sol' "$test_dir/codex-only/$role"
	[[ $(grep -c '^model:' "$test_dir/claude-only/$role") == 1 ]]
done
echo 'PASS templates: Codex を外したときだけレビュー 4 役を Claude へ替える'

for role in ci-monitor usage-monitor dependabot-merger; do
	if grep -q '^role:' "$test_dir/all/$role"; then exit 1; fi
	grep -qx 'max_concurrent_tasks: 1' "$test_dir/all/$role"
done
# 見張りの役の指示とオートパイロットが、ホストのスクリプトへ渡す引数と値（squad-pr-watch・squad-dependabot-merge・squad-usage-check）と、setup が登録するオートパイロットの名前。
grep -qF 'squad-pr-watch ci-check <タスク> agent-orchestrator agent-ci-monitor' "$test_dir/all/ci-monitor"
grep -qF 'squad-dependabot-merge example/project project-a list' "$test_dir/all/autopilots"
for token in USAGE_CHECK_PROJECT project-a USAGE_CHECK_MEMBER member-a; do
	grep -qF "$token" "$test_dir/all/autopilots"
done
grep -qF '使用上限の見張り demo-member-a' "$test_dir/all/autopilots"
grep -qF '依存ライブラリの脆弱性チェック demo' "$test_dir/all/autopilots"
if grep -q '^## ' "$test_dir/minimum/autopilots"; then exit 1; fi
echo 'PASS templates: 見張りはスクワッド外でホストの引数を使い、省略時はオートパイロットも消える'

# 読む側: セットアップ（setup.sh と lib/workspace.sh）が common/labels を読み、lib/host.sh が common/codex/config.toml のマークの行を読む。
awk -F'|' '!/^#/ && NF {if(NF!=3 || $2 !~ /^#[0-9a-f]+$/ || length($2)!=7 || seen[$1]++) exit 1; count++} END {if(count!=5) exit 1}' "$root/common/labels"
for label in 開発 運用 検証 指示の改善 重要; do grep -q "^$label|" "$root/common/labels"; done
grep -qx '# multica-squad-kit-managed' "$root/common/codex/config.toml"
grep -qx 'allow_login_shell = false' "$root/common/codex/config.toml"
if grep -Eq 'mcp_config:|max_concurrent_tasks: [2-9]|^skills:.*e2e-test|github-link' "$root/common/agents/"*.md "$root/common/autopilots.md"; then exit 1; fi
echo 'PASS templates: 5 ラベルとマーク付き Codex 設定を持ち、固有の接続やメモリの上限を含めない'

# 最上位の役は、系統ごとに決まったモデルと推論の強さを持ち、読んで指摘するだけにする。
principal_model() { awk -F': ' -v key="$2" '$1==key {print $2}' "$root/common/agents/$1.md"; }
test "$(principal_model claude-principal model)" = claude-fable-5-2
test "$(principal_model codex-principal model)" = gpt-6.2-astra
for role in claude-principal codex-principal; do
	test "$(principal_model "$role" thinking_level)" = xhigh
	test "$(principal_model "$role" skills)" = 'squad-handoff, verify'
	[[ $(principal_model "$role" role) == 最上位のレビュー* ]]
	grep -qF 'squad-review-wait report <タスク> <きっかけのコメント> <ファイル>' "$root/common/agents/$role.md"
	if grep -E '<!-- IF' "$root/common/agents/$role.md" | grep -vqE 'orchestrator|planner|security-reviewer|designer'; then exit 1; fi
	grep -qF '`重要`' "$root/common/agents/$role.md"
	grep -qF '診断:' "$root/common/agents/$role.md"
	grep -qF '直す役:' "$root/common/agents/$role.md"
	grep -qF '  - 診断:' "$root/common/agents/$role.md"
	absent -qF 'ラベル `重要` があるタスクだけで呼ばれます' "$root/common/agents/$role.md"
done
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	[[ ! -f $test_dir/$scenario/claude-principal ]] || grep -qx 'model: claude-fable-5-2' "$test_dir/$scenario/claude-principal"
	[[ ! -f $test_dir/$scenario/codex-principal ]] || grep -qx 'model: gpt-6.2-astra' "$test_dir/$scenario/codex-principal"
	for role in claude-principal codex-principal; do
		file="$test_dir/$scenario/$role"
		[[ -f $file ]] || continue
		grep -qx 'thinking_level: xhigh' "$file"
		grep -q '^description:.*診断' "$file"
		grep -q '^role:.*診断' "$file"
		grep -qxF '診断: <直せる | 人間の判断が要る>' "$file"
		grep -qxF '直す役: <修正の役 | 設計の役 | なし>' "$file"
		# 診断の要約の行の順は、返すものの行の順と同じで、診断の行は設計への指摘の行のあとにある。
		diag_line=$(grep -nxF '診断: <直せる | 人間の判断が要る>' "$file" | head -1 | cut -d: -f1)
		sed -n "$((diag_line - 4)),$((diag_line + 1))p" "$file" >"$test_dir/diag-lines"
		printf '%s\n' '```text' '確認したコミット: <完全な SHA>' '<マーク> <自分のエージェントの名前>: <根本の原因を 1 文で>' '設計への指摘: <あり | なし>' '診断: <直せる | 人間の判断が要る>' '直す役: <修正の役 | 設計の役 | なし>' >"$test_dir/diag-want"
		cmp "$test_dir/diag-lines" "$test_dir/diag-want" || { echo "診断の行の順が違う: $role" >&2; exit 1; }
		# 読む差分を決めるのは、節「受け取ったら最初に確認すること」の文。担当の節にも `見る範囲:` があるので、この節だけを取り出して探す。読む側は最上位の役、書く側は common/monitor/squad-review-next。
		range_section=$(awk '/^## 受け取ったら最初に確認すること$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file")
		for phrase in '`見る範囲:`' '`PR の差分全体`' '`<前の SHA>..<今の SHA>`'; do
			grep -qF -- "$phrase" <<<"$range_section"
		done
		# 担当の節の最終レビューの文も、再確認で見る差分を `見る範囲:` で示す。同じ名前がほかの節にもあるので、この節を取り出して探す。
		duty_section=$(awk '/^## 担当すること・しないこと$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file")
		grep -qF -- '`見る範囲:`' <<<"$duty_section"
	done
done
[[ ! -f $test_dir/runtime-claude-only/codex-principal && ! -f $test_dir/runtime-codex-only/claude-principal ]]
[[ -f $test_dir/runtime-claude-only/claude-principal && -f $test_dir/runtime-codex-only/codex-principal && -f $test_dir/all/claude-principal && -f $test_dir/all/codex-principal ]]
echo 'PASS templates: 最上位の役は、系統ごとに決まったモデルと xhigh を持ち、診断の記録の行を返し、見る範囲: の行で読む差分を決め（担当の節と確認の節の両方）、使わない系統には置かない'

# 要件を決める役がない構成の最上位の役が、見直さないときに返す 3 行。squad-review-wait report がこの順で読む。
for scenario in no-planner no-planning; do
	for role in claude-principal codex-principal; do
		file="$test_dir/$scenario/$role"
		[[ -f $file ]] || continue
		awk '/^確認したコミット: なし（/ {print; getline; print; getline; print}' "$file" >"$test_dir/not-reviewed"
		printf '%s\n' '確認したコミット: なし（<見直さなかった理由>）' '❌ <自分のエージェントの名前>: 要件を見直していない' '設計への指摘: なし' >"$test_dir/not-reviewed-expected"
		cmp "$test_dir/not-reviewed-expected" "$test_dir/not-reviewed"
	done
done
echo 'PASS templates: 要件を決める役がない構成の最上位の役は、見直さないときの 3 行を report が読む順で持つ'

# 読む側: 役の指示（orchestrator と最上位の役）と common/monitor/squad-review-next が、leader-principal.md・leader-dispatch.md の見出しを名前で指す。
# 最上位の役の参照の見出しと、リーダーの重要の基準の見出し。
refs="$root/common/skills/squad-handoff/references"
for heading in 判断する時機 重要のマークの記録 修正の依頼の数え方 最上位の役を呼ぶところ 返事の待ち方 最上位の役の選び方; do
	grep -qxF "## $heading" "$refs/leader-principal.md"
done
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	grep -qxF '## 重要の基準' "$test_dir/$scenario/orchestrator"
done
for role in claude-principal codex-principal; do
	grep -qF -- "- \`$role\`:" "$test_dir/all/orchestrator"
done
for role in orchestrator designer squad; do
	[[ -f $test_dir/runtime-claude-only/$role ]] || continue
	if grep -qF 'codex-principal' "$test_dir/runtime-claude-only/$role"; then exit 1; fi
	if grep -qF 'claude-principal' "$test_dir/runtime-codex-only/$role"; then exit 1; fi
done
grep -qF 'claude-principal' "$test_dir/runtime-claude-only/orchestrator"
grep -qF 'codex-principal' "$test_dir/runtime-codex-only/orchestrator"
grep -qxF '## 重要の基準' "$root/skeleton/project.md"
grep -qF '[記入: このプロジェクトで重要なタスクとみなす条件' "$root/skeleton/project.md"
grep -qxF '## ラベル `重要` のあるタスク' "$root/common/agents/designer.md"
echo 'PASS templates: 重要の基準の見出しと系統ごとの役の有無を保ち、最上位の役の参照の見出しを置く'

for broken in unknown-role missing-value unclosed else-twice; do
	case $broken in
	unknown-role) printf '<!-- IF unknown-role -->\ntext\n<!-- ENDIF -->\n' ;;
	missing-value) printf '%s\n' '{{missing_value}}' ;;
	unclosed) printf '<!-- IF planner -->\ntext\n' ;;
	else-twice) printf '<!-- IF planner -->\n<!-- ELSE -->\n<!-- ELSE -->\n<!-- ENDIF -->\n' ;;
	esac >"$test_dir/broken"
	if render "$roles" "$test_dir/values" "$test_dir/broken" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	[[ -s $test_dir/err ]]
done
echo 'PASS templates: 未知の役・値の不足・マークの不整合は展開を失敗させる'

# 挿入した文字列に差し込みやマークがあっても、再解釈しない。
printf '%s\n' '{{project_name}}' >"$test_dir/literal"
printf '%s\n' '{"project_name":"literal {{missing_value}} & $HOME \\ <!-- IF planner -->\nnext"}' >"$test_dir/literal.json"
template_apply "$test_dir/literal.json" "$test_dir/literal" >"$test_dir/literal.out"
jq -jr '.project_name+"\n"' "$test_dir/literal.json" >"$test_dir/literal.want"
cmp "$test_dir/literal.out" "$test_dir/literal.want"
echo 'PASS templates: 差し込んだ値のマーク・記法・改行・引用文字を再解釈しない'

# PR を作った直後の紐付けの呼び方と、失敗の記録の行。読む側は、`紐付けの失敗:` の行を読む common/monitor/squad-review-next と、呼び方を実行する設計・実装の役。
skill="$root/common/skills/squad-handoff/SKILL.md"
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	for role in designer claude-implementer codex-implementer; do
		file="$test_dir/$scenario/$role"
		[[ -f $file ]] || continue
		grep -qF 'squad-pr-link <タスク> <PR の URL>' "$file"
	done
done
sed -n '/^## PR を作る・実装を積む$/,/^### PR の本文の置き場所と順序$/p' "$skill" >"$test_dir/pr-link-procedure"
# 手順のバッククォートの語は、種類に分けて見る。種類ごとの見る・見ないと理由は tests/pr-link-procedure-table.tsv にあり、表の行ごとに手順を 1 か所だけ変えた写しを作って、検査が落ちる・通るを照合する。説明文は固定しない。読む側は common/monitor/squad-pr-link・squad-pr-watch・squad-review-next と leader-run-status.md で、鍵の pr_url と branch を読む。
pr_link_check="$root/tests/pr-link-procedure-check.py"
python3 "$pr_link_check" check "$test_dir/pr-link-procedure"
python3 "$pr_link_check" table "$root/tests/pr-link-procedure-table.tsv" "$test_dir/pr-link-procedure" >"$test_dir/pr-link-table.out"
absent -qF '先頭、結論の行のすぐ次の行に' "$test_dir/pr-link-procedure"
absent -qF '紐付け済みとして飛ばす' "$test_dir/pr-link-procedure"
absent -qF 'PR とタスクは、タスクの画面で URL を指定して紐付ける' "$test_dir/pr-link-procedure"
echo "PASS templates: 全構成で PR 作成直後に squad-pr-link を呼び、手順のバッククォートの語を種類ごとに見て、紐付けの失敗の記録の行と metadata の鍵（pr_url と branch）を保つ（$(<"$test_dir/pr-link-table.out")）"

for heading in 本文の書き方 'PR を作る・実装を積む' 'PR の本文の置き場所と順序' 引き継ぐとき 'レビューと E2E の返事を返す' 'PR にレビューやテストの結果を書く'; do
	grep -qx "#\{2,3\} $heading" "$skill"
done
grep -qF 'codex exec --sandbox read-only --ephemeral' "$test_dir/all/codex-fixer"
absent -qF 'Agent ツールで' "$test_dir/all/codex-fixer"
echo 'PASS templates: 共通スキルが役の指示の参照する見出しを持ち、Codex の修正の役は codex exec で見直す'

# 設計との照合の引き継ぎの行。読む側は、`設計との差:` の行を読む leader-flow.md と leader-dispatch.md、`設計との差の扱い:` の行を読む leader-flow.md・leader-dispatch.md・leader-principal.md。git の形は、実装・修正の役が実行する。
for dir in "$test_dir/"*/; do
	[[ -f $dir/orchestrator ]] || continue
	for role in claude-implementer codex-implementer claude-fixer codex-fixer; do
		file=$dir/$role
		[[ -f $file ]] || continue
		case $role in
		*-implementer)
			awk '/^## push の前の照合$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/design-check"
			;;
		*-fixer)
			awk '/^## push の前の設計との照合$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/design-check"
			;;
		esac
		for phrase in 'git fetch origin <base>' 'git diff origin/<base>...HEAD'; do
			grep -qF -- "$phrase" "$test_dir/design-check"
		done
		awk '/^## 結果の出し方$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/design-result"
		for line in '設計との差: なし' '設計との差: <ファイル> <一覧にない変更か、決めたことと違う文の要約>' '設計との差: 照らす設計なし'; do
			grep -qxF "  $line" "$test_dir/design-result"
		done
	done
	file=$dir/designer
	[[ -f $file ]] || continue
	awk '/^## 設計との差を受けたとき$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/design-handling"
		grep -qF -- '設計との差の扱い: <ファイル> <表に載せる | 戻す | 設計を変える>' "$test_dir/design-handling"
done
echo 'PASS templates: 両系統の実装・修正の役が設計との差の行と git の形を保ち、設計の役が設計との差の扱いの行を返す'

# バグの再現のテスト: 実装の役 2 つの節が、見出し・置き場所・記録の行の形・同じバイト列を保ち、対象外の役に無い。節の説明の文は固定の文字列で確認しない。
# 記録の行の頭 `再現のテスト:` は、docs/bug-repro-test.md の「働いた跡」の pattern `(?m)^- 再現のテスト:` が読む側である。
repro_heading='## バグの再現のテスト'
for role in claude-implementer codex-implementer; do
	file=$root/common/agents/$role.md
	[[ $(grep -cx -- "$repro_heading" "$file") == 1 ]]
	awk -v h="$repro_heading" '$0 == h {inside=1; print; next} inside && /^## / {exit} inside {print}' "$file" >"$test_dir/repro-$role"
	for line in '再現のテスト: `<コマンド>`。直す前: 落ちた（終了コード <数>、<落ちた出力の要点>）。直した後: 通った（終了コード <数>）' '再現のテスト: 書けない（<理由>）。代わりに確認したこと: <再現手順での確認と結果>'; do
		[[ $(grep -cxF -- "$line" "$test_dir/repro-$role") == 1 ]]
	done
	keep_line=$(grep -nx -- '## 変えてよいもの' "$file" | cut -d: -f1)
	repro_line=$(grep -nx -- "$repro_heading" "$file" | cut -d: -f1)
	review_line=$(grep -nx -- '## push の前の照合' "$file" | cut -d: -f1)
	((keep_line < repro_line && repro_line < review_line))
done
cmp -s "$test_dir/repro-claude-implementer" "$test_dir/repro-codex-implementer"
for role in claude-fixer codex-fixer code-reviewer designer; do
	absent -F -- '再現のテスト:' "$root/common/agents/$role.md"
done
echo 'PASS templates: 実装の役 2 つのバグの再現のテストの節は、置き場所・記録の 2 つの行の形・同じバイト列を保ち、修正・コードレビュー・設計の役には無い'

# 再確認での列挙: 前に ❌ を出した部品と依頼の行の部品を列挙し、結果に範囲の行を置く。展開後も 12KB 以内に収める。
for role in code-reviewer ux-reviewer performance-reviewer; do
	for dir in "$test_dir/"*/; do
		[[ -f $dir/$role ]] || continue
		[[ $(wc -c <"$dir/$role") -le 12288 ]]
	done
done
echo 'PASS templates: code・ux・performance のレビューの指示は全構成で 12KB 以内に収まる'

# security-reviewer と設計の役は 12KB 以内に収める。
for role in security-reviewer designer; do
	for dir in "$test_dir/"*/; do
		[[ -f $dir/$role ]] || continue
		[[ $(wc -c <"$dir/$role") -le 12288 ]]
	done
done
# 最上位の役だけ 16384 にする。診断の種類と行の形を指示に置くため、測った最大 14645 に余裕を見た。ほかの役は 12288 のまま。
for role in claude-principal codex-principal; do
	for dir in "$test_dir/"*/; do
		[[ -f $dir/$role ]] || continue
		[[ $(wc -c <"$dir/$role") -le 16384 ]]
	done
done
echo 'PASS templates: security-reviewer と設計の役は 12KB 以内、最上位の役は 16KB 以内に収まる'

# 設計の役が返す記録の行。読む側は、`直したあとの返し先:` と `重要のマーク:` を読む leader-principal.md の手順。
grep -qF '直したあとの返し先: スクワッド' "$test_dir/all/designer"
grep -qF '重要のマーク:' "$test_dir/all/designer"
echo 'PASS templates: 設計の役の指示が、見せ直しの返し先と重要のマークの記録の行を読む'

# セットアップが起票した記入のタスクの metadata（squad_kit_task）を、役が探すマークにする。
sed -n '/^## 記入が足りずに止まるとき$/,/^## 人間を呼んで止まるとき$/p' "$skill" >"$test_dir/unfilled-stop"
grep -qx '## 記入が足りずに止まるとき' "$test_dir/unfilled-stop"
for phrase in 'squad_kit_task=project-instructions' 'squad_kit_task=repository-change'; do
	grep -qF "$phrase" "$test_dir/unfilled-stop"
done
echo 'PASS templates: 共通スキルの未記入の案内が、記入のタスクのマークを持つ'

verify_skill="$root/skeleton/.agents/skills/verify/SKILL.md"
for phrase in 推測して実行せず '未記入や未実行は成功にしません' 'squad-handoff の「記入が足りずに止まるとき」'; do
	grep -qF "$phrase" "$verify_skill"
done
echo 'PASS templates: 検証スキルのひな形は推測と成功扱いを禁じ、共通スキルの返し方へ案内する'

# 指示にはリポジトリの一覧が必要である。
awk -F '\t' '$1!="repositories"' "$test_dir/values" >"$test_dir/without-list"
if render 'orchestrator codex-implementer codex-fixer' "$test_dir/without-list" "$root/common/agents/orchestrator.md" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q '値が足りない: repositories' "$test_dir/err"
echo 'PASS templates: 全構成でリポジトリの一覧を渡し、単一の値だけでは一覧の欠落を補わない'

# リーダーの手順は、スキルの参照のファイルに置く。スキルは展開しないので、マークも差し込みも持たない。
refs="$root/common/skills/squad-handoff/references"
for name in flow dispatch principal review-wait pr-checks run-status; do
	[[ -s $refs/leader-$name.md ]]
	if grep -qE '<!-- IF|\{\{' "$refs/leader-$name.md"; then exit 1; fi
done
echo 'PASS templates: リーダーの手順の参照 6 件がスキルにあり、展開のマークも差し込みも持たない'

# 読む側: common/monitor/squad-review-wait が `返事を待つ役:` の行を読み、リーダーが leader-review-wait.md の手順で squad-review-wait を呼ぶ。
# 返事を待つ役の手順が持つ squad-review-wait の呼び方と依頼の行。
for phrase in 'squad-review-wait watch' 'squad-review-wait proceed' 'squad-review-wait status' '返事を待つ役:' '確認するコミット:' '返事の待ち: 次に進む'; do
	grep -qF "$phrase" "$refs/leader-review-wait.md"
done
echo 'PASS templates: 返事の手順の参照が、squad-review-wait の呼び方と依頼の行を持つ'

# 読む側: リーダーが leader-run-status.md の手順で、multica CLI の runs・run-messages を流す。
# 実行の状態を読むコマンドの形。
for phrase in 'runs <タスク> --active' '--siblings' 'run-messages' '--help'; do
	grep -qF -- "$phrase" "$refs/leader-run-status.md"
done
echo 'PASS templates: 進捗と停止の参照が、実行の状態を読むコマンドの形を持つ'
grep -qF -- 'squad-pr-watch conflicts-check' "$refs/leader-pr-checks.md"
echo 'PASS templates: PR の状態の参照が、conflicts-check の呼び方を持つ'
for phrase in 'squad-pr-watch link-check <タスク>' '紐付けていません:'; do
	grep -qF -- "$phrase" "$refs/leader-pr-checks.md"
done
echo 'PASS templates: PR の紐付けの参照が、link-check の呼び方と「紐付けていません:」の行を持つ'

# 使用率の待ちの呼び方。リーダーが squad-usage-wait へ渡す形。
for phrase in 'squad-usage-wait pick <タスク> <implement | fix>' 'squad-usage-wait answer <タスク> <工程>'; do
	grep -qF -- "$phrase" "$refs/leader-dispatch.md"
done
if grep -qF -- '使用率の待ちの延長: <工程>。決めた人: <名前>' "$refs/leader-dispatch.md"; then
	echo 'FAIL templates: leader-dispatch.md が、使用率の待ちの延長の行を書く指示を持つ' >&2
	exit 1
fi
if grep -qF -- '質問だけでは待ち始めの時刻は新しくならない' "$refs/leader-dispatch.md"; then
	echo 'FAIL templates: leader-dispatch.md が、延長の行の指示の文を持つ' >&2
	exit 1
fi
echo 'PASS templates: 振り分けの参照が squad-usage-wait の呼び方を持ち、延長の行を書く指示を持たない'
for phrase in 'squad-usage-wait pick <タスク> principal' '見直しの種類:' '重要のマーク:' '修正の依頼: <N> 回目' '設計の変更: 実装を始めたあと'; do
	grep -qF -- "$phrase" "$refs/leader-principal.md"
done
for phrase in 'ci-wait <タスク>' 'ci-wait-clear <タスク>' 'マージの依頼: <head の完全な SHA>'; do
	grep -qF -- "$phrase" "$refs/leader-pr-checks.md"
done
grep -qF '| 要件定義 | Fable 5.2 | Fable 5.2 | GPT-6.2 Astra |' "$root/manual.md"
grep -qF '最上位の役が、人間の用意した要件を次の役へ回す前に見直す' "$root/manual.md"
# 手引きの「片方だけのランタイムで動かす」の表の設計の行は Opus 5.5・Opus 5.5・GPT-6.2 Sol で、最上位のモデルで動かす役に設計の役を挙げない。
[[ $(grep -c '^| 設計 | Opus 5.5 | Opus 5.5 | GPT-6.2 Sol |$' "$root/manual.md") -eq 1 ]]
[[ $(grep -c '^| 要件定義 | Fable 5.2 | Fable 5.2 | GPT-6.2 Astra |$' "$root/manual.md") -eq 1 ]]
[[ $(grep -c '要件定義の役と設計の役' "$root/manual.md") -eq 0 ]]
echo 'PASS templates: 手引きの表の設計の行が Opus 5.5・Opus 5.5・GPT-6.2 Sol で、最上位のモデルで動かす役は要件定義の役だけ'

# 共通 4 は指示から外した。リーダーの指示に残さない。
for dir in "$test_dir/"*/; do
	file=$dir/orchestrator
	[[ -f $file ]] || continue
	absent -qF '共通 4' "$file"
	absent -qF '手戻りが設計と要件の食い違いを表すリスク' "$file"
done
# 最上位の役の参照が持つ記録の行。読む側は、leader-principal.md と leader-flow.md の手順で、`見直しの種類:` と `手戻りの見直し:` は common/monitor/squad-review-next と squad-cli-lib も読む。
for phrase in '見直しの種類:' '重要のマーク:' '手戻りの見直し:' '修正の続行の確認:' '修正の依頼:' '設計を用意した人:'; do
	grep -qF -- "$phrase" "$refs/leader-principal.md"
done
grep -qF '修正の続行の確認:' "$refs/leader-flow.md"
# `見る範囲:` の行は、common/monitor/squad-review-next が最終レビューの依頼に書いて頼み直しのときに読み、最上位の役が読む差分を決める。名前も値の形も 1 行で守る。
grep -qxF '見る範囲: <PR の差分全体 | <前の SHA>..<今の SHA>>' "$refs/leader-principal.md"
# 流れと振り分けの参照は、共通 4 を使わない。
absent -qF '共通 4' "$refs/leader-flow.md"
absent -qF '共通 4' "$refs/leader-dispatch.md"
absent -qF '共通 4' "$test_dir/all/designer"
absent -qF 'マークの判断と重なるとき' "$refs/leader-flow.md"
echo 'PASS templates: 最上位の役・流れの参照が、スクリプトの呼び方と記録の行（見る範囲: の行を含む）を持ち、使わない共通 4 の語を持たない'

# 読む側: リーダーと最上位の役が leader-principal.md の見出しを名前で指し、common/monitor/squad-review-next が依頼の行を読む。
# security-reviewer への依頼: 見出し、判断の行、表の確認の行、2 つの役の待ち、見せ直し、基準を全部並べる記録の行。
for heading in 'security-reviewer への依頼' '2 つの役の結果の扱い' '見せ直し'; do
	grep -qxF "### $heading" "$refs/leader-principal.md"
done
for phrase in '共通 2 の判断: <当たる | 当たらない>。理由: <1 文>' '入力と信頼の表の確認: 頼む' '直したあとの返し先: スクワッド' '見せ直し: 1 回目'; do
	grep -qF -- "$phrase" "$refs/leader-principal.md"
done
echo 'PASS templates: 最上位の役の参照が、security-reviewer への依頼の見出しと記録の行を持つ'

# 設計の文書 docs/principal-review.md が指す参照の見出し。
grep -qF 'planner-requirements.md#役を置かない構成の要件の見直し' "$root/docs/principal-review.md"
# 作業先を決める指示は、metadata を読む古い言い方に戻さない。
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	absent -qF '振り分け前に metadata' "$test_dir/$scenario/orchestrator"
done
echo 'PASS templates: 設計の文書が指す参照の見出しがあり、リーダーは振り分け前に metadata を読む古い指示を持たない'

# レビューと E2E の返事: 返事を書く役は report で返し、設計への指摘の行を持つ。次の依頼は common/monitor/squad-review-next の decide が書き、リーダーは決められないときだけ起きる。
handoff_skill="$root/common/skills/squad-handoff/SKILL.md"
grep -qF -- '設計への指摘: <あり | なし>' "$handoff_skill"
for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-principal codex-principal; do
	grep -qF 'squad-review-wait report <タスク> <きっかけのコメント> <ファイル>' "$test_dir/all/$role"
done
for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-principal codex-principal; do
	grep -qF '`設計への指摘: あり`' "$test_dir/all/$role"
	grep -qF '`設計への指摘: なし`' "$test_dir/all/$role"
done
grep -qF -- '`squad-review-next decide`' "$refs/leader-review-wait.md"
grep -qF '`--leader <ID>`' "$refs/leader-pr-checks.md"
grep -qF 'squad-usage-wait pick <タスク> planner' "$refs/leader-flow.md"
grep -qF 'squad-usage-wait pick <タスク> designer' "$refs/leader-flow.md"
grep -qF '`squad-review-next request`' "$test_dir/all/orchestrator"
echo 'PASS templates: 返事の役は report と設計への指摘の行で返し、リーダーは decide と squad-usage-wait の呼び方を持つ'

# manual.md の「共通 2 の設計の見直し」: 設計の役がない構成で、人間が直す・security-reviewer だけが 1 回見直す・返事の書き方・
# 人間の設計にも入力と信頼の表が要る、の 4 つを同じ項目の中で検査する。文全体ではなく、意味を担う短い句を見る。
# 意味を削れば落ち、言い回しや助詞の手直しでは落ちない。人間が直す・security-reviewer だけに見せ直すは、設計の役がある構成の
# 同じ句と区別するため、「設計の役を置かない構成」の文の中だけで見る。表の句は、ほかの文にもあるため、「人間の設計にも」の文の中だけで見る。
manual_line=$(grep -F -- '- 共通 2 の設計の見直し:' "$root/manual.md")
[[ $(grep -cF -- '- 共通 2 の設計の見直し:' "$root/manual.md") -eq 1 ]]
# manual_sentence <行> <始まりの句>: 始まりの句から最初の「。」までを出す。始まりの句がなければ何も出さない。
manual_sentence() {
	local rest=${1#*"$2"}
	[[ $rest != "$1" ]] || return 0
	printf '%s%s\n' "$2" "${rest%%。*}"
}
manual_no_designer=$(manual_sentence "$manual_line" '設計の役を置かない構成')
manual_human_design=$(manual_sentence "$manual_line" '人間の設計にも')
manual_check() { # $1=見る範囲の名前 $2=範囲の本文 $3..=意味を担う句
	local scope=$1 text=$2 phrase
	shift 2
	[[ -n $text ]] || { echo "FAIL: manual.md の「共通 2 の設計の見直し」に、${scope}がない" >&2; exit 1; }
	for phrase in "$@"; do
		[[ $text == *"$phrase"* ]] || {
			echo "FAIL: manual.md の「共通 2 の設計の見直し」の${scope}に、次の句がない: $phrase" >&2
			exit 1
		}
	done
}
manual_check '「設計の役を置かない構成」の文' "$manual_no_designer" 'security の ❌' '人間が直' 'security-reviewer だけ' '1 回'
manual_check '返事の書き方' "$manual_line" '返事' '「直した」' '「直さずに進める」'
manual_check '「人間の設計にも」の文' "$manual_human_design" '入力と信頼の表'
echo 'PASS templates: manual.md の「共通 2 の設計の見直し」に、設計の役がない構成で人間が直して security-reviewer だけに 1 回見せ直す句、返事の書き方、人間の設計にも入力と信頼の表が要る句がある'

# squad-review-next がマークを読み、squad-cli-lib が前の回: と結果の行の並びを読む。
# 説明文は固定せず、記録の鍵・プレースホルダーと、その並びだけを確認する。
python3 - "$handoff_skill" "$refs/leader-principal.md" "$test_dir/all" <<'PY_RESULT'
import re
import sys
from pathlib import Path

skill, principal, agents = map(Path, sys.argv[1:])
mark = '<マーク> <自分のエージェントの名前>: <結論>'
commit = '確認したコミット:'
design = '設計への指摘:'
text = skill.read_text()
section = text.split('## PR にレビューやテストの結果を書く\n', 1)[1].split('\n## ', 1)[0]
assert mark in section
for symbol in ('❌', '⚠️', '✅'):
    assert re.search(r'^\| ' + symbol + r' \|', section, re.M), symbol
reply = text.split('## レビューと E2E の返事を返す\n', 1)[1].split('\n## ', 1)[0]
assert any(commit in p and mark in p and p.index(commit) < p.index(mark)
           for p in reply.split('\n\n')), '共通スキル: コミット・マークの順'
for role in ('code-reviewer', 'ux-reviewer', 'security-reviewer', 'performance-reviewer',
             'qa', 'claude-principal', 'codex-principal'):
    text = (agents / role).read_text()
    assert mark in text, role
    assert re.search(r'`確認したコミット:`[^\n]*マーク[^\n]*`設計への指摘:`', text), role
    assert '`返事の回:`' in text and '`report`' in text, role
assert '`前の回: <レビューと E2E の回のコメントの ID>`' in principal.read_text()
PY_RESULT
echo 'PASS templates: 通常の結果のマーク・記録の並びと最終レビューの前の回の形を保つ'

# 検証が未実行の結果の行。共通スキルの節が置き、common/monitor/squad-review-next の decide が読む。役のひな形は写さない。
sed -n '/^### 未記入の報告を返す$/,/^### リーダーが報告を受けたとき$/p' "$handoff_skill" >"$test_dir/unfilled-report"
grep -qxF '未実行: 検証スキルが未記入' "$test_dir/unfilled-report"
for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-principal codex-principal; do
	if grep -qF '未実行: 検証スキルが未記入' "$test_dir/all/$role"; then
		echo "FAIL templates: $role のひな形に、共通スキルが持つ未実行の行を写している" >&2
		exit 1
	fi
done
echo 'PASS templates: 未記入の報告を返す節が未実行の行を持ち、役のひな形は写さない'

# 成功の条件の表の見出しと、確認の結果の記録の行。表は設計の役が置き、読む側は、表を読む実装・修正の役とレビューの役の指示（claude-implementer・codex-implementer・claude-fixer・codex-fixer・各レビューの役）と leader-principal.md。確認の結果の行は、リーダーが SKILL.md の「成功の条件の表」の手順で読む。
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	if [[ -f $test_dir/$scenario/designer ]]; then
		file="$test_dir/$scenario/designer"
		for phrase in '### 成功の条件と確認の方法' '| 番号 | 受け入れ条件 | 成功の条件 | 確認の方法 | 確認する人 | フェーズ |'; do
			grep -qF -- "$phrase" "$file"
		done
	fi
	for role in claude-implementer codex-implementer claude-fixer codex-fixer; do
		[[ -f $test_dir/$scenario/$role ]] || continue
		file="$test_dir/$scenario/$role"
		for phrase in '### 成功の条件の確認' '確認したコミット: <完全な SHA>' '結論: <すべて満たす | 満たさない条件がある>' '成功の条件の確認: PR のコメントに置いた（<結論>）' '成功の条件の確認: 表なし'; do
			grep -qF -- "$phrase" "$file"
		done
		case $role in
		*-implementer) grep -qF -- '成功の条件の確認: <フェーズ N>' "$file" ;;
		*-fixer) grep -qF -- '成功の条件の確認: <修正の依頼 N 回目>' "$file" ;;
		esac
	done
done
echo 'PASS templates: 設計の役の成功の条件の表の見出しと、実装・修正の役の確認の結果の記録の行がある'

# 読む側: リーダーと最上位の役が leader-flow.md・leader-principal.md の手順と行の形で、同じ誤りと同じ部品の診断を依頼し、数え直す。
# 同じ誤りと同じ部品の診断は、参照のファイルが手順・行の形・止まる先を持つ。数え方は main の同じ誤り・同じ部品の行に重ねる。
refs="$root/common/skills/squad-handoff/references"
diag_flow_phrases=(
	'#### 診断に入る条件'
	'#### 同じ誤りが続くとき'
	'#### 同じ誤りの対象'
	'#### 数え方の行'
	'#### 診断の検証待ち'
	'#### 修正の依頼の前に確認する順'
	'`診断の依頼: <N> 回目。失敗: <同じ誤り \| 同じ部品> <対象>`'
	'`数え直し: 同じ誤り <対象>。理由: 直った（<確認したこと>）`'
	'`数え直し: 同じ誤りのすべて。理由: <人間の再開 \| 設計の承認し直し>`'
	'`診断の数え直し: 人間の再開`'
	'同じ誤り: <対象> <N> 回目'
)
for phrase in "${diag_flow_phrases[@]}"; do
	grep -qF -- "$phrase" "$refs/leader-flow.md"
done
# 手当ての行の形: 展開した手順に行の形がある。この行の名前と値は、評価の場面 keep-38・keep-68 の [記録] 4 が読む。
render "$roles" "$test_dir/all-values" "$refs/leader-flow.md" >"$test_dir/remedy-flow.md"
grep -qF -- '手当ての種類: <禁止 | 機械判定 | 動作確認 | 文>' "$test_dir/remedy-flow.md"
echo 'PASS templates: 展開した手順に手当ての種類の行の形がある'
# 診断に入る条件が、同じ誤りの N の表より先にある。条件を満たさないリーダーは、今の手順のまま数える。
flow_entry_line=$(grep -nxF -- '#### 診断に入る条件' "$refs/leader-flow.md" | cut -d: -f1)
flow_steps_line=$(grep -nxF -- '#### 同じ誤りが続くとき' "$refs/leader-flow.md" | cut -d: -f1)
((flow_entry_line < flow_steps_line))
# 同じ部品の診断の値は common/ の中で leader-flow.md にだけ書く。診断の回数や N は、ほかのファイルへ写さない。
[[ $(grep -rlF -- '診断を使うとき' "$root/common" | sort -u) == "$refs/leader-flow.md" ]]
# 同じ部品の 3 回目で診断を頼む値は、leader-flow.md のほかの common/ のファイルに写さない（修正の依頼の 2 回目からという decide の停止の理由は別の値）。
absent -rE '同じ部品.{0,30}3 回(目|分)' "$root/common" --exclude=leader-flow.md
# 数え方の行は、同じ失敗: と 往復: を使わない。
absent -rqE '^(同じ失敗|往復): ' "$root/common"
absent -rqF -- '同じ失敗: <種類>' "$root/common"
absent -rqF -- '往復: <役の名前>' "$root/common"
diag_principal_phrases=(
	'見直しの種類: <設計の見直し | 設計と PR の見直し | 最終レビュー | 要件の見直し | 診断>'
	'`次の依頼を決められません: 診断の回はリーダーが扱う`'
)
for phrase in "${diag_principal_phrases[@]}"; do
	grep -qF -- "$phrase" "$refs/leader-principal.md"
done
# 診断の回だけ、decide がリーダーに任せる。往復や検証待ちの止まり方は decide に置かない。
grep -qF -- '| `診断の回はリーダーが扱う` |' "$refs/leader-review-wait.md"
absent -qF -- '往復が続く回はリーダーが扱う' "$refs/leader-review-wait.md"
absent -qF -- '診断のあとの ❌ はリーダーが扱う' "$refs/leader-review-wait.md"
grep -qF -- '[leader-principal.md](leader-principal.md)' "$refs/leader-review-wait.md"
absent -qE '往復が続く|診断のあとの ❌|往復:' "$root/common/monitor/squad-review-next"
echo 'PASS templates: 診断の参照が、診断の見出し・行の形を持ち、同じ失敗: と 往復: の行を使わない'

# 本文が検証のスキルに従うと書く役と、その役が担当するオートパイロットは、検証スキルを受け取る。
# 本文と割り当てがずれると、役が検証の手順を読めずに人間へ問い返す。
cat >"$test_dir/verify-assignment.py" <<'PY_VERIFY'
import re
import sys
from pathlib import Path

agents_dir, autopilots = Path(sys.argv[1]), Path(sys.argv[2])
words = ("検証のスキル", "検証スキル")


def has_verify(path):
    for line in path.read_text().splitlines():
        if line.startswith("skills:"):
            return "verify" in [name.strip() for name in line[len("skills:"):].split(",")]
    return False


missing = []
for path in sorted(agents_dir.glob("*.md")):
    if path.name == "FORMAT":
        continue
    if any(word in path.read_text() for word in words) and not has_verify(path):
        missing.append(path.stem)
for section in re.split(r"^## ", autopilots.read_text(), flags=re.M)[1:]:
    owner = re.search(r"\{\{agent\.([a-z-]+)\.name\}\}", section)
    role = agents_dir / f"{owner[1]}.md" if owner else None
    if role and role.is_file() and any(word in section for word in words) and not has_verify(role):
        missing.append(role.stem)
if missing:
    print("検証スキルを割り当てていない役: " + " ".join(sorted(set(missing))), file=sys.stderr)
    sys.exit(1)
PY_VERIFY
python3 -I "$test_dir/verify-assignment.py" "$root/common/agents" "$root/common/autopilots.md"
# 外した写しで、この確認が失敗し、役のキーが出ることを残す。
cp -R "$root/common/agents" "$test_dir/agents-without-verify"
for role in claude-fixer qa; do
	sed -i.bak 's/^skills: squad-handoff, verify$/skills: squad-handoff/' "$test_dir/agents-without-verify/$role.md"
done
rm -f "$test_dir/agents-without-verify/"*.bak
if python3 -I "$test_dir/verify-assignment.py" "$test_dir/agents-without-verify" "$root/common/autopilots.md" 2>"$test_dir/verify-err"; then
	echo "verify を外した写しで、割り当ての確認が失敗していません" >&2
	exit 1
fi
grep -qF "claude-fixer qa" "$test_dir/verify-err"
echo 'PASS templates: 本文が検証のスキルに従うと書く役と、そのオートパイロットの担当の役は、skills に verify を持ち、外した写しでは役のキーを出して失敗する'

# 依存の監査の結果を分ける表と、役が返す行の形。読む側は、`監査の結果:` と `補助の確認:` の行を読む common/autopilots.md の週次の手順。
audit_role=$test_dir/all/security-reviewer
awk '/^## 依存の監査を頼まれたとき$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$audit_role" >"$test_dir/audit-section"
[[ -s $test_dir/audit-section ]]
for phrase in \
	'| 検出なし |' '| 検出あり |' '| 取得失敗 |' '| 手順なし |' \
	'監査の結果: <依存の名前> <検出なし | 検出あり | 取得失敗 | 手順なし>' \
	'補助の確認: <したことと結果>'; do
	grep -qF -- "$phrase" "$test_dir/audit-section"
done
audit_pilot=$test_dir/all/autopilots
awk '/^## 週 1 回の依存ライブラリの脆弱性チェック /{inside=1; next} inside && /^## / {exit} inside {print}' "$audit_pilot" >"$test_dir/audit-pilot"
grep -E '^1\. ' "$test_dir/audit-pilot" >"$test_dir/audit-step1"
grep -E '^6\. ' "$test_dir/audit-pilot" >"$test_dir/audit-step6"
for phrase in '監査の結果:' '補助の確認:'; do
	grep -qF -- "$phrase" "$test_dir/audit-step6"
done
# 行の形の正本は役の指示にある。週次の指示は、行の形を写さない。
absent -qF '監査の結果: <依存の名前>' "$test_dir/audit-pilot"
echo 'PASS templates: 監査する役の指示と週次の指示に、4 つの結果と 2 つの行の形があり、行の形は役の指示だけに置く'

# 読む側: Git が読む取得・手元の確認のコマンド、見張りに渡す --base、監査と Dependabot の結果の行。
# 承認された docs/default-branch.md の取得失敗の分類と、停止時・空配列時の返答も確認する。
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	pilots=$test_dir/$scenario/autopilots
	for role in security-reviewer dependabot-merger; do
		[[ -f $test_dir/$scenario/$role ]] || continue
		if [[ $role == security-reviewer ]]; then heading='^## 週 1 回の依存ライブラリの脆弱性チェック '
		else heading='^## Dependabot の PR の週次の確認 '; fi
		awk -v heading="$heading" '$0 ~ heading {inside=1; next} inside && /^## / {exit} inside {print}' "$pilots" >"$test_dir/default-branch-pilot"
		pilot=$test_dir/default-branch-pilot
		[[ -s $pilot ]]
		for command in 'git ls-remote --symref origin HEAD' 'git status --porcelain' 'git branch -r --contains HEAD' \
			'git fetch origin +refs/heads/<ブランチ名>:refs/remotes/origin/<ブランチ名>' \
			'git checkout --detach refs/remotes/origin/<ブランチ名>' 'git rev-parse HEAD'; do
			grep -qF -- "$command" "$pilot"
		done
		for token in 'ref: refs/heads/<ブランチ名><タブ>HEAD' 'コマンドの失敗' 'ref: の行がない' 'ref: の行が 2 行以上'; do
			grep -qF -- "$token" "$pilot"
		done
		absent -qE 'main の最新|--ref main|git fetch origin main|git checkout --detach origin/main|FETCH_HEAD|「なし」とだけ返' "$pilot"
		if [[ $role == security-reviewer ]]; then
			grep -qF '依存を監査せず、チェックを done にしない' "$pilot"
			grep -qF '対象ブランチ: <ブランチ名>' "$pilot"
			grep -qF '確認したコミット: <40 桁の SHA>' "$pilot"
			grep -qF '両方を「なし」にする' "$pilot"
			# 報告を読む人が、監査の結果より前に対象を読める順序を確認する。
			grep -qF '`監査の結果:` より前に `対象ブランチ:' "$pilot"
		else
			grep -qF 'squad-dependabot-merge example/project project-a list --base <対象ブランチ>' "$pilot"
			grep -qF 'advance <PR> --base <対象ブランチ> --reviewed-head' "$pilot"
			grep -qF 'PR の確認・追従・マージ・タスクの作成を始めず' "$pilot"
			grep -qF 'squad-dependabot-merge list の失敗:' "$pilot"
			grep -qF '対象ブランチ: なし' "$pilot"
			grep -qF '「対象ブランチ: <ブランチ名>」と「なし」の 2 行' "$pilot"
			grep -qF '対象外のブランチ向け' "$pilot"
			absent -qF 'main に追いつけない' "$pilot"
			awk '/^## 結果の出し方$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$test_dir/$scenario/$role" >"$test_dir/dependabot-result"
			grep -qF '1 行目を `対象ブランチ:` の行にし' "$test_dir/dependabot-result"
			grep -qF 'list が返したすべての PR' "$test_dir/dependabot-result"
			grep -qF '対象ブランチの行と「なし」の 2 行' "$test_dir/dependabot-result"
			absent -qF '「なし」とだけ返す' "$test_dir/dependabot-result"
		fi
	done
done
echo 'PASS templates: 週次の 2 つの指示がデフォルトブランチを取得し、失敗で止まり、対象の行を返す'

# 読む側: 役の指示が指す common/skills/squad-handoff/SKILL.md の節「更新を知らされたときに照合する」を、全役が更新を知らされたときに読む。
# 照合のために役が流す読み取りのコマンドと、報告の行の形。
awk '/^## 更新を知らされたときに照合する$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$handoff_skill" >"$test_dir/reconcile-section"
[[ -s $test_dir/reconcile-section ]]
for phrase in \
	'| 接続先 | `multica auth status`' \
	'| ワークスペース | `multica workspace get --output json`' \
	'| スキルの一覧と ID | `multica skill list --output json`' \
	'| 本文と追加のファイル | `multica skill get <スキルの ID> --with-content --output json`' \
	'| 役への割り当て | `multica agent skills list <エージェントの ID> --output json`' \
	'| 役の指示の更新の時刻 | `multica agent get <エージェントの ID> --output json`' \
	'照合: <役の指示 | 共通スキル | 検証スキル | 割り当て> <変わった | 変わっていない | 読めなかった | 基準なし>'; do
	grep -qF -- "$phrase" "$test_dir/reconcile-section"
done
echo 'PASS templates: 共通スキルの照合の節に、読むコマンド 6 つと照合の行の形がある'

# 読む側: 役の指示（qa・planner・code-reviewer など）が、common/skills/squad-handoff/SKILL.md のこれらの節の見出しを名前で指す。
# 役の指示が参照する、共通スキルの節の見出し。
type_skill="$root/common/skills/squad-handoff/SKILL.md"
for phrase in '## コメントと本文の型' '### 共通の項目名' '### タスクの本文'; do
	grep -qF -- "$phrase" "$type_skill"
done
echo 'PASS templates: 共通スキルに、役の指示が参照するコメントと本文の型の見出しがある'

# 言い回しの決まり: 共通スキルの小節「言い回し」は「本文の書き方」と「コメントと本文の型」の間にあり、6 つの決まりの行を 1 行ずつ持つ。同じ行が STYLE.md にも 1 行ずつある。読む側は、小節を読む全役と、STYLE.md を読む原本の文書を書く人。
phrasing_style="$root/STYLE.md"
body_line=$(grep -nxF '## 本文の書き方' "$type_skill" | cut -d: -f1)
phrasing_line=$(grep -nxF '### 言い回し' "$type_skill" | cut -d: -f1)
types_line=$(grep -nxF '## コメントと本文の型' "$type_skill" | cut -d: -f1)
[[ -n $body_line && -n $phrasing_line && -n $types_line ]]
((body_line < phrasing_line && phrasing_line < types_line))
phrasing_section=$(awk '/^### 言い回し$/ {inside=1; next} inside && /^#/ {exit} inside {print}' "$type_skill")
for name in 事実 足さないもの 確かさ 語 文の分け方 読み直し; do
	rule=$(grep -E -- "^- $name: ." <<<"$phrasing_section")
	[[ $(grep -c . <<<"$rule") == 1 ]]
	[[ $(grep -cxF -- "$rule" "$phrasing_style") == 1 ]]
done
echo 'PASS templates: 共通スキルの小節「言い回し」は本文の書き方の後にあり、6 つの決まりの行が STYLE.md と同じ文字列で 1 行ずつある'

# 役の指示は、型を写さずに squad-handoff の型を指し、使わない名前を持たない。
for role in claude-implementer codex-implementer claude-fixer codex-fixer code-reviewer performance-reviewer security-reviewer ux-reviewer claude-principal codex-principal qa planner; do
	for phrase in 結果へのリンク 推す答え 確認した内容 '確認の行' '1,000 字以内を目安' '3 行以内' '1 件 5 行ほど'; do
		if grep -qF -- "$phrase" "$test_dir/all/$role"; then
			echo "FAIL templates: $role に使わない名前「$phrase」がある" >&2
			exit 1
		fi
	done
done
echo 'PASS templates: 役の指示は、使わない項目名を持たない'

# 消した語句が戻らないことの確認。構成による出し分けは出し分けの表が確認するので、ここでは構成によらず消した語句だけを見る。
for scenario in all no-designer claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	absent -qF '質問は 1 つずつ' "$test_dir/$scenario/planner"
done
for dir in "$test_dir/"*/; do
	if [[ -f $dir/orchestrator ]]; then
		absent -qF '空なら止まる' "$dir/orchestrator"
	fi
	if [[ -f $dir/security-reviewer ]]; then
		absent -qF 'コードではなく' "$dir/security-reviewer"
	fi
	for role in claude-principal codex-principal; do
		if [[ -f $dir/$role ]]; then
			absent -qF '再確認は前の最終レビューからの差分だけを見る' "$dir/$role"
		fi
	done
done
for role in claude-fixer codex-fixer; do
	absent -qF '{{' "$test_dir/all/$role"
done
for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-principal codex-principal; do
	absent -qF 'の形と順序にそろえる。`確認したコミット:` の行の形と置き場所は' "$test_dir/all/$role"
done
absent -qF '人間の承認を得てから修正に戻る' "$refs/leader-principal.md"
judgment=$(awk '/^## 判断する時機$/{on=1; next} on && /^## /{exit} on' "$refs/leader-principal.md")
absent -qF '| 修正を振り分けるとき |' <<<"$judgment"
absent -qF '共通 1〜4' <<<"$judgment"
answer_row=$(grep -F -- '| 待つ、進める | `squad-usage-wait answer' "$refs/leader-dispatch.md")
[[ -n $answer_row ]]
absent -qF -- '120 秒以上' <<<"$answer_row"
echo 'PASS templates: 消した語句や指示が、役の指示と参照に戻っていない'

# 機械やほかのファイルが読む、コマンドの名前と引数の形。読む側は、コマンドを実行する役と、引数を読むホストのスクリプトである。
# 読む側: 要件を決める役がない構成の最上位の役が実行する `multica issue children`（sub-issue の metadata を読む）。
for role in claude-principal codex-principal; do
	grep -qF 'multica issue children <タスク>' "$test_dir/no-planner/$role"
	grep -qF 'metadata の `repository`' "$test_dir/no-planner/$role"
done
# 読む側: 修正の役が実行する git。`--diff-filter=U` と `origin/main...HEAD` は解消の範囲を、`--remerge-diff` はマージの確認を読む。
for role in claude-fixer codex-fixer; do
	grep -qF 'git diff --name-only --diff-filter=U' "$test_dir/all/$role"
	grep -qF 'git diff --name-only origin/main...HEAD' "$test_dir/all/$role"
	grep -qF 'git show --remerge-diff <マージのコミット>' "$test_dir/all/$role"
done
# 読む側: 停止の提案でリーダーが実行する gh。leader-run-status.md の「実行を止める」が、link-check の判定の正規形を渡す。
stop_section=$(awk '/^## 実行を止める$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$refs/leader-run-status.md")
grep -qF 'gh pr view <正規形> --json headRefOid,headRefName' <<<"$stop_section"
absent -qF 'gh pr view <PR の URL>' <<<"$stop_section"
# 読む側: common/monitor/squad-usage-wait が、工程の引数 implement を読む。leader-principal.md の実装の役の選び方が渡す。
grep -qF 'squad-usage-wait pick <タスク> implement' "$refs/leader-principal.md"
# 読む側: 週次の依存の監査（common/autopilots.md）が、重複の判定に multica issue search を ID と別名のそれぞれで実行する。
grep -qF 'multica issue search <ID> --include-closed --output json' "$test_dir/all/autopilots"
# 読む側: leader-run-status.md の `multica issue cancel-task` 等は Multica の CLI が、leader-principal.md の `jq -j .description | shasum -a 256` は jq と shasum が読む。
# コマンドの名前（サブコマンド）は、表にないものを綴りの誤りとして落とし、引数やパイプの形は表の形で始まるものを要る。説明文は固定しない。表と理由は tests/command-forms-table.tsv にあり、表の行ごとに参照を 1 か所だけ変えた写しで落ちる・通るを照合する。
command_forms_check="$root/tests/command-forms-check.py"
python3 "$command_forms_check" check "$root/tests/command-forms-table.tsv" "$root" >/dev/null
python3 "$command_forms_check" table "$root/tests/command-forms-table.tsv" "$root" >"$test_dir/command-forms-table.out"
echo "PASS templates: 機械やほかのファイルが読むコマンドの形を、読む側が実行する指示が持つ。参照のコマンドの名前と形は、表の行ごとに 1 か所だけ変えた写しで照合する（$(<"$test_dir/command-forms-table.out")）"
