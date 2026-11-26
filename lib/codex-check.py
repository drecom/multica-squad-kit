#!/usr/bin/env python3
"""Codex の設定の厳しい検証を流し、時間切れのときは子のプロセスのグループを止める。

使い方: codex-check.py <CODEX_HOME> <上限の秒> <猶予の秒> [<確認の秒>]

標準出力に 2 行を返す。1 行目は状態、2 行目は詳細である。
  ok            終了コード 0
  old           古い Codex が --strict-config を受け付けない
  failed        0 以外の終了コード（詳細に終了コード）
  launch        Codex を起動できなかった（設定の誤りではない）
  timeout       上限を過ぎ、グループが停止済みになった
  unconfirmed   上限を過ぎ、グループの停止を確認できなかった（詳細にグループの番号）

時間切れの手順と分類は、docs/agent-settings.md の「時間切れの扱い」が決める。
送る処理・状態の読み取り・回収・時計は Operations に集め、tests/codex-check-test.sh が差し替える。
"""
import errno
import os
import signal
import subprocess
import sys
import tempfile
import time

COMMAND = ["codex", "app-server", "--strict-config", "--listen", "stdio://"]
POLL_SECONDS = 0.05
# 確認の間は全プロセスを読むので、読み取りの間隔は待ちの刻みより広げる。期限は変えない。
STATE_POLL_SECONDS = 0.25

RUNNING = "running"
STOPPED = "stopped"
UNDETERMINABLE = "undeterminable"


class Operations:
    """グループへの送信・状態の読み取り・直接の子の回収・時計。テストが差し替える。"""

    def __init__(self, child):
        self.child = child

    def send(self, pgid, number):
        os.killpg(pgid, number)

    def state(self, pgid, timeout):
        # 状態は ps の状態だけから読む。判定に使わないコマンド列は読まない。シグナルを送った結果から生存を決めない。
        try:
            done = subprocess.run(["ps", "-A", "-o", "pid,pgid,stat"], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        except (OSError, subprocess.SubprocessError):
            return UNDETERMINABLE
        return classify(done.returncode, done.stdout.decode("utf-8", errors="replace"), pgid)

    def reap(self):
        # 直接の子が終了していれば回収して True を返す。動いていれば回収せず False を返す。
        return self.child.poll() is not None

    def now(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


def classify(returncode, text, pgid):
    """ps の出力から、グループの状態を決める。読めなければ判定不能にする。"""
    if returncode != 0:
        return UNDETERMINABLE
    lines = text.splitlines()
    if not lines or lines[0].split()[:3] != ["PID", "PGID", "STAT"]:
        return UNDETERMINABLE
    running = False
    for line in lines[1:]:
        if not line.strip():
            continue
        fields = line.split(None, 3)
        if len(fields) < 3 or not fields[0].isdigit() or not fields[1].isdigit():
            return UNDETERMINABLE
        if int(fields[1]) == pgid and not fields[2].startswith("Z"):
            running = True
    return RUNNING if running else STOPPED


def send_name(error):
    if error is None:
        return "ok"
    if error.errno == errno.ESRCH:
        return "ESRCH"
    if error.errno == errno.EPERM:
        return "EPERM"
    return "error"


def stop_group(ops, pgid, grace, confirm):
    """TERM・固定の猶予・KILL・状態の確認と回収の順に進め、(結果, 送った記録) を返す。

    結果は "timeout"（停止済みを確認し、直接の子を回収した）か "unconfirmed"（確認できなかった）である。
    猶予の間は状態を見ず、直接の子も回収しない。回収のあとにグループへ送らない。
    終了までの上限は、TERM から猶予と確認の期間を足した時刻である。期限は 1 回だけ決め、
    状態の読み取り・回収の再試行・例外の後始末は、すべてその期限までの残り時間だけを使う。
    """
    sends = []
    # 期限は、時計を読めた時点で 1 回だけ決める。例外の後始末も、同じ期限を引き継ぐ。
    limits = {}

    def send(name, number):
        # 送った結果は記録するだけで、停止の判定には使わない。
        try:
            ops.send(pgid, number)
        except OSError as error:
            sends.append((name, send_name(error)))
        else:
            sends.append((name, send_name(None)))

    try:
        send("TERM", signal.SIGTERM)
        term_time = ops.now()
        limits["last"] = term_time + grace + confirm
        while True:
            remaining = term_time + grace - ops.now()
            if remaining <= 0:
                break
            ops.sleep(min(remaining, POLL_SECONDS))
        send("KILL", signal.SIGKILL)
        # 確認の期限は KILL の直後に決める。TERM から数えた上限を超えない。
        deadline = min(ops.now() + confirm, limits["last"])
        limits["deadline"] = deadline
        while True:
            remaining = deadline - ops.now()
            if remaining <= 0:
                break
            if ops.state(pgid, remaining) == STOPPED and ops.reap():
                return "timeout", sends
            ops.sleep(min(max(deadline - ops.now(), 0), STATE_POLL_SECONDS))
        # 期限まで停止済みにならなかった。終了していれば直接の子だけ回収する。
        ops.reap()
        return "unconfirmed", sends
    except Exception:
        reap_until(ops, limits.get("deadline"), limits.get("last"), confirm)
        return "unconfirmed", sends


def reap_until(ops, deadline, last, confirm):
    """例外のあとも、決めた期限まで直接の子の回収を試みる。新しい期間は足さない。

    確認の期限を決める前に例外が起きたときは、今から確認の期間を取る。ただし TERM から数えた上限を超えない。
    """
    try:
        if deadline is None:
            deadline = ops.now() + confirm
            if last is not None:
                deadline = min(deadline, last)
        while True:
            try:
                if ops.reap():
                    return
            except Exception:
                pass
            remaining = deadline - ops.now()
            if remaining <= 0:
                return
            ops.sleep(min(remaining, POLL_SECONDS))
    except Exception:
        # 時計も使えないときは、1 回だけ試す。
        try:
            ops.reap()
        except Exception:
            pass


def run(home, seconds, grace, confirm, make_operations=Operations):
    environment = dict(os.environ, CODEX_HOME=home)
    with tempfile.TemporaryFile() as errors:
        try:
            # 標準入力を閉じ、新しいセッションで起動する。グループの番号は直接の子の PID と同じになる。
            child = subprocess.Popen(COMMAND, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=errors, env=environment, start_new_session=True)
        except OSError:
            return "launch", ""
        try:
            code = child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            result, _ = stop_group(make_operations(child), child.pid, grace, confirm)
            return (result, str(child.pid)) if result == "unconfirmed" else (result, "")
        errors.seek(0)
        text = errors.read().decode("utf-8", errors="replace")
    # Codex の出力は、人の設定の秘密値を含みうるので、状態と終了コードだけを返す。
    if code == 0:
        return "ok", ""
    if code == 2 and "unexpected argument '--strict-config'" in text:
        return "old", ""
    return "failed", str(code)


def main(argv):
    home, seconds, grace = argv[1], float(argv[2]), float(argv[3])
    confirm = float(argv[4]) if len(argv) > 4 else 5.0
    status, detail = run(home, seconds, grace, confirm)
    print(status)
    print(detail)


if __name__ == "__main__":
    main(sys.argv)
