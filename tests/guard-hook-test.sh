#!/usr/bin/env bash
# ZIP のルートで bash tests/guard-hook-test.sh を実行する。
# PreToolUse のフックを確認する。
# 前半は、Bash とシェルの入力を 1 つずつのコマンドに分ける部品（common/guard/shell_split.py）を、
# 設計の docs/agent-guards.md「Bash とシェルの入力は、次の順に読む」の 1〜6 の順に確認する。
# 後半は、PreToolUse のスクリプト（common/guard/pre-tool-use）が、照合の例と分離の例を、Claude と Codex の入力の形で同じに判定することを確認する。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
splitter="$root/common/guard/shell_split.py"
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/guard-hook-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

# 入力を分け、JSON を標準出力に出す。分けられないときは、終了コード 3 と標準エラーの理由を返す。
split() {
	printf '%s' "$1" | python3 -I "$splitter"
}
# 実行するコマンドの argv を、コマンドごとの配列にして並べ替えた JSON を出す。
argvs() {
	split "$1" | jq -c '[.commands[] | select(.argv | length > 0) | [.argv[].text]] | sort'
}
# 入力が分かれる先の argv の並び（順は問わない）を確認する。
expect_argvs() {
	local input=$1 expected=$2 actual
	actual=$(argvs "$input")
	expected=$(printf '%s' "$expected" | jq -c 'sort')
	if [[ $actual != "$expected" ]]; then
		printf 'FAIL 入力: %s\n  期待: %s\n  実際: %s\n' "$input" "$expected" "$actual" >&2
		exit 1
	fi
}
# 分けられないとして、終了コード 3 と理由を返すことを確認する。
expect_unsplittable() {
	local input=$1 rc=0
	printf '%s' "$input" | python3 -I "$splitter" >"$test_dir/out" 2>"$test_dir/err" || rc=$?
	if [[ $rc -ne 3 || -s $test_dir/out ]] || ! grep -q '^分けられない: ' "$test_dir/err"; then
		printf 'FAIL 分けられないはずの入力: %s（終了コード %s）\n' "$input" "$rc" >&2
		exit 1
	fi
}
# 分けた JSON に jq の条件が成り立つことを確認する。
expect_json() {
	local input=$1 filter=$2
	if ! split "$input" | jq -e "$filter" >/dev/null; then
		printf 'FAIL 入力: %s\n  条件: %s\n' "$input" "$filter" >&2
		split "$input" >&2 || true
		exit 1
	fi
}

# --- 1. 区切りで分ける ---

expect_argvs $'a; b && c || d | e\nf' '[["a"],["b"],["c"],["d"],["e"],["f"]]'
expect_argvs 'a & b |& c' '[["a"],["b"],["c"]]'
expect_argvs $'a\n\n  b  \n' '[["a"],["b"]]'
expect_argvs 'a\
b' '[["ab"]]'
# 引用符の中と、エスケープした区切りでは分けない
expect_argvs 'echo "a;b" '\''c && d'\'' e\;f g\|h' '[["echo","a;b","c && d","e;f","g|h"]]'
expect_argvs $'echo "a\nb" \'c\nd\'' '[["echo","a\nb","c\nd"]]'
expect_argvs 'echo a # b; c' '[["echo","a"]]'
expect_argvs 'echo a#b' '[["echo","a#b"]]'
expect_argvs 'git -c "core.hooksPath=/dev/null" push' '[["git","-c","core.hooksPath=/dev/null","push"]]'
echo 'PASS 分け方: 区切りで分け、引用符とエスケープの中では分けない'

# --- 2. 展開の中を別のコマンドとして読む ---

