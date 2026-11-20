# 通常の時計と待機。テストは写しのファイルをスタブへ差し替える。
clock_now() { clock_value=$SECONDS; }
clock_sleep() { sleep "$@"; }
