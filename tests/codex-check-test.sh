#!/usr/bin/env bash
# lib/codex-check.py の停止の手順を、差し替えた操作（送る・状態の読み取り・回収・時計）で流す。
# 手順と表は、docs/agent-settings.md の「時間切れの扱い」が決める。実プロセスの行は tests/host-timeout-test.sh が流す。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$root/lib/codex-check.py" <<'PY'
import errno
import importlib.util
import os
import signal
import sys

# 原本の lib/ に、バイトコードのキャッシュを残さない。
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("codex_check", sys.argv[1])
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

GRACE = 5.0
CONFIRM = 5.0
PGID = 4242
TERM, KILL = signal.SIGTERM, signal.SIGKILL
EPERM = OSError(errno.EPERM, "denied")
ESRCH = OSError(errno.ESRCH, "no such process")
EIO = OSError(errno.EIO, "other")


class Fake(check.Operations):
    """仮想の時計で動く。events に (時刻, 操作, 値) を残し、状態・送信・回収の結果は表から決める。"""

    def __init__(self, sends=None, state=None, reap=None, raises=None, raise_at=None):
        self.t = 0.0
        # raise_at: 操作の名前 -> (時刻, 例外, 回数)。仮想の時刻がその時刻以後になった呼び出しで、回数だけ例外にする。
        self.raise_at = dict(raise_at or {})
        self.events = []
        self.sends = sends or {}
        # state(時刻, 何回目) -> 状態。回収済みのあとに読んだ回数は数えない。
        self.state_of = state or (lambda t, n: check.RUNNING)
        self.reap_of = reap or (lambda t, n: True)
        self.raises = raises or {}
        self.reads = 0
        self.reaps = 0

    def log(self, name, value=None):
        self.events.append((self.t, name, value))

    def maybe_raise(self, name):
        if name in self.raises:
            raise self.raises[name]
        if name in self.raise_at:
            when, error, count = self.raise_at[name]
            if self.t >= when and count > 0:
                self.raise_at[name] = (when, error, count - 1)
                raise error

    def send(self, pgid, number):
        assert pgid == PGID
        name = "TERM" if number == TERM else "KILL"
        self.log("send", name)
        self.maybe_raise("send-" + name)
        error = self.sends.get(name)
        if error is not None:
            raise error

    def state(self, pgid, timeout):
        assert pgid == PGID and timeout > 0
        self.reads += 1
        self.log("state")
        self.maybe_raise("state")
        self.t += 0.01
        return self.state_of(self.t, self.reads)

    def reap(self):
        self.reaps += 1
        self.log("reap")
        self.maybe_raise("reap")
        return self.reap_of(self.t, self.reaps)

    def now(self):
        self.maybe_raise("now")
        return self.t

    def sleep(self, seconds):
        assert seconds >= 0
        self.t += seconds


def times(fake, kind, value=None):
    return [t for t, name, v in fake.events if name == kind and (value is None or v == value)]


def invariants(fake, result):
    """どの流れでも守る性質: TERM が先、KILL は TERM から猶予のあと、猶予の間は読まず回収せず、回収のあとに送らない。"""
    terms, kills = times(fake, "send", "TERM"), times(fake, "send", "KILL")
    names = [name for _, name, _ in fake.events]
    if "send" not in names:
        return
    assert terms and names[0] == "send" and fake.events[0][2] == "TERM", fake.events
    # どの流れでも、終了処理は TERM から猶予と確認の期間を足した時間を超えない（読み取りと待ちの刻みの分だけ許す）。
    assert fake.t - terms[0] <= GRACE + CONFIRM + 0.1, ("終了処理が期限を超えた", fake.t - terms[0], fake.events)
    if kills:
        assert kills[0] - terms[0] >= GRACE, ("KILL が TERM から猶予より早い", fake.events)
        between = [e for e in fake.events if terms[0] <= e[0] < kills[0] and e[1] in ("state", "reap")]
        assert not between, ("猶予の間に状態を読むか回収した", between)
    successful_reap = [i for i, e in enumerate(fake.events) if e[1] == "reap" and result[0] == "timeout"]
    if successful_reap:
        # 回収に成功した最後の呼び出しのあとに、送らない。
        last = successful_reap[-1]
        assert all(e[1] != "send" for e in fake.events[last:]), fake.events
    # 回収の前に、状態を読んで停止済みになっていた（例外の流れを除く）。
    if result[0] == "timeout":
        first_reap = next(i for i, e in enumerate(fake.events) if e[1] == "reap")
        assert any(e[1] == "state" for e in fake.events[:first_reap]), fake.events


