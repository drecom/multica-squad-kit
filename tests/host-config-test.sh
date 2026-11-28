#!/usr/bin/env bash
# この部分は、停止・起動の失敗・片方だけのランタイム・同居環境の既存ファイル・Codex の設定の読み方と厳しい検証を確認する。
set -euo pipefail
source "$(dirname "$0")/host-test-lib.sh"
# 前の部分が作る導入済みのホストを用意する。
set_mode stopped
run
agent_env

for fail in 'daemon status --output json' 'runtime list --output json'; do
 set_mode running
 printf '%s\n' "$fail" >"$test_dir/fail"
 deny
 if grep -Eq '^daemon (stop|start)$' "$test_dir/calls"; then exit 1; fi
done
rm "$test_dir/fail"
echo 'PASS host: 状態・ランタイムの取得失敗を、停止してよい状態と扱わない'
set_mode running
printf wrong >"$test_dir/process-env"
printf 'daemon stop\n' >"$test_dir/fail"
deny
if grep -q '^daemon start$' "$test_dir/calls"; then exit 1; fi
set_mode stopped
printf 'daemon start\n' >"$test_dir/fail"
deny
rm "$test_dir/fail"
set_mode stopped
touch "$test_dir/no-runtimes"
deny
grep -q 'オンラインになりません' "$test_dir/err"
[[ $(grep -c '^daemon start$' "$test_dir/calls") == 1 ]]
rm "$test_dir/no-runtimes"
echo 'PASS host: 停止・起動の失敗とオンライン待ちの上限を失敗として返す'
# 使わない側はコマンドなし・未ログイン・オフラインでも準備できる。
for selected in claude codex; do
 (
  export TEST_RUNTIMES="[\"$selected\"]" TEST_RUNTIME_LIST="$test_dir/selected-runtime.json"
  export TEMPLATE_AGENT_HOME="$test_dir/$selected-only"
  if [[ $selected == claude ]]; then export TEST_MISSING_RUNTIME=codex; else export TEST_MISSING_RUNTIME=claude; fi
  touch "$test_dir/no-$TEST_MISSING_RUNTIME-auth"
  : >"$test_dir/codex-checks"
  printf '[{"id":"runtime-%s","owner_id":"member-a","daemon_id":"daemon-a","provider":"%s","status":"online"}]\n' "$selected" "$selected" >"$TEST_RUNTIME_LIST"
  set_mode stopped
  run
  grep -qx 'daemon start' "$test_dir/calls"
  if [[ $selected == claude ]]; then
   [[ ! -e $TEMPLATE_AGENT_HOME/codex/config.toml ]]
   ! grep -q '使用する Codex の設定' "$test_dir/err"
   [[ ! -s $test_dir/codex-checks ]]
   printf 'invalid existing config\n' >"$TEMPLATE_AGENT_HOME/codex/config.toml"
  else
   expected_codex_config
   cmp "$test_dir/expected-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
   [[ ! -e $TEMPLATE_AGENT_HOME/claude/settings.json ]]
  fi
  set_mode busy
  agent_env
  run
  ! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
  if [[ $selected == claude ]]; then grep -qx 'invalid existing config' "$TEMPLATE_AGENT_HOME/codex/config.toml"; fi
  touch "$test_dir/no-$selected-auth"
  : >"$test_dir/calls"
  deny
  grep -q 'ログインしてください' "$test_dir/err"
  [[ ! -s $test_dir/calls ]]
  rm "$test_dir/no-$selected-auth" "$test_dir/no-$TEST_MISSING_RUNTIME-auth"
 )
 echo "PASS host: $selected だけで起動・再利用し、選んだ側の認証を求め、使わない側は求めない"
done
# Claude を使うとき、最低より古いか読めない Claude Code では、何も書かず、デーモンにも触れずに止まる。
set_mode running
agent_env
snapshot() { (cd "$TEMPLATE_AGENT_HOME" && find . | LC_ALL=C sort && find . -type f -exec cksum {} +); }
snapshot >"$test_dir/before-version"
for version in '2.1.321 (Claude Code)' '2.0.999' '1.99.1' 'unknown' ''; do
 : >"$test_dir/calls"
 TEST_CLAUDE_VERSION=$version deny
 grep -q '最低\|読めません' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
 snapshot >"$test_dir/after-version"
 cmp "$test_dir/before-version" "$test_dir/after-version"
