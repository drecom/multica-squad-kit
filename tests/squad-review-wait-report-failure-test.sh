#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-failure-test.sh で実行する。
# この部分は、決める実行の失敗の知らせと、前の回をたどる条件を確認する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。report と proceed の知らせ・次へ回す記録を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
both='result:a:r1:5 result:b:r2:6'
own_record='decide:a:posted-2:90'

# 決める実行が失敗したとき（終了コード 1 など）は、標準エラーの最後の行を理由にする。空なら終了コードを書く。長い理由は 300 字で切る。
for failure in stderr empty long exit3; do
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record >"$test_dir/comments.json"
	echo 1 >"$test_dir/decide-status"
	case $failure in
	stderr) printf '途中の経過\n次の依頼を書けません: コメントの投稿に失敗した\n\n' >"$test_dir/decide-err"; expect='コメントの投稿に失敗した' ;;
	empty) expect='squad-review-next decide が 1 で終わった' ;;
	long) printf '次の依頼を書けません: %s\n' "$(printf 'あ%.0s' $(seq 1 400))" >"$test_dir/decide-err"; expect="$(printf 'あ%.0s' $(seq 1 300))…" ;;
	exit3) echo 3 >"$test_dir/decide-status"; printf '別の出力\n' >"$test_dir/decide-out"; expect='squad-review-next decide が 3 で終わった' ;;
	esac
	bash "$script" report test-issue trigger "$test_dir/result.md"
	jq -s -e --arg reason "$expect" '.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: " + $reason + "\n\n")' "$test_dir/posted.jsonl" >/dev/null
done
echo 'PASS report: 決める実行が失敗したときは、標準エラーの最後の行か終了コードを理由にして知らせる'

# 理由の 300 字切りは、ロケールによらず文字単位で、不正な UTF-8 を作らない。C と UTF-8 のロケールで同じ本文になる。
# 日本語だけの理由と、ASCII と日本語が混ざった理由、不正なバイトを含む理由で確認する。
for shape in japanese mixed invalid; do
	case $shape in
	japanese) printf '次の依頼を書けません: %s\n' "$(printf 'あ%.0s' $(seq 1 400))" >"$test_dir/decide-err.src"
		expect=$(python3 -I -c 'print("あ" * 300 + "…", end="")') ;;
	mixed) printf '次の依頼を書けません: 理由: %s\n' "$(printf 'あ%.0s' $(seq 1 400))" >"$test_dir/decide-err.src"
		expect=$(python3 -I -c 'print(("理由: " + "あ" * 400)[:300] + "…", end="")') ;;
	invalid) { printf '次の依頼を書けません: 理由: '; printf '\377\376'; printf 'あ%.0s' $(seq 1 400); printf '\n'; } >"$test_dir/decide-err.src"
		expect=$(python3 -I -c 'print(("理由: \ufffd\ufffd" + "あ" * 400)[:300] + "…", end="")') ;;
	esac
	for locale in C C.UTF-8 en_US.UTF-8; do
		reset_calls
		build_comments $both >"$test_dir/comments.1.json"
		cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
		build_comments $both $own_record >"$test_dir/comments.json"
		echo 1 >"$test_dir/decide-status"
		cp "$test_dir/decide-err.src" "$test_dir/decide-err"
		LC_ALL=$locale bash "$script" report test-issue trigger "$test_dir/result.md"
		jq -s -j '.[2].body' "$test_dir/posted.jsonl" >"$test_dir/body.$shape.$locale"
		# 不正な UTF-8 を含まず、理由の行が期待の文字列で始まる。
		python3 -I -c 'import sys
body = open(sys.argv[1], "rb").read().decode("utf-8")
expect = sys.argv[2]
prefix = "[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: "
assert body.startswith(prefix + expect + "\n\n"), "理由の行が期待と違う"' "$test_dir/body.$shape.$locale" "$expect"
	done
	# 3 つのロケールで、本文が同じ。
	cmp "$test_dir/body.$shape.C" "$test_dir/body.$shape.C.UTF-8"
	cmp "$test_dir/body.$shape.C" "$test_dir/body.$shape.en_US.UTF-8"
done
echo 'PASS report: 理由の 300 字切りは、C と UTF-8 のロケールで同じ本文になり、不正な UTF-8 を作らない'

