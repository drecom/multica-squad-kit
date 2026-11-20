#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-cli-lib-body-table-test.sh で実行する。
# squad-cli-lib の本文の読み方を、設計（docs/review-next-step.md）の「本文の読み方のテスト」の表 1 の全行（tests/review-body-table.tsv）で確認する。
# 同じ入力を、制御記録の判定（analyze）、マージの依頼の確認（merge_requested）、最新の回の状態（state）の 3 つのモードに通し、同じ結果になることを見る。
# コマンドの引数の違う呼び方も、全行で流す。作者が決める役（リーダーでない）の merge_requested と、最上位の役の一覧が null の state である。
# 読む側の各スクリプトが同じ入力で同じ結果を返すかは、表の代表の行で、squad-review-next-decide-body-test.sh、squad-review-wait-body-test.sh、squad-pr-watch-ci-wait-body-test.sh が確認する（docs/test-trim.md の「代表の行」）。
# 代表の行の組（control 1、notcontrol 1、読めない理由 8 種それぞれ 1、NUL と単独の CR を含む行）もここで確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/common/monitor/squad-cli-lib"
source "$root/tests/review-body-table.sh"

round_text=$'確認するコミット: abc1234\n返事を待つ役: [@qa](mention://agent/qa)\n観点: qa（テスト）'
head=0123456789abcdef0123456789abcdef01234567
final_text=$'見直しの種類: 最終レビュー\n確認するコミット: abc1234\n返事を待つ役: [@qa](mention://agent/qa)'

# 回 r1、決める記録、候補 x（リーダーが回のあとに書いた本文）の一覧。
# 候補の作者（2 つ目）と回の本文（3 つ目）は省ける。決める役が書くマージの依頼は、作者を qa、回を最終レビューにして読む。
comments() { # 本文の JSON 文字列 [候補の作者] [回の本文]
	jq -n --argjson body "$1" --arg author "${2:-L}" --arg round "${3:-$round_text}" '[
		{id: "r1", author_id: "L", author_type: "agent", created_at: "2026-11-10T12:00:01Z", content: $round},
		{id: "d1", author_id: "qa", author_type: "agent", created_at: "2026-11-10T12:00:02Z", content: "/note\n返事の待ち: 次の依頼を決めます"},
		{id: "x", author_id: $author, author_type: "agent", created_at: "2026-11-10T12:00:03Z", content: $body}]'
}
fail() { printf '%s\n本文: %s\n' "$1" "$2" >&2; exit 1; }

check_analyze() { # 期待 説明 本文
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control analyze "$(comments "$json")" '["L"]' '["P"]' r1)
	case $expect in
	control) jq -e '[.controls[] | select(.id == "x" and .kind == "fix" and .prev == "r1")] | length == 1' <<<"$out" >/dev/null \
		&& jq -e '.blocked == null' <<<"$out" >/dev/null || fail "analyze（${label}）: 制御記録として読むはずが: $out" "$json" ;;
	notcontrol) jq -e '[.controls[] | select(.id == "x")] | length == 0' <<<"$out" >/dev/null \
		&& jq -e '.blocked == null' <<<"$out" >/dev/null || fail "analyze（${label}）: 読めて制御記録でないはずが: $out" "$json" ;;
	unreadable:*) jq -e --arg want "制御記録を読めない（x: ${expect#unreadable:}）" '.blocked == $want and ([.controls[] | select(.id == "x")] | length == 0)' <<<"$out" >/dev/null \
		|| fail "analyze（${label}）: 「${expect#unreadable:}」で読めないはずが: $out" "$json" ;;
	esac
}
check_state() { # 期待 説明 本文
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control state "$(comments "$json")" '["L"]' '["P"]')
	case $expect in
	unreadable:*) jq -e --arg want "制御記録を読めない（x: ${expect#unreadable:}）" '.blocked == $want' <<<"$out" >/dev/null \
		|| fail "state（${label}）: 「${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	*) jq -e '.blocked == null' <<<"$out" >/dev/null || fail "state（${label}）: 止まってはいけない: $out" "$json" ;;
	esac
}
check_state_null() { # 期待 説明 本文（最上位の役の一覧が null。squad-review-wait の呼び方）
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control state "$(comments "$json")" '["L"]' null)
	case $expect in
	unreadable:*) jq -e --arg want "制御記録を読めない（x: ${expect#unreadable:}）" '.blocked == $want' <<<"$out" >/dev/null \
		|| fail "state（null）（${label}）: 「${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	*) jq -e '.blocked == null' <<<"$out" >/dev/null || fail "state（null）（${label}）: 止まってはいけない: $out" "$json" ;;
	esac
}
check_merge() { # 期待 説明 本文（種類の行がマージの依頼）
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control merge_requested "$(comments "$json")" '["L"]' '["P"]' "$head")
	case $expect in
	control) [[ $out == yes ]] || fail "merge_requested（${label}）: 依頼済みのはずが: $out" "$json" ;;
	notcontrol) [[ $out == no ]] || fail "merge_requested（${label}）: 依頼済みでも止まりでもないはずが: $out" "$json" ;;
	unreadable:*) [[ $out == "blocked 制御記録を読めない（x: ${expect#unreadable:}）" ]] || fail "merge_requested（${label}）: 「${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	esac
}
check_merge_by_decider() { # 期待 説明 本文（種類の行がマージの依頼。作者は決める役。squad-pr-watch ci-wait の呼び方）
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control merge_requested "$(comments "$json" qa "$final_text")" '["L"]' null "$head")
	case $expect in
	control) [[ $out == yes ]] || fail "merge_requested（決める役）（${label}）: 依頼済みのはずが: $out" "$json" ;;
	notcontrol) [[ $out == no ]] || fail "merge_requested（決める役）（${label}）: 依頼済みでも止まりでもないはずが: $out" "$json" ;;
	unreadable:*) [[ $out == "blocked 制御記録を読めない（x: ${expect#unreadable:}）" ]] || fail "merge_requested（決める役）（${label}）: 「${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	esac
}