# 引用していない $( ) とバッククォート
expect_argvs 'echo $(git push --no-verify)' '[["echo","$(git push --no-verify)"],["git","push","--no-verify"]]'
expect_argvs 'echo `gh api -X POST x`' '[["echo","`gh api -X POST x`"],["gh","api","-X","POST","x"]]'
# 二重引用符の中の $( ) とバッククォート
expect_argvs 'echo "$(git push --no-verify origin HEAD)"' '[["echo","$(git push --no-verify origin HEAD)"],["git","push","--no-verify","origin","HEAD"]]'
expect_argvs 'multica issue get "`gh api -X POST x`"' '[["multica","issue","get","`gh api -X POST x`"],["gh","api","-X","POST","x"]]'
expect_argvs 'echo "a $(gh x) b $(gh y)"' '[["echo","a $(gh x) b $(gh y)"],["gh","x"],["gh","y"]]'
# 入れ子の展開
expect_argvs 'echo "$(echo "$(gh x)")"' '[["echo","$(echo \"$(gh x)\")"],["echo","$(gh x)"],["gh","x"]]'
expect_argvs 'echo $(echo `gh x`)' '[["echo","$(echo `gh x`)"],["echo","`gh x`"],["gh","x"]]'
expect_argvs 'echo $(a; b | c)' '[["echo","$(a; b | c)"],["a"],["b"],["c"]]'
# プロセス置換。引用していない隣り合う <( と >( だけで、引用した中はデータ
expect_argvs 'multica issue get $(cat <(gh auth token))' '[["multica","issue","get","$(cat <(gh auth token))"],["cat","<(gh auth token)"],["gh","auth","token"]]'
expect_argvs 'tee >(gh x) <(gh y)' '[["tee",">(gh x)","<(gh y)"],["gh","x"],["gh","y"]]'
expect_argvs 'echo "<(gh x)" '\''>(gh y)'\''' '[["echo","<(gh x)",">(gh y)"]]'
# ${ } と $(( )) の中の展開
expect_argvs 'echo ${x:-$(gh y)}' '[["echo","${x:-$(gh y)}"],["gh","y"]]'
expect_argvs 'echo "${x:-$(gh y)}"' '[["echo","${x:-$(gh y)}"],["gh","y"]]'
expect_argvs 'echo $((1+$(gh y)))' '[["echo","$((1+$(gh y)))"],["gh","y"]]'
expect_argvs 'echo $((1+2)) $(( 3 * (4 + 5) ))' '[["echo","$((1+2))","$(( 3 * (4 + 5) ))"]]'
expect_argvs 'echo $( (gh x) )' '[["echo","$( (gh x) )"],["gh","x"]]'
# 単引用符の中、エスケープした展開、$'..' はデータ
expect_argvs 'echo '\''$(gh x) `gh y` <(gh z)'\''' '[["echo","$(gh x) `gh y` <(gh z)"]]'
expect_argvs 'echo "\$(gh x) \`gh y\`"' '[["echo","$(gh x) `gh y`"]]'
expect_argvs 'echo \$\(gh\ x\)' '[["echo","$(gh x)"]]'
expect_argvs 'echo $'\''a;b $(gh x)'\''' '[["echo","a;b $(gh x)"]]'
# 代入の値の中の展開
expect_argvs 'A=$(gh x) B=2' '[["gh","x"]]'
echo 'PASS 展開: 引用していない所と二重引用符の中の展開を読み、単引用符とエスケープの中は読まない'

# --- 3. ヒアドキュメント ---

# 引用していない区切りは、本文の中の展開を読む
expect_argvs $'cat <<EOF\nhello $(gh auth token)\nEOF\necho after' '[["cat"],["gh","auth","token"],["echo","after"]]'
expect_argvs $'cat <<EOF\nhello `gh a`\nEOF' '[["cat"],["gh","a"]]'
expect_argvs $'multica issue comment add X --content-stdin <<EOF\n$(gh api -X POST x)\nEOF' '[["multica","issue","comment","add","X","--content-stdin"],["gh","api","-X","POST","x"]]'
expect_argvs $'cat <<EOF\n${x:-$(gh y)} $((1+$(gh z)))\nEOF' '[["cat"],["gh","y"],["gh","z"]]'
# 本文の中の区切りと、エスケープした展開と、二重引用符は、コマンドにならない
expect_argvs $'cat <<EOF\na; b && c\n"x" \\$(gh a) \\`gh b\\`\nEOF\necho after' '[["cat"],["echo","after"]]'
# 引用した区切りの本文は、展開されないデータ
expect_argvs $'cat <<\'EOF\'\nhello $(gh auth token) `gh a`\nEOF\necho after' '[["cat"],["echo","after"]]'
expect_argvs $'cat <<"EOF"\n$(gh a)\nEOF' '[["cat"]]'
expect_argvs $'cat <<\\EOF\n$(gh a)\nEOF' '[["cat"]]'
expect_argvs $'cat <<E"O"F\n$(gh a)\nEOF' '[["cat"]]'
# <<- は、終わりの行の先頭のタブを無視する
expect_argvs $'cat <<-EOF\n\t$(gh a)\n\tEOF\necho after' '[["cat"],["gh","a"],["echo","after"]]'
expect_argvs $'cat <<EOF\n$(gh a)\n\tEOF\nEOF\necho after' '[["cat"],["gh","a"],["echo","after"]]'
# 終わりの行がなければ、入力の終わりまでが本文
expect_argvs $'cat <<EOF\n$(gh a)\nno end' '[["cat"],["gh","a"]]'
# 1 つの行に複数のヒアドキュメントがあるとき、順に読む
expect_argvs $'cat <<A <<\'B\'\n$(gh a)\nA\n$(gh b)\nB\necho after' '[["cat"],["gh","a"],["echo","after"]]'
# $( ) の中のヒアドキュメントと、here-string
expect_argvs $'echo "$(cat <<EOF\n$(gh a)\nEOF\n)"' '[["echo","$(cat <<EOF\n$(gh a)\nEOF\n)"],["cat"],["gh","a"]]'
expect_argvs 'cat <<< "$(gh a)"' '[["cat"],["gh","a"]]'
expect_json $'cat <<EOF\nx\nEOF' '.commands[0].redirects == [{"op":"<<","target":"EOF","dynamic":false}]'
expect_json 'cat <<< x' '.commands[0].redirects[0].op == "<<<"'
echo 'PASS ヒアドキュメント: 引用していない区切りの本文の展開は読み、引用した区切りの本文は読まない'

