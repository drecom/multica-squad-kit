"""終端通知を持つ補助の契約を、FIFO で順序を決めて確認する。"""
import importlib.util
import contextlib
import io
import itertools
import os
from pathlib import Path
import signal
import select
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
helper = root / 'tests/tty-session.py'
counter = itertools.count()
os.environ["TERM"] = "xterm-256color"


def launch(code, *, fds='in,out,err', answer=None, script=None, extra=(), command=None):
    case = scratch / str(next(counter))
    case.mkdir()
    (case / 'command.py').write_text(code)
    args = [sys.executable, str(helper), '--fds', fds,
            '--output', str(case / 'out'), '--error', str(case / 'err')]
    if answer is not None:
        (case / 'input').write_bytes(answer)
        args += ['--input', str(case / 'input')]
    if script is not None:
        (case / 'script').write_bytes(script)
        args += ['--script', str(case / 'script')]
    args += list(extra) + ['--', *(command or [sys.executable, str(case / 'command.py')])]
    return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE), case


def finish(proc, case, expected=0):
    out, err = proc.communicate()
    assert proc.returncode == expected, (case.name, proc.returncode, out, err)
    return (case / 'out').read_bytes(), (case / 'err').read_bytes(), err


def fifo(name):
    path = scratch / f'{name}-{next(counter)}'
    os.mkfifo(path)
    return path


def no_process(*pids):
    for pid in pids:
        state = subprocess.run(['ps', '-p', str(pid), '-o', 'pid='], capture_output=True).stdout
        assert not state.strip(), ('残ったプロセス', pid, state)


for fds in ('', 'out', 'err', 'out,err', 'in', 'in,out', 'in,err', 'in,out,err'):
    for amount in (0, 16, 131072):
        proc, case = launch(f'import sys,os\nassert [os.isatty(fd) for fd in range(3)] == {[key in fds.split(chr(44)) for key in ("in","out","err")]}\nassert len({{os.ttyname(fd) for fd in range(3) if os.isatty(fd)}})<=1\nassert sys.stdin.readline()=="y\\n"\nsys.stdout.buffer.write(b"A"*{amount}); sys.stdout.flush()\nsys.stderr.buffer.write(b"B"*{amount}); sys.stderr.flush()\n', fds=fds, answer=b'y\n')
        out, err, _ = finish(proc, case)
        echo = b'y\r\n' if 'in' in fds.split(',') else b''
        if 'out' in fds and 'err' in fds:
            assert out == echo + b'A' * amount + b'B' * amount and err == b''
        elif 'out' in fds:
            assert out == echo + b'A' * amount and err == b'B' * amount
        elif 'err' in fds:
            assert out == b'A' * amount and err == echo + b'B' * amount
        else:
            assert out == b'A' * amount and err == b'B' * amount
print('PASS tty-session T01/T19: 全 FD の組み合わせ、ファイル入力、3 種の出力量が一致する', flush=True)

gate, notice = fifo('hold'), fifo('notice')
proc, case = launch(f'import os\nos.write(1,b"before")\nf=os.open({str(notice)!r},os.O_WRONLY)\nos.write(f,b"done")\nos._exit(0)\n', extra=('--hold-read', str(gate)))
writer = os.open(gate, os.O_WRONLY)
with notice.open('rb') as stream:
    assert stream.read() == b'done'
os.close(writer)
assert finish(proc, case)[0] == b'before'
print('PASS tty-session T02: 読み始める前に終了しても全量を受ける', flush=True)

for ending in (b'', b'after'):
    proc, case = launch(f'import os,sys\nos.write(1,b"ready? ")\nassert input()=="y"\nos.write(1,{ending!r})\n', script=b'expect ready? \nsend y\n')
    assert finish(proc, case)[0] == b'ready? y\r\n' + ending
proc, case = launch('import os\nos.write(1,b"x"*4094+b"question? ")\nassert input()=="y"\nos.write(1,b"once")', script=b'expect question? \nsend y\n')
assert finish(proc, case)[0] == b'x' * 4094 + b'question? y\r\nonce'
print('PASS tty-session T03/T04/T20: 完全な問いと読み取りの境界、答え直後の出力とエコー', flush=True)

