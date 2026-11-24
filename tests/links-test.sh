#!/usr/bin/env bash
# scripts/check-links.py が、リンク先のファイルや見出しがない文書を行の番号を添えて止め、見出しの作り方が GitHub と同じであることを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/links.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
check() { python3 "$root/scripts/check-links.py" "$@"; }

check
echo 'PASS links: リポジトリの Markdown のリンクの行き先は、すべてある'

# 切れた例が、行の番号と理由を添えて落ちることを確認する。
printf '# 題\n\nあ。\n' >"$test_dir/b.md"
deny() {
	printf '%b' "$1" >"$test_dir/ng.md"
	if check "$test_dir/ng.md" >/dev/null 2>"$test_dir/err"; then echo "FAIL links: 通ってしまった: $3" >&2; exit 1; fi
	grep -qF "ng.md:$2: リンク: $3" "$test_dir/err" || { echo "FAIL links: 場所か理由が違う: $3" >&2; cat "$test_dir/err" >&2; exit 1; }
}
ok() {
	printf '%b' "$1" >"$test_dir/ok.md"
	check "$test_dir/ok.md" >/dev/null
}
deny '# 題\n\n[先](none.md)\n' 3 'none.md のファイルがない'
deny '# 題\n\n[先](b.md#ない)\n' 3 'b.md#ない の見出しがない'
deny '# 題\n\n[先](#ない)\n' 3 '#ない の見出しがない'
deny '# 題\n\n[先]: none.md\n' 3 'none.md のファイルがない'
ok '# 題\n\n[先](b.md#題) と [先](https://example.com/x) と `[先](none.md)` と [先](#題)\n'
echo 'PASS links: ファイルや見出しがないリンクは、行の番号と理由を添えて落ち、あるリンクは通る'

# 見出しの作り方は、GitHub と同じにする。同じ見出しの 2 つ目は「-1」を付け、日本語の見出しは「・」と（）を除く。
ok '# 題\n\n## 同じ\n\n## 同じ\n\n[先](#同じ-1)\n'
deny '# 題\n\n## 同じ\n\n## 同じ\n\n[先](#同じ-2)\n' 7 '#同じ-2 の見出しがない'
ok '# 題\n\n## 手順・確認（例）\n\n[先](#手順確認例)\n'
deny '# 題\n\n## 手順・確認（例）\n\n[先](#手順・確認（例）)\n' 5 '#手順・確認（例） の見出しがない'
echo 'PASS links: 同じ見出しの 2 つ目は「-1」、日本語の見出しは「・」と（）を除いた形で指す'

# コメントとコード中のタグは実在するアンカーではない。見出し中のコメントも表示されない。
deny '# 題\n\n`<a id="fake"></a>`\n[先](#fake)\n' 4 '#fake の見出しがない'
deny '# 題\n\n<!-- <a id="fake"></a> -->\n[先](#fake)\n' 4 '#fake の見出しがない'
deny '# 題\n\n<!--\n<a id="fake"></a>\n-->\n[先](#fake)\n' 6 '#fake の見出しがない'
ok '# 題 <!-- comment -->\n\n[先](#題)\n<a id="real"></a>\n[先](#real)\n'
ok '# 題 <!-- ` -->\n\n[先](#題) と `<!--`\n'
ok '# 題\n\n<!-- [先](none.md) -->\n'
echo 'PASS links: コメントとインラインコードをアンカーに数えず、見出しからコメントを除く'

# コードスパンの区切りの長さと行数を変えて、リンク・アンカー・コメントの始まりを隠す。
for ticks in '`' '``' '```' '````'; do
    ok "# 題\n\n文中 ${ticks}[先](none.md) <!--${ticks}\n[先](#題)\n"
    ok "# 題\n\n文中 ${ticks}例\n[先](none.md) <!--${ticks}\n[先](#題)\n"
    deny "# 題\n\n文中 ${ticks}例\n<a id=\"fake\"></a>${ticks}\n[先](#fake)\n" 5 '#fake の見出しがない'
    deny "# 題\n\n文中 ${ticks}<!--\n[先](none.md)${ticks}\n[先](missing.md)\n" 5 'missing.md のファイルがない'
done
ok '# 題\n\n> 文中 `例\n> [先](none.md) <!--`\n\n[先](#題)\n'
# 閉じない区切りを、段落・見出し・引用・フェンスの境界を越えて持ち越さない。
deny '# 題\n\n文中 `例\n\n[先](missing.md)`\n' 5 'missing.md のファイルがない'
deny '# 題\n\n文中 `例\n## 節\n[先](missing.md)`\n' 5 'missing.md のファイルがない'
deny '# 題\n\n> 文中 `例\n[先](missing.md)`\n' 4 'missing.md のファイルがない'
deny '# 題\n\n文中 `例\n```text\n`\n```\n[先](missing.md)\n' 7 'missing.md のファイルがない'
echo 'PASS links: 単行と複数行のコードスパンを隠し、区切りの長さと段落・見出し・引用・フェンスの境界を守る'