# --- 4. 先頭の代入と、飛ばすコマンド ---

expect_json 'A=1 B="x y" git push' '(.commands | length) == 1 and (.commands[0].assign | map([.name, .value, .dynamic, .wrapper])) == [["A","1",false,false],["B","x y",false,false]] and (.commands[0].argv | map(.text)) == ["git","push"]'
expect_json 'GH_CONFIG_DIR=/tmp/x' '(.commands | length) == 1 and .commands[0].assign[0].name == "GH_CONFIG_DIR" and .commands[0].argv == []'
expect_json 'A+=1 B[2]=x C= git x' '[.commands[0].assign[].name] == ["A","B","C"]'
expect_json 'A=(a b $(gh x)) git' '.commands[1].assign[0].name == "A" and .commands[1].assign[0].dynamic and ([.commands[].argv[0].text] | sort) == ["gh","git"]'
# 代入の名前が引用符で分かれたもの・先頭でないものは、代入ではない
expect_json 'git A=1' '(.commands[0].assign | length) == 0 and (.commands[0].argv | map(.text)) == ["git","A=1"]'
expect_json '"A=1" git' '(.commands[0].assign | length) == 0'
expect_argvs 'env git push' '[["git","push"]]'
expect_argvs 'env -i git push' '[["git","push"]]'
expect_argvs 'env -u GH_CONFIG_DIR -- git push' '[["git","push"]]'
expect_argvs 'env -uGH_CONFIG_DIR -C /tmp git push' '[["git","push"]]'
expect_argvs 'env --unset GH_CONFIG_DIR --chdir=/tmp --ignore-environment git push' '[["git","push"]]'
expect_argvs 'env -S "git push --no-verify"' '[["git","push","--no-verify"]]'
expect_argvs 'env -S"git push" origin' '[["git","push","origin"]]'
expect_argvs '/usr/bin/env -i /usr/bin/git push' '[["/usr/bin/git","push"]]'
expect_argvs 'command git push' '[["git","push"]]'
expect_argvs 'command -p -- git push' '[["git","push"]]'
expect_argvs 'exec git push' '[["git","push"]]'
expect_argvs 'exec -c -l -a name git push' '[["git","push"]]'
expect_argvs 'nice git push' '[["git","push"]]'
expect_argvs 'nice -n 5 git push' '[["git","push"]]'
expect_argvs 'nice -n5 git push' '[["git","push"]]'
expect_argvs 'nice -5 git push' '[["git","push"]]'
expect_argvs 'nice --adjustment=5 git push' '[["git","push"]]'
expect_argvs 'nice --adjustment 5 git push' '[["git","push"]]'
expect_argvs 'sudo git push' '[["git","push"]]'
expect_argvs 'sudo -u root -E -- git push' '[["git","push"]]'
expect_argvs 'sudo -uroot -g wheel -p x git push' '[["git","push"]]'
expect_argvs 'sudo --user=root --prompt x git push' '[["git","push"]]'
expect_argvs 'sudo -n env -i nice -n 1 command exec git push' '[["git","push"]]'
# env と sudo の後の代入は、代入として読む。飛ばした語も words に残る
expect_json 'env A=1 B=2 git push' '(.commands[0].assign | map([.name, .wrapper])) == [["A",true],["B",true]] and (.commands[0].argv | map(.text)) == ["git","push"]'
expect_json 'env -i -u GH_CONFIG_DIR git push' '(.commands[0].words | map(.text)) == ["env","-i","-u","GH_CONFIG_DIR","git","push"]'
expect_json 'A=1 env B=2 git push' '(.commands[0].assign | map([.name, .wrapper])) == [["A",false],["B",true]]'
# 実行しないもの、決まらないものは、argv に出さない・決まらないと示す
expect_json 'command -v git' '.commands[0].argv == []'
expect_json 'env $X git' '.commands[0].argv[0].dynamic == true'
expect_argvs 'env' '[]'
echo 'PASS 代入と飛ばすコマンド: 先頭の代入を読み、env・command・exec・nice・sudo の先を実行するコマンドにする'

# --- 5. bash・sh・zsh の -c と eval ---