done
TEST_RUNTIMES='["codex"]' TEST_CLAUDE_VERSION=1.0.0 run
echo 'PASS host: 最低より古いか読めない Claude Code では、何も書かずに止まり、Codex だけなら止まらない'
# 同居する既存システムの Mac の代わり。マークのないファイルと資格情報を残す。
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/pre-push" >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
printf '# existing codex config\nallow_login_shell = false\n%s\n' "$(trust_lines)" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
printf 'original allowed repository\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
printf 'existing credential\n' >"$TEMPLATE_AGENT_HOME/claude/credentials.json"
printf 'existing codex credential\n' >"$TEMPLATE_AGENT_HOME/codex/auth.json"
mkdir "$test_dir/original"
for file in bin/gh git-hooks/pre-push codex/config.toml allowed-repos claude/credentials.json codex/auth.json; do
 mkdir -p "$test_dir/original/$(dirname "$file")"
 cp "$TEMPLATE_AGENT_HOME/$file" "$test_dir/original/$file"
done
set_mode running
agent_env
printf "# multica-squad-kit-managed\nchanged\n" >"$TEMPLATE_AGENT_HOME/bin/squad-pr-watch"
for file in squad-pr-link squad-pr-link-lib; do
 printf '# multica-squad-kit-managed\nold\n' >"$TEMPLATE_AGENT_HOME/bin/$file"
 chmod 644 "$TEMPLATE_AGENT_HOME/bin/$file"
done
run
for file in bin/gh git-hooks/pre-push codex/config.toml allowed-repos claude/credentials.json codex/auth.json; do cmp "$TEMPLATE_AGENT_HOME/$file" "$test_dir/original/$file"; done
cmp "$root/common/monitor/squad-pr-watch" "$TEMPLATE_AGENT_HOME/bin/squad-pr-watch"
grep -q 'マークのない既存' "$test_dir/err"
echo 'PASS host: マークのない同居環境のガード・設定・資格情報・共有許可ファイルを変えず、専用の見張りだけ更新する'
for file in squad-pr-link squad-pr-link-lib; do
 cmp "$root/common/monitor/$file" "$TEMPLATE_AGENT_HOME/bin/$file"
 [[ -x $TEMPLATE_AGENT_HOME/bin/$file ]]
done
echo 'PASS host: 流し直しでマークのある PR の紐付けコマンドと共有関数を原本に更新し、実行権限を付ける'

for display in "使用する gh のガード: $TEMPLATE_AGENT_HOME/bin/gh" "使用する git push のガード: $TEMPLATE_AGENT_HOME/git-hooks/pre-push" "使用する Codex の設定: $TEMPLATE_AGENT_HOME/codex/config.toml"; do grep -qxF "$display" "$test_dir/err"; done
echo 'PASS host: マークのない既存を保持する場合も、使用する三つの実ファイルを明示する'
for invalid in '' 'allow_login_shell = true' 'allow_login_shell = "false"' 'allow_login_shell = 0' $'[profiles.other]\nallow_login_shell = false' $'allow_login_shell = false\nallow_login_shell = false' 'allow_login_shell = ['; do
 printf '%s\n' "$invalid" "$(trust_lines)" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/invalid-config"
 : >"$test_dir/calls"
 deny
 cmp "$test_dir/invalid-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
 # TOML として読めない設定は、信頼の値も読めないので、信頼の確認で止める（どちらも何も書く前に止まる）。
 grep -qE 'allow_login_shell = false を確認できません|信頼の記録がない' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
done
cp "$test_dir/original/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
echo 'PASS host: 確認した起動ファイルを使えない Codex の既存設定は保持し、直し方を出してデーモン操作前に止まる'

for valid in '"allow_login_shell" = false' "'allow_login_shell' = false" $'allow_login_shell = false # comment\n[profiles.other]\nallow_login_shell = true'; do
 printf '%s\n' "$valid" "$(trust_lines)" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/valid-config"
 set_mode running
 agent_env
 run
 cmp "$test_dir/valid-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
 grep -q '^daemon status' "$test_dir/calls"
done
echo 'PASS host: TOML の引用キーとトップレベルの真偽値 false を読み、別テーブルの同名キーを混同しない'

