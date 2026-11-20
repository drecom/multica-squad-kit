#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/clock-boundary.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/lib/clock.sh"
before=$SECONDS
clock_now
after=$SECONDS
((before <= clock_value && clock_value <= after))
sleep() { printf '%s\n' "$@" >"$test_dir/arguments"; }
clock_sleep 0.1
[[ $(cat "$test_dir/arguments") == 0.1 ]]
source "$root/tests/clock-stub.sh"
clock_now
[[ $clock_value == 0 ]]
clock_sleep 600
clock_now
[[ $clock_value == 0 ]]
printf '599\n600\n' >"$test_dir/ticks"
CLOCK_STUB_TICKS="$test_dir/ticks" CLOCK_STUB_EVENTS="$test_dir/events" \
    bash -euo pipefail -c 'source "$1/tests/clock-stub.sh"; clock_sleep 0.1; clock_now; [[ $clock_value == 599 ]]; clock_sleep 1; clock_now; [[ $clock_value == 600 ]]' _ "$root"
[[ $(cat "$test_dir/events") == 'sleep 1' ]]
printf 'bad\n' >"$test_dir/ticks"
rc=0
CLOCK_STUB_TICKS="$test_dir/ticks" CLOCK_STUB_EVENTS="$test_dir/events" \
    bash -c 'source "$1/tests/clock-stub.sh"; clock_sleep 1' _ "$root" >"$test_dir/log" 2>&1 || rc=$?
[[ $rc == 125 ]]
echo 'PASS clock: 実時計と待機の境界、止めた時計と進める時計、不正な時刻の拒否'
