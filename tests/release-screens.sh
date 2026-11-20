#!/usr/bin/env bash
# テストと共通のスタブで、公開の 5 場面を流し、問いまでと答え以降の端末の出力を保存する。
# 設計は docs/release.md の「画面を画像で見比べる」。PNG の描画は別の補助が担当する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
usage() {
	printf '使い方: bash tests/release-screens.sh <release.sh のパス> <出力先> [--capture-only]\n'
}
capture_only=no
args=()
for arg in "$@"; do
	case $arg in
	--capture-only) capture_only=yes ;;
	--help | -h) usage; exit 0 ;;
	--*) usage >&2; exit 2 ;;
	*) args+=("$arg") ;;
	esac
done
[[ ${#args[@]} == 2 ]] || { usage >&2; exit 2; }
if [[ $capture_only != yes ]]; then
	screens_python=${RELEASE_SCREENS_PYTHON:-python3}
	if ! "$screens_python" -c 'import PIL' 2>/dev/null; then
		printf 'Pillow がありません。tmp/ の venv に tests/release-screens-requirements.txt で入れ、RELEASE_SCREENS_PYTHON にその Python のパスを指定してください。出力だけなら --capture-only を使えます。\n' >&2
		exit 1
	fi
fi
release_script=$(cd "$(dirname "${args[0]}")" && pwd)/$(basename "${args[0]}")
[[ -f $release_script ]] || { printf '公開のスクリプトがありません: %s\n' "$release_script" >&2; exit 1; }
mkdir -p "${args[1]}" "$root/tmp"
output_dir=$(cd "${args[1]}" && pwd)
test_dir=$(mktemp -d "$root/tmp/release-screens.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/tests/release-test-lib.sh"
# 同じ入力で流し直したとき、コミットの日時が画面の SHA を変えないようにする。
export GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
printf 'y\n' >"$test_dir/answer"
awk '$0 == "## v1.0.0" {found=1; next} found && /^## / {exit} found {print}' "$root/CHANGELOG.md" >"$test_dir/notes"
[[ -n $(tr -d '[:space:]' <"$test_dir/notes") ]] || { printf 'CHANGELOG.md の v1.0.0 の節がありません。\n' >&2; exit 1; }

for scene in 1 2 3 4 5; do
	make_case "$scene"
	cp "$root/lib/terminal.sh" "$work/lib/terminal.sh"
	cp "$release_script" "$work/scripts/release.sh"
	{ printf '# 変更の記録\n\n## v1.6.0\n'; cat "$test_dir/notes"; } >"$work/CHANGELOG.md"
	(cd "$work" && bash scripts/manifest.sh)
	commit_work 'Release screen content'
	unset NO_COLOR
	case $scene in
	2) tag_here; add_release true ;;
	3) export GH_WATCH_FAIL=1 ;;
	4) export GH_ATTEST_FAIL=SHA256SUMS GH_ATTEST_FAIL_WITH=nobundle ;;
	5) export NO_COLOR=1 ;;
	esac
	# D: 実物の端末で問いの全文と答えを同期し、時計だけを止める。
	printf 'expect 公開しますか [y/N]: \nsend y\n' >"$case_dir/scene-script"
	status=0
	(cd "$work" && env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" TERM=xterm-256color \
		python3 "$root/tests/tty-session.py" --script "$case_dir/scene-script" --marks "$case_dir/marks" \
		--output "$case_dir/all" --error "$case_dir/error" -- /bin/bash scripts/release.sh) || status=$?
	if [[ $status == 125 ]]; then
		printf '場面 %s の出力を取れませんでした。画像を作りません。\n' "$scene" >&2
		exit 1
	fi
	python3 - "$case_dir" "$output_dir/$scene-confirm.ansi" "$output_dir/$scene-after.ansi" <<'SPLIT'
from pathlib import Path
import sys
p=Path(sys.argv[1]);data=(p/'all').read_bytes();at=int((p/'marks').read_text().splitlines()[0])
Path(sys.argv[2]).write_bytes(data[:at]);Path(sys.argv[3]).write_bytes(data[at:])
SPLIT
	printf '%s\n' "$status" >"$output_dir/$scene-status"
	if [[ $capture_only != yes ]]; then
		"$screens_python" "$root/tests/ansi-to-png.py" "$output_dir/$scene-confirm.ansi" "$output_dir/$scene-confirm.png" --last-lines 40
		"$screens_python" "$root/tests/ansi-to-png.py" "$output_dir/$scene-after.ansi" "$output_dir/$scene-after.png" --before "$output_dir/$scene-confirm.ansi"
	fi
done
printf '画面の出力を保存しました: %s\n' "$output_dir"
