#!/usr/bin/env bash
# scripts/check-style.py が、文書の書き方の決まりに反する文書を行の番号と決まりの名前を添えて止め、直した文書を通すことを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/style.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
check() { python3 "$root/scripts/check-style.py" "$@"; }

check
echo 'PASS style: リポジトリの対象の文書は、対象外の一覧にあるものを除いて検査を通る'

# 反する例を 1 つずつ入れて、行の番号と決まりの名前で落ちることを確認し、直した例が通ることを確認する。
deny() {
	printf '%b' "$1" >"$test_dir/ng.md"
	if check "$test_dir/ng.md" >/dev/null 2>"$test_dir/err"; then echo "FAIL style: 通ってしまった: $3" >&2; exit 1; fi
	grep -qF "ng.md:$2: $3" "$test_dir/err" || { echo "FAIL style: 場所か決まりの名前が違う: $3" >&2; cat "$test_dir/err" >&2; exit 1; }
}
fix() {
	printf '%b' "$1" >"$test_dir/ok.md"
	check "$test_dir/ok.md" >/dev/null
}
deny '# 題\n\n文末は です。\n' 3 '文体: 文末を「です」「ます」にしない'
fix '# 題\n\n文末は常体にする。\n'
deny '# 題\n\n0123456789012345678901234567890123456789012345678901234567890123456789012345678901 字。\n' 3 '文と段落の長さ: 1 文は 80 字まで'
deny '# 題\n\nあ、い、う、え、お。\n' 3 '文と段落の長さ: 1 文の読点は 3 つまで'
deny '# 題\n\nあ。い。う。え。お。\n' 3 '文と段落の長さ: 1 段落は 4 文まで'
deny '# 題\n\n- あ。い。う。\n' 3 '文と段落の長さ: 箇条書きの 1 項目は 2 文まで'
deny '# 題\n\n文，です\n' 3 '句読点: 全角のカンマ'
deny '# 題\n\n- 項目。\n' 3 '句読点: 箇条書きの項目・表のセル・見出しの末尾に「。」を付けない'
deny '# 題\n\n日本語(括弧)にする。\n' 3 '句読点: 日本語を含む括弧は全角の（）にする'
deny '# 題\n\nＡＢＣ を使う。\n' 3 '全角と半角: 全角の英数字'
deny '# 題\n\n日本語abc日本語にする。\n' 3 '全角と半角: 日本語と、半角の英数字・インラインコードの間に、半角の空白を 1 つ置く'
deny '# 題\n\n日本語、 次の文にする。\n' 3 '全角と半角: 句読点と括弧の前後に空白を置かない'
deny '# 題\n\n文を書く。  \n' 3 '改行: 行の末尾に空白を置かない'
deny '# 題\n\n```\nコード\n```\n' 3 '箇条書き・表・コード・注記: コードブロックには言語を書く'
deny '# 題\n\n```bash\n$ ls\n```\n' 4 '箇条書き・表・コード・注記: コマンドの前に、プロンプトの「$」を付けない'
deny '# 題\n\n- 親\n  - 子\n    - 孫\n' 5 '箇条書き・表・コード・注記: 箇条書きの入れ子は 1 段までにする'
deny '# 題\n\n![図](a.png)\n' 3 '図: 画像を置かず、図は mermaid のコードブロックにする'
deny '# 題\n\n[ここ](a.md)を読む。\n' 3 'リンク: リンクの文字を「こちら」「ここ」「リンク」にしない'
deny '# 題\n\n[あ](https://github.com/x/multica-squad-kit/blob/main/a.md)を読む。\n' 3 'リンク: リポジトリの中のファイルを GitHub の URL で指さない'
deny '本文だけを書く。\n' 1 '文書の種類ごとの構成: H1 は文書の先頭の 1 つだけにする'
deny '本文を書く。\n\n# 題\n' 3 '文書の種類ごとの構成: H1 は文書の先頭の 1 つだけにする'
deny '```text\n# 題\n```\n' 1 '文書の種類ごとの構成: H1 は文書の先頭の 1 つだけにする'
deny '' 1 '文書の種類ごとの構成: H1 は文書の先頭の 1 つだけにする'
fix '\n<!-- コメント -->\n\n# 題\n\n結論を書く。\n'
deny '# 題\n\n[ここ][先]\n\n[先]: a.md\n' 3 'リンク: リンクの文字を「こちら」「ここ」「リンク」にしない'
deny '# 題\n\n![](a.png)\n' 3 '図: 画像を置かず、図は mermaid のコードブロックにする'
deny '# 題\n\n# 二つ目\n' 3 '文書の種類ごとの構成: H1 は文書の先頭の 1 つだけにする'
deny '# 題\n\n### 飛ばす\n\n結論を書く。\n' 3 '文書の種類ごとの構成: 見出しの階層は 1 つずつ下げる'
deny '# 題\n\n## 節\n\n### 小節\n\n結論を書く。\n' 3 '文書の種類ごとの構成: 見出しのすぐ後に見出しを続けず、節の結論を書く'
deny '# 題\n\n途中で\n改行する。\n' 4 '改行: 段落は途中で改行しない'
deny '# 題\n\n- 項目を\n  続ける。\n' 4 '改行: 箇条書きの項目は途中で改行しない'
deny '# 題\n\n| 見出し |\n| --- |\n| あ。い。う。 |\n' 5 '文と段落の長さ: 表のセルは 2 文まで'
deny '# 題\n\n## 節\n\n結論を書く。\n\n### 小節\n\n結論を書く。\n\n#### 項\n\n結論を書く。\n\n##### 深い\n\n結論を書く。\n' 15 '文書の種類ごとの構成: 見出しは #### までにする'
deny '# 題\n\n<img src="a.png">\n' 3 '図: 画像を置かず、図は mermaid のコードブロックにする'
deny '# 題\n\n全角　空白を使う。\n' 3 '全角と半角: 全角の英数字・全角の空白・半角のカタカナを使わない'
deny '# 題\n\nコメントは `<!--` で始める。\n\n文末は です。\n' 5 '文体: 文末を「です」「ます」にしない'
deny '# 題\n\n> ```bash\n> $ ls\n> ```\n' 4 '箇条書き・表・コード・注記: コマンドの前に、プロンプトの「$」を付けない'
fix '# 題\n\n途中で改行しない。\n\n- 項目を続ける\n'
fix '# 題\n\n<番号> を書く。\n'
fix '# 題\n\n> ```text\n> です、あ、い、う、え、お\n> ```\n'
# 段落の字数は、文の終わりの「。」を数えずに、文ごとの字数を合わせる。60 字の文 4 つ（240 字）は通り、1 字足すと落ちる。
sentence=$(printf 'あ%.0s' $(seq 60))
fix "# 題\n\n${sentence}。${sentence}。${sentence}。${sentence}。\n"
deny "# 題\n\n${sentence}。${sentence}。${sentence}。${sentence}あ。\n" 3 '文と段落の長さ: 1 段落は 240 字まで（241 字）'
echo 'PASS style: 決まりに反する例は、行の番号と決まりの名前を添えて落ち、直した例は通る'