def run(fake, expected):
    result = check.stop_group(fake, PGID, GRACE, CONFIRM)
    invariants(fake, result)
    assert result[0] == expected, (result, fake.events)
    return result


stopped = lambda t, n: check.STOPPED

# --- 表の「終わり方」の行 ---------------------------------------------------
# 上限の直後に直接の子が終わる（ゾンビのまま残る）。グループは停止済みでも、TERM・猶予・KILL を省かない。
fake = Fake(state=stopped)
result = run(fake, "timeout")
assert [s[0] for s in result[1]] == ["TERM", "KILL"]
assert GRACE <= times(fake, "send", "KILL")[0] - times(fake, "send", "TERM")[0] < GRACE + 0.1
assert times(fake, "reap"), "停止済みになったら直接の子を回収する"

# TERM を送る直前にグループが止まる。TERM の結果が ESRCH と EPERM のどちらでも、流れは変わらない。
for error, name in ((ESRCH, "ESRCH"), (EPERM, "EPERM")):
    fake = Fake(sends={"TERM": error}, state=stopped)
    result = run(fake, "timeout")
    assert result[1][0] == ("TERM", name), result
    assert times(fake, "send", "KILL"), "TERM の結果にかかわらず KILL まで進む"

# 猶予の間に、親が先に終わる（状態がすぐ停止済みになる）。猶予を短くせず、猶予の間は状態を読まない。
fake = Fake(state=stopped)
run(fake, "timeout")
assert not [e for e in fake.events if e[1] == "state" and e[0] < GRACE], fake.events
assert times(fake, "send", "KILL")[0] >= GRACE

# KILL を送る直前にグループが止まる。KILL の結果が ESRCH と EPERM のどちらでも、手順 4 で停止済みになる。
for error, name in ((ESRCH, "ESRCH"), (EPERM, "EPERM")):
    fake = Fake(sends={"KILL": error}, state=stopped)
    result = run(fake, "timeout")
    assert result[1][1] == ("KILL", name), result

# 状態を読む間に、プロセスが終わる。実行中や判定不能の読み取りのあと、期限までの読み直しで停止済みになる。
for first in (check.RUNNING, check.UNDETERMINABLE):
    fake = Fake(state=lambda t, n, first=first: check.STOPPED if n >= 3 else first)
    run(fake, "timeout")
    assert fake.reads == 3 and fake.reaps == 1
print("PASS codex-check: 終わり方の 5 行（上限の直後・TERM の直前・猶予の間・KILL の直前・状態を読む間）が表の結果になり、猶予は短くならない")

# --- 送った結果の表 ------------------------------------------------------------
# 記録する名前: 成功は ok、ESRCH と EPERM はそのまま、ほかの失敗は error。
outcomes = {"ok": None, "ESRCH": ESRCH, "EPERM": EPERM, "error": EIO}
for term_name, term_error in outcomes.items():
    for kill_name, kill_error in outcomes.items():
        sends = {"TERM": term_error, "KILL": kill_error}
        # 送った結果は記録するだけで、停止済みとは読まない。状態が実行中なら期限まで読み直し、確認できない。
        fake = Fake(sends=sends, state=lambda t, n: check.RUNNING, reap=lambda t, n: False)
        result = run(fake, "unconfirmed")
        assert [s[1] for s in result[1]] == [term_name, kill_name] and result[1][0][0] == "TERM"
        assert times(fake, "state")[-1] >= times(fake, "send", "KILL")[0] + CONFIRM - 0.2, "期限まで読み直す"
        assert times(fake, "state")[-1] <= times(fake, "send", "KILL")[0] + CONFIRM + 0.1, "期限を過ぎて待たない"
        # 状態が停止済みなら、どの送った結果でも停止済みとして扱う。
        fake = Fake(sends=sends, state=stopped)
        result = run(fake, "timeout")
        assert [s[1] for s in result[1]] == [term_name, kill_name]
