#!/usr/bin/env bash
# 決めた境界の値で描き、画面の組み立て用に改行を変換する。
set -euo pipefail
mode=$1 out=$2 err=$3
shift 3
input=
while [[ ${1-} != -- ]]; do
    case $1 in
    --stdin) input=$2 ;;
    --ui) export DRAW_UI=$2 ;;
    *) exit 2 ;;
    esac
    shift 2
done
[[ $1 == -- ]] && shift
case $mode in
out) TERM_STUB_TTY=out ;;
err) TERM_STUB_TTY=err ;;
both) TERM_STUB_TTY='out err' ;;
screen) TERM_STUB_TTY='in out err' ;;
none) TERM_STUB_TTY= ;;
*) exit 2 ;;
esac
export TERM_STUB_TTY TERM_STUB_SIZE=${TERM_STUB_SIZE:-40 100} TERM_STUB_TPUT=${TERM_STUB_TPUT:-256 24 80}
unset LINES COLUMNS
if [[ -n $input && -z ${TERM_STUB_EVENTS:-} ]]; then
    TERM_STUB_EVENTS="$out.events"
    while IFS= read -r event_answer || [[ -n $event_answer ]]; do printf 'answer %s\n' "$event_answer"; done <"$input" >"$TERM_STUB_EVENTS"
    printf 'eof\n' >>"$TERM_STUB_EVENTS"
    export TERM_STUB_EVENTS
fi
status=0
if [[ -n $input ]]; then
    "$@" <"$input" >"$out" 2>"$err" || status=$?
else
    "$@" >"$out" 2>"$err" || status=$?
fi
python3 - "$mode" "$out" "$err" <<'PY'
from pathlib import Path
import sys
for target, name in zip(('out', 'err'), sys.argv[2:]):
    if sys.argv[1] not in (target, 'both', 'screen'):
        continue
    path = Path(name)
    path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
PY
exit "$status"