for delimiter in '"""' "'''"; do
 printf '%s\n' "model_instructions = $delimiter" 'allow_login_shell = false' "$delimiter" "$(trust_lines)" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/multiline-config"
 : >"$test_dir/calls"
 deny
 cmp "$test_dir/multiline-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
 grep -qF 'allow_login_shell = false を確認できません' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
 # 文字列内に true があっても、本物のトップレベルの false を使う。
 printf '%s\n' 'allow_login_shell = false' "model_instructions = $delimiter" 'allow_login_shell = true' "$delimiter" "$(trust_lines)" >"$TEMPLATE_AGENT_HOME/codex/config.toml"
 cp "$TEMPLATE_AGENT_HOME/codex/config.toml" "$test_dir/multiline-config"
 run
 cmp "$test_dir/multiline-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
done
cp "$test_dir/original/codex/config.toml" "$TEMPLATE_AGENT_HOME/codex/config.toml"
echo 'PASS host: 基本・リテラルの複数行文字列をキーと扱わず、本物のトップレベルの値だけを判定する'

for spec in 'guard/gh:bin/gh' 'guard/pre-push:git-hooks/pre-push' 'codex/config.toml:codex/config.toml'; do
 target=${spec#*:}
 printf '# multica-squad-kit-managed\nold\n' >"$TEMPLATE_AGENT_HOME/$target"
done
run
cmp "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh"
cmp "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
expected_codex_config
cmp "$test_dir/expected-config" "$TEMPLATE_AGENT_HOME/codex/config.toml"
echo 'PASS host: マークのある共有ファイルは 原本の内容へ更新する'

# マークのない設定に 2 つのキーがないときは、警告して書き換えずに先へ進む。
config=$TEMPLATE_AGENT_HOME/codex/config.toml
for unmarked in $'allow_login_shell = false' $'allow_login_shell = false\ncheck_for_update_on_startup = true\n[analytics]\nenabled = false' $'allow_login_shell = false\ncheck_for_update_on_startup = false\n[analytics]\nenabled = "false"' $'allow_login_shell = false\ncheck_for_update_on_startup = false\n[analytics]\nother = false'; do
 printf '%s\n' "$unmarked" "$(trust_lines)" >"$config"
 cp "$config" "$test_dir/unmarked-config"
 set_mode running
 agent_env
 run
 cmp "$config" "$test_dir/unmarked-config"
 grep -qF '警告: マークのない設定に、更新の確認と利用状況の送信を切るキーがありません' "$test_dir/err"
 grep -q '^daemon status' "$test_dir/calls"
done
printf '%s\n' $'allow_login_shell = false\ncheck_for_update_on_startup = false' "$(trust_lines)" >"$config"
run
grep -qF '[analytics] の enabled = false' "$test_dir/err"
! grep -qF 'check_for_update_on_startup' "$test_dir/err"
printf '%s\n' $'allow_login_shell = false\n[analytics]\nenabled = false' "$(trust_lines)" >"$config"
run
grep -qF 'check_for_update_on_startup = false' "$test_dir/err"
! grep -qF 'analytics' "$test_dir/err"
printf '%s\n' $'allow_login_shell = false\ncheck_for_update_on_startup = false\n[analytics]\nenabled = false' "$(trust_lines)" >"$config"
run
! grep -qF 'マークのない設定に' "$test_dir/err"
echo 'PASS host: マークのない Codex の設定に 2 つのキーがないときだけ、書き換えずに警告して進む'

# フックの信頼。hooks/list の値を設定に書き、読めないときは何も書かずに止まる。
hooks_calls=$test_dir/codex-hooks-calls
rm -f "$config"
: >"$hooks_calls"
echo ok >"$test_dir/codex-hooks"
set_mode running
agent_env
run
expected_codex_config
cmp "$test_dir/expected-config" "$config"
# app-server は、役と同じフックの -c の引数と、役と同じ CODEX_HOME で起こす。
python3 - "$hooks_calls" "$TEMPLATE_AGENT_HOME" <<'PY'
import json
import sys

calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
guard = sys.argv[2] + "/guard"


def quote(path):
    return "'" + path.replace("'", "'\\''") + "'"


assert len(calls) == 1, calls
assert calls[0]["home"] == sys.argv[2] + "/codex", calls
assert calls[0]["args"] == [
    "app-server", "--listen", "stdio://",
    "-c", 'hooks.PreToolUse=[{matcher="^(Bash|shell|exec_command|local_shell)$",hooks=[{type="command",command=%s}]}]' % json.dumps(quote(guard + "/pre-tool-use")),
    "-c", 'hooks.Stop=[{hooks=[{type="command",command=%s}]}]' % json.dumps(quote(guard + "/stop"))], calls
PY
# 人の設定のフック（source が人の設定）は、キットのフックと取り違えない。
! grep -q 'human' "$config"
# 同じ入力の流し直しは、同じ設定を保つ。
cp "$config" "$test_dir/trusted-config"
run
cmp "$test_dir/trusted-config" "$config"
# 古い信頼の値は、hooks/list の今の値に更新する。
sed 's/trusted_hash = "sha256:[0-9a-f]*"/trusted_hash = "sha256:old"/' "$test_dir/trusted-config" >"$config"
run
cmp "$test_dir/trusted-config" "$config"
echo 'PASS host: hooks/list が返した 2 つのフックの鍵と currentHash を、役と同じ引数で起こした app-server から読んで設定に書く'

# 通知と応答が 1 回の書き込みで届いても、応答を取りこぼさずに同じ設定を書く。
rm -f "$config"
echo batched >"$test_dir/codex-hooks"
set_mode running
agent_env
TEST_CODEX_SECONDS=5 run
expected_codex_config
cmp "$test_dir/expected-config" "$config"
echo ok >"$test_dir/codex-hooks"
echo 'PASS host: 通知と hooks/list の応答が同じ書き込みで届いても、応答を読んで設定に書く'

# 読めない・足りないときは、何も書かず、Codex の出力も写さずに止まる。
for failure in unreadable garbled exit empty pre-only stop-only other-command hang; do
 rm -f "$config"
 : >"$hooks_calls"
 echo "$failure" >"$test_dir/codex-hooks"
 set_mode running
 agent_env
 TEST_CODEX_SECONDS=1 deny
 [[ ! -e $config ]]
 grep -qE 'hooks/list|フックの一覧' "$test_dir/err"
 ! grep -q 'SYNTHETIC_SECRET_VALUE' "$test_dir/out" "$test_dir/err"
 ! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
done
echo ok >"$test_dir/codex-hooks"
echo 'PASS host: hooks/list を読めない・応答が壊れている・フックが足りないとき、設定を書かず、Codex の出力を写さずに止まる'

# マークのない設定は書き換えない。信頼が合うときは先へ進み、足りないときは足す行を出して、何も書く前に止まる。
unmarked_keys=$'allow_login_shell = false\ncheck_for_update_on_startup = false\n[analytics]\nenabled = false'
echo ok >"$test_dir/codex-hooks"
printf '%s\n' "$unmarked_keys" >"$config"
cp "$config" "$test_dir/unmarked-config"
set_mode running
agent_env
deny
cmp "$config" "$test_dir/unmarked-config"
# 信頼がないと、足す行（2 つの鍵と trusted_hash）を表示する。
grep -qF "$config" "$test_dir/err"
grep -qF 'の行を足してから' "$test_dir/err"
[[ $(grep -c '^\[hooks\.state\.' "$test_dir/err") == 2 && $(grep -c '^trusted_hash = "sha256:' "$test_dir/err") == 2 ]]
# 表示した行を足した設定は、書き換えず、止めない。
{ printf '%s\n' "$unmarked_keys"; grep -E '^\[hooks\.state\.|^trusted_hash' "$test_dir/err"; } >"$test_dir/unmarked-trusted"
cp "$test_dir/unmarked-trusted" "$config"
run
cmp "$config" "$test_dir/unmarked-trusted"
# 信頼の値が hooks/list と違うときは、合っていないものとして止める。
sed 's/trusted_hash = "sha256:[0-9a-f]*"/trusted_hash = "sha256:old"/' "$test_dir/unmarked-trusted" >"$config"
cp "$config" "$test_dir/unmarked-stale"
deny
cmp "$config" "$test_dir/unmarked-stale"
grep -qF 'trusted_hash = "sha256:' "$test_dir/err"
! grep -qF 'sha256:old' "$test_dir/err"
printf '%s\n' "$unmarked_keys" >"$config"
echo 'PASS host: マークのない設定は、信頼がなければ足す行を出して何も書く前に止まり、信頼が合えば書き換えずに進む'

unset TEST_TRUST_OUT TEST_DISABLED_OUT
echo ok >"$test_dir/codex-hooks"

# 設定の検証。0 で進み、0 以外で止まり、古い Codex と時間切れは警告して進む。
cp "$test_dir/original/codex/config.toml" "$config"
cp "$root/common/codex/config.toml" "$config"
: >"$test_dir/codex-checks"
echo ok >"$test_dir/codex-strict"
set_mode running
agent_env
run
[[ $(wc -l <"$test_dir/codex-checks") -eq 1 ]]
! grep -qF 'strict-config' "$test_dir/err"
for failure in fail silent other2 secret; do
 echo "$failure" >"$test_dir/codex-strict"
 cp "$config" "$test_dir/strict-config"
 set_mode running
 agent_env
 deny
 grep -qF 'Codex の設定が厳しい検証を通りません' "$test_dir/err"
 grep -qF 'キーを直すか消してから、セットアップを流し直してください' "$test_dir/err"
 grep -qF '終了コード' "$test_dir/err"
 grep -qF -- '--strict-config --listen stdio:// </dev/null' "$test_dir/err"
 # Codex の出力は、秘密値を含みうるので表示しない。
 ! grep -qF 'bogus' "$test_dir/err"
 ! grep -qF 'another usage error' "$test_dir/err"
 ! grep -qF 'SYNTHETIC_SECRET_VALUE' "$test_dir/err"
 cmp "$config" "$test_dir/strict-config"
 [[ ! -s $test_dir/calls ]]
done
# Codex を起動できないときは、設定の誤りと別の表示にし、設定のキーを直す案内を出さない。
# 検証の処理が「起動できない」と返す。実際に起動できない場合は tests/codex-check-test.sh が確認する。
mkdir -p "$test_dir/py-bin"
cat >"$test_dir/py-bin/python3" <<'STUB'
#!/bin/bash
if [[ ${1:-} == */lib/codex-check.py ]]; then printf 'launch\n\n'; exit 0; fi
PATH=${PATH#*py-bin:} exec python3 "$@"
STUB
chmod +x "$test_dir/py-bin/python3"
PATH="$test_dir/py-bin:$PATH" deny
grep -qF 'Codex を起動できませんでした' "$test_dir/err"
grep -qF 'PATH に codex があり実行できることを確認' "$test_dir/err"
! grep -qF '設定が厳しい検証を通りません' "$test_dir/err"
! grep -qF 'キーを直すか消して' "$test_dir/err"
! grep -qF '終了コード' "$test_dir/err"
# ログインの確認は、書き換える前の確認なので、設定の検証より先にあり、ログイン切れなら設定の誤りより先に出す。
echo fail >"$test_dir/codex-strict"
touch "$test_dir/no-codex-auth"
deny
grep -qF 'codex login' "$test_dir/err"
! grep -qF 'Codex の設定が厳しい検証を通りません' "$test_dir/err"
rm "$test_dir/no-codex-auth"
deny
grep -qF 'Codex の設定が厳しい検証を通りません' "$test_dir/err"
echo ok >"$test_dir/codex-strict"
echo 'PASS host: Codex の検証が 0 以外で書き換えずに止まり、ログインの確認は設定の検証より先に止める'

# 拡張を使うセットアップでは root が lib を持たない作業場所を指す。検証の処理は原本（kit_root）の lib から呼び、検証の結果も通常どおり扱う。
mkdir -p "$test_dir/extension-work"
cp -R "$root/common" "$root/skeleton" "$test_dir/extension-work/"
[[ ! -e $test_dir/extension-work/lib ]]
: >"$test_dir/codex-checks"
echo ok >"$test_dir/codex-strict"
set_mode running
agent_env
TEST_EXTENSION_WORK="$test_dir/extension-work" run
[[ $(wc -l <"$test_dir/codex-checks") -eq 1 ]]
if grep -qF 'Codex の設定の検証を実行できませんでした' "$test_dir/err"; then exit 1; fi
echo fail >"$test_dir/codex-strict"
set_mode running
agent_env
TEST_EXTENSION_WORK="$test_dir/extension-work" deny
grep -qF 'Codex の設定が厳しい検証を通りません' "$test_dir/err"
if grep -qF 'Codex の設定の検証を実行できませんでした' "$test_dir/err"; then exit 1; fi
echo ok >"$test_dir/codex-strict"
echo 'PASS host: 拡張の作業場所へ root を付け替えても、原本の lib の検証の処理を呼び、結果を通常どおり扱う'