proc, case = launch('import os\nos.write(1,b"partial")\nraise SystemExit(7)', script=b'expect absent\nsend y\n')
out, _, diag = finish(proc, case, 125)
assert out == b'partial' and b'absent' in diag
for code, expected in [('raise SystemExit(7)', 7), ('import os,signal\nos.kill(os.getpid(),signal.SIGTERM)', 143)]:
    proc, case = launch(code)
    finish(proc, case, expected)
print('PASS tty-session T05/T06/T07: 来ない問い、非ゼロとシグナルの終了コード', flush=True)

notice, gate = fifo('closed'), fifo('release')
proc, case = launch(f'import os\nos.write(1,b"closed")\nos.close(1);os.close(2)\nf=os.open({str(notice)!r},os.O_WRONLY);os.write(f,b"x")\ng=os.open({str(gate)!r},os.O_RDONLY);assert os.read(g,1)==b"x"\nos._exit(7)')
with notice.open('rb') as stream:
    assert stream.read(1) == b'x'
with gate.open('wb', buffering=0) as stream:
    stream.write(b'x')
assert finish(proc, case, 7)[0] == b'closed'
print('PASS tty-session T08: 出力が閉じてもコマンドの終了コードを待つ', flush=True)

notice, gate = fifo('parent-exit'), fifo('descendant')
pid_file = scratch / 'descendant-pid'
proc, case = launch(f'''import os
p=os.fork()
if p:
 f=os.open({str(notice)!r},os.O_WRONLY);os.write(f,b"done");os._exit(0)
open({str(pid_file)!r},'w').write(str(os.getpid()))
f=os.open({str(gate)!r},os.O_RDONLY);os.read(f,1)
os.write(1,b'late');os._exit(0)
''')
with notice.open('rb') as stream:
    assert stream.read() == b'done'
with gate.open('wb', buffering=0) as stream:
    stream.write(b'x')
assert finish(proc, case)[0] == b'late'
no_process(int(pid_file.read_text()))
print('PASS tty-session T09: コマンド後の子孫の出力を受け、残らない', flush=True)

notice = fifo('remaining')
gate = fifo('unreleased')
pid_file = scratch / 'remaining-pid'
proc, case = launch(f'''import os
p=os.fork()
if p: os._exit(0)
open({str(pid_file)!r},'w').write(str(os.getpid()))
f=os.open({str(notice)!r},os.O_WRONLY);os.write(f,b'x')
os.close(9)
os.open({str(gate)!r},os.O_RDONLY)
''')
with notice.open('rb') as stream:
    assert stream.read(1) == b'x'
finish(proc, case)
no_process(int(pid_file.read_text()))
watch = fifo('stopped')
proc, case = launch('import os,signal\nos.kill(os.getpid(),signal.SIGSTOP)', extra=('--watch', str(watch)))
with watch.open('rb') as stream:
    wrapper, child = map(int, stream.readline().split())
    assert stream.read() == b''
assert b'command stopped' in finish(proc, case, 125)[2]
no_process(wrapper, child)
print('PASS tty-session T10/T11: 保持を閉じて残る子孫と停止したコマンドを回収する', flush=True)

for target, expected in (('wrapper', 125), ('parent', -9), ('term', 143)):
    watch, notice, gate = fifo('watch'), fifo('running'), fifo('blocked')
    proc, case = launch(f'import os,signal\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nf=os.open({str(notice)!r},os.O_WRONLY);os.write(f,b"x")\nos.open({str(gate)!r},os.O_RDONLY)', extra=('--watch', str(watch)))
    with watch.open('rb') as stream:
        wrapper, child = map(int, stream.readline().split())
        with notice.open('rb') as entered:
            assert entered.read(1) == b'x'
        os.kill(wrapper if target == 'wrapper' else proc.pid, signal.SIGTERM if target == 'term' else signal.SIGKILL)
        assert stream.read() == b''
    finish(proc, case, expected)
    no_process(wrapper, child)
print('PASS tty-session T12/T13/T14: 包み・親の終了と補助への TERM で子を残さない', flush=True)