# 代表の行の組を数える。コールバックは、期待ごとの行の数と、NUL と単独の CR を含む行の数を足す。
rep_control=0 rep_notcontrol=0 rep_nul=0 rep_cr=0 rep_reasons=
count_rep() { # 期待 説明 本文
	case $1 in
	control) rep_control=$((rep_control + 1)) ;;
	notcontrol) rep_notcontrol=$((rep_notcontrol + 1)) ;;
	unreadable:*) rep_reasons+="${1#unreadable:}"$'\n' ;;
	esac
	jq -e '[explode[] | select(. == 0)] | length > 0' <<<"$3" >/dev/null && rep_nul=$((rep_nul + 1))
	jq -e 'gsub("\r\n"; "") | contains("\r")' <<<"$3" >/dev/null && rep_cr=$((rep_cr + 1))
	return 0
}

body_table '修正の依頼: 1 回目' r1 check_analyze
rows=$body_table_count
body_table '修正の依頼: 1 回目' r1 check_state
body_table '修正の依頼: 1 回目' r1 check_state_null
body_table "マージの依頼: $head" r1 check_merge
body_table "マージの依頼: $head" r1 check_merge_by_decider
[[ $rows -eq 61 ]] || { echo "表の行が 61 でない: $rows" >&2; exit 1; }

body_table '修正の依頼: 1 回目' r1 count_rep representative
reasons=$(printf '%s' "$rep_reasons" | LC_ALL=C sort | LC_ALL=C uniq -c | awk '{print $1}' | sort -u | tr -d '\n')
reason_kinds=$(printf '%s' "$rep_reasons" | LC_ALL=C sort -u | grep -c .)
[[ $body_table_count -eq 10 && $rep_control -eq 1 && $rep_notcontrol -eq 1 && $reason_kinds -eq 8 && $reasons == 1 ]] \
	|| { echo "代表の行の組が違う: 行 ${body_table_count}、control ${rep_control}、notcontrol ${rep_notcontrol}、読めない理由 ${reason_kinds} 種（各 1 行なら 1: ${reasons}）" >&2; exit 1; }
[[ $rep_nul -ge 1 && $rep_cr -ge 1 ]] || { echo "代表の行に NUL（${rep_nul}）か単独の CR（${rep_cr}）がない" >&2; exit 1; }
echo "PASS cli-lib: 本文の読み方の表 ${rows} 行を、analyze、state、merge_requested の 3 つのモードが同じ結果で読む。決める役が書くマージの依頼と、最上位の役の一覧が null の state も同じ"
echo "PASS cli-lib: 代表の行は 10 行（control 1、notcontrol 1、読めない理由 8 種それぞれ 1）で、NUL と単独の CR を含む行がある"