expect_argvs "bash -c 'git push --no-verify'" '[["bash","-c","git push --no-verify"],["git","push","--no-verify"]]'
expect_argvs "sh -c 'git config core.hooksPath /dev/null'" '[["sh","-c","git config core.hooksPath /dev/null"],["git","config","core.hooksPath","/dev/null"]]'
expect_argvs "zsh -c 'a; b && c' arg0 arg1" '[["zsh","-c","a; b && c","arg0","arg1"],["a"],["b"],["c"]]'
expect_argvs "bash -lc 'git x'" '[["bash","-lc","git x"],["git","x"]]'
expect_argvs "bash -e -o pipefail -c 'git x'" '[["bash","-e","-o","pipefail","-c","git x"],["git","x"]]'
expect_argvs "bash --norc -c 'git x'" '[["bash","--norc","-c","git x"],["git","x"]]'
expect_argvs "sudo -u root /bin/bash -c 'git x'" '[["/bin/bash","-c","git x"],["git","x"]]'
# 外側の二重引用符の中の展開と、-c の文字列の中の展開は、別々に読むので 2 回出る
expect_argvs 'bash -c "echo $(gh a)"' '[["bash","-c","echo $(gh a)"],["echo","$(gh a)"],["gh","a"],["gh","a"]]'
# 入れ子
expect_argvs "bash -c \"bash -c 'git x'\"" '[["bash","-c","bash -c '\''git x'\''"],["bash","-c","git x"],["git","x"]]'
expect_argvs "bash -c 'echo \$(gh a)'" '[["bash","-c","echo $(gh a)"],["echo","$(gh a)"],["gh","a"]]'
# スクリプトのファイルを実行するだけの bash は、文字列を読まない
expect_argvs 'bash script.sh -c "git x"' '[["bash","script.sh","-c","git x"]]'
expect_argvs 'bash' '[["bash"]]'
expect_argvs 'eval "git push --no-verify"' '[["eval","git push --no-verify"],["git","push","--no-verify"]]'
expect_argvs 'eval git push --no-verify' '[["eval","git","push","--no-verify"],["git","push","--no-verify"]]'
expect_argvs 'eval -- "a; b"' '[["eval","--","a; b"],["a"],["b"]]'
expect_argvs 'command eval git x' '[["eval","git","x"],["git","x"]]'
# 渡す文字列が決まらないときは、実行するコマンドが決まらないと示す
expect_json 'bash -c "$CMD"' '[.commands[] | select(.argv[0].text == "$CMD" and .argv[0].dynamic)] | length == 1'
echo 'PASS -c と eval: 渡す文字列を、同じ順で読む'

# --- 6. 分けられないものは止める ---

expect_unsplittable 'echo "abc'
expect_unsplittable "echo 'abc"
expect_unsplittable 'echo $(abc'
expect_unsplittable 'echo `abc'
expect_unsplittable 'echo ${abc'
expect_unsplittable 'echo $((1+2'
expect_unsplittable 'echo "$(echo "x)"'
expect_unsplittable '(abc'
expect_unsplittable 'echo )'
expect_unsplittable 'cat >'
expect_unsplittable 'cat <<'
expect_unsplittable 'cat > ; echo'
expect_unsplittable "bash -c 'echo \"x'"
expect_unsplittable "eval 'echo (' "
expect_unsplittable 'env -S "git push'
expect_unsplittable 'echo $'\''abc'
expect_unsplittable 'case x in a) echo'
expect_unsplittable $'echo "a\n$(echo'
expect_unsplittable 'A=(a b'
expect_unsplittable $'cat <<EOF\n$(echo\nEOF'
# 入れ子が深すぎて読み切れないものも、分けられない
deep=x
for _ in $(seq 1500); do deep="\$($deep)"; done
expect_unsplittable "echo $deep"
# 空の入力は、コマンドがない
expect_json '' '.commands == []'
expect_json $'\n  # comment only\n' '.commands == []'
echo 'PASS 分けられないもの: 引用符や展開が閉じないなどは、標準エラーに理由を書いて終了コード 3 で終わる'

# --- 構文の形 ---

