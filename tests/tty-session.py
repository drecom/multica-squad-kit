"""単一端末でコマンドを動かし、包みの終端マークを受領して回収する。"""
import argparse
import errno
import faulthandler
import fcntl
import os
from pathlib import Path
import re
import select
import signal
import struct
import sys
import termios

HOLD_FD = 9
CSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')
stack_file = None
stack_pid = None


def register_stack():
    """時間切れの記録のため、SIGUSR2 を受けたら、自分の PID の名前のファイルへスタックを書くよう登録する。

    SQUAD_KIT_TEST_STACK_DIR（tests/run-one.sh が渡す）があるときだけ動く。
    先に `registering-<PID>` の名前で、先頭に印（PID・親・グループ・セッション）を書き、登録を終えてから
    `<PID>` へ改名して公開する。送る側は PID の名前のファイルだけを見るので、登録の途中のプロセスへは送らない。
    fork の子は親の登録とファイルを引き継ぐので、子は自分の PID で登録し直す。
    記録のための補助なので、登録に失敗しても動作は変えない。
    """
    global stack_file, stack_pid
    directory = os.environ.get('SQUAD_KIT_TEST_STACK_DIR')
    if not directory or stack_pid == os.getpid():
        return
    pid = os.getpid()
    temporary = os.path.join(directory, f'registering-{pid}')
    opened = None
    registered = False
    try:
        opened = open(temporary, 'wb')
        opened.write(f'{pid} {os.getppid()} {os.getpgrp()} {os.getsid(0)}\n'.encode())
        opened.flush()
        faulthandler.register(signal.SIGUSR2, file=opened, all_threads=True)
        registered = True
        os.rename(temporary, os.path.join(directory, str(pid)))
    except (OSError, ValueError, RuntimeError):
        if registered:
            faulthandler.unregister(signal.SIGUSR2)
        if opened:
            opened.close()
        try:
            os.unlink(temporary)
        except OSError:
            pass
        return
    previous, stack_file, stack_pid = stack_file, opened, pid
    if previous:
        previous.close()


def unregister_stack():
    """正常に終わる前に、自分の登録を取り下げ、自分の PID の名前のファイルを消す。

    先にファイルを消し、そのあと登録を外してファイルを閉じる。送る側が消える前にファイルを見つけても、
    送られた先はまだ登録を持っている。fork の子（登録を引き継いだだけで、自分では登録していない）は、
    親のファイルを消さないよう、登録した PID が自分のときだけ動く。`os._exit` は atexit を呼ばないので、
    終わる直前に明示して呼ぶ。KILL などで正常に終わらなかったプロセスのファイルは残る。
    """
    global stack_file, stack_pid
    if stack_pid is None or stack_pid != os.getpid():
        return
    directory = os.environ.get('SQUAD_KIT_TEST_STACK_DIR')
    if directory:
        try:
            os.unlink(os.path.join(directory, str(stack_pid)))
        except OSError:
            pass
    faulthandler.unregister(signal.SIGUSR2)
    opened, stack_file, stack_pid = stack_file, None, None
    if opened:
        opened.close()


def write_all(fd, value):
    while value:
        value = value[os.write(fd, value):]


def close(fd):
    if fd is not None:
        try:
            os.close(fd)
        except OSError as error:
            if error.errno != errno.EBADF:
                raise


def kill_group(group):
    if group is not None:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS は、同じ UID のゾンビだけのグループへの KILL を EPERM にする。
            # C はテスト命令のグループなので、ここには止める生存プロセスがない。
            if sys.platform != 'darwin':
                raise


def reap(pid):
    while True:
        try:
            return os.waitpid(pid, 0)[1]
        except InterruptedError:
            continue


