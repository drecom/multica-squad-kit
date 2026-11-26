#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/guard-check-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
export TEMPLATE_AGENT_HOME="$test_dir/agent's home" TEST_GUARD_CALLS="$test_dir/calls"
mkdir -p "$test_dir/bin" "$TEMPLATE_AGENT_HOME/bin" "$TEMPLATE_AGENT_HOME/git-hooks" "$TEMPLATE_AGENT_HOME/allowed-repos.d" "$TEMPLATE_AGENT_HOME/template/shell/project-a"
mkdir -p "$test_dir/package/common"
cp -R "$root/common/shell" "$test_dir/package/common/"
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
chmod +x "$test_dir/bin/gh"
export PATH="$test_dir/bin:$PATH"
unset GH_HOST GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
# 人の gh の置き場と、役が使う空の置き場。人の置き場は、本物の gh が認証を読む場所の代わりである。
export GH_CONFIG_DIR="$test_dir/human-gh"
mkdir -p "$GH_CONFIG_DIR" "$TEMPLATE_AGENT_HOME/guard/gh-empty"
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/gh" >"$test_dir/shared-gh"
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/pre-push" >"$test_dir/shared-push"
reset_guards() {
 cp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
 cp "$test_dir/shared-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 chmod +x "$TEMPLATE_AGENT_HOME/bin/gh" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 : >"$TEST_GUARD_CALLS"
}
printf 'example/old\n' >"$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
printf 'old shell\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
printf 'old bash\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh"
printf 'example/neighbor\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
source_root=$1
root=$2
die() { echo "$*" >&2; exit 1; }
source "$source_root/lib/ui.sh"
source "$source_root/lib/host.sh"
prepare_project_host project-a example/one example/two example/third
DRIVER
run() { /bin/bash "$test_dir/driver" "$root" "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"; }
deny() {
 cp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/shared-before"
 if run; then echo 'unexpected success'; exit 1; fi
 [[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/old ]]
 [[ $(cat "$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv") == 'old shell' ]]
 [[ $(cat "$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh") == 'old bash' ]]
 cmp "$test_dir/shared-before" "$TEMPLATE_AGENT_HOME/allowed-repos"
 [[ -z $(find "$test_dir/package/tmp" -maxdepth 1 -name 'guard-check.*' -print) ]]
 grep -q '従来の許可とシェル起動ファイルを保って停止' "$test_dir/err"
}
reset_guards
for status in 401 403 404 500 empty bad-json 201; do
 TEST_GUARD_RESPONSE=$status deny
 grep -Eq '入力検証まで届きませんでした|想定外に成功' "$test_dir/err"
 grep -q '確認' "$test_dir/err"
done
echo 'PASS guard-check: 認証・権限・不明な応答・接続失敗・想定外の成功では止まり、従来の許可と起動ファイルを保つ'

reset_guards
sed 's|^ALLOWED_FILE=.*|ALLOWED_FILE=$TEMPLATE_AGENT_HOME/allowed-repos|' "$test_dir/shared-gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
deny
[[ ! -s $TEST_GUARD_CALLS ]]
grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
echo 'PASS guard-check: 共有の固定許可だけを読む古いガードは、起動ファイルを用意しただけで成功とせず拒否を検出する'

# 共有許可に選択全件があっても、空のプロジェクト許可で拒否しなければならない。
printf 'example/one\nexample/two\nexample/third\nexample/neighbor\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
for fixed in gh push both; do
 reset_guards
 if [[ $fixed == gh || $fixed == both ]]; then
  sed 's|^ALLOWED_FILE=.*|ALLOWED_FILE=$TEMPLATE_AGENT_HOME/allowed-repos|' "$test_dir/shared-gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
 fi
 if [[ $fixed == push || $fixed == both ]]; then
  sed 's|^ALLOWED_FILE=.*|ALLOWED_FILE=$TEMPLATE_AGENT_HOME/allowed-repos|' "$test_dir/shared-push" >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 fi
 cp "$TEMPLATE_AGENT_HOME/bin/gh" "$test_dir/expected-gh"
 cp "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "$test_dir/expected-push"
 deny
 cmp "$test_dir/expected-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
 cmp "$test_dir/expected-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
 grep -q '空の許可' "$test_dir/err"
 grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
 grep -q '管理者' "$test_dir/err"
 echo "PASS guard-check: $fixed が共有の全選択と選択外の許可を固定で読んでも、空の許可で検出し従来の設定を保つ"
done
printf 'example/neighbor\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"

