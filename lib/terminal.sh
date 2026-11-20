# 端末の命令をそのまま呼ぶ境界。値は呼び出し元のシェルに置く。
ui_tty() {
	case $1 in
	in) [[ -t 0 ]] ;;
	out) [[ -t 1 ]] ;;
	err) [[ -t 2 ]] ;;
	*) return 1 ;;
	esac
}
ui_tty_size() {
	ui_tty_value=
	case $1 in
	out) { ui_tty_value=$(stty size <&3 2>/dev/null); } 3>&1 ;;
	err) { ui_tty_value=$(stty size <&3 2>/dev/null); } 3>&2 ;;
	*) return 1 ;;
	esac
}
ui_tty_tput() { ui_tty_value=$(tput "$1" 2>/dev/null); }
ui_tty_read() { read "$@"; }
