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

# 字下げしたコードの中は、リンクとアンカーを検査しない。
ok '# 題\n\n    [先](none.md) <!--\n    [名前]: none.md\n\n[先](#題)\n'
ok '# 題\n\n\t[先](none.md)\n\n[先](#題)\n'
deny '# 題\n\n    <a id="fake"></a>\n\n[先](#fake)\n' 5 '#fake の見出しがない'
deny '# 題\n\n本文\n    [先](missing.md)\n' 4 'missing.md のファイルがない'
echo 'PASS links: 字下げしたコードを隠し、段落の続きの字下げは検査する'

# 索引の検査は、docs/ の直下の文書が索引のリンクの先に載っているかを調べる。リポジトリの索引は、先頭の引数なしの検査で確認した。
check | grep -qF '索引にない文書 0 本' || { echo 'FAIL links: 引数なしの検査が、索引の集計を出さない' >&2; exit 1; }
index_repo="$test_dir/index-repository"
index_dir="$index_repo/docs"
mkdir -p "$index_dir/sub" "$index_repo/scripts"
cp "$root/scripts/check-links.py" "$index_repo/scripts/check-links.py"
git init -q "$index_repo"
printf '# 文書\n\nあ。\n' >"$index_dir/a.md"
printf '# 文書\n\nい。\n' >"$index_dir/b.md"
printf '# 文書\n\nう。\n' >"$index_dir/sub/c.md"
index_check() {
	printf '%b' "$1" >"$index_dir/README.md"
	if [ "$index_mode" = explicit ]; then
		check --index "$index_dir/README.md" >"$test_dir/out" 2>"$test_dir/err"
	else
		git -C "$index_repo" add docs/README.md
		python3 "$index_repo/scripts/check-links.py" >"$test_dir/out" 2>"$test_dir/err"
	fi
}
index_deny() {
	local status=0
	index_check "$1" || status=$?
	[ "$status" -eq 1 ] || { echo "FAIL links: 索引にない文書の終了コードが 1 でない: $status (${index_mode})" >&2; cat "$test_dir/err" >&2; exit 1; }
	grep -qF "README.md: 索引: $2 が載っていない" "$test_dir/err" || { echo "FAIL links: 載っていない文書の行が違う: $2" >&2; cat "$test_dir/err" >&2; exit 1; }
}
index_ok() {
	index_check "$1" || { echo 'FAIL links: 載っている文書が、載っていないと数えられた' >&2; cat "$test_dir/err" >&2; exit 1; }
}
for index_mode in explicit default; do
index_deny '# 索引\n\n[a](a.md)\n' 'b.md'
grep -qF '索引にない文書 1 本' "$test_dir/out" || { echo 'FAIL links: 索引の集計の行が違う' >&2; cat "$test_dir/out" >&2; exit 1; }
if grep -qF 'a.md が載っていない' "$test_dir/err"; then echo 'FAIL links: 載っている文書を、載っていないと数えた' >&2; exit 1; fi
index_ok '# 索引\n\n[a](a.md) と [b](b.md)\n'
grep -qF '設計の文書 2 本、索引にない文書 0 本' "$test_dir/out" || { echo 'FAIL links: 索引の集計の行が違う' >&2; cat "$test_dir/out" >&2; exit 1; }
echo 'PASS links: 索引にない文書は「索引: <名前> が載っていない」を出して落ち、すべて載っていれば通る'

# アンカー付きのリンクで載せた文書は、載っていると数える。下のディレクトリの文書は見ない。
index_ok '# 索引\n\n[a](a.md#文書) と [b](./b.md#文書)\n'
echo 'PASS links: アンカー付きのリンクで載せた文書も、載っていると数える'

# コードの中と HTML のコメントの中のリンクは、載っていると数えない。
index_deny '# 索引\n\n[a](a.md) と `[b](b.md)`\n' 'b.md'
index_deny '# 索引\n\n[a](a.md)\n\n```text\n[b](b.md)\n```\n' 'b.md'
index_deny '# 索引\n\n[a](a.md)\n\n<!-- [b](b.md) -->\n' 'b.md'
index_deny '# 索引\n\n[a](a.md)\n\n    [b](b.md)\n' 'b.md'
index_deny '# 索引\n\n[a](a.md)\n\n\t[b](b.md)\n' 'b.md'
index_deny '# 索引\n\n[a](a.md)\n\n>     [b](b.md)\n' 'b.md'
index_ok '# 索引\n\n[a](a.md)\n    [b](b.md)\n'
echo 'PASS links: コードと HTML のコメントの中のリンクは、載っていると数えない'