def script_lines(path):
    result = []
    if path:
        for number, line in enumerate(Path(path).read_bytes().splitlines(), 1):
            kind, sep, value = line.partition(b' ')
            if kind not in (b'expect', b'send', b'resize') or not sep:
                raise ValueError(f'台本 {number}: 知らない行')
            if kind == b'expect' and not value:
                raise ValueError(f'台本 {number}: 問いが空')
            if kind == b'resize':
                fields = value.split()
                if len(fields) != 2 or not all(p.isdigit() and int(p) > 0 for p in fields):
                    raise ValueError(f'台本 {number}: 大きさが不正')
                value = tuple(int(p) for p in fields)
            result.append((kind, value))
    return result


def wrapper(master, slave, status_r, status_w, control_r, control_w, targets, command, nonce, watch):
    child = None
    descriptors = {master, slave, status_r, status_w, control_r, control_w, *targets}
    watch_fd = None
    grouped = False
    termination_sent = False
    child_reaped = False
    try:
        close(master)
        close(status_r)
        close(control_w)
        # 閉じた番号は、次に開くファイル（スタックの登録）が使う。終わりの片付けで閉じ直さない。
        descriptors.difference_update((master, status_r, control_w))
        os.setsid()
        register_stack()  # 別のセッションへ移ったあとに公開する。移る前は、親と同じセッションの印で診断が包みへも届く
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for sig in (signal.SIGHUP, signal.SIGTTOU, signal.SIGTTIN, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        began_r, began_w = os.pipe()
        held_r, held_w = os.pipe()
        exec_r, exec_w = os.pipe()
        changed_r, changed_w = os.pipe()
        descriptors.update((began_r, began_w, held_r, held_w, exec_r, exec_w, changed_r, changed_w))
        os.set_blocking(changed_w, False)

        def changed(_signum, _frame):
            try:
                os.write(changed_w, b'c')
            except BlockingIOError:
                pass

        signal.signal(signal.SIGCHLD, changed)
        # SIGCHLD が届くと、インタプリタの C のハンドラが自己パイプへ書く。
        # Python のハンドラが動く前に届いた SIGCHLD でも、select が返る。
        signal.set_wakeup_fd(changed_w, warn_on_full_buffer=False)
        child = os.fork()
        if child == 0:
            try:
                # C を作る setpgid は包みだけが呼ぶ。子も呼ぶと、macOS では
                # 同時の 2 回が競合し、どちらかが EPERM になる。
                close(status_w)
                close(control_r)
                close(began_w)
                close(held_r)
                close(exec_r)
                close(changed_r)
                close(changed_w)
                if os.read(began_r, 1) != b'x':
                    os._exit(125)
                close(began_r)
                for target, source in enumerate(targets):
                    os.dup2(source, target)
                os.dup2(held_w, HOLD_FD, inheritable=True)
                for name in os.listdir('/dev/fd'):
                    fd = int(name)
                    if fd > 2 and fd not in (HOLD_FD, exec_w):
                        close(fd)
                for sig in (signal.SIGHUP, signal.SIGTTIN, signal.SIGTTOU, signal.SIGCHLD,
                            signal.SIGTERM, signal.SIGINT, signal.SIGPIPE):
                    signal.signal(sig, signal.SIG_DFL)
                os.execvp(command[0], command)
            except BaseException as failure:
                write_all(exec_w, b'failed')
                os._exit(127)
        close(began_r)
        descriptors.discard(began_r)
        close(held_w)
        descriptors.discard(held_w)
        close(exec_w)
        descriptors.discard(exec_w)
        # 子は開始のパイプで止まっているので、exec 済みの EACCES にはならない。
        os.setpgid(child, child)
        grouped = True
        os.tcsetpgrp(slave, child)
        write_all(status_w, f'pid {child}\n'.encode())
        if watch:
            watch_fd = os.open(watch, os.O_WRONLY)
            write_all(watch_fd, f'{os.getpid()} {child}\n'.encode())
        write_all(began_w, b'x')
        close(began_w)
        descriptors.discard(began_w)
        child_status = None
        held = True
        failed_exec = False
        child_changed = False
        observed = {control_r, changed_r, held_r, exec_r}
        while child_status is None or held:
            if child_status is None:
                # 終了の通知を読んだあとは、その状態の回収を待つ。
                # 通知と waitpid で読める状態の間を、空の select で取り落とさない。
                flags = os.WUNTRACED | (0 if child_changed else os.WNOHANG)
                pid, state = os.waitpid(child, flags)
                child_changed = False
                if pid:
                    if os.WIFSTOPPED(state):
                        termination_sent = True
                        kill_group(child)
                        reap(child)
                        child_reaped = True
                        child_status = 125
                        write_all(2, b'tty-session: command stopped\n')
                    else:
                        code = os.waitstatus_to_exitcode(state)
                        child_reaped = True
                        child_status = code if code >= 0 else 128 - code
            if child_status is not None and not held:
                break
            ready, _, _ = select.select(list(observed), [], [])
            for fd in ready:
                data = os.read(fd, 4096)
                if fd == control_r:
                    if not data:
                        termination_sent = True
                        kill_group(child)
                        if child_status is None:
                            reap(child)
                            child_reaped = True
                        return
                elif fd == held_r and not data:
                    held = False
                    observed.remove(fd)
                elif fd == exec_r:
                    failed_exec = failed_exec or bool(data)
                    if not data:
                        observed.remove(fd)
                elif fd == changed_r:
                    child_changed = True
        if not termination_sent:
            termination_sent = True
            kill_group(child)
        if failed_exec:
            child_status = 127
        write_all(slave, b'\x1e' + nonce + b':' + str(child_status).encode() + b'\x1f')
        os.read(control_r, 1)
    finally:
        signal.set_wakeup_fd(-1)
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        try:
            if not termination_sent:
                if grouped:
                    kill_group(child)
                elif child:
                    # C を作る前に失敗したときは、子が開始のパイプで止まっている。
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        finally:
            if child and not child_reaped:
                reap(child)
            for fd in descriptors:
                close(fd)
            close(watch_fd)


class InterruptedSession(Exception):
    pass


def run(command, *, fds=('in', 'out', 'err'), output, error, input_file=None,
        script=None, marks=None, size=(40, 100), hold_read=None, watch=None):
    actions = script_lines(script)
    if not command or not set(fds).issubset({'in', 'out', 'err'}):
        raise ValueError('端末の指定かコマンドが不正')
    if input_file and script:
        raise ValueError('先に打つ入力と台本は併用できない')
    master = slave = status_r = status_w = control_r = control_w = None
    wrapper_pid = child = None
    handles = []
    captured = bytearray()
    offsets = []
    result = 125
    received = False
    old_term = signal.getsignal(signal.SIGTERM)

    def interrupted(_signum, _frame):
        raise InterruptedSession()

    try:
        register_stack()
        signal.signal(signal.SIGTERM, interrupted)
        for path in (output, error):
            handles.append(open(path, 'w+b'))
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', *size, 0, 0))
        targets = []
        for i, name in enumerate(('in', 'out', 'err')):
            if name in fds:
                targets.append(slave)
            elif i == 0:
                handles.append(open(input_file or os.devnull, 'rb'))
                targets.append(handles[-1].fileno())
            else:
                targets.append(handles[i - 1].fileno())
        status_r, status_w = os.pipe()
        control_r, control_w = os.pipe()
        nonce = os.urandom(16).hex().encode()
        wrapper_pid = os.fork()
        if wrapper_pid == 0:
            try:
                wrapper(master, slave, status_r, status_w, control_r, control_w,
                        targets, command, nonce, watch)
                unregister_stack()
                os._exit(0)
            except BaseException as failure:
                print(f'tty-session: wrapper: {type(failure).__name__}: {failure}', file=sys.stderr)
                unregister_stack()
                os._exit(125)
        close(slave)
        slave = None
        close(status_w)
        status_w = None
        close(control_r)
        control_r = None
        os.set_blocking(master, False)
        status_data = bytearray()
        pending = bytearray()
        position = 0
        cursor = 0
        began = False
        prefix = b'\x1e' + nonce + b':'
        if hold_read:
            with open(hold_read, 'rb') as gate:
                while gate.read(4096):
                    pass
        while True:
            plain = CSI.sub(b'', captured)
            while began and position < len(actions):
                kind, value = actions[position]
                if kind == b'expect':
                    found = plain.find(value, cursor)
                    if found < 0:
                        break
                    cursor = found + len(value)
                elif kind == b'send':
                    offsets.append(len(captured))
                    pending.extend(value + b'\r')
                else:
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', *value, 0, 0))
                position += 1
            ready, writable, _ = select.select([master, status_r], [master] if pending else [], [])
            if status_r in ready:
                data = os.read(status_r, 4096)
                if not data:
                    raise RuntimeError('マークの前に包みが終了した')
                status_data.extend(data)
                while b'\n' in status_data:
                    line, _, rest = status_data.partition(b'\n')
                    status_data = bytearray(rest)
                    match = re.fullmatch(rb'pid ([1-9][0-9]*)', line)
                    if not match:
                        raise RuntimeError('包みの状態が不正')
                    child = int(match[1])
                    began = True
                    if input_file and 'in' in fds:
                        answer = Path(input_file).read_bytes().replace(b'\n', b'\r')
                        pending.extend(answer if answer else b'\x04')
            if master in ready:
                data = os.read(master, 4096)
                if not data:
                    raise RuntimeError('マークの前に端末が閉じた')
                captured.extend(data)
                start = captured.find(prefix)
                if start >= 0:
                    end = captured.find(b'\x1f', start)
                    if end >= 0:
                        received = True
                        result = int(captured[start + len(prefix):end])
                        del captured[start:]
                        if position != len(actions):
                            missing = actions[position][1]
                            print(f'tty-session: 来なかった問い: {missing!r}', file=sys.stderr)
                            result = 125
                        write_all(control_w, b'a')
                        break
            if master in writable and pending:
                sent = os.write(master, pending)
                del pending[:sent]
    except InterruptedSession:
        result = 143
    except Exception as failure:
        print(f'tty-session: {type(failure).__name__}: {failure}', file=sys.stderr)
        result = 125
    finally:
        if not received:
            try:
                kill_group(child)
            except OSError as failure:
                print(f'tty-session: {type(failure).__name__}: {failure}', file=sys.stderr)
        close(control_w)
        if wrapper_pid:
            reap(wrapper_pid)
        close(master)
        close(slave)
        close(status_r)
        close(status_w)
        close(control_r)
        if 'out' in fds and handles:
            handles[0].write(captured)
        elif 'err' in fds and len(handles) > 1:
            handles[1].write(captured)
        if marks:
            Path(marks).write_text(''.join(f'{offset}\n' for offset in offsets))
        for handle in handles:
            handle.close()
        signal.signal(signal.SIGTERM, old_term)
        unregister_stack()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fds', default='in,out,err')
    parser.add_argument('--output', required=True)
    parser.add_argument('--error', required=True)
    parser.add_argument('--input', dest='input_file')
    parser.add_argument('--script')
    parser.add_argument('--marks')
    parser.add_argument('--size', nargs=2, type=int, default=(40, 100), metavar=('ROWS', 'COLS'))
    parser.add_argument('--hold-read')
    parser.add_argument('--watch')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = vars(parser.parse_args())
    args['fds'] = tuple(filter(None, args['fds'].split(',')))
    if args['command'][:1] == ['--']:
        args['command'] = args['command'][1:]
    try:
        return run(**args)
    except Exception as failure:
        print(f'tty-session: {failure}', file=sys.stderr)
        return 125


if __name__ == '__main__':
    sys.exit(main())
