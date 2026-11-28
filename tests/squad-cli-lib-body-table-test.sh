#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-cli-lib-body-table-test.sh で実行する。
# squad-cli-lib の本文の読み方を、設計（docs/review-next-step.md）の「本文の読み方のテスト」の表 1 の全行（tests/review-body-table.tsv）で確認する。
# 表の入力を analyze・merge_requested・state・check に通し、読めないときは同じ行番号と理由を返すことを見る。
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

check_analyze() { # 期待 説明 本文 行番号
	local expect=$1 label=$2 json=$3 number=$4 out
	out=$(squad_cli_control analyze "$(comments "$json")" '["L"]' '["P"]' r1)
	case $expect in
	control) jq -e '[.controls[] | select(.id == "x" and .kind == "fix" and .prev == "r1")] | length == 1' <<<"$out" >/dev/null \
		&& jq -e '.blocked == null' <<<"$out" >/dev/null || fail "analyze（${label}）: 制御記録として読むはずが: $out" "$json" ;;
	notcontrol) jq -e '[.controls[] | select(.id == "x")] | length == 0' <<<"$out" >/dev/null \
		&& jq -e '.blocked == null' <<<"$out" >/dev/null || fail "analyze（${label}）: 読めて制御記録でないはずが: $out" "$json" ;;
	unreadable:*) jq -e --arg want "制御記録を読めない（x: $number 行目: ${expect#unreadable:}）" '.blocked == $want and ([.controls[] | select(.id == "x")] | length == 0)' <<<"$out" >/dev/null \
		|| fail "analyze（${label}）: 「${expect#unreadable:}」で読めないはずが: $out" "$json" ;;
	esac
}
check_state() { # 期待 説明 本文 行番号 [最上位の役]
	local expect=$1 label=$2 json=$3 number=$4 principals=${5:-'["P"]'} out
	out=$(squad_cli_control state "$(comments "$json")" '["L"]' "$principals")
	case $expect in
	unreadable:*) jq -e --argjson line "$number" --arg reason "${expect#unreadable:}" '
		.blocked == "制御記録を読めない（x: \($line) 行目: \($reason)）"
		and .unreadable == [{id: "x", line: $line, reason: $reason, kind: "record"}]' <<<"$out" >/dev/null \
		|| fail "state（${label}）: 「$number 行目: ${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	*) jq -e '.blocked == null and .unreadable == []' <<<"$out" >/dev/null || fail "state（${label}）: 止まってはいけない: $out" "$json" ;;
	esac
}
check_state_null() { check_state "$@" null; }

check_merge() { # 期待 説明 本文 行番号（種類の行がマージの依頼）
	local expect=$1 label=$2 json=$3 number=$4 out
	out=$(squad_cli_control merge_requested "$(comments "$json")" '["L"]' '["P"]' "$head")
	case $expect in
	control) [[ $out == yes ]] || fail "merge_requested（${label}）: 依頼済みのはずが: $out" "$json" ;;
	notcontrol) [[ $out == no ]] || fail "merge_requested（${label}）: 依頼済みでも止まりでもないはずが: $out" "$json" ;;
	unreadable:*) [[ $out == "blocked 制御記録を読めない（x: $number 行目: ${expect#unreadable:}）" ]] || fail "merge_requested（${label}）: 「$number 行目: ${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	esac
}
check_merge_by_decider() { # 期待 説明 本文 行番号（種類の行がマージの依頼。作者は決める役。squad-pr-watch ci-wait の呼び方）
	local expect=$1 label=$2 json=$3 number=$4 out
	out=$(squad_cli_control merge_requested "$(comments "$json" qa "$final_text")" '["L"]' null "$head")
	case $expect in
	control) [[ $out == yes ]] || fail "merge_requested（決める役）（${label}）: 依頼済みのはずが: $out" "$json" ;;
	notcontrol) [[ $out == no ]] || fail "merge_requested（決める役）（${label}）: 依頼済みでも止まりでもないはずが: $out" "$json" ;;
	unreadable:*) [[ $out == "blocked 制御記録を読めない（x: $number 行目: ${expect#unreadable:}）" ]] || fail "merge_requested（決める役）（${label}）: 「$number 行目: ${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	esac
}

check_body() { # 期待する終了コード 出力 説明 本文
	local want_status=$1 want=$2 label=$3 json=$4 out status=0
	out=$(jq -j . <<<"$json" | squad_cli_control check) || status=$?
	[[ $status == "$want_status" && $out == "$want" ]] \
		|| fail "check（${label}）: 終了 $want_status・${want} を期待。実際は終了 $status・${out}" "$json"
}

check_request() { # 期待 説明 本文 行番号（種類の行が返事を待つ役）
	case $1 in
	control) check_body 0 '本文: 読める' "$2" "$3" ;;
	notcontrol) check_body 1 '返事を待つ役: の行がない' "$2" "$3" ;;
	unreadable:*) check_body 1 "$4 行目: ${1#unreadable:}" "$2" "$3" ;;
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
body_table '返事を待つ役: [@qa](mention://agent/qa)' r1 check_request
[[ $rows -eq 61 ]] || { echo "表の行が 61 でない: $rows" >&2; exit 1; }

check_body 1 '返事を待つ役: の行がない' '待つ役の行なし' '"確認するコミット: abc"'
check_body 1 '返事を待つ役: にエージェントのメンションがない' '役名だけ' '"返事を待つ役: qa"'
check_body 1 '返事の回: の行がある' '囲みの中でも結果の行は読む' '"返事を待つ役: [@qa](mention://agent/qa)\n```\n返事の回: r1\n```"'
check_body 1 '3 行目: 制御文字' '最初の制御文字。/note と CRLF と単独の CR も数える' '"/note\r\n根拠\rここに\u0000ある\n次に\u001bある"'
check_body 1 '5 行目: 閉じない囲み' '2 つ目の囲みを開いた行' '"/note\n```\n内容\n```\n~~~text\n内容"'
check_body 1 '2 行目: 引用' '先に当たった行' '"/note\n> 引用\n<div>"'
check_body 0 '本文: 読める' '依頼の種類の値は問わない' '"見直しの種類: 未知\n前の回: 2 語\n返事を待つ役: [@qa](mention://agent/qa)"'

body_table '修正の依頼: 1 回目' r1 count_rep representative
reasons=$(printf '%s' "$rep_reasons" | LC_ALL=C sort | LC_ALL=C uniq -c | awk '{print $1}' | sort -u | tr -d '\n')
reason_kinds=$(printf '%s' "$rep_reasons" | LC_ALL=C sort -u | grep -c .)
[[ $body_table_count -eq 10 && $rep_control -eq 1 && $rep_notcontrol -eq 1 && $reason_kinds -eq 8 && $reasons == 1 ]] \
	|| { echo "代表の行の組が違う: 行 ${body_table_count}、control ${rep_control}、notcontrol ${rep_notcontrol}、読めない理由 ${reason_kinds} 種（各 1 行なら 1: ${reasons}）" >&2; exit 1; }
[[ $rep_nul -ge 1 && $rep_cr -ge 1 ]] || { echo "代表の行に NUL（${rep_nul}）か単独の CR（${rep_cr}）がない" >&2; exit 1; }
echo "PASS cli-lib: 本文の読み方の表 ${rows} 行を analyze、state、merge_requested、check が同じ結果で読み、読めない行の番号と理由が一致する"
echo "PASS cli-lib: 代表の行は 10 行（control 1、notcontrol 1、読めない理由 8 種それぞれ 1）で、NUL と単独の CR を含む行がある"
