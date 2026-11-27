#!/usr/bin/env bash
# ZIP のルートで bash tests/guard-git-test.sh を実行する。
# git の認証情報のヘルパーと SSH のコマンドを、本物の GitHub へ送信せずに確認する。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
helper="$root/common/guard/git-credential"
ssh_guard="$root/common/guard/git-ssh"
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/guard-git-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export GUARD_GIT_TEST_DIR="$test_dir"
export SQUAD_KIT_ALLOWED_REPOS="$test_dir/allowed-repos"
printf '%s\n' example/template >"$SQUAD_KIT_ALLOWED_REPOS"
human_dir="$test_dir/human-gh"
mkdir -p "$test_dir/bin" "$test_dir/guard-bin" "$human_dir"
unset GH_CONFIG_DIR SQUAD_KIT_GH_CONFIG_DIR GH_HOST

# ガードの gh（マークがある）と本物の gh の差し替えを、別々の PATH の置き場に置く。
# ヘルパーは、マークのある gh を飛ばして本物を呼ぶ。
cat >"$test_dir/guard-bin/gh" <<'EOF'
#!/usr/bin/env bash
# multica-squad-kit-managed
echo 'ガードの gh が呼ばれた' >>"$GUARD_GIT_TEST_DIR/guard-gh-calls"
exit 1
EOF
cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GUARD_GIT_TEST_DIR/gh-calls"
printf '%s\n' "${GH_CONFIG_DIR-unset}" >>"$GUARD_GIT_TEST_DIR/gh-config-dirs"
cat >"$GUARD_GIT_TEST_DIR/gh-stdin"
printf 'username=fixture\npassword=fixture-token\n'
EOF
# ssh の差し替え。渡された引数を記録するだけで、接続しない。
cat >"$test_dir/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >>"$GUARD_GIT_TEST_DIR/ssh-calls"
echo 'fixture ssh'
EOF
chmod +x "$test_dir/guard-bin/gh" "$test_dir/bin/gh" "$test_dir/bin/ssh"
export PATH="$test_dir/guard-bin:$test_dir/bin:$PATH"

reset_calls() {
	: >"$test_dir/gh-calls"
	: >"$test_dir/gh-config-dirs"
	: >"$test_dir/gh-stdin"
	: >"$test_dir/guard-gh-calls"
	: >"$test_dir/ssh-calls"
}

# git-remote-https という名前の親のもとで、ヘルパーを呼ぶ。
# exec -a で argv[0] を git-remote-https にした bash の子として、ヘルパーを動かす。
as_remote_https() {
	local action=$1 input=$2
	printf '%s' "$input" | (exec -a git-remote-https bash -c 'bash "$1" "$2"; exit $?' git-remote-https "$helper" "$action") \
		>"$test_dir/out" 2>"$test_dir/err"
}
# 親に git-remote-https がない（git credential fill を呼ぶ役の端末と同じ）形で、ヘルパーを呼ぶ。
as_other_parent() {
	local action=$1 input=$2
	printf '%s' "$input" | bash "$helper" "$action" >"$test_dir/out" 2>"$test_dir/err"
}
query() {
	printf 'protocol=%s\nhost=%s\npath=%s\n\n' "${1-https}" "${2-github.com}" "${3-example/template.git}"
}
answers() {
	[[ $(cat "$test_dir/out") == $'username=fixture\npassword=fixture-token' ]]
}
silent() {
	[[ ! -s $test_dir/out && ! -s $test_dir/err ]]
	[[ ! -s $test_dir/gh-calls && ! -s $test_dir/guard-gh-calls ]]
}

# --- 認証情報のヘルパー ---

reset_calls
export SQUAD_KIT_GH_CONFIG_DIR=$human_dir
for path in example/template.git example/template EXAMPLE/Template.git; do
	reset_calls
	as_remote_https get "$(query https github.com "$path")"
	answers
	[[ $(cat "$test_dir/gh-calls") == 'auth git-credential get' ]]
	[[ $(cat "$test_dir/gh-config-dirs") == "$human_dir" ]]
	[[ $(cat "$test_dir/gh-stdin") == "$(query https github.com "$path")" ]]
	[[ ! -s $test_dir/guard-gh-calls ]]
done
echo 'PASS ヘルパー: 許すリポジトリと git-remote-https の親のとき、本物の gh に人の置き場を渡して答える（ガードの gh は呼ばない）'

