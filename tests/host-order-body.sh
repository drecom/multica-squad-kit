# 更新が書くものと止める確認の表（tests/fixtures/host-update-order.tsv）の本体。tests/host-order-1-test.sh から 3 つの test が
# HOST_ORDER_SHARD（k/3）を決めて source し、表の行を 3 つに分けて流す。1 本が 450 秒の上限に収まるようにするため。
source "${BASH_SOURCE[0]%/*}/host-test-lib.sh"
shard=${HOST_ORDER_SHARD:?}
shard_index=${shard%/*} shard_count=${shard#*/}
settings=$TEMPLATE_AGENT_HOME/claude/settings.json
set_mode stopped
run
# マークのある設定を、人の設定（信頼なし）に替えて、足す信頼の行を読み、信頼が合う人の設定を作る。
config=$TEMPLATE_AGENT_HOME/codex/config.toml
unmarked_keys=$'allow_login_shell = false\ncheck_for_update_on_startup = false\n[analytics]\nenabled = false'
echo ok >"$test_dir/codex-hooks"
printf '%s\n' "$unmarked_keys" >"$config"
set_mode running
agent_env
deny
{ printf '%s\n' "$unmarked_keys"; grep -E '^\[hooks\.state\.|^trusted_hash' "$test_dir/err"; } >"$test_dir/unmarked-trusted"
# 更新が書くものと止める確認の表（tests/fixtures/host-update-order.tsv）。行ごとに、止めたあとの $agent_home の全ファイルが止める前と同じことを確認する。
# 書き換わる行（none）が実際に書き換えることも確認し、止めた行の「変わらない」が書く手順を流さなかっただけの結果でないようにする。
# 内容だけでなく、種類・権限・リンク先と、ディレクトリの有無と権限も比べる。
snapshot_home() {
 python3 - "$TEMPLATE_AGENT_HOME" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
rows = []
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        path = os.path.join(base, name)
        info = os.lstat(path)
        kind = "link" if stat.S_ISLNK(info.st_mode) else "dir" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "special"
        detail = os.readlink(path) if kind == "link" else hashlib.sha256(open(path, "rb").read()).hexdigest() if kind == "file" else ""
        rows.append("%s %s %o %s" % (os.path.relpath(path, root), kind, stat.S_IMODE(info.st_mode), detail))
print(hashlib.sha256("\n".join(sorted(rows)).encode()).hexdigest())
PY
}
unset TEST_TRUST_OUT TEST_DISABLED_OUT
order_rows=0 row_no=0
rm -rf "$TEMPLATE_AGENT_HOME"
mkdir -p "$TEMPLATE_AGENT_HOME"
echo ok >"$test_dir/codex-hooks"
set_mode running
agent_env
run
rm -rf "$test_dir/installed-home"
cp -R "$TEMPLATE_AGENT_HOME" "$test_dir/installed-home"
while IFS=$'\t' read -r id state refusal message remain; do
 [[ -n $id && $id != '#'* ]] || continue
 row_no=$((row_no + 1))
 # この test が受け持つ行だけを流す（残りは、ほかの 2 つの test が流す）。
 (( row_no % shard_count + 1 == shard_index )) || continue
 order_rows=$((order_rows + 1))
 # 入れたあとの状態から、管理するファイルを古くして、書けば変わる形にする。
 echo ok >"$test_dir/codex-hooks"
 chmod -R u+rwx "$TEMPLATE_AGENT_HOME" 2>/dev/null || true
 rm -rf "$TEMPLATE_AGENT_HOME"
 cp -R "$test_dir/installed-home" "$TEMPLATE_AGENT_HOME"
 set_mode running
 agent_env
 while IFS= read -r file; do
  case $file in
  "$settings" | "$config") ;;
  *) printf '# stale\n' >>"$file" ;;
  esac
 done < <(find "$TEMPLATE_AGENT_HOME" -type f)
 printf '%s\n' '{"theme":"dark"}' >"$settings"
 case $state in
 managed) sed 's/trusted_hash = "sha256:[0-9a-f]*"/trusted_hash = "sha256:old"/' "$config" >"$test_dir/old-config"; cp "$test_dir/old-config" "$config" ;;
 new) rm -f "$config" ;;
 unmarked) printf '%s\n' "$unmarked_keys" >"$config" ;;
 unmarked-fresh) cp "$test_dir/unmarked-trusted" "$config" ;;
 unmarked-trusted) sed 's/trusted_hash = "sha256:[0-9a-f]*"/trusted_hash = "sha256:old"/' "$test_dir/unmarked-trusted" >"$config" ;;
 *) echo "表の状態が不明です: $state" >&2; exit 1 ;;
 esac
 # 空の置き場の権限は、止めた行で変わらないことを見るため、既定の 700 と違う値にしておく。
 chmod 750 "$TEMPLATE_AGENT_HOME/guard/gh-empty"
 target='' fixed=no
 case $refusal in
 guard:* | guard-link:*) target=$TEMPLATE_AGENT_HOME/guard/${refusal#*:} ;;
 link:* | readonly:* | dirro:* | special:*) target=$TEMPLATE_AGENT_HOME/${refusal#*:} ;;
 noexec:*) target=$TEMPLATE_AGENT_HOME/${refusal#noexec:} ;;
 login-shell) target=$config ;;
 esac
 case $refusal in
 guard:*) printf '# 人のファイル\n' >"$target" ;;
 guard-link:* | link:*)
  # 設定のリンクは、リンク先が管理済みの設定でも止まることを見る。
  cp "$target" "$test_dir/link-target" 2>/dev/null || echo ok >"$test_dir/link-target"
  rm -f "$target"; ln -s "$test_dir/link-target" "$target" ;;
 readonly:*) chmod 444 "$target" ;;
 dirro:*) [[ $refusal == dirro:claude/settings.json ]] || rm -f "$target"; chmod 555 "${target%/*}" ;;
 special:*) rm -f "$target"; mkfifo "$target" ;;
 noexec:*) printf '# 人のファイル\n' >"$target"; chmod 644 "$target" ;;
 login-shell) sed 's/allow_login_shell = false/allow_login_shell = true/' "$test_dir/unmarked-trusted" >"$config" ;;
 esac
 before=$(snapshot_home)
 set_mode running
 agent_env
 case $refusal in
 none) run ;;
 hooks:*) echo "${refusal#hooks:}" >"$test_dir/codex-hooks"; TEST_CODEX_SECONDS=1 deny ;;
 env:*) env "${refusal#env:}=x" /bin/bash "$test_dir/run.sh" "$root" >"$test_dir/out" 2>"$test_dir/err" && exit 1; [[ -s $test_dir/err ]] ;;
 gh-empty-file) : >"$TEMPLATE_AGENT_HOME/guard/gh-empty/hosts.yml"; before=$(snapshot_home); deny ;;
 disable-all-hooks) printf '%s\n' '{"disableAllHooks":true}' >"$settings"; before=$(snapshot_home); deny ;;
 claude-auth) touch "$test_dir/no-claude-auth"; deny; rm -f "$test_dir/no-claude-auth" ;;
 codex-auth) touch "$test_dir/no-codex-auth"; deny; rm -f "$test_dir/no-codex-auth" ;;
 untrusted | stale) deny ;;
 guard:* | guard-link:* | link:* | noexec:* | login-shell | readonly:* | dirro:*) fixed=yes; deny ;;
 special:*) fixed=yes; TEST_LIMIT=30 deny ;;
 *) echo "表の止める条件が不明です: $refusal" >&2; exit 1 ;;
 esac
 if [[ $refusal == none ]]; then
  [[ $(snapshot_home) != "$before" ]] || { echo "書き換わらない行: $id" >&2; exit 1; }
 else
  grep -qF -- "$message" "$test_dir/err" || { echo "表示が違う行: $id" >&2; cat "$test_dir/err" >&2; exit 1; }
  [[ $(snapshot_home) == "$before" ]] || { echo "止めたのに書き換わった行: $id" >&2; exit 1; }
  [[ ! -s $test_dir/calls ]] || { echo "止めたのにデーモンを操作した行: $id" >&2; exit 1; }
  [[ $state != new || ! -e $config ]] || { echo "設定を作った行: $id" >&2; exit 1; }
 fi
 if [[ $fixed == yes ]]; then
  # 原因を直して流し直すと全件がそろい、もう一度流しても何も変わらない。
  case $refusal in
  login-shell) cp "$test_dir/unmarked-trusted" "$config" ;;
  dirro:*) chmod u+rwx "${target%/*}" ;;
  esac
  case $refusal in
  login-shell | dirro:claude/settings.json) ;;
  *:claude/settings.json) chmod u+w "$target" 2>/dev/null || true; rm -f "$target"; printf '%s\n' '{"theme":"dark"}' >"$target" ;;
  dirro:*) rm -f "$target"; cp -P "$test_dir/installed-home/${target#"$TEMPLATE_AGENT_HOME"/}" "$target" ;;
  *) chmod u+w "$target" 2>/dev/null || true; rm -f "$target"; cp -P "$test_dir/installed-home/${target#"$TEMPLATE_AGENT_HOME"/}" "$target" ;;
  esac
  set_mode running
  agent_env
  run
  for name in git-credential git-ssh pre-tool-use stop shell_split.py; do
   cmp -s "$root/common/guard/$name" "$TEMPLATE_AGENT_HOME/guard/$name" && [[ ! -L $TEMPLATE_AGENT_HOME/guard/$name ]] || { echo "流し直してもそろわない行: $id ($name)" >&2; exit 1; }
  done
  cmp -s "$root/common/guard/gh" "$TEMPLATE_AGENT_HOME/bin/gh" && cmp -s "$root/common/guard/pre-push" "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" || { echo "流し直してもそろわない行: $id (gh と pre-push)" >&2; exit 1; }
  settled=$(snapshot_home)
  set_mode running
  agent_env
  run
  [[ $(snapshot_home) == "$settled" ]] || { echo "2 回目の流し直しで変わった行: $id" >&2; exit 1; }
 fi
done <"$root/tests/fixtures/host-update-order.tsv"
echo ok >"$test_dir/codex-hooks"
# 3 つの test で全行を流したことは、行数の合計で確認できるよう、この test の行数が表からの計算と合うことを見る。
[[ $order_rows == $(grep -v '^#' "$root/tests/fixtures/host-update-order.tsv" | awk -v k="$shard_index" -v n="$shard_count" 'NF && (NR % n) + 1 == k' | wc -l | tr -d ' ') ]]
echo "PASS host: 更新の表（${shard}）の ${order_rows} 行で、書き換える前に判定できる確認が合わなければ、ガード・Codex の設定と信頼・settings.json を含む全ファイルを書き換えずに止まる"
