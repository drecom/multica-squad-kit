#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-check-test.sh で実行する。
# squad-review-next check が、設計（docs/review-next-step.md）の「手で書く依頼の確認」の表どおりに、投稿の前の本文を読むかを確認する。
# 本文の読み方の表 1 の全行（tests/review-body-table.tsv）、回の行が足りない本文、引数とファイルの誤り、check を通った本文を回として読む status と report を見る。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/review-wait-test-lib.sh"
source "$root/tests/review-body-table.sh"

next="$root/common/monitor/squad-review-next"
body_file="$test_dir/body.md"
role_line="返事を待つ役: [@review](mention://agent/$a) [@qa](mention://agent/$b)"

# check を流し、終了コードを code、標準出力を out、標準エラーを err に置く。何も書かない（multica を呼ばない）ことも見る。
run_check() { # 引数（check のあとに渡すもの）
	code=0
	: >"$test_dir/calls.jsonl"
	out=$(bash "$next" check "$@" 2>"$test_dir/check-err") || code=$?
	err=$(<"$test_dir/check-err")
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/posted.jsonl ]] || { echo 'check は何も書かず、multica を呼んではいけない' >&2; exit 1; }
}
fail() { printf '%s\n' "$*" >&2; exit 1; }

# 本文の JSON 文字列をファイルに置き（NUL や単独の CR を含められる）、check を流して終了コードと標準出力を見る。
expect_check() { # 期待する終了コード 期待する出力 説明 本文の JSON 文字列
	jq -j . <<<"$4" >"$body_file"
	run_check "$body_file"
	[[ $code == "$1" && $out == "$2" && -z $err ]] \
		|| fail "（$3）終了 $1・「$2」を期待。実際は終了 ${code}・「${out}」・標準エラー「${err}」"$'\n'"本文: $4"
}

check_row() { # 期待 説明 本文の JSON 文字列 行番号（種類の行が返事を待つ役）
	case $1 in
	control) expect_check 0 '本文: 読める' "$2" "$3" ;;
	notcontrol) expect_check 1 '返事を待つ役: の行がない' "$2" "$3" ;;
	unreadable:*) expect_check 1 "$4 行目: ${1#unreadable:}" "$2" "$3" ;;
	esac
}
body_table '返事を待つ役: [@qa](mention://agent/qa)' r1 check_row
[[ $body_table_count -eq 61 ]] || fail "表の行が 61 でない: $body_table_count"
echo "PASS review-next check: 本文の読み方の表 ${body_table_count} 行で、読める行は終了 0、読めない行は終了 1 と表の行と理由を出す"

# 回の行が足りない本文は終了 1。
expect_check 1 '返事を待つ役: の行がない' '待つ役の行なし' '"確認するコミット: abc"'
expect_check 1 '返事を待つ役: にエージェントのメンションがない' '役名だけ' '"返事を待つ役: qa"'
expect_check 1 '返事を待つ役: にエージェントのメンションがない' '人間のメンション' '"返事を待つ役: [@someone](mention://member/m1)"'
expect_check 1 '返事の回: の行がある' '結果の印の行' "$(jq -Rs . <<<"$role_line"$'\n返事の回: round')"
expect_check 1 '返事の回: の行がある' '囲みの中でも結果の行は読む' '"返事を待つ役: [@qa](mention://agent/qa)\n```\n返事の回: r1\n```"'
expect_check 1 '2 行目: 行頭の空白' '制御の行の字下げ' '"確認するコミット: abc\n  返事を待つ役: [@qa](mention://agent/qa)"'
echo 'PASS review-next check: 待つ役の行がない・メンションがない・返事の回: の行がある本文は終了 1'

# 種類ごとの行の置き方は見ない。依頼の種類の値を問わず、回の行がそろえば終了 0。
expect_check 0 '本文: 読める' '種類の値は問わない' '"見直しの種類: 未知\n前の回: 2 語\n返事を待つ役: [@qa](mention://agent/qa)"'
expect_check 0 '本文: 読める' '種類の行がなくても読める' "$(jq -Rs . <<<"$role_line"$'\n観点: qa（テスト）')"
echo 'PASS review-next check: 種類ごとの行の正しさは見ない'

# 引数の誤りとファイルを読めないときは終了 2。標準出力は空で、標準エラーに理由を出す。
expect_usage() { # 説明 引数...
	local label=$1
	shift
	run_check "$@"
	[[ $code == 2 && -z $out && -n $err ]] || fail "（$label）終了 2・空の標準出力・標準エラーの理由を期待。実際は終了 ${code}・「${out}」・「${err}」"
}
printf '%s\n' "$role_line" >"$body_file"
expect_usage '引数なし'
expect_usage '引数が多い' "$body_file" "$body_file"
expect_usage '存在しないファイル' "$test_dir/none.md"
expect_usage 'ディレクトリ' "$test_dir"
if [[ $(id -u) != 0 ]]; then
	cp "$body_file" "$test_dir/unreadable.md"
	chmod 000 "$test_dir/unreadable.md"
	expect_usage '読めないファイル' "$test_dir/unreadable.md"
	chmod 600 "$test_dir/unreadable.md"
fi
[[ $err == *'本文のファイルを読めません'* || $err == *'使い方'* ]] || fail "標準エラーに理由がない: $err"
echo 'PASS review-next check: 引数の誤りと読めないファイルは、何も出さず標準エラーに理由を出して終了 2'

# check を通った本文をリーダーが投稿すると、status と report が回と読む。
printf '%s\n観点: qa（テスト）\n' "$role_line" >"$body_file"
run_check "$body_file"
[[ $code == 0 && $out == '本文: 読める' ]] || fail "回の本文が check を通らない: $code $out $err"
reset_calls
fixture issue-comments agent | jq --arg a "$a" --arg b "$b" --arg time "$round_time" --rawfile content "$body_file" '. as $base | [$base + {
	id: "round", author_type: "agent", author_id: "orchestrator", created_at: $time, content: $content}]' >"$test_dir/comments.json"
printf '[]' >"$test_dir/runs.json"
status_out=$(bash "$script" status test-issue 2>"$test_dir/status-err") || { cat "$test_dir/status-err" >&2; exit 1; }
[[ $status_out != *'回がないので何もしない'* ]] || fail "status が回と読まなかった: $status_out"
[[ $status_out == $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない' ]] || fail "status の出力が回の待ちでない: $status_out"
reset_calls
fixture issue-comments agent | jq --arg a "$a" --arg b "$b" --arg time "$round_time" --rawfile content "$body_file" '. as $base | [$base + {
	id: "round", author_type: "agent", author_id: "orchestrator", created_at: $time, content: $content}]' >"$test_dir/comments.json"
MULTICA_AGENT_ID=$a bash "$script" report test-issue round "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"
assert_jq -s 'length >= 1 and (.[0].body | contains("返事の回: round"))' "$test_dir/posted.jsonl" \
	|| fail "report が回の返事として書かなかった: $(<"$test_dir/posted.jsonl") $(<"$test_dir/error")"
assert_jq -s 'all(.[]; .body | contains("読めない制御記録") | not)' "$test_dir/posted.jsonl" || fail 'report が読めない候補の知らせを書いた'
echo 'PASS review-next check: check を通った本文を投稿すると、status と report が回と読む'