reset_calls
unset SQUAD_KIT_GH_CONFIG_DIR
GH_CONFIG_DIR="$test_dir/gh-empty" as_remote_https get "$(query)"
answers
[[ $(cat "$test_dir/gh-config-dirs") == "$test_dir/gh-empty" ]]
export SQUAD_KIT_GH_CONFIG_DIR=$human_dir
echo 'PASS ヘルパー: SQUAD_KIT_GH_CONFIG_DIR がなければ、渡された GH_CONFIG_DIR のまま本物の gh を呼ぶ'

for blocked in example/other.git other/template.git example/template.git/extra example/ /example/template.git \
	'example/template.git?x=1' example/template.git/ ../example/template.git 'example/temp late.git' ''; do
	reset_calls
	as_remote_https get "$(query https github.com "$blocked")"
	silent
done
echo 'PASS ヘルパー: 許すリポジトリでないパス・形が違うパスには、何も返さない'

for form in 'http github.com example/template.git' 'ssh github.com example/template.git' \
	'https github.com.evil.example example/template.git' 'https notgithub.com example/template.git' \
	'https outside.example example/template.git' 'https github.com:443 example/template.git'; do
	reset_calls
	# shellcheck disable=SC2086
	as_remote_https get "$(query $form)"
	silent
done
echo 'PASS ヘルパー: github.com の HTTPS でない問い合わせには、何も返さない'

reset_calls
as_remote_https get "$(printf 'protocol=https\nhost=github.com\n\n')"
silent
as_remote_https get ''
silent
echo 'PASS ヘルパー: パスがない問い合わせと空の入力には、何も返さない'

for action in store erase '' unknown; do
	reset_calls
	as_remote_https "$action" "$(query)"
	silent
done
echo 'PASS ヘルパー: get 以外（store・erase・引数なし・未知）には何もしない'

reset_calls
as_other_parent get "$(query)"
silent
echo 'PASS ヘルパー: 親に git-remote-https がなければ、許すリポジトリでも何も返さない'

reset_calls
printf '%s\n' "other/template" >"$SQUAD_KIT_ALLOWED_REPOS"
as_remote_https get "$(query)"
silent
: >"$SQUAD_KIT_ALLOWED_REPOS"
as_remote_https get "$(query)"
silent
rm "$SQUAD_KIT_ALLOWED_REPOS"
as_remote_https get "$(query)"
silent
printf '%s\n' example/template >"$SQUAD_KIT_ALLOWED_REPOS"
echo 'PASS ヘルパー: 許すリポジトリのファイルに載っていない・空・読めないときは、何も返さない'

reset_calls
as_remote_https get "$(query)"
answers
# ガードの gh だけが PATH にあるとき、本物がないので何も返さない。
# 手元にある本物の gh を拾わないよう、PATH はガードの gh と、ヘルパーが使う道具だけにする。
mkdir -p "$test_dir/tools"
for tool in bash cat grep head ps; do
	ln -s "$(command -v "$tool")" "$test_dir/tools/$tool"
done
reset_calls
(PATH="$test_dir/guard-bin:$test_dir/tools" as_remote_https get "$(query)")
silent
echo 'PASS ヘルパー: 本物の gh がなければ、ガードの gh を呼ばずに何も返さない'