printf '# 題\n\n`です` と「です。」と <!-- です -->は数えない。\n\n```bash\nls です、あ、い、う、え、お\n```\n' >"$test_dir/ok.md"
check "$test_dir/ok.md" >/dev/null
echo 'PASS style: コードブロック・インラインコード・「」・HTML のコメントの中は、文体と文の区切りで数えない'

# 診断の確認表: コメントとコードの相互の開始、閉じた位置、コメント内のフェンス。
fix '# 題 <!-- コメント -->\n\n文は常体にする。 <!-- コメント -->\n'
for ticks in '`' '``' '```' '````'; do
    fix "# 題\n\n${ticks}<!--${ticks}\n"
    deny "# 題\n\n<!-- ${ticks} --> ${ticks}value${ticks} 文末は です。\n" 3 '文体: 文末を「です」「ます」にしない'
    fix "# 題\n\n<!-- ${ticks} --> ${ticks}value${ticks} 文末は常体にする。\n"
    deny "# 題\n\n<!-- ${ticks} --> ${ticks}value${ticks}\n\n文末は です。\n" 5 '文体: 文末を「です」「ます」にしない'
    fix "# 題\n\n<!-- ${ticks} --> ${ticks}value${ticks}\n\n文末は常体にする。\n"
    deny "# 題\n\n<!--\n${ticks} です。\n--> ${ticks}value${ticks}\n\n文末は です。\n" 7 '文体: 文末を「です」「ます」にしない'
    fix "# 題\n\n<!--\n${ticks} です。\n--> ${ticks}value${ticks}\n\n文末は常体にする。\n"
    deny "# 題\n\n文中 ${ticks}<!--${ticks}\n\n文末は です。\n" 5 '文体: 文末を「です」「ます」にしない'
    fix "# 題\n\n文中 ${ticks}<!--\nです。${ticks}\n\n文末は常体にする。\n"
done
for marker in '```' '~~~'; do
    deny "# 題\n\n<!--\n${marker}text\nです。\n-->\n\n文末は です。\n" 8 '文体: 文末を「です」「ます」にしない'
    fix "# 題\n\n<!--\n${marker}text\nです。\n-->\n\n文末は常体にする。\n"
    fix "# 題\n\n${marker}text\n<!-- です。\n${marker}\n\n文末は常体にする。\n"
done
fix '# 題\n\n> 文中 `<!--\n> です。`\n\n本文は常体にする。\n'
echo 'PASS style: 診断の確認表の相互の開始記号・単行と複数行・コメント内のフェンスを処理し、外の文体違反を元の行で検出する'

# 一覧は、書き直すまでの文書を引数なしで飛ばし、引数に渡すと検査する。誤りがあると止まる。
tree="$test_dir/tree"
mkdir -p "$tree/scripts" "$tree/docs"
cp "$root/scripts/check-style.py" "$tree/scripts/"
printf '# 題\n\n文末は です。\n' >"$tree/docs/a.md"
printf '# 題\n\n文末は常体にする。\n' >"$tree/docs/b.md"
printf 'docs/a.md\n' >"$tree/scripts/style-exempt.txt"
python3 "$tree/scripts/check-style.py" >/dev/null
if python3 "$tree/scripts/check-style.py" "$tree/docs/a.md" >/dev/null 2>&1; then exit 1; fi
echo 'PASS style: 一覧のファイルは引数がないと飛ばし、引数に渡すと検査する'

for bad in 'docs/b.md\ndocs/a.md\n' 'docs/a.md\ndocs/a.md\n' 'docs/a.md\n\n' 'docs/none.md\n'; do
	printf "$bad" >"$tree/scripts/style-exempt.txt"
	status=0
	python3 "$tree/scripts/check-style.py" >/dev/null 2>"$test_dir/err" || status=$?
	[ "$status" -eq 2 ] || { echo "FAIL style: 一覧の誤りで止まらなかった: $bad" >&2; exit 1; }
	grep -q '^scripts/style-exempt.txt:[0-9]*: ' "$test_dir/err"
done
echo 'PASS style: 一覧の誤り（名前順でない・重なり・空の行・ないファイル）は、行の番号を添えて終了コード 2 で止まる'
