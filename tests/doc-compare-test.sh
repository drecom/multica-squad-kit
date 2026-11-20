#!/usr/bin/env bash
# scripts/doc-compare.py が、書き直しの前後でコード・図・インラインコード・数値・リンク先の違いだけを 1 件 1 行で出すことを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/compare.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

# 一時の Git のリポジトリに、前のコミットを作る。
repo="$test_dir/repo"
mkdir -p "$repo/scripts" "$repo/docs"
cp "$root/scripts/doc-compare.py" "$repo/scripts/"
git -C "$repo" init -q
commit() { git -C "$repo" add -A && git -C "$repo" -c user.name=test -c user.email=test@example.com commit -q -m "$1"; }
compare() { python3 "$repo/scripts/doc-compare.py" "$@"; }
fence='```'
printf '# 題\n\n手順は 3 つある。`ls` を流して、[別の文書](other.md#節) を読む。\n\n%sbash\necho one\n%s\n\n%smermaid\nflowchart LR\n  a --> b\n%s\n' "$fence" "$fence" "$fence" "$fence" >"$repo/docs/a.md"
printf '# 別\n' >"$repo/docs/other.md"
commit base
base=$(git -C "$repo" rev-parse HEAD)

# 改行・字下げ・文の言い換えだけの書き直しは、差が 0 件で終了コード 0 になる。
printf '# 題\n\n手順は 3 つあり、\n最初に `ls` を流す。\n詳しくは [別の文書](./other.md#節) にある。\n\n- 項目\n\n  %sbash\n  echo one   \n  %s\n\n%smermaid\nflowchart LR\n  a --> b\n%s\n' "$fence" "$fence" "$fence" "$fence" >"$repo/docs/a.md"
compare --base "$base" >"$test_dir/out" || { echo 'FAIL compare: 改行と文だけの書き直しで差が出た' >&2; cat "$test_dir/out" >&2; exit 1; }
grep -qx '照合の結果: 差 0 件' "$test_dir/out"
echo 'PASS compare: 改行・字下げ・文だけの書き直しは、差が 0 件で終了コード 0'

# 要素を 1 つ足すと、その 1 行だけが出て終了コード 1 になる。
changed() {
	git -C "$repo" checkout -q -- docs/a.md
	printf '%b' "$1" >>"$repo/docs/a.md"
	status=0
	compare --base "$base" >"$test_dir/out" || status=$?
	[ "$status" -eq 1 ] || { echo "FAIL compare: 終了コードが 1 でない: $2" >&2; exit 1; }
	[ "$(grep -c '^差: ' "$test_dir/out")" -eq 1 ] || { echo "FAIL compare: 差が 1 行でない: $2" >&2; cat "$test_dir/out" >&2; exit 1; }
	grep -qE "$2" "$test_dir/out" || { echo "FAIL compare: 期待する行がない: $2" >&2; cat "$test_dir/out" >&2; exit 1; }
	grep -qx '照合の結果: 差 1 件' "$test_dir/out"
}
changed '\n新しい節は 4 つ。\n' '^差: docs/a\.md 数値 \+ 4$'
changed '\n`rm` を足す。\n' '^差: docs/a\.md インラインコード \+ rm$'
changed "\n${fence}bash\necho two\n${fence}\n" '^差: docs/a\.md コード \+ [0-9a-f]{8} echo two$'
changed "\n${fence}mermaid\nflowchart TD\n${fence}\n" '^差: docs/a\.md 図 \+ [0-9a-f]{8} flowchart TD$'
changed '\n[文書](other.md)\n' '^差: docs/a\.md リンク先 \+ docs/other\.md$'
echo 'PASS compare: コード・図・インラインコード・数値・リンク先を 1 つ足すと、その 1 行だけが出て終了コード 1'

# 2 回流した出力は同じで、ないコミットは終了コード 2 になる。
compare --base "$base" >"$test_dir/first" || true
compare --base "$base" >"$test_dir/second" || true
cmp -s "$test_dir/first" "$test_dir/second"
status=0
compare --base no-such-commit >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo 'FAIL compare: ないコミットで終了コード 2 にならなかった' >&2; exit 1; }
echo 'PASS compare: 2 回流した出力は同じで、ないコミットは終了コード 2'

# 複数行のコードスパンは、改行だけなら同じで、語を替えれば前後の差が出る。
for ticks in '`' '``'; do
    printf '# 題\n\n%s echo\none %s\n' "$ticks" "$ticks" >"$repo/docs/a.md"
    commit multiline
    multiline_base=$(git -C "$repo" rev-parse HEAD)
    printf '# 題\n\n%s echo one %s\n' "$ticks" "$ticks" >"$repo/docs/a.md"
    compare --base "$multiline_base" >"$test_dir/out"
    grep -qx '照合の結果: 差 0 件' "$test_dir/out"
    printf '# 題\n\n%s echo\ntwo %s\n' "$ticks" "$ticks" >"$repo/docs/a.md"
    status=0
    compare --base "$multiline_base" >"$test_dir/out" || status=$?
    [ "$status" -eq 1 ]
    grep -qx '差: docs/a.md インラインコード - echo one' "$test_dir/out"
    grep -qx '差: docs/a.md インラインコード + echo two' "$test_dir/out"
    grep -qx '照合の結果: 差 2 件' "$test_dir/out"