# 先の二つだけでは成功にしない。三つ目を拒否する既存 gh を使う。
reset_guards
cp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/previous-gh"
chmod +x "$TEMPLATE_AGENT_HOME/bin/previous-gh"
{
 printf '#!/bin/bash\nif [[ " $* " == *" repos/example/third/git/refs "* ]]; then echo "existing gh denied third" >&2; exit 72; fi\n'
 printf 'exec %q "$@"\n' "$TEMPLATE_AGENT_HOME/bin/previous-gh"
} >"$TEMPLATE_AGENT_HOME/bin/gh"
cp "$TEMPLATE_AGENT_HOME/bin/gh" "$test_dir/expected-gh"
deny
cmp "$test_dir/expected-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
grep -q 'existing gh denied third' "$test_dir/err"
grep -q 'example/third' "$test_dir/err"
grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 4 ]]
echo 'PASS guard-check: マークのない既存 gh が三つ目を拒否すると、その理由と直し方を出して全選択の反映前に止まる'

reset_guards
cp "$test_dir/shared-push" "$TEMPLATE_AGENT_HOME/git-hooks/previous-push"
chmod +x "$TEMPLATE_AGENT_HOME/git-hooks/previous-push"
{
 printf '#!/bin/bash\nif [[ $2 == https://github.com/example/third.git ]]; then echo "existing push denied third" >&2; exit 73; fi\n'
 printf 'exec %q "$@"\n' "$TEMPLATE_AGENT_HOME/git-hooks/previous-push"
} >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
cp "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "$test_dir/expected-push"
deny
cmp "$test_dir/expected-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
grep -q 'existing push denied third' "$test_dir/err"
grep -q 'pre-push が選択先を拒否' "$test_dir/err"
grep -q 'SQUAD_KIT_ALLOWED_REPOS' "$test_dir/err"
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 5 ]]
echo 'PASS guard-check: マークのない既存 pre-push が後ろの選択を拒否しても、既存ファイルを変えず対処を案内する'

# 前の頭で拒否するマークのないガード。前の頭は、bash 3.2 の printf が展開する 16 進のエスケープで、UTF-8 のバイト列として書く。
previous_gh_head=$(printf 'gh \xe3\x81\xae\xe9\x96\xa2\xe6\x89\x80:')
previous_push_head=$(printf 'git push \xe3\x81\xae\xe9\x96\xa2\xe6\x89\x80:')
reset_guards
sed "s|gh のガード:|$previous_gh_head|" "$test_dir/shared-gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
cp "$TEMPLATE_AGENT_HOME/bin/gh" "$test_dir/expected-gh"
deny
cmp "$test_dir/expected-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
grep -q '拒否の文が「gh のガード:」で始まりません。前のバージョンのガードか、マークのないガードです' "$test_dir/err"
grep -q "^$previous_gh_head" "$test_dir/err"
grep -q '既存のガードの確認' "$test_dir/err"
! grep -q '拒否したと確認できません' "$test_dir/err"
echo 'PASS guard-check: 前の頭で拒否するマークのない gh は、頭が違う文と拒否の文を出し、既存のガードの確認を案内して止まる'

reset_guards
sed "s|git push のガード:|$previous_push_head|" "$test_dir/shared-push" >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
cp "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "$test_dir/expected-push"
deny
cmp "$test_dir/expected-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
grep -q '拒否の文が「git push のガード:」で始まりません。前のバージョンのガードか、マークのないガードです' "$test_dir/err"
grep -q "^$previous_push_head" "$test_dir/err"
grep -q '既存のガードの確認' "$test_dir/err"
! grep -q 'のガードによる拒否を確認できません' "$test_dir/err"
echo 'PASS guard-check: 前の頭で拒否するマークのない pre-push は、頭が違う文と拒否の文を出し、既存のガードの確認を案内して止まる'

# 標準エラーが空の拒否は頭が違うとは言えないので、今の文のまま止まる。
reset_guards
cp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/previous-gh"
chmod +x "$TEMPLATE_AGENT_HOME/bin/previous-gh"
printf '#!/bin/bash\nexec %q "$@" 2>/dev/null\n' "$TEMPLATE_AGENT_HOME/bin/previous-gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
deny
grep -q '空の許可で選択先を拒否したと確認できません' "$test_dir/err"
! grep -q '始まりません' "$test_dir/err"
echo 'PASS guard-check: 標準エラーが空の拒否は頭が違う文にせず、今の文のまま止まる'

reset_guards
run
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 3 ]]
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 6 ]]
for repo in one two third; do
 [[ $(grep -c "repos/example/$repo/git/refs" "$TEST_GUARD_CALLS") == 2 ]]
done
cmp "$test_dir/shared-gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$test_dir/shared-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos") == example/neighbor ]]
printf 'example/one\nexample/two\nexample/third\n' >"$test_dir/expected-allowed"
cmp "$test_dir/expected-allowed" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
echo 'PASS guard-check: マークのない実際のガードを bash・zsh と起動ファイルから通し、全三リポジトリの確認後に許可を反映する'
TEST_GUARD_RESPONSE=409 run
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 3 ]]
echo 'PASS guard-check: 空リポジトリなどの GitHub の409応答もガード通過として確認し、参照を作らない'