expect_argvs 'if git push --no-verify; then echo ok; elif a; then b; else c; fi' '[["git","push","--no-verify"],["echo","ok"],["a"],["b"],["c"]]'
expect_argvs 'for f in $(gh x); do echo $f; done' '[["gh","x"],["echo","$f"],["f","in","$(gh x)"]]'
expect_argvs 'while read l; do git x; done < file' '[["read","l"],["git","x"]]'
expect_argvs $'case $x in a) git push;; b|c) echo;;\n (d) gh y\nesac; echo z' '[["git","push"],["echo"],["gh","y"],["echo","z"]]'
expect_argvs 'case "$(gh a)" in x) ;; esac' '[["gh","a"]]'
expect_argvs 'echo $(case a in a) git x;; esac)' '[["echo","$(case a in a) git x;; esac)"],["git","x"]]'
expect_argvs '{ git a; git b; }' '[["git","a"],["git","b"]]'
expect_argvs '(git a; git b) | git c' '[["git","a"],["git","b"],["git","c"]]'
expect_argvs '! git x' '[["git","x"]]'
expect_argvs 'time git x' '[["git","x"]]'
expect_argvs 'f() { git push; }; f' '[["git","push"],["f"]]'
expect_argvs 'function f { git push; }' '[["git","push"]]'
expect_argvs '[[ a == b && c || d ]] && echo' '[["[[","a","==","b","&&","c","||","d","]]"],["echo"]]'
expect_argvs '[[ $(gh a) == x ]]' '[["[[","$(gh a)","==","x","]]"],["gh","a"]]'
expect_argvs '(( x = 1 + 2 )); echo' '[["echo"]]'
expect_argvs '((x=$(gh a))); echo' '[["gh","a"],["echo"]]'
expect_argvs '((git a); git b)' '[["git","a"],["git","b"]]'
expect_argvs 'echo a && { echo b; } || (echo c)' '[["echo","a"],["echo","b"],["echo","c"]]'
echo 'PASS 構文の形: if・for・while・case・グループ・関数・[[ ]]・(( )) の中のコマンドも分ける'

# --- リダイレクト ---

expect_json 'echo x > ~/.netrc' '.commands[0].redirects == [{"op":">","target":"~/.netrc","dynamic":false,"tilde":true}] and (.commands[0].argv | map(.text)) == ["echo","x"]'
expect_json 'echo x>>f 2>&1 1>/dev/null <in &> out' '(.commands[0].redirects | map([.op, .target])) == [[">>","f"],["2>&","1"],["1>","/dev/null"],["<","in"],["&>","out"]]'
expect_json 'cat > "$HOME/x" < $(gh a)' '(.commands | map(.redirects | length)) == [0,2] and .commands[1].redirects[0].dynamic'
expect_json '> out' '.commands[0].argv == [] and .commands[0].redirects[0].target == "out"'
expect_json '(cd x) > out' '.commands[-1].redirects[0].target == "out"'
expect_json 'echo 2 3 >out' '(.commands[0].argv | map(.text)) == ["echo","2","3"]'
echo 'PASS リダイレクト: 演算子（fd を含む）と先を、引数とは別に出す'

# --- 値が決まらない語 ---

expect_json $'cat \'~/a\' ~/b "~/c" d=~/e x~y' '[.commands[0].argv[1:][] | .tilde // false] == [false,true,false,true,false]'
expect_json '$CMD x' '.commands[0].argv[0].dynamic and (.commands[0].argv[1].dynamic | not)'
expect_json 'git* x' '.commands[0].argv[0].dynamic'
expect_json 'git{a,b} x' '.commands[0].argv[0].dynamic'
expect_json '"$x" `y` "$(z)" ${w}' '[.commands[-1].argv[].dynamic] == [true,true,true,true]'
expect_json $'\'$x\' "\\$x" \\* "*" "{a,b}" a.b' '[.commands[0].argv[].dynamic] == [false,false,false,false,false,false]'
expect_json '[ -f x ] && [[ x ]]' '[.commands[].argv[0].dynamic] == [false,false]'
echo 'PASS 値が決まらない語: 展開・引用していないグロブとブレース展開を含む語に印を付ける'

echo 'PASS guard-hook: PreToolUse の入力の分け方'

# --- PreToolUse のスクリプト ---
# 置き場は、ホストに写したときと同じ形にする。スクリプトと分割の部品が並び、空の gh の置き場が隣にある。
hook_dir="$test_dir/guard"
work="$test_dir/work"
home="$test_dir/home"
mkdir -p "$hook_dir/gh-empty" "$work/sub" "$home/.config/gh" "$home/.ssh"
cp "$root/common/guard/pre-tool-use" "$root/common/guard/shell_split.py" "$hook_dir/"
chmod 700 "$hook_dir/gh-empty"
printf 'secret\n' >"$home/.ssh/id_ed25519"
ln -s "$home/.ssh" "$work/ssh-link"
hook="$hook_dir/pre-tool-use"

# 入力の形。Claude は Bash の command、Codex は shell の command 配列と exec_command の cmd で渡す。
json_claude() { jq -nc --arg c "$1" --arg d "$work" '{hook_event_name:"PreToolUse",session_id:"s",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'; }
json_codex_shell() { jq -nc --arg c "$1" --arg d "$work" '{hook_event_name:"PreToolUse",session_id:"s",turn_id:"t",cwd:$d,tool_name:"shell",tool_input:{command:["bash","-lc",$c]}}'; }
json_codex_exec() { jq -nc --arg c "$1" --arg d "$work" '{hook_event_name:"PreToolUse",session_id:"s",turn_id:"t",cwd:$d,tool_name:"exec_command",tool_input:{cmd:$c,workdir:$d}}'; }
json_file_tool() { jq -nc --arg t "$1" --arg k "$2" --arg p "$3" --arg d "$work" '{hook_event_name:"PreToolUse",session_id:"s",cwd:$d,tool_name:$t,tool_input:({($k):$p,content:"GIT_CONFIG_COUNT",new_string:"export GH_TOKEN=x"})}'; }