spec = importlib.util.spec_from_file_location('tty_session', helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# 終了したプロセスだけがグループに残る順序を、回収せずに作る。
# macOS の EPERM と Linux の成功は、どちらも生存プロセスがない同じ状態。
zombie = os.fork()
if zombie == 0:
    os.setpgid(0, 0)
    os._exit(0)
try:
    os.waitid(os.P_PID, zombie, os.WEXITED | os.WNOWAIT)
    module.kill_group(zombie)
finally:
    os.waitpid(zombie, 0)
no_process(zombie)
print('PASS tty-session T19: 終了したプロセスだけのグループを処理し、回収する', flush=True)
original_read, original_write = os.read, os.write
owner = os.getpid()


def inline(code, *, scripted=None, answer=None, fds=('in', 'out', 'err'), command=None):
    global last_diagnostic, last_pid_path
    case = scratch / str(next(counter))
    case.mkdir()
    pid_path = last_pid_path = case / 'pid'
    (case / 'command.py').write_text(f'import os\nopen({str(pid_path)!r},"w").write(str(os.getpid()))\n' + code)
    command = command or [sys.executable, str(case / 'command.py')]
    script = None
    if scripted:
        script = case / 'script'
        script.write_bytes(scripted)
    input_path = None
    if answer is not None:
        input_path = case / 'input'
        input_path.write_bytes(answer)
    # 時間切れの記録の登録（run() の始めの register_stack）が開くファイルを、比べる fd に数えない。
    # 登録は同じプロセスで 1 回だけ開くので、比べる前に済ませておく。
    getattr(module, 'register_stack', lambda: None)()
    before = set(os.listdir('/dev/fd'))
    diagnostic = io.StringIO()
    with contextlib.redirect_stderr(diagnostic):
        result = module.run(command, output=str(case / 'out'), error=str(case / 'err'), script=script, input_file=input_path, fds=fds)
    last_diagnostic = diagnostic.getvalue()
    assert set(os.listdir('/dev/fd')) == before
    if pid_path.exists():
        no_process(int(pid_path.read_text()))
    return result, (case / 'out').read_bytes()


watch = fifo('exec-failed')
before = set(os.listdir('/dev/fd'))
proc, case = launch('', command=[str(scratch / 'missing-command')], extra=('--watch', str(watch)))
with watch.open('rb') as stream:
    wrapper, child = map(int, stream.readline().split())
    assert stream.read() == b''
finish(proc, case, 127)
no_process(wrapper, child)
assert set(os.listdir('/dev/fd')) == before
proc, case = launch('import os,select\nassert os.environ["TERM"]=="xterm-256color"\nassert os.get_terminal_size(1)==(100,40)\nassert os.tcgetpgrp(0)==os.getpgrp()\nassert not select.select([0],[],[],0)[0]\nos.write(1,b"ready? ")\nassert input()=="y"', script=b'expect ready? \nsend y\n')
assert finish(proc, case)[0] == b'ready? y\r\n'
print('PASS tty-session T15/T16/T22: 起動失敗と fd 回収、前面グループと入力の開始順序', flush=True)

proc, case = launch('''import os,tty
tty.setraw(0)
os.write(1,b'raw-ready')
data=b'A'*131072
while data: data=data[os.write(1,data):]
answer=b''
while not answer.endswith(b'\\r'): answer+=os.read(0,65536)
assert answer==b'x'*131072+b'\\r'
''', script=b'expect raw-ready\nsend ' + b'x' * 131072 + b'\n')
assert finish(proc, case)[0] == b'raw-ready' + b'A' * 131072
print('PASS tty-session T17: 大きな送受信を同時に進める', flush=True)

reads = 0
def broken_read(fd, count):
    global reads
    if os.getpid() == owner and fd > 2 and os.isatty(fd):
        reads += 1
        if reads > 1:
            raise OSError('injected read failure')
        return original_read(fd, 1)
    return original_read(fd, count)
os.read = broken_read
try:
    result, data = inline('import os\nos.write(1,b"first")\nos.read(0,1)')
    assert result == 125 and data == b'f'
    assert 'OSError: injected read failure' in last_diagnostic
finally:
    os.read = original_read
for partial in (False, True):
    def changed_write(fd, data):
        if os.getpid() == owner and fd > 2 and os.isatty(fd):
            if not partial:
                raise OSError('injected write failure')
            return original_write(fd, data[:1])
        return original_write(fd, data)
    os.write = changed_write
    try:
        result, data = inline('import os\nos.write(1,b"ready? ")\nassert input()=="yes"', scripted=b'expect ready? \nsend yes\n')
        assert result == (0 if partial else 125)
        if not partial:
            assert 'OSError: injected write failure' in last_diagnostic
    finally:
        os.write = original_write
assert inline('pass')[0] == 0
assert inline('assert input()=="y"', answer=b'y\n', fds=('out', 'err'))[0] == 0
# 終了の通知を先に読み、非停止の waitpid ではまだ状態を読めない順序を作る。
original_waitpid = os.waitpid
def deferred_status(pid, flags):
    if os.getpid() != owner and flags & os.WNOHANG:
        return 0, 0
    return original_waitpid(pid, flags)
os.waitpid = deferred_status
try:
    assert inline('pass')[0] == 0
finally:
    os.waitpid = original_waitpid
# 包みが通知の読み手を閉じる瞬間に SIGCHLD が届く順序も作る。
original_close = os.close
wrapper_states = []
def closing_signal(fd):
    caller = sys._getframe(1).f_back
    shutdown = (os.getpid() != owner and caller is not None
                and caller.f_code.co_name == 'wrapper'
                and caller.f_locals.get('child_reaped')
                and caller.f_locals.get('changed_r') == fd)
    original_close(fd)
    if shutdown:
        os.kill(os.getpid(), signal.SIGCHLD)
def collected_status(pid, flags):
    result = original_waitpid(pid, flags)
    if os.getpid() == owner and flags == 0 and sys._getframe(1).f_code.co_name == 'reap':
        wrapper_states.append(result[1])
    return result
os.close = closing_signal
os.waitpid = collected_status
try:
    assert inline('pass')[0] == 0
    assert wrapper_states and all(os.WIFEXITED(s) and os.WEXITSTATUS(s) == 0 for s in wrapper_states)
finally:
    os.close = original_close
    os.waitpid = original_waitpid
print('PASS tty-session T18/T23: 入出力例外と書きかけ、成功後も fd が増えない', flush=True)

# C を作る setpgid を、子と包みの両方が呼ぶと、macOS では同時の 2 回が競合して
# どちらかが EPERM になる。呼び出し元と順序を記録し、呼び出しを包みの 1 回に固定する。
original_setpgid, original_tcsetpgrp = os.setpgid, os.tcsetpgrp
calls = scratch / 'group-calls'
def record(*fields):
    descriptor = os.open(calls, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        original_write(descriptor, (' '.join(map(str, fields)) + '\n').encode())
    finally:
        os.close(descriptor)
def recorded_setpgid(pid, group):
    record('setpgid', os.getpid(), pid, group)
    return original_setpgid(pid, group)
def recorded_tcsetpgrp(fd, group):
    record('tcsetpgrp', os.getpid(), group)
    return original_tcsetpgrp(fd, group)
os.setpgid, os.tcsetpgrp = recorded_setpgid, recorded_tcsetpgrp
try:
    assert inline('pass')[0] == 0
finally:
    os.setpgid, os.tcsetpgrp = original_setpgid, original_tcsetpgrp
command = int(last_pid_path.read_text())
events = [line.split() for line in calls.read_text().splitlines()]
made = [(i, e) for i, e in enumerate(events) if e[0] == 'setpgid' and int(e[2]) in (0, command)]
assert len(made) == 1, ('C を作る setpgid は 1 回だけ', events)
index, (_, caller, target, group) = made[0]
assert int(caller) not in (command, os.getpid()) and (int(target), int(group)) == (command, command), events
foreground = [i for i, e in enumerate(events) if e[0] == 'tcsetpgrp']
assert [events[i][2] for i in foreground] == [str(command)] and foreground[0] > index, events
print('PASS tty-session T26: C を作る setpgid は包みの 1 回だけで、前面にする前に済む', flush=True)

# 子の終了の SIGCHLD が、Python のハンドラが自己パイプへ書く前に届き、通知が読まれない順序を、FIFO で作る。
# コマンドは fd 9（保持）を閉じてから、ケースが作った FIFO の 1 行を読んで終わる。子は FIFO に書かれるまで終わらない。
# 包みの select のうち、見張る fd が 2 本（制御と通知）だけで、子がまだ回収されていない最初の呼び出しを差し替える。
# exec と保持のパイプは、それより前の呼び出しで終わりを読んで外れている。差し替えた呼び出しでは、SIGCHLD の
# Python のハンドラを、自己パイプへ書かず専用のパイプへ書くものに替え、FIFO に書いて子を終わらせ、子がゾンビになるのを
# waitid で待つ。専用のパイプの 1 バイトを読めば、SIGCHLD が届いてハンドラが動いたことを、時計なしで確認できる。
# 元のハンドラに戻してから、本物の select を同じ fd・期限 0 で呼び、見張った fd の数と読めた fd を記録する。
# 読めなければ、本物の select なら全 fd が待ちのまま止まる場所なので、空を返す。
# 続けて、次の waitpid が WNOHANG を付けたかと、子を返したかを記録する。
original_select = select.select
gate = fifo('T27-child')
record_file = scratch / 'T27-record'
intercepted, waited = [], []


def gated_select(readers, writers, errors, *timeout):
    caller = sys._getframe(1)
    if (os.getpid() == owner or caller.f_code.co_name != 'wrapper' or intercepted or len(readers) != 2
            or not caller.f_locals.get('child') or caller.f_locals.get('child_reaped')):
        return original_select(readers, writers, errors, *timeout)
    intercepted.append(True)
    notified, control = caller.f_locals['changed_r'], caller.f_locals['control_r']
    assert sorted(readers) == sorted((notified, control)), ('T27: 見張る fd が制御と通知でない', readers)
    while original_select([notified], [], [], 0)[0]:
        os.read(notified, 4096)
    arrived_r, arrived_w = os.pipe()
    previous = signal.signal(signal.SIGCHLD, lambda *_: original_write(arrived_w, b'x'))
    try:
        with gate.open('wb', buffering=0) as stream:
            stream.write(b'go\n')
        os.waitid(os.P_PID, caller.f_locals['child'], os.WEXITED | os.WNOWAIT)
        assert os.read(arrived_r, 1) == b'x'
    finally:
        signal.signal(signal.SIGCHLD, previous)
        os.close(arrived_r)
        os.close(arrived_w)
    ready = original_select(readers, writers, errors, 0)
    names = [name for fd, name in ((notified, 'notified'), (control, 'control')) if fd in ready[0]]
    with record_file.open('a') as stream:
        stream.write(f'select watched={len(readers)} readable={",".join(names) or "none"}\n')
    return ready if names else ([], [], [])


def recorded_waitpid(pid, flags):
    result = original_waitpid(pid, flags)
    if (os.getpid() != owner and intercepted and not waited
            and sys._getframe(1).f_code.co_name == 'wrapper'):
        waited.append(True)
        with record_file.open('a') as stream:
            stream.write(f'waitpid nohang={"yes" if flags & os.WNOHANG else "no"} reaped={"yes" if result[0] else "no"}\n')
    return result


select.select, os.waitpid = gated_select, recorded_waitpid
try:
    result = inline('', command=['sh', '-c', 'exec 9>&-; read _ < "$1"', 'sh', str(gate)])[0]
finally:
    select.select, os.waitpid = original_select, original_waitpid
recorded = record_file.read_text() if record_file.exists() else ''
assert recorded == 'select watched=2 readable=notified\nwaitpid nohang=no reaped=yes\n' and result == 0, \
    ('T27: 子の終了の通知が自己パイプで読めない', result, recorded)
print('PASS tty-session T27: 見張る fd が 2 本の select の前に子が終わっても、通知が読めて、待って回収し 0 を返す', flush=True)

proc, case = launch('''import os,fcntl,termios,struct,signal
changed=False
def winch(*_):
 global changed
 changed=True
signal.signal(signal.SIGWINCH,winch)
os.write(1,b'ready? ')
assert input()=='y'
assert changed
assert struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\\0'*8))[:2]==(18,72)
os.write(1,b'changed')
''', script=b'expect ready? \nresize 18 72\nsend y\n')
assert finish(proc, case)[0] == b'ready? y\r\nchanged'
watch = scratch / 'not-started'
watch.write_bytes(b'')
proc, case = launch('raise Exception("must not start")', script=b'unknown value\n', extra=('--watch', str(watch)))
proc.communicate()
assert proc.returncode == 125 and watch.read_bytes() == b''
# 本物の nonce は 16 進の文字だけなので、この 32 バイトとは必ず異なる。
proc, case = launch('import os\nos.write(1,b"\\x1e"+b"x"*32+b":0\\x1f")')
assert finish(proc, case)[0] == b'\x1e' + b'x' * 32 + b':0\x1f'
print('PASS tty-session T21/T24/T25: WINCH、未知の台本を起動前に拒否、異なる nonce は出力', flush=True)