# 実際の git が、ヘルパーを git-remote-https の下で呼ぶことを確認する。
# ネットワークは使わず、接続の前に認証情報を問い合わせる環境がないので、プロセスの親子の形だけを確認する。
cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'username=fixture\npassword=fixture-token\n'
EOF
chmod +x "$test_dir/bin/gh"
cat >"$test_dir/ancestors" <<'EOF'
#!/usr/bin/env bash
# 親をたどり、実行ファイルの先頭の語を記録する。
pid=$PPID
while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
	args=$(ps -o args= -p "$pid" 2>/dev/null || true)
	args=${args# }
	printf '%s\n' "${args%% *}" >>"$GUARD_GIT_TEST_DIR/ancestors.log"
	pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
done
exit 0
EOF
chmod +x "$test_dir/ancestors"
: >"$test_dir/ancestors.log"
# 接続先は、手元でつながらない TEST-NET のアドレス。接続の失敗は無視し、ヘルパーが呼ばれたかだけを見る。
GIT_CONFIG_COUNT=3 \
	GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
	GIT_CONFIG_KEY_1=credential.https://github.com.useHttpPath GIT_CONFIG_VALUE_1=true \
	GIT_CONFIG_KEY_2=credential.https://github.com.helper GIT_CONFIG_VALUE_2="!$test_dir/ancestors" \
	GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
	GIT_ASKPASS=/bin/false \
	git -c http.proxy=http://127.0.0.1:9 ls-remote https://github.com/example/template.git >/dev/null 2>&1 || true
if [[ -s $test_dir/ancestors.log ]]; then
	grep -q '^git-remote-https$' "$test_dir/ancestors.log"
	echo 'PASS ヘルパー: 実際の git では、親をたどると git-remote-https がある'
else
	echo 'SKIP ヘルパー: この環境の git は、接続の前にヘルパーを呼ばなかったので、親の名前の確認を飛ばした'
fi

# --- SSH のコマンド ---

ssh_allow() {
	reset_calls
	bash "$ssh_guard" "$@" >"$test_dir/out" 2>"$test_dir/err"
	[[ $(cat "$test_dir/out") == 'fixture ssh' && ! -s $test_dir/err ]]
	jq -se --argjson expected "$(jq -cn --args '$ARGS.positional' -- "$@")" '. == [$expected]' "$test_dir/ssh-calls" >/dev/null
}
ssh_block() {
	local reason=$1
	shift
	reset_calls
	if bash "$ssh_guard" "$@" >"$test_dir/out" 2>"$test_dir/err"; then
		echo "止まらなかった: $*" >&2
		exit 1
	fi
	[[ ! -s $test_dir/out && ! -s $test_dir/ssh-calls ]]
	grep -q '^git push のガード:' "$test_dir/err"
	grep -qF -- "$reason" "$test_dir/err"
}

# 受ける形の表（tests/fixtures/git-ssh-forms.tsv）を入力にして、1 行ごとに扱いを確認する。
# 扱いは pass（本物の ssh に元の引数のまま渡す）か block:<文>（自分の文で止めて ssh を呼ばない）。
forms_file="$root/tests/fixtures/git-ssh-forms.tsv"
form_count=0
trap 'echo "表の行 ${form_id:-?}（${form_desc:-}）が、表の扱いのとおりにならなかった" >&2' ERR
while IFS=$'\t' read -r form_id form_treatment form_args form_desc; do
	[[ -z $form_id || $form_id == '#'* ]] && continue
	form_argv=()
	while IFS= read -r -d '' item; do form_argv+=("$item"); done < <(jq -j '.[] | ., "\u0000"' <<<"$form_args")
	form_count=$((form_count + 1))
	case $form_treatment in
	pass) ssh_allow ${form_argv[@]+"${form_argv[@]}"} ;;
	block:*) ssh_block "${form_treatment#block:}" ${form_argv[@]+"${form_argv[@]}"} ;;
	*) echo "表の行 ${form_id} の扱いが読めない: ${form_treatment}" >&2; exit 1 ;;
	esac
done <"$forms_file"
trap - ERR
(( form_count >= 40 ))
echo "PASS ssh: 受ける形の表 ${form_count} 行が、行ごとの扱いのとおり（通す・許すものだけ渡す・分類できない形は止める）"

printf '%s\n' other/template >"$SQUAD_KIT_ALLOWED_REPOS"
ssh_block 'example/template への SSH の push は止めた' git@github.com "git-receive-pack 'example/template.git'"
: >"$SQUAD_KIT_ALLOWED_REPOS"
ssh_block 'example/template への SSH の push は止めた' git@github.com "git-receive-pack 'example/template.git'"
rm "$SQUAD_KIT_ALLOWED_REPOS"
ssh_block 'example/template への SSH の push は止めた' git@github.com "git-receive-pack 'example/template.git'"
printf '%s\n' example/template >"$SQUAD_KIT_ALLOWED_REPOS"
echo 'PASS ssh: 許すリポジトリのファイルに載っていない・空・読めないときは、push を止める'

# 実際の git の push が、ssh のコマンドに送る引数の形を確認する。ssh のコマンドの差し替えが、受け取った引数を記録する。
if command -v git >/dev/null; then
	reset_calls
	cat >"$test_dir/record-ssh" <<'EOF'