task_id=task-1
extra_env=()
# フックを流し、終了コードを返す。標準エラーは $test_dir/err に残す。extra_env に、役の環境へ足す NAME=値を置く。
run_hook() {
	local json=$1 rc=0
	env -i PATH="$PATH" HOME="$home" ${task_id:+MULTICA_TASK_ID="$task_id"} \
		GH_CONFIG_DIR="$hook_dir/gh-empty" SQUAD_KIT_GH_CONFIG_DIR="$home/.config/gh" \
		${extra_env[@]+"${extra_env[@]}"} "$hook" <<<"$json" >"$test_dir/hook-out" 2>"$test_dir/err" || rc=$?
	printf '%s' "$rc"
}
# 判定を確認する。止めるときは、終了コード 2 と、理由とガードを避けない文が標準エラーにあることまで見る。
expect_verdict() {
	local verdict=$1 label=$2 json=$3 rc
	rc=$(run_hook "$json")
	if [[ $verdict == pass ]]; then
		if [[ $rc -ne 0 ]]; then
			printf 'FAIL 通すはずの入力（%s）: 終了コード %s\n  入力: %s\n' "$label" "$rc" "$json" >&2
			cat "$test_dir/err" >&2
			exit 1
		fi
	elif [[ $rc -ne 2 ]] || ! grep -q '^PreToolUse のガード: ' "$test_dir/err" || ! grep -q '避ける' "$test_dir/err"; then
		printf 'FAIL 止めるはずの入力（%s）: 終了コード %s\n  入力: %s\n' "$label" "$rc" "$json" >&2
		cat "$test_dir/err" >&2
		exit 1
	fi
}
# 同じコマンドを、3 つの入力の形で同じに判定する。
expect_command() {
	local verdict=$1 command=$2
	expect_verdict "$verdict" "Claude: $command" "$(json_claude "$command")"
	expect_verdict "$verdict" "Codex shell: $command" "$(json_codex_shell "$command")"
	expect_verdict "$verdict" "Codex exec_command: $command" "$(json_codex_exec "$command")"
}

# --- 7. 照合の例（通す 4 件と止める 9 件） ---

expect_command pass 'rg -n GH_CONFIG_DIR common/guard/gh'
expect_command pass 'grep -rn -- --no-verify docs tests'
expect_verdict pass 'Edit: docs への書き込み' "$(json_file_tool Edit file_path "$work/docs/agent-guards.md")"
expect_command pass 'bash tests/run.sh tests/gh-test.sh'

expect_command stop 'GH_CONFIG_DIR=/tmp/x gh pr create'
expect_command stop 'export GH_TOKEN=x'
expect_command stop 'git push --no-verify origin HEAD'
expect_command stop 'git -c credential.helper= push'
expect_command stop "bash -c 'git config core.hooksPath /dev/null'"
expect_command stop 'env -i git push'
expect_command stop 'echo "$(git push --no-verify origin HEAD)"'
expect_command stop 'cat ~/.ssh/id_ed25519'
expect_verdict stop 'Write: 作業ディレクトリの直下の .mcp.json' "$(json_file_tool Write file_path "$work/.mcp.json")"
echo 'PASS 照合の例: 通す 4 件と止める 9 件を、Claude と Codex の入力の形で同じに判定する'

# --- 8. 種類ごとの止める操作と、通す操作 ---

# 認証の置き場の変数
for c in 'GH_CONFIG_DIR=x gh auth status' 'SQUAD_KIT_ALLOWED_REPOS=/dev/null gh x' 'export SQUAD_KIT_GH_CONFIG_DIR=/x' \
	'unset GH_CONFIG_DIR' 'env -u GH_TOKEN gh x' 'env --unset=GITHUB_TOKEN gh x' 'env GH_ENTERPRISE_TOKEN=x gh x' \
	'export GITHUB_ENTERPRISE_TOKEN' 'declare -x GH_TOKEN=x' 'X=1 GH_TOKEN=x git fetch'; do
	expect_command stop "$c"
done
# git の環境変数
for c in 'GIT_CONFIG_COUNT=0 git push' 'export GIT_CONFIG_KEY_1=x' 'GIT_TRACE=1 git fetch' 'GIT_SSH_COMMAND=ssh git push' \
	'export GIT_SSH=x' 'GIT_ASKPASS=x git push' 'export SSH_ASKPASS=x'; do
	expect_command stop "$c"
done
# 環境を外す
for c in 'env -i x' 'env --ignore-environment x' 'env - x' 'sudo env -i x'; do
	expect_command stop "$c"
