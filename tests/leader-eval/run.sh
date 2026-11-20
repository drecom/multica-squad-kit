#!/usr/bin/env bash
# リーダーの指示を、場面ごとに今のバージョンと新しいバージョンで流して比べる。実際のモデルを呼ぶので、手で流す。
# tests/run.sh と CI には入れない。設計は docs/leader-principles.md の「評価」の節。
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
here="$root/tests/leader-eval"
source "$root/lib/render.sh"

usage() {
	cat <<'USAGE'
使い方: bash tests/leader-eval/run.sh [オプション]
  --baseline REF   今のバージョンにする git の参照（既定: origin/main）
  --scenes IDS     流す場面の ID をコンマで区切る（既定: すべて）
  --runs N         1 場面あたりの回数（既定: 3）
  --runtime NAME   claude か codex（既定: claude。合否の判定は claude の結果で決める）
  --role ROLE      orchestrator か principal（既定: orchestrator）。principal は最上位の役（<runtime>-principal）を、
                   principal-scenes の場面で流す。今のバージョンとの比べはなく、新しい指示だけを流す
  --thinking LEVEL 流す役の思考の深さを、ひな形の値ではなく LEVEL にする（high、xhigh など。既定はひな形の値）
  --only WHICH     old か new だけを流す（既定: 両方）
  --old-skills S   base か new（既定: base）。new は、今のバージョンの指示の作業場所にも、
                   新しい指示の squad-handoff を写す。今の指示に新しいスキルを読ませる共存の確認用で、
                   --scenes を省くと compat-scenes の場面を流す
  --jobs N         並列数（既定: 4）
  --timeout SEC    1 回の実行の時間切れ（既定: 900）
  --out DIR        結果を置くディレクトリ（既定: ${TMPDIR:-/tmp} の下の leader-eval.XXXXXX）
USAGE
}

baseline=origin/main
scene_ids=
runs=3
runtime=claude
only=
eval_role=orchestrator
thinking=
old_skills=base
timeout=900
jobs=4
out=
while (($#)); do
	case $1 in
	--baseline) baseline=${2:?}; shift 2 ;;
	--scenes) scene_ids=${2:?}; shift 2 ;;
	--runs) runs=${2:?}; shift 2 ;;
	--runtime) runtime=${2:?}; shift 2 ;;
	--only) only=${2:?}; shift 2 ;;
	--role) eval_role=${2:?}; shift 2 ;;
	--thinking) thinking=${2:?}; shift 2 ;;
	--old-skills) old_skills=${2:?}; shift 2 ;;
	--jobs) jobs=${2:?}; shift 2 ;;
	--timeout) timeout=${2:?}; shift 2 ;;
	--out) out=${2:?}; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done
case $runtime in claude | codex) ;; *) echo "--runtime は claude か codex です" >&2; exit 2 ;; esac
case $only in '' | old | new) ;; *) echo "--only は old か new です" >&2; exit 2 ;; esac
case $old_skills in base | new) ;; *) echo "--old-skills は base か new です" >&2; exit 2 ;; esac
case $eval_role in orchestrator | principal) ;; *) echo "--role は orchestrator か principal です" >&2; exit 2 ;; esac
[[ -z $thinking || $thinking =~ ^[a-z]+$ ]] || { echo "--thinking は小文字の英字です（high、xhigh など）" >&2; exit 2; }
if [[ $eval_role == principal ]]; then
	# 最上位の役には今のバージョンがなく、リーダーの今の指示との共存の確認もない
	[[ -z $only || $only == new ]] || { echo "--role principal は --only new だけです" >&2; exit 2; }
	[[ $old_skills == base ]] || { echo "--role principal は --old-skills を使いません" >&2; exit 2; }
	only=new
fi
[[ $runs =~ ^[1-9][0-9]*$ && $timeout =~ ^[1-9][0-9]*$ && $jobs =~ ^[1-9][0-9]*$ ]] || { echo "--runs、--jobs、--timeout は正の整数です" >&2; exit 2; }
helper=("python3" "-I" "-B" "$here/leader_eval.py")

