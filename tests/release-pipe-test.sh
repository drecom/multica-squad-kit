#!/usr/bin/env bash
# 読み手が早く終わるパイプを、大きな古い節で検出する。設計は docs/terminal-tests.md。
set -euo pipefail
# Broken pipe の文を、ホストの表示言語によらず照合する。
export LC_ALL=C
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-assertions.sh"

make_case changelog-pipe
python3 - "$work/CHANGELOG.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text() + '\n' + ('old-section-padding ' + 'x' * 108 + '\n') * 65536)
PY
(cd "$work" && bash scripts/manifest.sh)
commit_work 'Add a large old section'
cp "$work/scripts/release.sh" "$case_dir/fixed-release.sh"

# 本体は正常終了だけを通し、問いと今の節の本文も確認する。
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
grep -qF '公開しますか [y/N]: ' "$case_dir/err"
grep -qF '新しいバージョンの 1 段落目。' "$case_dir/out"
[[ $(cat "$GH_NOTES") == "$notes_expected" ]]
! grep -qF 'old-section-padding' "$case_dir/out"
echo 'PASS release-pipe: 大きな古い節を読み切り、今の本文と問いを出す'

# どちらか 1 か所に早い終了を戻しても、この確認が見逃さないことを確認する。
for parser in version notes; do
	cp "$case_dir/fixed-release.sh" "$work/scripts/release.sh"
	python3 - "$work/scripts/release.sh" "$parser" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
fixed, early = {
    'version': ("!found && /^## / {print $2; found = 1}", "/^## / {print $2; exit}"),
    'notes': ("$0 == heading && !done {found = 1; next} found && /^## / {found = 0; done = 1} found",
              "$0 == heading {found = 1; next} found && /^## / {exit} found"),
}[sys.argv[2]]
text = p.read_text()
assert text.count(fixed) == 1
p.write_text(text.replace(fixed, early))
PY
	(cd "$work" && bash scripts/manifest.sh)
	commit_work "Restore the early $parser parser exit"
	run_release "$test_dir/answer-n"
	if [[ $rc != 141 ]]; then
		[[ $rc == 1 ]]
		grep -qF 'Broken pipe' "$case_dir/err"
	fi
	! grep -qF '公開しますか [y/N]: ' "$case_dir/err"
	echo "PASS release-pipe: $parser の早い終了を戻した写しは SIGPIPE で止まる（rc=${rc}）"
done
