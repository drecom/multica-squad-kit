# terminal-stub と clock-stub を読む部品用の写し。呼ぶテストは root と test_dir を用意する。
draw_root="$test_dir/drawing"
mkdir -p "$draw_root/lib"
cp "$root/lib/"*.sh "$draw_root/lib/"
cp "$root/tests/terminal-stub.sh" "$draw_root/lib/terminal.sh"
cp "$root/tests/clock-stub.sh" "$draw_root/lib/clock.sh"
