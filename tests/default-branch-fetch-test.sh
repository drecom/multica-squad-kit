#!/usr/bin/env bash
# 週次の依存の監査と Dependabot の確認の、デフォルトブランチを手元に用意する手順を、
# refspec を絞った clone で 2 回続けて流して確認する（docs/default-branch.md の「最新のコミットにする」「追跡の ref を更新する」）。
# 手順のコマンドは common/autopilots.md の 2 つの指示から読み、<ブランチ名> を置き換えて流す。
# リモートのコミットは、push ではなく bare のリポジトリの中で作る。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/default-branch-fetch.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

# 読む側: オートパイロットの指示を実行するエージェント。2 つの指示から、fetch・checkout・判定のコマンドを読む。
for heading in '^## 週 1 回の依存ライブラリの脆弱性チェック ' '^## Dependabot の PR の週次の確認 '; do
	section=$test_dir/section
	awk -v heading="$heading" '$0 ~ heading {inside=1; next} inside && /^## / {exit} inside {print}' "$root/common/autopilots.md" >"$section"
	[[ -s $section ]]
	for command in 'git status --porcelain' 'git branch -r --contains HEAD' 'git rev-parse HEAD'; do
		grep -qF -- "$command" "$section"
	done
	# 手順は「、」で区切って並ぶ。文字クラスはロケールで壊れるので、文字列の切り出しで読む。
	[[ $(grep -cF 'git fetch origin ' "$section") -eq 1 && $(grep -cF 'git checkout --detach ' "$section") -eq 1 ]]
	line=$(grep -F 'git fetch origin ' "$section")
	rest=${line#*git fetch origin }
	fetch="git fetch origin ${rest%%、*}"
	line=$(grep -F 'git checkout --detach ' "$section")
	rest=${line#*git checkout --detach }
	checkout="git checkout --detach ${rest%%、*}"
	if [[ -z ${expected_fetch+x} ]]; then
		expected_fetch=$fetch expected_checkout=$checkout
	fi
	# 2 つの指示が同じ fetch と checkout を書く。
	[[ $fetch == "$expected_fetch" && $checkout == "$expected_checkout" ]]
done
[[ $expected_fetch == 'git fetch origin +refs/heads/<ブランチ名>:refs/remotes/origin/<ブランチ名>' ]]
[[ $expected_checkout == 'git checkout --detach refs/remotes/origin/<ブランチ名>' ]]
echo 'PASS fetch: 2 つの指示が、追跡の ref に置く同じ fetch と checkout を書く'

git_t() { git -c user.name=test -c user.email=test@example.com -c protocol.file.allow=always "$@"; }

# デフォルトが develop で、main と develop が別のコミットを指す bare のリモート。コミットは bare の中で作る。
remote=$test_dir/remote.git
git init -q --bare "$remote"
git -C "$remote" symbolic-ref HEAD refs/heads/develop
blob=$(printf 'one\n' | git -C "$remote" hash-object -w --stdin)
tree=$(printf '100644 blob %s\tfile\n' "$blob" | git -C "$remote" mktree)
remote_commit() { # <ブランチ> [<親>]
	local parent=()
	[[ -n ${2:-} ]] && parent=(-p "$2")
	local sha
	sha=$(git_t -C "$remote" commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "$1")
	git -C "$remote" update-ref "refs/heads/$1" "$sha"
	echo "$sha"
}
main_tip=$(remote_commit main)
develop_tip=$(remote_commit develop)

# 手順 1 の流れ。判定（未コミット・未 push）に当たると、fetch の前に終了コード 10 か 11 で止まる。
# 指示のコマンドの <ブランチ名> を置き換えて流す。
steps() { # <リポジトリ> <ブランチ> [<fetch> <checkout>]
	local repo=$1 branch=$2
	local fetch=${3:-$expected_fetch} checkout=${4:-$expected_checkout}
	local -a words
	fetch=${fetch//<ブランチ名>/$branch}
	checkout=${checkout//<ブランチ名>/$branch}
	[[ -z $(git -C "$repo" status --porcelain) ]] || return 10
	[[ -n $(git -C "$repo" branch -r --contains HEAD) ]] || return 11
	read -r -a words <<<"$fetch"
	(cd "$repo" && "${words[@]}") >/dev/null 2>&1 || return 12
	read -r -a words <<<"$checkout"
	(cd "$repo" && "${words[@]}") >/dev/null 2>&1 || return 13
	git -C "$repo" rev-parse HEAD
}
# 実行の結果は code に入れる。set -e の下でも、止まる側の終了コードを読めるようにする。
attempt() { code=0; out=$(steps "$@") || code=$?; }

# refspec を main だけに絞った clone。いま main にいて、公開済みのコミットなのでクリーンと読まれる。
narrow_clone() { # <名前>
	local repo=$test_dir/$1
	git init -q "$repo"
	git -C "$repo" remote add -t main origin "$remote"
	git_t -C "$repo" fetch -q origin
	git -C "$repo" checkout -q --detach origin/main
	# 絞った refspec は main だけで、develop の追跡の ref はない。
	[[ $(git -C "$repo" config --get-all remote.origin.fetch) == '+refs/heads/main:refs/remotes/origin/main' ]]
	[[ -z $(git -C "$repo" for-each-ref refs/remotes/origin/develop) ]]
	echo "$repo"
}

work=$(narrow_clone work)
attempt "$work" develop
[[ $code -eq 0 && $out == "$develop_tip" ]]
[[ $(git -C "$work" rev-parse refs/remotes/origin/develop) == "$develop_tip" ]]
# 手元の refspec の設定は変えない。
[[ $(git -C "$work" config --get-all remote.origin.fetch) == '+refs/heads/main:refs/remotes/origin/main' ]]

# リモートが進んでから 2 回目を流す。前回取得したコミットを、未 push と取り違えずに最新へ進む。
develop_next=$(remote_commit develop "$develop_tip")
attempt "$work" develop
[[ $code -eq 0 && $out == "$develop_next" ]]
[[ $(git -C "$work" rev-parse HEAD) == "$develop_next" ]]
echo 'PASS fetch: refspec を main に絞った clone で、デフォルトの develop の手順を 2 回続けて流しても、2 回目が判定を通る'

# 前の形（FETCH_HEAD だけに取得する）では、2 回目が公開済みのコミットを未 push と取り違えて止まる。
old=$(narrow_clone old)
attempt "$old" develop 'git fetch origin refs/heads/<ブランチ名>' 'git checkout --detach FETCH_HEAD'
[[ $code -eq 0 && $out == "$develop_next" ]]
attempt "$old" develop 'git fetch origin refs/heads/<ブランチ名>' 'git checkout --detach FETCH_HEAD'
[[ $code -eq 11 ]]
echo 'PASS fetch: FETCH_HEAD だけに取得する前の形は、2 回目で未 push と取り違えて止まる'

# 未コミットの変更: 追跡しているファイルの変更も、追跡していないファイルも、止まって手元に残る。
dirty=$(narrow_clone dirty)
before=$(git -C "$dirty" rev-parse HEAD)
printf 'two\n' >>"$dirty/file"
printf 'new\n' >"$dirty/untracked"
attempt "$dirty" develop
[[ $code -eq 10 ]]
[[ $(git -C "$dirty" rev-parse HEAD) == "$before" ]]
[[ $(cat "$dirty/file") == $'one\ntwo' && $(cat "$dirty/untracked") == new ]]
[[ -z $(git -C "$dirty" for-each-ref refs/remotes/origin/develop) ]]
echo 'PASS fetch: 未コミットの変更があると判定で止まり、取得も checkout もせず、変更は手元に残る'

# 未 push のコミット: どのリモートのブランチにも含まれない HEAD で止まり、コミットは手元に残る。
ahead=$(narrow_clone ahead)
git_t -C "$ahead" commit -q --allow-empty -m local
local_commit=$(git -C "$ahead" rev-parse HEAD)
attempt "$ahead" develop
[[ $code -eq 11 ]]
[[ $(git -C "$ahead" rev-parse HEAD) == "$local_commit" ]]
git -C "$ahead" cat-file -e "$local_commit^{commit}"
[[ -z $(git -C "$ahead" status --porcelain) && -z $(git -C "$ahead" for-each-ref refs/remotes/origin/develop) ]]
echo 'PASS fetch: 未 push のコミットがあると判定で止まり、取得も checkout もせず、コミットは手元に残る'
