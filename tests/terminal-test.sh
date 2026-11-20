#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/terminal-boundary.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
cat >"$test_dir/probe.sh" <<'SH'
set -euo pipefail
source "$1/lib/ui.sh"
unset LINES COLUMNS
for target in in out err; do
    a=no b=no
    if ui_tty "$target"; then a=yes; fi
    case $target in in) [[ ! -t 0 ]] || b=yes ;; out) [[ ! -t 1 ]] || b=yes ;; err) [[ ! -t 2 ]] || b=yes ;; esac
    [[ $a == "$b" ]]
done
for target in out err; do
    actual_status=0 direct_status=0
    ui_tty_size "$target" || actual_status=$?
    case $target in out) { direct=$(stty size <&3 2>/dev/null) || direct_status=$?; } 3>&1 ;; err) { direct=$(stty size <&3 2>/dev/null) || direct_status=$?; } 3>&2 ;; esac
    [[ $actual_status == "$direct_status" && $ui_tty_value == "$direct" ]]
    if [[ $direct_status != 0 ]]; then direct="$(tput lines) $(tput cols)"; fi
    ui_size "$target"
    [[ "$ui_lines $ui_columns" == "$direct" ]]
done
for capability in colors lines cols; do
    direct=$(tput "$capability")
    ui_tty_tput "$capability"
    [[ $ui_tty_value == "$direct" ]]
done
printf 'ready? ' >&2
IFS= ui_tty_read -r value
[[ $value == '  a\b  ' ]]
printf 'boundary-ok' >&2
SH
printf '%s\n' 'expect ready? ' 'send   a\b  ' >"$test_dir/script"
for fds in in,out,err in,err; do
TERM=xterm-256color python3 "$root/tests/tty-session.py" --fds "$fds" --script "$test_dir/script" --output "$test_dir/out" --error "$test_dir/err" -- /bin/bash "$test_dir/probe.sh" "$root"
if [[ $fds == in,err ]]; then capture=err other=out; else capture=out other=err; fi
python3 - "$test_dir/$capture" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes() == b'ready?   a\\b  \r\nboundary-ok'
PY
[[ ! -s $test_dir/$other ]]
done
echo 'PASS terminal: 本物の端末の fd・大きさ・tput と境界が一致し、空白とバックスラッシュを読む'

printf '%s\n' 'size 18 72' 'answer   a\b  ' eof >"$test_dir/events"
TERM_STUB_TTY='in err' TERM_STUB_SIZE='40 100' TERM_STUB_TPUT='256 24 80' TERM_STUB_EVENTS="$test_dir/events" \
    bash -euo pipefail -c '
source "$1/tests/terminal-stub.sh"
ui_tty in && ui_tty err
if ui_tty out; then exit 1; fi
ui_tty_size err; [[ $ui_tty_value == "40 100" ]]
ui_tty_tput colors; [[ $ui_tty_value == 256 ]]
IFS= ui_tty_read -r answer
[[ $answer == "  a\b  " ]]
ui_tty_size err; [[ $ui_tty_value == "18 72" ]]
if IFS= ui_tty_read -r answer; then exit 1; fi
' _ "$root" 2>"$test_dir/echo"
printf '%s\n' '  a\b  ' >"$test_dir/expected"
cmp "$test_dir/echo" "$test_dir/expected"
for variant in missing exhausted unknown; do
    case $variant in
    missing) : >"$test_dir/events" ;;
    exhausted) : >"$test_dir/events" ;;
    unknown) printf 'unknown\n' >"$test_dir/events" ;;
    esac
    rc=0
    if [[ $variant == missing ]]; then
        env -u TERM_STUB_TTY bash -c 'source "$1/tests/terminal-stub.sh"; ui_tty in' _ "$root" >"$test_dir/log" 2>&1 || rc=$?
    else
        TERM_STUB_EVENTS="$test_dir/events" bash -c 'source "$1/tests/terminal-stub.sh"; IFS= ui_tty_read -r answer' _ "$root" >"$test_dir/log" 2>&1 || rc=$?
    fi
    [[ $rc == 125 ]]
    grep -q '^terminal-stub:' "$test_dir/log"
done
echo 'PASS terminal-stub: 条件と出来事・エコーを固定し、未指定・尽きた入力・未知の行を拒む'
