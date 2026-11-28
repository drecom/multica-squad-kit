# 何も変更しない事前確認。
check_tools() {
	local tool missing=0
	for tool in multica jq gh git zip unzip ps; do
		if ! command -v "$tool" >/dev/null; then
			case $(uname -s):$tool in
			Darwin:multica) ui_error 'multica がありません。Homebrew で brew install multica-ai/tap/multica を実行してください。' ;;
			Darwin:*) ui_error "$tool がありません。macOS の標準の道具を確認し、Homebrew の道具は brew install $tool で導入してください。" ;;
			Linux:multica) ui_error 'multica がありません。公式の Linux 向け導入手順 https://github.com/multica-ai/multica/blob/main/CLI_INSTALL.md に従って導入してください。Homebrew は必須ではありません。' ;;
			Linux:*) ui_error "$tool がありません。Ubuntu では sudo apt-get install jq gh git zip unzip procps を実行してください。他の Linux ではディストリビューションのパッケージで導入してください。" ;;
			esac
			missing=1
		fi
	done
	if [[ ! -x /bin/bash || ! -x /bin/zsh ]]; then
		ui_error '/bin/bash と /bin/zsh が必要です。Ubuntu では sudo apt-get install bash zsh、macOS では標準のシェルを確認してください。'
		missing=1
	fi
	if ! python3 -c 'import tomllib; from zoneinfo import ZoneInfo; ZoneInfo("UTC"); ZoneInfo("Asia/Tokyo")' >/dev/null 2>&1; then
		ui_error 'TOML と時刻の確認に Python 3.11 以上（tomllib）とタイムゾーンデータが必要です。macOS では brew install python、Ubuntu 24.04 では sudo apt-get install python3 tzdata を実行し、python3 のバージョンと PATH を確認してください。'
		missing=1
	fi
	[[ $missing == 0 ]] || die 'manual.md の「受け取る人の準備」に従って道具を入れてから流し直してください。'
	if ! command -v claude >/dev/null && ! command -v codex >/dev/null; then
		die 'claude と codex がありません。利用する組織の手順で Claude Code か Codex CLI を導入し、PATH を確認して流し直してください。'
	fi
}

# 保存済みの答えに選択がない場合は、claude と codex の両方を使う。
uses_runtime() {
	jq -e --arg runtime "$1" 'index($runtime)!=null' >/dev/null <<<"${runtimes:-[\"claude\",\"codex\"]}"
}

# StopFailure、CLAUDE_CODE_MAX_TURNS、auth status --json の期限を確認した最も古いバージョン。
claude_min_version=2.1.322

# `claude --version` の先頭の行を x.y.z として読み、最低以上かを見る。古いときも読めないときも失敗にする。
# 出力は写さない。
check_claude_version() {
	local output version_re='^([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})([^0-9.]|$)' min_major min_minor min_patch
	IFS=. read -r min_major min_minor min_patch <<<"$claude_min_version"
	output=$(claude --version 2>/dev/null) || output=
	output=${output%%$'\n'*}
	if [[ ! $output =~ $version_re ]]; then
		ui_error "claude --version からバージョンを読めません。Claude Code の最低のバージョンは $claude_min_version です。Claude Code を確認して新しくしてください。"
		return 1
	fi
	local major=$((10#${BASH_REMATCH[1]})) minor=$((10#${BASH_REMATCH[2]})) patch=$((10#${BASH_REMATCH[3]}))
	if ((major < min_major || (major == min_major && (minor < min_minor || (minor == min_minor && patch < min_patch))))); then
		ui_error "Claude Code $major.$minor.$patch は、最低のバージョン $claude_min_version より古いです。Claude Code を新しくしてください。"
		return 1
	fi
}

check_runtime_tools() {
	local tool missing=0
	for tool in claude codex; do
		uses_runtime "$tool" || continue
		if ! command -v "$tool" >/dev/null; then
			ui_error "$tool がありません。利用する組織の手順でエージェント用のランタイムを導入し、PATH を確認してください。"
			missing=1
		elif [[ $tool == claude ]] && ! check_claude_version; then
			missing=1
		fi
	done
	[[ $missing == 0 ]]
}

mc() { MULTICA_SERVER_URL="$server_url" MULTICA_WORKSPACE_ID="${workspace_id:-}" multica "$@"; }

# 接続先の質問とログインの案内は questions.sh。

read_list() {
	local kind=$1 raw
	shift
	raw=$(mc "$@" --output json) || die "$kind を取得できませんでした。"
	case $kind in
	ワークスペース) jq -e 'type=="array" and all(.[]; (.id|type=="string" and test("^[A-Za-z0-9_-]+$")) and (.name|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	プロジェクト) jq -e 'type=="array" and all(.[]; (.id|type=="string" and test("^[A-Za-z0-9_-]+$")) and (.title|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	リポジトリ) jq -e 'type=="array" and all(.[]; .url|type=="string" and length>0)' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	メンバー) jq -e 'type=="array" and all(.[]; (.user_id|type=="string" and test("^[A-Za-z0-9_-]+$")) and (.name|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	esac
	printf '%s\n' "$raw"
}

# スクワッドだけは既存の大文字・小文字の表記を保って引き継ぐ。
squad_named() {
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0) and (.name|type=="string" and length>0))' >/dev/null <<<"$1" || die 'スクワッド一覧の応答が不正です。'
	matches=$(jq -c --arg name "$2" '[.[] | select((.name|ascii_downcase)==($name|ascii_downcase))]' <<<"$1")
	[[ $(jq length <<<"$matches") -le 1 ]] || die "大文字小文字の違いだけのスクワッドが複数あります: $2"
}