# gh 2.104.0 以降の help の形（--include[=true|false]）でも、ガードを通して確認が最後まで進む。
reset_guards
TEST_GUARD_BOOL_FORM=brackets run
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 3 ]]
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 6 ]]
echo 'PASS guard-check: bool のフラグが --name[=true|false] の形でも、ガードを通して許可の確認が最後まで進む'

# PATH を直さない古い起動ファイルでは、絶対パスのガードだけを確認して成功にしない。
for file in .zshenv env.sh; do
 head -n 2 "$root/common/shell/$file" >"$test_dir/package/common/shell/$file"
done
printf 'example/old\n' >"$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
printf 'old shell\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
printf 'old bash\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh"
reset_guards
deny
grep -q '通常の gh がガードを選びません' "$test_dir/err"
[[ ! -s $TEST_GUARD_CALLS ]]
echo 'PASS guard-check: 通常の gh が本物を先に選ぶと、通信せず既存の許可と起動ファイルを保って止まる'

# 役の gh の認証の分離を確認できないときは、通信もファイルの反映もせずに止まり、直し方を出す。
cp "$root/common/shell/.zshenv" "$root/common/shell/env.sh" "$test_dir/package/common/shell/"
# 成功した実行が書き換えた許可と起動ファイルを、従来の内容へ戻す。
restore_old() {
 printf 'example/old\n' >"$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
 printf 'old shell\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/.zshenv"
 printf 'old bash\n' >"$TEMPLATE_AGENT_HOME/template/shell/project-a/env.sh"
}
restore_old
reset_guards
run
restore_old
echo 'PASS guard-check: 分離の確認がそろっていれば、続けて通る'

for token in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
 reset_guards
 export "$token=secret-test-value"
 deny
 unset "$token"
 grep -q "セットアップを流した端末に ${token} があります" "$test_dir/err"
 grep -q '新しい端末でセットアップを流し直してください' "$test_dir/err"
 ! grep -q 'secret-test-value' "$test_dir/err" "$test_dir/out"
 [[ ! -s $TEST_GUARD_CALLS ]]
done
reset_guards
export GH_TOKEN=secret-a GITHUB_TOKEN=secret-b
deny
unset GH_TOKEN GITHUB_TOKEN
grep -q 'セットアップを流した端末に GH_TOKEN、GITHUB_TOKEN があります' "$test_dir/err"
# 空の値は、gh も設定ありとして扱わない。
reset_guards
GH_TOKEN= run
restore_old
echo 'PASS guard-check: トークンの変数があると、名前（値は出さない）と直し方を出し、通信せず従来の設定を保って止まる'

reset_guards
printf 'token\n' >"$TEMPLATE_AGENT_HOME/guard/gh-empty/hosts.yml"
touch "$TEMPLATE_AGENT_HOME/guard/gh-empty/.hidden"
deny
rm -f "$TEMPLATE_AGENT_HOME/guard/gh-empty/hosts.yml" "$TEMPLATE_AGENT_HOME/guard/gh-empty/.hidden"
grep -q '空の gh の置き場にファイルがあります' "$test_dir/err"
grep -q 'hosts.yml' "$test_dir/err"
grep -q '.hidden' "$test_dir/err"
grep -q '中のファイルを消してから、セットアップを流し直してください' "$test_dir/err"
[[ ! -s $TEST_GUARD_CALLS ]]
reset_guards
rmdir "$TEMPLATE_AGENT_HOME/guard/gh-empty"
deny
mkdir "$TEMPLATE_AGENT_HOME/guard/gh-empty"
grep -q '空の gh の置き場がありません' "$test_dir/err"
echo 'PASS guard-check: 空の置き場にファイルがあるか、置き場がないと、直し方を出して止まる'

# 置き場の外の認証（キーチェーンなど）が残っていて、空の置き場でも gh が認証済みなら止まる。
reset_guards
TEST_GH_AUTH=yes TEST_GH_AUTH_CALLS="$test_dir/auth-calls" deny
grep -q '空の gh の置き場でも、本物の gh' "$test_dir/err"
grep -q 'gh auth status の表示から認証の置き場' "$test_dir/err"
grep -q 'Logged in (test)' "$test_dir/err"
# 確認は、役と同じ空の置き場を指して行う。
[[ $(cat "$test_dir/auth-calls") == "$TEMPLATE_AGENT_HOME/guard/gh-empty" ]]
[[ ! -s $TEST_GUARD_CALLS ]]
echo 'PASS guard-check: 空の置き場でも本物の gh が認証済みなら、認証の置き場を探す案内を出して止まる'

# 人の gh の置き場が見つからなければ、gh auth login を案内して止まる。
reset_guards
saved_config=$GH_CONFIG_DIR
export GH_CONFIG_DIR="$test_dir/no-human-gh"
deny
export GH_CONFIG_DIR=$saved_config
grep -q '人の gh の置き場が見つかりません' "$test_dir/err"
grep -q 'gh auth login' "$test_dir/err"
echo 'PASS guard-check: 人の gh の置き場がなければ、gh auth login を案内して止まる'
