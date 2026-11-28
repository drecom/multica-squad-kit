#!/bin/bash
# ガードの次にある gh の差し替え。本物の GitHub へ送信しない。
set -euo pipefail
case "$*" in
'api --help')
 cat <<'HELP'
FLAGS
HELP
 # gh 2.104.0 以降は bool を --name[=true|false] の形で出す。
 if [[ ${TEST_GUARD_BOOL_FORM:-plain} == brackets ]]; then
  echo '  -i, --include[=true|false]   Include HTTP response headers'
 else
  echo '  -i, --include                Include HTTP response headers'
 fi
 cat <<'HELP'
  -X, --method string          HTTP method
  -f, --raw-field key=value    Add a string parameter

HELP
 ;;
'auth status')
 # 本物の gh と同じく、トークンの変数か、置き場の中のファイルがあれば認証済みにする。
 # TEST_GH_AUTH=yes は、キーチェーンなど、置き場の外の認証が残っている状態の再現である。
 [[ -z ${TEST_GH_AUTH_CALLS:-} ]] || printf '%s\n' "${GH_CONFIG_DIR-unset}" >>"$TEST_GH_AUTH_CALLS"
 # TEST_GH_AUTH_EXIT は、実行できない・異常終了など、未認証と確認できない終わり方の再現である。
 if [[ -n ${TEST_GH_AUTH_EXIT:-} ]]; then echo 'gh: broken (test)' >&2; exit "$TEST_GH_AUTH_EXIT"; fi
 if [[ -n ${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-} || ${TEST_GH_AUTH:-no} == yes ]] ||
  [[ -n ${GH_CONFIG_DIR:-} && -d $GH_CONFIG_DIR && -n $(ls -A "$GH_CONFIG_DIR") ]]; then
  echo 'github.com: Logged in (test)'; exit 0
 fi
 echo 'You are not logged into any GitHub hosts. To log in, run: gh auth login' >&2; exit 1 ;;
'pr comment --help'|'issue comment --help'|'issue edit --help')
 cat <<'HELP'
FLAGS
  -b, --body text               Comment body
      --add-assignee login     Add an assignee

INHERITED FLAGS
  -R, --repo [HOST/]OWNER/REPO   Select repository

HELP
 ;;
'api --include --method POST repos/'*'/git/refs --raw-field ref=invalid')
	[[ -z ${TEST_GUARD_MARKER:-} ]] || touch "$TEST_GUARD_MARKER"
 [[ -z ${TEST_GUARD_CALLS:-} ]] || jq -nc --args '$ARGS.positional' -- "$@" >>"$TEST_GUARD_CALLS"
 case ${TEST_GUARD_RESPONSE:-422} in
 empty) echo 'intentional network failure' >&2; exit 77 ;;
 bad-json) printf 'HTTP/2.0 422\n\nnot json\n'; exit 1 ;;
 201) printf 'HTTP/2.0 201\n\n{}\n'; exit 0 ;;
 *) printf 'HTTP/2.0 %s\n\n{"message":"Validation Failed"}\n' "${TEST_GUARD_RESPONSE:-422}"; exit 1 ;;
 esac ;;
'pr comment '*|'issue comment '*|'issue edit '*)
 [[ -z ${HOST_GH_CALLS:-} ]] || jq -nc --args '$ARGS.positional' -- "$@" >>"$HOST_GH_CALLS" ;;
*) echo "Unexpected gh call: $*" >&2; exit 90 ;;
esac