# コメント内のコード・フェンスは状態を変えず、コメントを閉じた後の本文を調べる。
for marker in '```' '~~~' '````' '~~~~'; do
    deny "# 題\n\n<!--\n${marker}text\n[先](none.md)\n-->\n[先](missing.md)\n" 7 'missing.md のファイルがない'
    ok "# 題\n\n<!--\n${marker}text\n[先](none.md)\n-->\n<a id=\"real\"></a>\n[先](#real)\n"
    deny "# 題\n\n<!-- ${marker} <a id=\"fake\"></a> -->\n[先](#fake)\n" 4 '#fake の見出しがない'
    # フェンス内のコメントの始まりは、後続の本文をコメントにしない。
    deny "# 題\n\n${marker}text\n<!-- [先](none.md)\n<a id=\"fake\"></a>\n${marker}\n[先](missing.md)\n" 7 'missing.md のファイルがない'
    deny "# 題\n\n${marker}text\n<a id=\"fake\"></a>\n${marker}\n[先](#fake)\n" 6 '#fake の見出しがない'
done
ok '# 題\n\n<!-- ` と `` --> [先](#題) <!-- 別 -->\n'
deny '# 題\n\n<!-- `例\n[先](none.md)` --> [先](missing.md)\n' 4 'missing.md のファイルがない'
ok '# 題 <!-- comment -->\n\n<!--\n# 題\n<a id="fake"></a>\n-->\n[先](#題)\n'
deny '# 題\n\n文中 `例\n[名前]: none.md`\n[先](missing.md)\n' 5 'missing.md のファイルがない'
deny '# 題\n\n<!--\n```text\n--> [先](missing.md)\n' 5 'missing.md のファイルがない'
deny '# 題\n\n> <!--\n> ~~~text\n> -->\n[先](missing.md)\n' 6 'missing.md のファイルがない'
# フェンスは同じ記号で同じ長さ以上の、情報を持たない行だけで閉じる。
ok '# 題\n\n````text\n```\n~~~\n<!--\n[先](none.md)\n````\n[先](#題)\n'
ok '# 題\n\n```text\n```text\n[先](none.md)\n```\n[先](#題)\n'
deny '# 題\n\n> ```text\n> <!--\n[先](missing.md)\n' 5 'missing.md のファイルがない'
echo 'PASS links: コメント内のフェンスとコード、フェンス内のコメントを隠し、閉じた後の本文は検査する'

# 字下げした段落は、箇条書きの項目のあとでも、リンクの検査から外れない（コードブロックとして隠さない）。
deny '# 題\n\n- 項目\n\n    [先](missing.md)\n' 5 'missing.md のファイルがない'
deny '# 題\n\n-\t項目\n\n\t[先](missing.md)\n' 5 'missing.md のファイルがない'
echo 'PASS links: 箇条書きの項目に続く字下げした段落の切れたリンクも検査する'

# 索引の検査は、docs/ の直下の文書が索引の表の 1 列目のリンクに載っているかを見る。
# 載っている書き方と載っていない書き方は、tests/links-index-table.tsv に表で持つ。
index_dir="$test_dir/docs"
mkdir -p "$index_dir/sub"
printf '# 題\n' >"$index_dir/a.md"
printf '# 題\n' >"$index_dir/b.md"
printf '# 題\n' >"$index_dir/sub/c.md"
index_missing() {
	# 索引の検査を流し、載っていない文書の名前を 1 行ずつ出す。終了コードは 1（載っていない）か 0。
	local status=0
	check --index "$index_dir/README.md" >"$test_dir/out" 2>"$test_dir/err" || status=$?
	if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then echo "FAIL links: 索引の検査の終了コードが $status" >&2; cat "$test_dir/err" >&2; exit 1; fi
	sed -n 's/^.*README.md: 索引: \(.*\) が載っていない$/\1/p' "$test_dir/err"
	[ "$status" -eq 0 ] && [ -s "$test_dir/err" ] && { echo 'FAIL links: 索引の検査が 0 で終わったのに、stderr がある' >&2; cat "$test_dir/err" >&2; exit 1; }
	[ "$status" -eq 1 ] && [ ! -s "$test_dir/err" ] && { echo 'FAIL links: 索引の検査が 1 で終わったのに、stderr がない' >&2; exit 1; }
	return 0
}
prefix='# 索引\n\n| 文書 | 書いてあること |\n| --- | --- |\n| [a](a.md) | あ |\n'
rows=0
while IFS=$'\t' read -r id kind body listed reason; do
	case "$id" in ''|'#'*) continue ;; esac
	rows=$((rows + 1))
	printf '%b' "$prefix$body" >"$index_dir/README.md"
	expect=''
	for name in a b; do
		case ",$listed," in *",$name,"*) ;; *) expect="$expect$name.md"$'\n' ;; esac
	done
	got=$(index_missing)
	[ "$got" = "${expect%$'\n'}" ] || { echo "FAIL links: 索引に載るかが違う: ${id}（${reason}）。期待 [${expect%$'\n'}]、実際 [$got]" >&2; exit 1; }
	case "$kind" in
	載る) case ",$listed," in *,b,*) ;; *) echo "FAIL links: 表の種類と載る列が合わない: $id" >&2; exit 1 ;; esac ;;
	載らない) case ",$listed," in *,b,*) echo "FAIL links: 表の種類と載る列が合わない: $id" >&2; exit 1 ;; esac ;;
	*) echo "FAIL links: 表の種類が違う: $id" >&2; exit 1 ;;
	esac