print("PASS codex-check: 送った結果（成功・ESRCH・EPERM・ほかの失敗）の 16 通りで、EPERM と成功を停止済みと読まず、期限で確認できないと返す")

# --- 手順 4 の結果の表 -----------------------------------------------------------
# 期限まで実行中が残る。直接の子が終了していれば回収し、確認できないと返す。
fake = Fake(state=lambda t, n: check.RUNNING, reap=lambda t, n: True)
run(fake, "unconfirmed")
assert fake.reaps >= 1 and fake.events[-1][1] == "reap", "期限のあとに、終了していれば回収する"
# 期限まで判定不能（ps が失敗する）が続く。同じ扱い。
fake = Fake(state=lambda t, n: check.UNDETERMINABLE, reap=lambda t, n: True)
run(fake, "unconfirmed")
assert fake.reaps >= 1 and fake.events[-1][1] == "reap"
# 停止済みでも、直接の子を回収できなければ、期限まで読み直して確認できないと返す。
fake = Fake(state=stopped, reap=lambda t, n: False)
run(fake, "unconfirmed")
assert fake.reaps > 1
# 回収を一度失敗してから成功すれば、停止済みとして返す。
fake = Fake(state=stopped, reap=lambda t, n: n >= 2)
run(fake, "timeout")
assert fake.reaps == 2
print("PASS codex-check: 手順 4 の結果（停止済み・実行中のまま・判定不能のまま）が、回収と返す結果を表のとおりにする")

# --- 途中の例外 ------------------------------------------------------------------
for where in ("state", "send-KILL"):
    fake = Fake(state=stopped, raises={where: RuntimeError("boom")}, reap=lambda t, n: n >= 3)
    result = check.stop_group(fake, PGID, GRACE, CONFIRM)
    assert result[0] == "unconfirmed", (where, result)
    assert fake.reaps >= 3, ("例外のあとも直接の子の回収を試みる", where, fake.events)
    names = [e[1] for e in fake.events]
    last_reap = max(i for i, n in enumerate(names) if n == "reap")
    assert "send" not in names[last_reap:], "回収のあとに送らない"
# 回収そのものが例外になっても、期限まで試して確認できないと返す。
fake = Fake(state=stopped, raises={"reap": RuntimeError("boom")})
result = check.stop_group(fake, PGID, GRACE, CONFIRM)
assert result[0] == "unconfirmed" and fake.reaps >= 2
# 時計が使えなくても、1 回は回収を試して確認できないと返す。
fake = Fake(raises={"now": RuntimeError("boom")})
result = check.stop_group(fake, PGID, GRACE, CONFIRM)
assert result[0] == "unconfirmed" and fake.reaps >= 1
print("PASS codex-check: 途中で例外が起きても、直接の子の回収を試み、回収のあとにグループへ送らず、確認できないと返す")

# --- 期限を数え直さない -----------------------------------------------------
# 確認の期限の近くで例外が起きても、回収の再試行は決めた期限までの残りだけを使う。
# 回収は期限まで成功しない。状態の読み取り・回収・時計が、時刻の以後に例外になる全部の組を流す。
for where in ("state", "reap", "now"):
    for when in (5.0, 7.5, 9.9, 9.93, 9.99):
        for count in (1, 1000):
            fake = Fake(sends={"TERM": EPERM, "KILL": EPERM}, state=lambda t, n: check.RUNNING,
                        reap=lambda t, n: False, raise_at={where: (when, RuntimeError("boom"), count)})
            result = run(fake, "unconfirmed")
            assert result[1][0] == ("TERM", "EPERM"), result
            assert fake.reaps >= 1, ("例外のあとも、期限までに直接の子の回収を試みる", where, when, fake.events)
            end = fake.t - times(fake, "send", "TERM")[0]
            assert end <= GRACE + CONFIRM + 0.1, ("期限を数え直した", where, when, count, end)
