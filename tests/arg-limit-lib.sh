#!/usr/bin/env bash
# Linux の引数の上限を macOS でも働かせる jq の包みと、拒んだ呼び出しの確認。テストが読み込む共通の補助で、単独では実行しない。
# Linux は、プロセスに渡す引数と環境変数の 1 つを 131,072 バイト未満に限る（macOS にはこの上限がない）。

# 包みの `jq` を $1 に置く。記録は $2 に 1 行ずつ足す。呼び出しの前に PATH で見つかる jq を本物として呼ぶ。
# 引数か環境変数（名前=値）の 1 つでも 131,072 バイト以上なら、本物を呼ばずに記録して 126 で終わる。大きさは文字でなくバイトで数える。
# 環境変数 JQ_FAIL_ON を置くと、引数をスペースでつないだ文字列がその型に合う呼び出しだけを、終了 5 で失敗させる（テストが、jq の失敗を場所ごとに起こすため）。
# 置いたあと、境目の自己検査（131,071 バイトは通り、131,072 バイトは拒む）をして、検査で拒んだ分の記録を消す。
install_arg_limit_jq() {
 local bin_dir=$1 record=$2 real_jq big status
 real_jq=$(command -v jq) || { echo 'install_arg_limit_jq: jq が見つからない' >&2; return 1; }
 mkdir -p "$bin_dir"
 cat >"$bin_dir/jq" <<WRAP
#!/bin/bash
too_long=\$(
 LC_ALL=C
 for arg in "\$@"; do ((\${#arg} < 131072)) || { echo 1; break; }; done
 for name in \$(compgen -e); do value=\${!name}; ((\${#name} + 1 + \${#value} < 131072)) || { echo 1; break; }; done
)
if [[ -n \$too_long ]]; then printf 'jq %.200s\\n' "\$*" >>"$record"; echo 'jq: Argument list too long' >&2; exit 126; fi
# 環境変数 JQ_FAIL_ON（glob の型）に引数をスペースでつないだ文字列が合えば、本物を呼ばずに 5 で終わる。取り出しの失敗を、場所ごとに起こすため。
if [[ -n \${JQ_FAIL_ON:-} ]]; then
 joined="\$*"
 if [[ \$joined == \$JQ_FAIL_ON ]]; then echo 'jq: injected failure' >&2; exit 5; fi
fi
exec "$real_jq" "\$@"
WRAP
 chmod +x "$bin_dir/jq"
 big=$(head -c 131072 /dev/zero | tr '\0' a)
 [[ $("$bin_dir/jq" -n --arg v "${big%a}" '$v|length') == 131071 ]] || return 1
 status=0; "$bin_dir/jq" -n --arg v "$big" '$v|length' >/dev/null 2>&1 || status=$?
 [[ $status == 126 ]] || return 1
 status=0; env "BIG=${big:0:131068}" "$bin_dir/jq" -n '1' >/dev/null 2>&1 || status=$?
 [[ $status == 126 ]] || return 1
 [[ $(env "BIG=${big:0:131067}" "$bin_dir/jq" -n '1') == 1 ]] || return 1
 : >"$record"
}

# 拒んだ呼び出しの記録が空であることを確認する。呼び出し側が失敗を否定の結果として読み流すと、拒まれても通ってしまうため、
# 記録が空でなければ、拒んだ呼び出しを出して失敗する。記録は $1（既定は $test_dir/rejected-calls）。
assert_no_rejected_calls() {
 local record=${1:-$test_dir/rejected-calls}
 if [[ -s $record ]]; then
  echo '131,072 バイト以上の引数で拒んだ呼び出しがある:' >&2
  cat "$record" >&2
  return 1
 fi
}

# EXIT の trap から呼ぶ終わりの処理。$1 は元の終了コード、$2 は片付けるディレクトリ（記録は $2/rejected-calls）。
# 記録が空でなくても、片付けてから終了コード 1 で終わる。
arg_limit_finish() {
 local exit_code=$1 dir=$2
 assert_no_rejected_calls "$dir/rejected-calls" || exit_code=1
 rm -rf -- "$dir"
 exit "$exit_code"
}