# 参照の定義だけでは載っていない。本文で使った参照は、書き方によらず載っている。
index_deny '# 索引\n\n[a](a.md)\n\n[b]: b.md\n' 'b.md'
index_deny '# 索引\n\n[a](a.md)\n\n    [文書][b]\n\n[b]: b.md\n' 'b.md'
index_ok '# 索引\n\n[a](a.md) と [文書][b]\n\n[b]: b.md#文書\n'
index_ok '# 索引\n\n[a](a.md) と [b][]\n\n[b]: ./b.md\n'
index_ok '# 索引\n\n[a](a.md) と [b]\n\n[b]: b.md\n'
index_ok '# 索引\n\n[a](a.md) と [文書][B  文書]\n\n[b 文書]: <b.md>\n'
echo 'PASS links: 未使用の参照定義は数えず、本文で使った参照形式は数える'

# 画像だけでは、文書へ進むリンクを置いたことにはならない。
index_deny '# 索引\n\n[a](a.md) と ![b](b.md)\n' 'b.md'
index_deny '# 索引\n\n[a](a.md) と ![文書][b]\n\n[b]: b.md\n' 'b.md'
index_deny '# 索引\n\n[a](a.md) と ![b][]\n\n[b]: b.md\n' 'b.md'
index_deny '# 索引\n\n[a](a.md) と ![b]\n\n[b]: b.md\n' 'b.md'
index_ok '# 索引\n\n[a](a.md) と [![画像](sub/c.md)](b.md)\n'
echo 'PASS links: 画像は数えず、画像を文字にした通常のリンクは数える'

# 表の行ごとに、載っている文書を照合する。表は tests/links-index-table.tsv（入力の種類ごとに 1 行）。
table_rows=0
while IFS=$'\t' read -r id kind doc listed check reason; do
	case "$id" in '#'*|'') continue ;; esac
	table_rows=$((table_rows + 1))
	expected=''
	for name in a b; do
		case ",$listed," in *",$name,"*) ;; *) expected="$expected $name.md" ;; esac
	done
	status=0
	index_check "$doc" || status=$?
	actual=$(sed -n 's/^.*README\.md: 索引: \(.*\) が載っていない$/\1/p' "$test_dir/err" | sort | tr '\n' ' ')
	want=$(printf '%s\n' $expected | sed '/^$/d' | sort | tr '\n' ' ')
	[ "$actual" = "$want" ] || { echo "FAIL links: 表の行 $id: 載っていない文書が違う（期待 [$want] 実際 [$actual]）(${index_mode})" >&2; cat "$test_dir/err" >&2; exit 1; }
	if [ -n "$expected" ]; then want_status=1; else want_status=0; fi
	[ "$status" -eq "$want_status" ] || { echo "FAIL links: 表の行 $id: 終了コードが $want_status でない: $status (${index_mode})" >&2; exit 1; }
done <"$root/tests/links-index-table.tsv"
[ "$table_rows" -ge 60 ] || { echo "FAIL links: 表の行を読めていない: $table_rows" >&2; exit 1; }
echo "PASS links: 索引の掲載判定は、表の $table_rows 行どおり（${index_mode}）"
echo "PASS links: 索引の確認は $index_mode で通った"
done

# 同じ表の行で、通常のリンクの確認が切れを見逃さないことを照合する。行き先は、ない名前（x-a.md、x-b.md）に替える。
while IFS=$'\t' read -r id kind doc listed check reason; do
	case "$id" in '#'*|'') continue ;; esac
	doc=${doc//a.md/x-a.md}
	doc=${doc//b.md/x-b.md}
	printf '%b' "$doc" >"$test_dir/table.md"
	check "$test_dir/table.md" >/dev/null 2>"$test_dir/err" || true
	actual=$(sed -n 's/^.*table\.md:\([0-9]*\): リンク: [<./]*x-\([ab]\)\.md[^ ]* のファイルがない$/\2:\1/p' "$test_dir/err" | sort -u | tr '\n' ' ')
	want=$(printf '%s\n' ${check//,/ } | sort -u | tr '\n' ' ')
	[ "$actual" = "$want" ] || { echo "FAIL links: 表の行 $id: 切れを落とす行が違う（期待 [$want] 実際 [$actual]）" >&2; cat "$test_dir/err" >&2; exit 1; }
done <"$root/tests/links-index-table.tsv"
echo 'PASS links: 通常のリンクの確認は、表の行どおりに切れを落とし、コードとコメントの中は見ない'

# 索引のファイルがないと、引数の誤りとして終了コード 2 で止まる。
status=0
check --index "$index_dir/none.md" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "FAIL links: 索引のファイルがないときの終了コードが 2 でない: $status" >&2; exit 1; }
echo 'PASS links: 索引のファイルがないと、終了コード 2 で止まる'