done <"$root/tests/links-index-table.tsv"
[ "$rows" -ge 20 ] || { echo "FAIL links: 索引の表の行が少ない: $rows" >&2; exit 1; }
echo "PASS links: 索引の表の 1 列目のインラインリンクだけを載っていると数える（$rows 行）"

# 載っていない文書は、名前を添えて 1 で落ち、載っている文書は 0 で通る。
printf '%b' "$prefix" >"$index_dir/README.md"
if check --index "$index_dir/README.md" >"$test_dir/out" 2>"$test_dir/err"; then echo 'FAIL links: 載っていない文書があるのに通った' >&2; exit 1; fi
grep -qF 'docs/README.md: 索引: b.md が載っていない' "$test_dir/err" || { echo 'FAIL links: 載っていない文書の名前がない' >&2; cat "$test_dir/err" >&2; exit 1; }
grep -qF '検査: 設計の文書 2 本、索引にない文書 1 本' "$test_dir/out" || { echo 'FAIL links: 検査の数が違う' >&2; cat "$test_dir/out" >&2; exit 1; }
printf '%b' "$prefix| [b](b.md#題) | い |\n" >"$index_dir/README.md"
check --index "$index_dir/README.md" >"$test_dir/out"
grep -qF '検査: 設計の文書 2 本、索引にない文書 0 本' "$test_dir/out" || { echo 'FAIL links: 索引にない文書の数が 0 でない' >&2; cat "$test_dir/out" >&2; exit 1; }
echo 'PASS links: 載っていない文書は索引: <名前> が載っていないで落ち、載っていれば通る'

# 索引のファイルがない、--index にファイルを重ねる、は 2 で落ちる。ファイルだけを渡すと、リンクの検査だけをする。
rm -f "$index_dir/README.md"
status=0
check --index "$index_dir/README.md" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "FAIL links: 索引がないのに終了コードが $status" >&2; exit 1; }
printf '%b' "$prefix| [b](b.md) | い |\n" >"$index_dir/README.md"
status=0
check --index "$index_dir/README.md" "$index_dir/a.md" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "FAIL links: --index にファイルを重ねたのに終了コードが $status" >&2; exit 1; }
printf '# 題\n\n[先](none.md)\n' >"$index_dir/a.md"
printf '%b' "$prefix" >"$index_dir/README.md"
status=0
check "$index_dir/README.md" >/dev/null 2>&1 || status=$?
[ "$status" -eq 0 ] || { echo "FAIL links: ファイルだけを渡したら、索引の検査まで流れた（終了コード ${status}）" >&2; exit 1; }
status=0
check "$index_dir/a.md" >/dev/null 2>&1 || status=$?
[ "$status" -eq 1 ] || { echo "FAIL links: ファイルだけを渡した検査が、切れたリンクを止めなかった（終了コード ${status}）" >&2; exit 1; }
echo 'PASS links: 索引のファイルがない・--index にファイルを重ねると 2 で落ち、ファイルだけならリンクの検査だけをする'

# 引数なしの検査は、この原本の docs/ の文書がすべて索引に載っていることを出力に示す。
check >"$test_dir/out"
grep -qF '索引にない文書 0 本' "$test_dir/out" || { echo 'FAIL links: 原本の docs/ に索引にない文書がある' >&2; cat "$test_dir/out" >&2; exit 1; }
echo 'PASS links: 原本の docs/ の文書は、すべて索引に載っている'
