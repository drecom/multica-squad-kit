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