# 入力の値の検査は、結果のディレクトリの作成や祖先の確認より前に行う。値が不正なときは、置き場所に関わらず、
# どの環境でも同じ理由で止める。
# 場面のディレクトリ。scenes になければ compat-scenes（今の指示との共存の確認）を使う。ID は 2 つの置き場で重ならない。
scene_dir() { # $1=場面の ID
	if [[ $eval_role == principal ]]; then echo "$here/principal-scenes/$1"
	elif [[ -d $here/scenes/$1 ]]; then echo "$here/scenes/$1"; else echo "$here/compat-scenes/$1"; fi
}
# 場面の一覧。ID の指定がなければ、scenes の下をすべて流す。--old-skills new のときは compat-scenes の下をすべて流す。
scene_list=()
if [[ -n $scene_ids ]]; then
	IFS=, read -r -a scene_list <<<"$scene_ids"
else
	default_dir=$here/scenes
	[[ $old_skills == base ]] || default_dir=$here/compat-scenes
	[[ $eval_role != principal ]] || default_dir=$here/principal-scenes
	for dir in "$default_dir"/*/; do [[ -d $dir ]] && scene_list+=("$(basename "$dir")"); done
fi
((${#scene_list[@]})) || { echo "流す場面がありません" >&2; exit 1; }
for id in "${scene_list[@]}"; do
	sdir=$(scene_dir "$id")
	[[ -f $sdir/scene.md && -f $sdir/cli.json ]] || { echo "場面がありません: $id" >&2; exit 1; }
	scene_data=$("${helper[@]}" scene "$sdir/scene.md")
	while IFS= read -r role; do
		[[ " $template_roles " == *" $role "* ]] || { echo "未知の役です: $role ($id)" >&2; exit 1; }
	done < <(jq -r '.excluded_roles[]' <<<"$scene_data")
	for key in ci_monitor planner security_reviewer; do
		jq -e --arg key "$key" 'if has($key) then (.[$key] | type == "boolean") else true end' "$sdir/cli.json" >/dev/null || {
			echo "$key は真偽値で指定してください: $id" >&2; exit 1;
		}
	done
	jq -e 'if has("repositories") then (.repositories | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))) else true end' "$sdir/cli.json" >/dev/null || {
		echo "repositories は OWNER/REPO の文字列の配列で指定してください: $id" >&2; exit 1;
	}
done

# 結果の置き場所は、リポジトリの外の一時ディレクトリにする。リポジトリの根の AGENTS.md や、Multica の作業ディレクトリの
# CLAUDE.md と .claude/skills を、評価のリーダーが祖先として読むと、評価の入力が置き場所で変わるため。
if [[ -z $out ]]; then
	out=$(mktemp -d "${TMPDIR:-/tmp}/leader-eval.XXXXXX")
fi
mkdir -p "$out"
# エージェントが pwd で見るパスと、許可を照らすパスをそろえるため、シンボリックリンクを解く
out=$(cd "$out" && pwd -P)
# 評価で起動するコマンドは、ここで 1 回だけ絶対パスに解決し、同じ値を目印の確認と起動（run-all）の両方に使う。
# 解決は、評価の実行と同じ除外をした PATH で行う（leader_eval.py の resolve_agents）。名前では引き直さない
# プロセス置換を read で読むと、python3 が 3 行を出す前に終わったとき、何も出さずに止まる。いったん変数に受ける
agent_info=$(python3 -I -B "$here/leader_eval.py" agent-paths "$runtime") || { echo "評価のコマンドの解決（agent-paths）が失敗しました" >&2; exit 1; }
{
	IFS= read -r agent_path
	IFS= read -r scorer_path
	IFS= read -r agent_kind
} <<<"$agent_info" || { echo "評価のコマンドの解決（agent-paths）の出力が 3 行ではありません: $agent_info" >&2; exit 1; }
# 祖先に指示やスキルがあれば、どの場面も流さずに終わる。テストのスタブの claude は祖先を読まないので、
# 環境変数 LEADER_EVAL_SKIP_ANCESTOR_CHECK=1 で飛ばせる。ただし、解決した評価のコマンドと採点のコマンドの
# 先頭に目印（LEADER_EVAL_STUB_AGENT）があるスタブのときだけ。呼び出し元から継承しても、本物の CLI では確認を外せない
skip_ancestor_check=
if [[ ${LEADER_EVAL_SKIP_ANCESTOR_CHECK:-} == 1 && $agent_kind == stub ]]; then
	skip_ancestor_check=1
fi
if [[ -z $skip_ancestor_check ]]; then
	found=()
	while IFS= read -r path; do found+=("$path"); done < <(python3 -I -B "$here/leader_eval.py" ancestors "$out")
	if ((${#found[@]})); then
		echo "結果のディレクトリの祖先に、エージェントが読む指示やスキルがあります。評価の入力が変わるので、流しません: $out" >&2
		printf '  %s\n' "${found[@]}" >&2
		echo "別の場所を --out で指定するか、TMPDIR を変えてください" >&2
		exit 1
	fi
fi
[[ -n $agent_path && -n $scorer_path ]] || { echo "評価のコマンド（$runtime と採点の claude）が PATH にありません" >&2; exit 1; }
mkdir -p "$out/scenes" "$out/scene-dirs"
for id in "${scene_list[@]}"; do
	if [[ $eval_role == principal ]]; then
		# 最上位の役の場面は、流す系統の役（<runtime>-principal）を指す。場面の @PRINCIPAL_ID@・@PRINCIPAL_NAME@・
		# @PRINCIPAL_MENTION@ を、values.json のその役の値に置き換えた写しを流す
		rm -rf "$out/scene-dirs/$id"
		mkdir -p "$out/scene-dirs/$id"
		for file in scene.md cli.json; do
			text=$(cat "$(scene_dir "$id")/$file")
			for key in id name mention; do
				value=$(jq -er --arg k "agent.$runtime-principal.$key" '.[$k]' "$here/values.json") || { echo "values.json に agent.$runtime-principal.$key がありません" >&2; exit 1; }
				upper=$(tr '[:lower:]' '[:upper:]' <<<"$key")
				text=${text//@PRINCIPAL_${upper}@/$value}
			done
			printf '%s\n' "$text" >"$out/scene-dirs/$id/$file"
		done
		"${helper[@]}" scene "$out/scene-dirs/$id/scene.md" >"$out/scenes/$id.json"
		continue
	fi
	"${helper[@]}" scene "$(scene_dir "$id")/scene.md" >"$out/scenes/$id.json"
	# 流す側（run-all）は場面の置き場を 1 つしか受け取らないので、流す場面だけを 1 か所に並べる
	ln -sfn "$(scene_dir "$id")" "$out/scene-dirs/$id"
done
# 既定ではすべての役が有効。CLI 見本で false の ci_monitor・planner・security_reviewer と、場面の「外す役」を外す。
# repositories がある場面は、その一覧でも場面ごとの指示を描く。
# どの構成も両方のランタイムを使う。
# モデルと思考の深さだけは、評価するランタイムだけで展開した front matter から読む。
enabled=" $template_roles "
runtimes='["claude","codex"]'
export runtimes

# 指示を描き、作業ディレクトリに置く一式を作る。
prepare() { # $1=old|new
	local which=$1 dest="$out/instructions/$1" source_file scene=${2:-} enabled="$enabled" role values="$here/values.json" scene_cli=
	if [[ -n $scene ]]; then
		dest="$dest/scenes/$scene"
		scene_cli="$(scene_dir "$scene")/cli.json"
		if jq -e '.ci_monitor == false' "$scene_cli" >/dev/null; then enabled=${enabled/ ci-monitor / }; fi
		if jq -e '.planner == false' "$scene_cli" >/dev/null; then enabled=${enabled/ planner / }; fi
		if jq -e '.security_reviewer == false' "$scene_cli" >/dev/null; then enabled=${enabled/ security-reviewer / }; fi
		while IFS= read -r role; do
			enabled=${enabled/ $role / }
		done < <(jq -r '.excluded_roles[]' "$out/scenes/$scene.json")
	fi
	mkdir -p "$dest/skills"
	if [[ -n $scene ]] && jq -e 'has("repositories")' "$scene_cli" >/dev/null; then
		values="$dest/values.json"
		jq --slurpfile scene "$scene_cli" '.repositories = ($scene[0].repositories | map("`" + . + "`") | join("、"))' "$here/values.json" >"$values"
	fi
	if [[ $which == old ]]; then
		git -C "$root" rev-parse --verify --quiet "$baseline^{commit}" >/dev/null || { echo "baseline が見つかりません: $baseline" >&2; exit 1; }
		source_file="$dest/orchestrator.template.md"
		git -C "$root" show "$baseline:common/agents/orchestrator.md" >"$source_file"
		if [[ $old_skills == new ]]; then
			# 今の指示のリーダーが、新しい squad-handoff を読む組み合わせ（共存の確認）
			mkdir -p "$dest/skills/squad-handoff"
			cp -R "$root/common/skills/squad-handoff/." "$dest/skills/squad-handoff/"
		else
			# パイプにすると、macOS の tar が先に終わり、git archive が SIGPIPE で落ちることがあるので、ファイルに書いてから展開する。
			git -C "$root" archive --format=tar -o "$dest/skills.tar" "$baseline" common/skills/squad-handoff
			tar -xf "$dest/skills.tar" -C "$dest/skills" --strip-components=2
			rm -f "$dest/skills.tar"
		fi
	else
		source_file="$root/common/agents/orchestrator.md"
		[[ $eval_role != principal ]] || source_file="$root/common/agents/$runtime-principal.md"
		mkdir -p "$dest/skills/squad-handoff"
		cp -R "$root/common/skills/squad-handoff/." "$dest/skills/squad-handoff/"
	fi
	template_filter "$enabled" "$source_file" >"$dest/filtered.md"
	runtimes="[\"$runtime\"]" template_filter "$enabled" "$source_file" >"$dest/runtime-filtered.md"
	jq -n --arg model "$(template_field "$dest/runtime-filtered.md" model)" \
		--arg thinking "${thinking:-$(template_field "$dest/runtime-filtered.md" thinking_level)}" \
		'{model: $model, thinking_level: $thinking} | if .model == "" or .thinking_level == "" then error("model と thinking_level が読めません") else . end' >"$dest/meta.json"
	template_body "$dest/filtered.md" >"$dest/body.md"
	template_filter "$enabled" "$here/runtime-brief.md" >"$dest/brief.md"
	# 前置きの Agent Identity は、流す役のものにする
	if [[ $eval_role == principal ]]; then
		sed "s/{{agent\.orchestrator\./{{agent.$runtime-principal./g" "$dest/brief.md" >"$dest/brief.principal.md"
		mv "$dest/brief.principal.md" "$dest/brief.md"
	fi
	{ cat "$dest/brief.md"; echo; cat "$dest/body.md"; } >"$dest/instructions.template.md"
	template_apply "$values" "$dest/instructions.template.md" >"$dest/instructions.md"
	if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$dest/instructions.md"; then
		echo "差し込みの残りがあります: $which" >&2
		exit 1
	fi
}

versions=(old new)
[[ -z $only ]] || versions=("$only")
for which in "${versions[@]}"; do
	prepare "$which"
	for id in "${scene_list[@]}"; do
		if jq -e '.ci_monitor == false or .planner == false or .security_reviewer == false or has("repositories")' "$(scene_dir "$id")/cli.json" >/dev/null ||
			jq -e '.excluded_roles | length > 0' "$out/scenes/$id.json" >/dev/null; then prepare "$which" "$id"; fi
	done
done
{
	echo "baseline: $baseline ($(git -C "$root" rev-parse --short "$baseline^{commit}" 2>/dev/null || echo なし))"
	echo "new: working tree ($(git -C "$root" rev-parse --short HEAD))"
	echo "runtime: $runtime"
	echo "old-skills: $old_skills"
	echo "role: $eval_role"
	echo "thinking: ${thinking:-ひな形の値}"
} >"$out/versions.txt"

ids=$(IFS=,; echo "${scene_list[*]}")
versions_csv=$(IFS=,; echo "${versions[*]}")
"${helper[@]}" run-all --out "$out" --scene-ids "$ids" --versions "$versions_csv" --runs "$runs" --jobs "$jobs" \
	--scenes "$out/scene-dirs" --instructions "$out/instructions" --runtime "$runtime" --timeout "$timeout" \
	--agent-path "$agent_path" --scorer-path "$scorer_path"
"${helper[@]}" summary "$out/runs.jsonl" "$out/summary.md"
cat "$out/summary.md"
if [[ $eval_role == principal ]]; then
	"${helper[@]}" usage-table "$out/runs.jsonl" "$out/usage.md"
	cat "$out/usage.md"
fi
echo "結果: $out"
