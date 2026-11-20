# 実時計を読まない時計。進めるときだけ FIFO を使う。
clock_value=${CLOCK_STUB_NOW:-0}
[[ $clock_value =~ ^[0-9]+$ ]] || { echo 'clock-stub: 時刻が不正' >&2; exit 125; }
if [[ -n ${CLOCK_STUB_TICKS:-} ]]; then exec 6<"$CLOCK_STUB_TICKS"; fi
clock_now() {
	if [[ -z ${CLOCK_STUB_TICKS:-} ]]; then
		clock_value=${CLOCK_STUB_NOW:-0}
		[[ $clock_value =~ ^[0-9]+$ ]] || { echo 'clock-stub: 時刻が不正' >&2; exit 125; }
	fi
}
clock_sleep() {
	if [[ -n ${CLOCK_STUB_TICKS:-} ]]; then
		printf 'sleep %s\n' "$1" >"${CLOCK_STUB_EVENTS:?}"
		IFS= read -r clock_value <&6 || { echo 'clock-stub: 次の時刻がない' >&2; exit 125; }
		[[ $clock_value =~ ^[0-9]+$ ]] || { echo 'clock-stub: 時刻が不正' >&2; exit 125; }
	fi
}
