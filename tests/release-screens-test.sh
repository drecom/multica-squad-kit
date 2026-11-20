#!/usr/bin/env bash
# 画面を画像にする仕組みの、出力を取るところまでを確認する。PNG と Pillow は CI には要らない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release-screens-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
# tty-session-test.sh の T01・T03・T05・T06・T16・T20 が入出力と終了コードを確認する。
# 描画前の読み取りは Pillow を入れずに確認する。CI では PNG を描かない。
python3 - "$root/tests/ansi-to-png.py" <<'PY'
import importlib.util
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('ansi_to_png', sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert module.xterm_color(28) == (0, 135, 0)
assert module.xterm_color(30) == (0, 135, 135)
assert module.xterm_color(196) == (255, 0, 0)
assert module.xterm_color(255) == (238, 238, 238)
text = 'A' * 99 + '界\x1b[1;38;5;28m緑\x1b[22ma\x1b[39mb\x1b[0mc'
lines = module.terminal_lines(text)
assert len(lines) == 2 and len(lines[0]) == 99
wide, green, normal, default, reset = lines[1]
assert (wide.column, wide.width) == (0, 2)
assert green.column == 2 and green.color == (0, 135, 0) and green.bold
assert normal.color == green.color and not normal.bold
assert default.color == reset.color == module.FOREGROUND
assert not default.bold and not reset.bold
unknown = module.terminal_lines('\x1b[38;5;28m\x1b[2J\x1b]0;title\x07\x1b[38;2;0;0;0m字\r\n')
assert len(unknown) == 1 and len(unknown[0]) == 1
assert unknown[0][0].text == '字' and unknown[0][0].color == (0, 135, 0)
assert 'PIL' not in sys.modules
PY
echo 'PASS release-screens: Pillow なしで全角の折り返し、色、太字、対象外の制御文字を確認した'

bash "$root/tests/release-screens.sh" "$root/scripts/release.sh" "$test_dir/screens" --capture-only
python3 - "$test_dir/screens" "$root/CHANGELOG.md" <<'PY'
from pathlib import Path
import re
import sys
screens, changelog = map(Path, sys.argv[1:])
notes = changelog.read_text().split('## v1.0.0\n', 1)[1].split('\n## ', 1)[0].strip()
ansi = re.compile(rb'\x1b\[[0-9;]*m')
for scene, expected in ((1, 0), (2, 0), (3, 1), (4, 1), (5, 0)):
    assert (screens / f'{scene}-status').read_text().strip() == str(expected), scene
    before = (screens / f'{scene}-confirm.ansi').read_bytes()
    after = (screens / f'{scene}-after.ansi').read_bytes()
    assert before.endswith('公開しますか [y/N]: '.encode()), scene
    plain_before = ansi.sub(b'', before).decode().replace('\r\n', '\n')
    body = '\n'.join(line[4:] if line.startswith('  │ ') else '' for line in plain_before.splitlines() if line.startswith('  │'))
    assert body == notes, scene
    assert after.startswith(b'y\r\n'), scene
    assert b'\x1b[' in before if scene != 5 else b'\x1b' not in before + after
    plain = ansi.sub(b'', after).decode().replace('\r\n', '\n')
    if expected == 0:
        summary=plain.rsplit('\n✔ v1.6.0  ',1)[1].splitlines()
        assert summary[0]=='https://github.com/example/kit/releases/tag/v1.6.0',scene
        assert re.fullmatch(r'  [0-9a-f]{40}', summary[1]),(scene,summary)
        assert summary[2:8]==['','  multica-squad-kit-v1.6.0.tar.gz','  install.sh','  SHA256SUMS','  multica-squad-kit-v1.6.0.sigstore.json',''],(scene,summary)
        assert summary[8]=='  https://github.com/example/kit/actions/runs/4242',(scene,summary)
        assert '配布物を検証する' in plain and 'Release を公開する' in plain, scene
        if scene != 2:
            assert '発行のワークフローに配布物を作らせ、終わるまで待つ' in plain, scene
    elif scene == 3:
        assert '$ gh run watch' in plain and '--exit-status' in plain
        assert "completed with 'failure'" in plain
        assert 'ここから】' not in plain
    else:
        assert '$ bash ' in plain and '--verify v1.6.0' in plain
        assert 'stub: attestation failed' in plain
        assert '✖ タグの install.sh' in plain and '✖ 配布物を検証する' in plain
        assert 'ここから】' not in plain
assert not list(screens.glob('*.png'))
PY
# 書き換えた一覧の先頭から残る。成功は完了した手順、失敗は ✖ が、後の画像の文字に残る。
text() { python3 "$root/tests/ansi-to-png.py" "$test_dir/screens/$1-after.ansi" --before "$test_dir/screens/$1-confirm.ansi" --text; }
for scene in 1 3 4 5; do
	text "$scene" | grep -F 'タグを作って push する' >/dev/null || { echo "FAIL release-screens: 場面 $scene の後の画像の文字に、一覧の先頭の手順がない" >&2; exit 1; }
done
text 1 | grep -F '✔ 下書きの Release を作る' >/dev/null || { echo 'FAIL release-screens: 場面 1 の後の画像の文字に、完了した手順がない' >&2; exit 1; }
text 1 | grep -F '✔ 発行のワークフローに配布物を作らせ、終わるまで待つ' >/dev/null || { echo 'FAIL release-screens: 場面 1 の後の画像の文字に、ワークフローの完了がない' >&2; exit 1; }
text 3 | grep -F '✖ 発行のワークフローに配布物を作らせ、終わるまで待つ' >/dev/null || { echo 'FAIL release-screens: 場面 3 の後の画像の文字に、失敗のマークがない' >&2; exit 1; }
text 4 | grep -F '✖ 配布物を検証する' >/dev/null || { echo 'FAIL release-screens: 場面 4 の後の画像の文字に、失敗のマークがない' >&2; exit 1; }
! text 3 | grep '○ タグを作って push する' >/dev/null || { echo 'FAIL release-screens: 場面 3 の後の画像に、書き換える前の行が残る' >&2; exit 1; }
echo 'PASS release-screens: 5 場面の終了コード、問い、長い本文、色、成功と失敗の画面を取れた'