#!/usr/bin/env bash
jq -cn --args '$ARGS.positional' -- "$@" >>"$GUARD_GIT_TEST_DIR/git-ssh-args"
exit 1
EOF
	chmod +x "$test_dir/record-ssh"
	: >"$test_dir/git-ssh-args"
	git init -q "$test_dir/repo"
	(
		cd "$test_dir/repo"
		export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
		export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
		export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
		git commit -q --allow-empty -m fixture
		for url in git@github.com:other/repo.git ssh://git@github.com/other/repo.git \
			git@github.com:example/template.git ssh://git@github.com/example/template.git; do
			git -c "core.sshCommand=bash $ssh_guard" push -q "$url" HEAD:refs/heads/fixture-test >"$test_dir/git-out" 2>&1 || true
			case $url in
			*other/repo*) grep -q '^git push のガード:.*other/repo への SSH の push は止めた' "$test_dir/git-out" ;;
			*) grep -q '^git push のガード:' "$test_dir/git-out" && exit 1 || true ;;
			esac
		done
	)
	# 許すリポジトリの 2 つの URL の形は、ssh の差し替えまで届く。許していないものは届かない。
	# git が種類を調べる -G などの呼び出しは数えず、receive-pack の呼び出しだけを見る。
	jq -se '[.[] | select(.[-1] | test("receive-pack"))] | length == 2 and all(.[]; .[-1] | test("^git-receive-pack .(/)?example/template.git.$"))' "$test_dir/ssh-calls" >/dev/null
	echo 'PASS ssh: 実際の git の push で、2 つの URL の形のうち、許していないものを自分の文で止め、許すものを ssh に渡す'
fi

# host 名に receive-pack を含み、ポートも付く URL の読み取りで、git が種類を調べる -G を、ガードが止めない。
if command -v git >/dev/null; then
	reset_calls
	(
		cd "$test_dir/repo"
		export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
		git -c "core.sshCommand=bash $ssh_guard" ls-remote ssh://git@receive-pack.example:2222/other/repo.git >"$test_dir/git-out" 2>&1 || true
	)
	! grep -q 'git push のガード' "$test_dir/git-out"
	jq -se 'map(select(.[-1] | test("^git-upload-pack "))) | length == 1' "$test_dir/ssh-calls" >/dev/null
	echo 'PASS ssh: 実際の git の ls-remote で、host 名に receive-pack とポートがあっても、止めずに本物の ssh に渡す'
fi

# 置き場に空白と単引用符があっても、役の環境の credential.helper と core.sshCommand を、git が起動できる。
# project_desired_env が出す値を、そのまま git に渡す。外へは接続せず、仮のヘルパーと ssh の差し替えを呼ぶ。
if command -v git >/dev/null; then
	odd_home="$test_dir/it's a home"
	mkdir -p "$odd_home/guard"
	cat >"$odd_home/guard/git-credential" <<'SCRIPT'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$*" >>"$GUARD_GIT_TEST_DIR/odd-helper-calls"
SCRIPT
	cat >"$odd_home/guard/git-ssh" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$#" >>"$GUARD_GIT_TEST_DIR/odd-ssh-calls"
exit 1
SCRIPT
	chmod +x "$odd_home/guard/git-credential" "$odd_home/guard/git-ssh"
	odd_env=$(bash -c '
		set -euo pipefail
		root=$1; agent_home=$2
		die() { echo "$*" >&2; exit 1; }
		source "$root/lib/check.sh"; source "$root/lib/host.sh"; source "$root/lib/project.sh"
		allowed_repos_file=/dev/null project_shell_dir=/dev/null
		project_desired_env fixture gpt-fixture' -- "$root" "$odd_home")
	: >"$test_dir/odd-helper-calls"
	: >"$test_dir/odd-ssh-calls"
	(
		cd "$test_dir/repo"
		for name in $(jq -r 'keys[] | select(test("^GIT_CONFIG_"))' <<<"$odd_env"); do
			export "$name=$(jq -r --arg n "$name" '.[$n]' <<<"$odd_env")"
		done
		export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
		printf 'protocol=https\nhost=github.com\npath=example/template.git\n\n' | git credential fill >/dev/null 2>&1 || true
		git push -q git@github.com:example/template.git HEAD:refs/heads/fixture-test >/dev/null 2>&1 || true
	)
	[[ -s $test_dir/odd-helper-calls && $(head -n 1 "$test_dir/odd-helper-calls") == get ]]
	[[ -s $test_dir/odd-ssh-calls ]]
	echo 'PASS 引用: 空白と単引用符を含む置き場でも、git が credential.helper と core.sshCommand の仮のスクリプトを起動する'
fi