# 状態の読み取りと回収が、同じ時刻以後にどちらも例外になる（14.93 秒に延びた組）。
for when in (5.0, 9.9, 9.93):
    boom = (when, RuntimeError("boom"), 1000)
    fake = Fake(sends={"TERM": EPERM, "KILL": EPERM}, state=lambda t, n: check.RUNNING,
                reap=lambda t, n: False, raise_at={"state": boom, "reap": boom})
    run(fake, "unconfirmed")
# 停止済みで、回収は 9.9 秒まで成功しない。9.9 秒の回収が例外になり、その後始末で回収できても、
# 例外のあとなので確認できないと返す。例外が実際に起きたことも確認する。
fake = Fake(state=stopped, reap=lambda t, n: t >= 9.9, raise_at={"reap": (9.9, RuntimeError("boom"), 1)})
result = run(fake, "unconfirmed")
assert fake.raise_at["reap"][2] == 0, "期限の直前の回収で、例外が実際に起きた"
assert fake.reaps >= 2 and fake.t >= 9.9, (fake.reaps, fake.t)
# KILL の直後に時計が 1 回だけ読めないときも、TERM から数えた上限までで終わる。
fake = Fake(sends={"TERM": EPERM, "KILL": EPERM}, state=lambda t, n: check.RUNNING, reap=lambda t, n: False)
real_now = fake.now
state = {"calls": 0}
def now_failing_after_kill():
    if any(name == "send" and value == "KILL" for _, name, value in fake.events) and state["calls"] == 0:
        state["calls"] += 1
        raise RuntimeError("clock")
    return real_now()
fake.now = now_failing_after_kill
result = run(fake, "unconfirmed")
assert state["calls"] == 1 and fake.reaps >= 1
print("PASS codex-check: 期限の近くで状態の読み取り・回収・時計が例外になっても、期限を数え直さず、TERM から猶予と確認の期間までで終わる")

# --- ps の出力の読み方 -----------------------------------------------------------
header = "  PID  PGID STAT COMMAND\n"
classify = check.classify
assert classify(0, header + "  100   100 S    codex app-server\n  101   100 Z    (child)\n  7 7 S other\n", 100) == check.RUNNING
assert classify(0, header + "  100   100 Z    (codex)\n  101   100 Z+   (child)\n  7 7 S other\n", 100) == check.STOPPED
assert classify(0, header + "  7 7 S other\n", 100) == check.STOPPED, "グループにプロセスがなければ停止済み"
assert classify(0, header + "  100   100 R+   codex app-server --listen stdio://\n", 100) == check.RUNNING
assert classify(0, header + "  100   99 S    parent in other group\n  101   100 Zs   zombie\n", 100) == check.STOPPED
assert classify(0, header + "  100   100 S    command with  spaces   and Z start\n", 100) == check.RUNNING
# ps が失敗する、または出力を読めないときは判定不能にし、空の出力を停止済みと読まない。
for text in ("", "garbage\n", header + "abc 100 S x\n", header + "  100\n", "PID PGID COMMAND\n  1 1 x\n"):
    assert classify(0, text, 100) == check.UNDETERMINABLE, text
assert classify(1, header + "  100   100 Z x\n", 100) == check.UNDETERMINABLE
print("PASS codex-check: ps の出力から、実行中・停止済み（ゾンビだけ・空）・判定不能（失敗・読めない出力）を分ける")

# --- 実際の操作の入口 --------------------------------------------------------------
saved = os.environ.get("PATH", "")
try:
    os.environ["PATH"] = "/nonexistent"
    assert check.Operations(None).state(PGID, 1.0) == check.UNDETERMINABLE, "ps を起動できなければ判定不能"
finally:
    os.environ["PATH"] = saved
# Codex を起動できないときは、設定の誤り（failed）と分けて launch を返す。
try:
    os.environ["PATH"] = "/nonexistent"
    assert check.run("/nonexistent", 1.0, 0.1, 0.1) == ("launch", ""), "起動できなければ launch"
finally:
    os.environ["PATH"] = saved
assert check.send_name(None) == "ok" and check.send_name(ESRCH) == "ESRCH"
assert check.send_name(EPERM) == "EPERM" and check.send_name(EIO) == "error"
print("PASS codex-check: ps を起動できなければ判定不能にし、送った結果の名前を決める")
PY