# 決めて書けたときは、スクリプトが書いたので知らせを書かない。
reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both $own_record >"$test_dir/comments.json"
printf '次の依頼: 修正\n' >"$test_dir/decide-out"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 0 && $(jq -s length "$test_dir/posted.jsonl") == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS report: 決めて書けたときは知らせを書かない'

# 回がなければ投稿せずエラー。
reset_calls
printf '[]' >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/posted.jsonl && -z $(slept) && -z $(decide_calls) ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS report: 回がなければ投稿しない'

# 知らせるスクワッドは、回の作者がリーダーのスクワッド。決める実行が書いた回は、役が作者なので、
# `前の回:` をたどってリーダーが書いた回のスクワッドを使う。たどるのは 10 回まで。たどれなければ、結果も書かずに失敗する。
chain_comments() { # 前の回をたどる回数 [リーダーが書いた回の作者]
	local hops=$1 leader=${2:-orchestrator}
	# r0 がリーダーの回。r1 以降は、前の回の決める実行の役（a）が、その決める記録のあとに書いた頼み直し。
	jq -n --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg b "$b" --arg leader "$leader" --argjson ts "$round_ts" --argjson hops "$hops" '
		def waited: "返事を待つ役: [@review](mention://agent/" + $a + ") [@qa](mention://agent/" + $b + ")";
		def at($n): ($ts - 3600 + $n) | todateiso8601;
		def round($id; $author; $n; $content): $comment[0] + {id: $id, author_type: "agent", author_id: $author, created_at: at($n), content: $content};
		[round("r0"; $leader; 0; waited + "\n観点: qa（テスト）")]
		+ [range(0; $hops) as $k
			| round("d\($k)"; $a; 10 * $k + 5; "/note\n返事の待ち: 次の依頼を決めます"),
			round("r\($k + 1)"; $a; 10 * $k + 10; "コミットが合わず頼み直す役: qa\n前の回: r\($k)\n" + waited)]
		+ [$comment[0] + {id: "x1", author_type: "agent", author_id: $a, created_at: (($ts + 5) | todateiso8601), content: "result"},
			$comment[0] + {id: "x2", author_type: "agent", author_id: $b, created_at: (($ts + 6) | todateiso8601), content: "result"}]'
}
for hops in 1 10; do
	reset_calls
	chain_comments "$hops" >"$test_dir/comments.json"
	echo 3 >"$test_dir/decide-status"
	printf '次の依頼を決められません: テスト\n' >"$test_dir/decide-out"
	jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --argjson ts "$round_ts" \
		'. + [$comment[0] + {id: "posted-2", author_type: "agent", author_id: $a, created_at: (($ts + 90) | todateiso8601), content: "/note\n返事の待ち: 次の依頼を決めます"}]' \
		"$test_dir/comments.json" >"$test_dir/comments.tmp"
	cp "$test_dir/comments.json" "$test_dir/comments.1.json"
	cp "$test_dir/comments.json" "$test_dir/comments.2.json"
	mv "$test_dir/comments.tmp" "$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	jq -s -e --arg round "r$hops" '.[0].body | endswith("返事の回: " + $round + "\n")' "$test_dir/posted.jsonl" >/dev/null
	jq -s -e '.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n")' "$test_dir/posted.jsonl" >/dev/null
done
echo 'PASS report: 役が書いた回は、前の回を 10 回までたどり、リーダーが書いた回のスクワッドで知らせる'
# 前の回を 10 回までにたどれない回と、リーダーに着かない回は、認める回でない。後者だけなら回がないときと同じに止まり、
# 前者は、たどれる最後の回（r10）が最新の回になる。どちらも認めない回に結果を紐付けず、知らせる先も決めない。
reset_calls
chain_comments 3 not-a-leader >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == '返事を待つ役の登録がありません'* ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
[[ ! -s $test_dir/posted.jsonl && -z $(slept) && -z $(decide_calls) && $(list_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
reset_calls
chain_comments 11 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || true
jq -s -e '.[0].body | endswith("返事の回: r10\n")' "$test_dir/posted.jsonl" >/dev/null
echo 'PASS report: 前の回を 10 回たどってもリーダーの回に着かない回は認めず、結果を紐付けない'