done
# git の守りを外す指定。キーは大文字と小文字を区別しない
for c in 'git push --no-ver origin' 'git push origin HEAD --no-verify' 'git -C sub push --no-verify' 'git credential fill' 'git credential-store get' \
	'git --config-env=credential.helper=X push' 'git -ccredential.helper=x push' 'git -c Core.SshCommand=x fetch' 'git -c url.x.insteadOf=y fetch' \
	'git -c http.extraHeader=x fetch' 'git -c include.path=x fetch' 'git -c includeIf.x.path=y fetch' \
	'git config CORE.HOOKSPATH x' 'git config --global credential.helper x' 'git config --unset core.sshCommand' 'git config --add url.a.insteadOf b' \
	'git config set core.hooksPath x' 'git config unset core.hooksPath' 'git config --file x core.hooksPath y'; do
	expect_command stop "$c"
done
# 認証情報の置き場と、読み込まれる設定のリダイレクト
for c in 'cat "$HOME/.ssh/id_ed25519"' 'cat ${HOME}/.git-credentials' 'cat ~/.netrc' 'ls ~/.ssh' 'cat < ~/.netrc' "cat $home/.config/gh/hosts.yml" \
	"cat $hook_dir/gh-empty/hosts.yml" 'cat ssh-link/id_ed25519' 'cat --file=~/.netrc' 'security find-generic-password -s x' 'security -q find-internet-password' \
	'echo x > .mcp.json' 'echo x >> .claude/settings.json' 'echo x 2> .claude/settings.local.json' 'echo x >| .mcp.json' 'echo x &> .mcp.json' \
	'echo x > ~/.ssh/authorized_keys' 'cat ~/.ssh'; do
	expect_command stop "$c"
done
# 通す操作。検索の語と引用したデータは、代入や置き場として読まない
for c in 'echo x > sub/.mcp.json' 'cat .mcp.json' 'cat .claude/settings.json' 'echo x > .claude/other.json' 'git config --get core.hooksPath' 'git config core.hooksPath' \
	'git config user.name x' 'git -c user.name=x commit -m y' 'git push origin HEAD' 'git push -n origin' 'git push origin -- --no-verify' \
	"echo 'export GH_TOKEN=x'" "echo 'cat ~/.ssh/id_ed25519'" "cat '\$HOME/.ssh/id_ed25519'" 'rg -n "GIT_CONFIG_COUNT" lib' 'env FOO=1 git status' \
	"rg -n '~/.ssh' docs" "cat '~/.ssh/id_ed25519'" \
	'env -u FOO git status' 'GIT_AUTHOR_NAME=x git commit -m y' 'export PATH=$PATH:/x' 'security list-keychains' 'echo env -i' \
	$'cat <<\'EOF\'\nGH_TOKEN=x $(gh api -X POST y)\nEOF'; do
	expect_command pass "$c"
done
# Write・Edit・NotebookEdit は、書く先だけを見る
expect_verdict stop 'Edit: .claude/settings.json' "$(json_file_tool Edit file_path "$work/.claude/settings.json")"
expect_verdict stop 'Edit: 相対のパス' "$(json_file_tool Edit file_path ".claude/settings.local.json")"
expect_verdict stop 'Write: シンボリックリンク' "$(ln -sfn "$work/.mcp.json" "$work/sub/link.json"; json_file_tool Write file_path "$work/sub/link.json")"
expect_verdict stop 'NotebookEdit: .mcp.json' "$(json_file_tool NotebookEdit notebook_path "$work/.mcp.json")"
expect_verdict pass 'Write: 下の階層の .mcp.json' "$(json_file_tool Write file_path "$work/sub/.mcp.json")"
expect_verdict pass 'NotebookEdit: ノートブック' "$(json_file_tool NotebookEdit notebook_path "$work/a.ipynb")"
expect_verdict pass 'Write: ホームの .ssh の中身を書く先でない作業先' "$(json_file_tool Write file_path "$work/tests/x.sh")"
expect_verdict stop 'Write: 書く先のパスがない' "$(jq -nc --arg d "$work" '{cwd:$d,tool_name:"Write",tool_input:{content:"x"}}')"
# 読むツールと、知らないツールは通す
expect_verdict pass 'Read' "$(jq -nc --arg d "$work" '{cwd:$d,tool_name:"Read",tool_input:{file_path:"/etc/hosts"}}')"
echo 'PASS 種類ごとの止める操作: 変数・git・環境・置き場・設定の書き込みを止め、検索の語・引用したデータ・別の場所は通す'

# --- 9. 読めない入力と分けられない入力は止める。MULTICA_TASK_ID がなければ通す ---

