# テストの写しでだけ使う端末の境界。
term_stub_line=0
if [[ -n ${TERM_STUB_EVENTS:-} ]]; then exec 7<"$TERM_STUB_EVENTS"; fi
term_stub_error() { printf 'terminal-stub: %s: %s\n' "$term_stub_line" "$1" >&2; exit 125; }
term_stub_require() { [[ $2 == set ]] || term_stub_error "$1 が未指定"; }
ui_tty() {
	term_stub_require TERM_STUB_TTY "${TERM_STUB_TTY+set}"
	case $1 in in|out|err) ;; *) term_stub_error '知らない fd' ;; esac
	local IFS=' ' _term_stub_target
	for _term_stub_target in $TERM_STUB_TTY; do
		case $_term_stub_target in in|out|err) ;; *) term_stub_error '知らない fd の条件' ;; esac
	done
	case " $TERM_STUB_TTY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
ui_tty_size() {
	term_stub_require TERM_STUB_SIZE "${TERM_STUB_SIZE+set}"
	ui_tty "$1" || return 1
	[[ $TERM_STUB_SIZE != fail ]] || return 1
	[[ $TERM_STUB_SIZE =~ ^[0-9]+\ [0-9]+$ ]] || term_stub_error '大きさの条件が不正'
	ui_tty_value=$TERM_STUB_SIZE
}
ui_tty_tput() {
	term_stub_require TERM_STUB_TPUT "${TERM_STUB_TPUT+set}"
	[[ $TERM_STUB_TPUT =~ ^(fail|[0-9]+)\ (fail|[0-9]+)\ (fail|[0-9]+)$ ]] || term_stub_error '端末の能力の条件が不正'
	local _term_stub_colors _term_stub_rows _term_stub_cols
	IFS=' ' read -r _term_stub_colors _term_stub_rows _term_stub_cols <<<"$TERM_STUB_TPUT"
	case $1 in
	colors) ui_tty_value=$_term_stub_colors ;;
	lines) ui_tty_value=$_term_stub_rows ;;
	cols) ui_tty_value=$_term_stub_cols ;;
	*) term_stub_error '知らない端末の問い合わせ' ;;
	esac
	[[ $ui_tty_value != fail ]]
}
term_stub_size() { TERM_STUB_SIZE="$1 $2"; }
ui_tty_read() {
	term_stub_require TERM_STUB_EVENTS "${TERM_STUB_EVENTS+set}"
	local _term_stub_record _term_stub_answer _term_stub_rows _term_stub_cols _term_stub_extra
	while IFS= read -r _term_stub_record <&7; do
		term_stub_line=$((term_stub_line + 1))
		case $_term_stub_record in
		'answer '*)
			_term_stub_answer=${_term_stub_record#answer }
			if ui_tty in; then printf '%s\n' "$_term_stub_answer" >&2; fi
			read "$@" <<<"$_term_stub_answer"
			return $? ;;
		'size '*)
			IFS=' ' read -r _term_stub_rows _term_stub_cols _term_stub_extra <<<"${_term_stub_record#size }"
			[[ $_term_stub_rows =~ ^[0-9]+$ && $_term_stub_cols =~ ^[0-9]+$ && -z $_term_stub_extra ]] || term_stub_error '大きさの行が不正'
			term_stub_size "$_term_stub_rows" "$_term_stub_cols" ;;
		eof) return 1 ;;
		*) term_stub_error '知らない出来事' ;;
		esac
	done
	term_stub_error '終わりの出来事がない'
}