done
echo 'PASS compare: 複数行のインラインコードは、改行だけなら差がなく、語の変更は前後の差になる'

# 診断の確認表: フェンスの種類と外側の引用の深さを変え、コード本文の記号を保存する。
for marker in '```' '~~~'; do
    for prefix in '' '> ' '> > '; do
        printf '# 題\n\n%s%sbash\n%s> state.txt\n%s<!-- `example`\n%s%s\n' "$prefix" "$marker" "$prefix" "$prefix" "$prefix" "$marker" >"$repo/docs/a.md"
        commit redirect
        redirect_base=$(git -C "$repo" rev-parse HEAD)
        printf '# 題\n\n%s%sbash\n%s>> state.txt\n%s<!-- `example`\n%s%s\n' "$prefix" "$marker" "$prefix" "$prefix" "$prefix" "$marker" >"$repo/docs/a.md"
        status=0
        compare --base "$redirect_base" >"$test_dir/out" || status=$?
        [ "$status" -eq 1 ]
        grep -qE '^差: docs/a.md コード - [0-9a-f]{8} > state.txt$' "$test_dir/out"
        grep -qE '^差: docs/a.md コード \+ [0-9a-f]{8} >> state.txt$' "$test_dir/out"
        grep -qx '照合の結果: 差 2 件' "$test_dir/out"
    done
done
echo 'PASS compare: 診断の確認表のフェンス 2 種と引用の外・中・入れ子で、リダイレクトの変更をコードの前後 2 件にする'

# コードスパンは単行・複数行をそろえ、後続の数値とリンクは本文として拾う。
for ticks in '`' '``' '```' '````'; do
    printf '# 題\n\n%secho one%s\n' "$ticks" "$ticks" >"$repo/docs/a.md"
    commit line-start
    start_base=$(git -C "$repo" rev-parse HEAD)
    printf '# 題\n\n%secho two%s\n' "$ticks" "$ticks" >"$repo/docs/a.md"
    status=0
    compare --base "$start_base" >"$test_dir/out" || status=$?
    [ "$status" -eq 1 ]
    grep -qx '差: docs/a.md インラインコード - echo one' "$test_dir/out"
    grep -qx '差: docs/a.md インラインコード + echo two' "$test_dir/out"
    grep -qx '照合の結果: 差 2 件' "$test_dir/out"
    for prefix in '' '> '; do
        printf '# 題\n\n%s文中 %secho one%s\n' "$prefix" "$ticks" "$ticks" >"$repo/docs/a.md"
        commit words
        words_base=$(git -C "$repo" rev-parse HEAD)
        printf '# 題\n\n%s文中 %secho\n%sone%s\n' "$prefix" "$ticks" "$prefix" "$ticks" >"$repo/docs/a.md"
        compare --base "$words_base" >"$test_dir/out"
        grep -qx '照合の結果: 差 0 件' "$test_dir/out"
        printf '# 題\n\n%s文中 %secho\n%stwo%s\n' "$prefix" "$ticks" "$prefix" "$ticks" >"$repo/docs/a.md"
        status=0
        compare --base "$words_base" >"$test_dir/out" || status=$?
        [ "$status" -eq 1 ]
        grep -qx '差: docs/a.md インラインコード - echo one' "$test_dir/out"
        grep -qx '差: docs/a.md インラインコード + echo two' "$test_dir/out"
        grep -qx '照合の結果: 差 2 件' "$test_dir/out"
        printf '# 題\n\n%s文中 %secho\n%sone%s 7. [文書](other.md)\n' "$prefix" "$ticks" "$prefix" "$ticks" >"$repo/docs/a.md"
        status=0
        compare --base "$words_base" >"$test_dir/out" || status=$?
        [ "$status" -eq 1 ]
        grep -qx '差: docs/a.md 数値 + 7' "$test_dir/out"
        grep -qx '差: docs/a.md リンク先 + docs/other.md' "$test_dir/out"
        grep -qx '照合の結果: 差 2 件' "$test_dir/out"
    done
done
for boundary in '\n' '## 節' '> ' '```text\nfixed\n```'; do
    printf '# 題\n\n文中 `echo\n%b\none`\n' "$boundary" >"$repo/docs/a.md"
    commit boundary
    boundary_base=$(git -C "$repo" rev-parse HEAD)
    printf '# 題\n\n文中 `echo\n%b\ntwo`\n' "$boundary" >"$repo/docs/a.md"
    compare --base "$boundary_base" >"$test_dir/out"
    grep -qx '照合の結果: 差 0 件' "$test_dir/out"
done
printf '# 題\n\n<!-- `one` 7\n~~~text\n--> 文中 `<!--`\n' >"$repo/docs/a.md"
commit comments
comments_base=$(git -C "$repo" rev-parse HEAD)
printf '# 題\n\n<!-- `two` 8\n```text\n--> 文中 `<!--`\n' >"$repo/docs/a.md"
compare --base "$comments_base" >"$test_dir/out"
grep -qx '照合の結果: 差 0 件' "$test_dir/out"
echo 'PASS compare: 診断の確認表のコードスパン 1〜4 個・境界・本文への復帰・コメントとコードの相互の開始記号を処理する'