expect_verdict stop '読めない JSON' 'not json'
expect_verdict stop 'オブジェクトでない JSON' '[1]'
expect_verdict stop 'ツールの名前がない' '{"tool_input":{"command":"ls"}}'
expect_verdict stop 'コマンドがない Bash' '{"tool_name":"Bash","tool_input":{}}'
expect_verdict stop '閉じない引用符' "$(json_claude 'echo "abc')"
expect_verdict stop '閉じない展開' "$(json_codex_shell 'echo $(ls')"
expect_command stop 'echo "$(ls'

task_id=
for c in 'export GH_TOKEN=x' 'env -i git push --no-verify' 'cat ~/.ssh/id_ed25519'; do
	expect_command pass "$c"
done
expect_verdict pass 'MULTICA_TASK_ID なしの Write' "$(json_file_tool Write file_path "$work/.mcp.json")"
expect_verdict pass 'MULTICA_TASK_ID なしの読めない入力' 'not json'
extra_env=(GH_TOKEN=fake)
expect_command pass 'gh pr create'
extra_env=()
task_id=task-1
echo 'PASS MULTICA_TASK_ID がないとき: 何もせずに通す。読めない入力と分けられない入力は、ある実行で止める'

# --- 10. 認証の分離 ---
# 仮のトークンの変数がある場合と、空の置き場に仮のファイルがある場合のそれぞれで、同じ例を 3 つの入力の形で判定する。

gh_post='gh api -X POST repos/o/r/issues'
check_isolation_examples() {
	local mode=$1
	# 通す 3 件
	expect_command pass 'multica issue get X'
	expect_command pass "multica issue get '\$($gh_post)'"
	expect_command pass $'multica issue comment add X --content-stdin <<\'EOF\'\n$('"$gh_post"$')\nEOF'
	# 止める 6 件
	expect_command stop "multica issue get \"\$($gh_post)\""
	expect_command stop "multica issue get \"\`$gh_post\`\""
	expect_command stop $'multica issue comment add X --content-stdin <<EOF\n$('"$gh_post"$')\nEOF'
	expect_command stop 'multica issue get $(cat <(gh auth token))'
	expect_command stop '$CMD issue get X'
	expect_command stop 'gh pr create'
	# 止める理由に、分離が成り立たないことと、呼ぶ人間に知らせることが出る
	run_hook "$(json_claude 'gh pr create')" >/dev/null
	grep -q '認証の分離が成り立っていません' "$test_dir/err" || { echo "FAIL ($mode) 分離の理由が出ない" >&2; cat "$test_dir/err" >&2; exit 1; }
	grep -q '呼ぶ人間' "$test_dir/err" || { echo "FAIL ($mode) 人間に知らせる文が出ない" >&2; exit 1; }
	# 追加の確認: 複数のコマンドは、すべてが multica のときだけ通す。Write・Edit は、通常の照合のまま
	expect_command pass 'multica issue get X | multica issue get Y'
	expect_command pass 'multica issue get X && multica issue comment add X --content "done"'
	expect_command stop 'multica issue get X; gh pr create'
	expect_command stop 'multica issue get X | cat'
	expect_command pass 'multica issue get $ISSUE_ID'
	expect_command stop 'multica issue get "$(echo x)"'
	expect_command stop 'multica issue get X > ~/.netrc'
	expect_command stop 'export GH_TOKEN=x; multica issue get X'
	expect_command stop 'cd sub && multica issue get X'
	expect_verdict pass "($mode) Write" "$(json_file_tool Write file_path "$work/docs/x.md")"
	expect_verdict stop "($mode) Write: .mcp.json" "$(json_file_tool Write file_path "$work/.mcp.json")"
}

# 仮のトークンの変数
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
	extra_env=("$var=fake-token")
	check_isolation_examples "トークン $var"
done
# 空のトークンの変数は、分離を壊さない
extra_env=(GH_TOKEN=)
expect_command pass 'gh pr create'
# 空の置き場の仮のファイル
extra_env=()
expect_command pass 'gh pr create'
printf 'fake: x\n' >"$hook_dir/gh-empty/hosts.yml"
check_isolation_examples '空の置き場の仮のファイル'
rm -f "$hook_dir/gh-empty/hosts.yml"
mkdir "$hook_dir/gh-empty/nested"
check_isolation_examples '空の置き場の仮のディレクトリ'
rmdir "$hook_dir/gh-empty/nested"
expect_command pass 'gh pr create'
# GH_CONFIG_DIR が、キットの空の置き場でない
extra_env=("GH_CONFIG_DIR=$home/.config/gh")
check_isolation_examples 'GH_CONFIG_DIR が別の場所'
extra_env=(GH_CONFIG_DIR=)
check_isolation_examples 'GH_CONFIG_DIR が空'
extra_env=()
echo 'PASS 認証の分離: 仮のトークンと空の置き場の仮のファイルで、multica だけを通し、二重引用符とバッククォートと引用していない区切りの展開を止める'
rm -f "$work/sub/link.json"

echo 'PASS guard-hook: PreToolUse のスクリプトの照合と分離の確認'
