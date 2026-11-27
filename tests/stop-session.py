# セッションに属するプロセスへシグナルを送る。tests/run-one.sh と tests/run.sh が、テストを止めるために呼ぶ。
#
# 使い方: python3 -I tests/stop-session.py <セッションの ID> TERM|KILL|ALIVE|LIST
#         python3 -I tests/stop-session.py <セッションの ID> STACKS <スタックのディレクトリ>
# TERM と KILL は、セッションの全プロセスにそのシグナルを送る。ALIVE は何も送らない。
# どれも、セッションにプロセスが 1 つでもあれば 0、なければ 1 で終わる。
# 終わってまだ回収されていないプロセス（ゾンビ）は、残っているものに数えない。
#
# LIST は、時間切れの記録のため、セッションのプロセスを 1 行ずつ標準出力に出す。何も送らない。
# 列は、PID・親の PID・プロセスグループ・状態・経過時間・コマンドで、空白で区切る（コマンドは残り全部）。
# ゾンビも、セッションを引けたものは出す。macOS では、ゾンビの os.getsid() が ESRCH で失敗するので、
# セッションを引けなかったプロセスは、ゾンビも含めて出さない。所属を親やグループから推すと、
# セッションの外のプロセスを含めてしまうため。出したプロセスがなければ 1 で終わる。
#
# STACKS は、時間切れの記録のため、スタックを登録したプロセスにだけ SIGUSR2 を送る。
# 送り先の候補は、スタックのディレクトリにある、名前が正の整数のファイル（tests/tty-session.py が、登録を終えてから
# 自分の PID の名前に改名して公開する）。ファイルの先頭の登録の印（PID・親の PID・プロセスグループ・セッション）の
# PID がファイルの名前と同じで、セッションが引数のセッションと同じであり、さらに OS が答える親の PID・プロセスグループ・
# セッションが印と同じときだけ、同じプロセスの中で続けて送る。合わない PID には送らず、理由を 1 行で出して、残りの確認を続ける。
# 出力は 1 行ずつ「送った <PID>」か「送らなかった <PID> 印が合わない|プロセスが合わない」で、ほかの名前のファイルは何も出さずに読み飛ばす。
# 1 つでも送れたら 0、なければ 1 で終わる。
#
# pkill -s は macOS にないので、全プロセスの一覧から os.getsid() でセッションを引く。
# テストが別のプロセスグループに移した子も、同じセッションに残るので止められる。
import os
import signal
import stat
import subprocess
import sys

session = int(sys.argv[1])
mode = sys.argv[2]


def read_mark(path):
    """登録の印を 4 つの整数で返す。読めない・形が違うときは None。FIFO などで止まらないよう、非ブロックで開く。"""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            return None
        line = os.read(descriptor, 256).split(b'\n', 1)[0].split()
        if len(line) != 4 or not all(field.isdigit() for field in line):
            return None
        return tuple(int(field) for field in line)
    except OSError:
        return None
    finally:
        os.close(descriptor)


def parent_of(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'ppid='], capture_output=True, text=True)
    fields = result.stdout.split()
    return int(fields[0]) if result.returncode == 0 and len(fields) == 1 and fields[0].isdigit() else None


def send_stacks(directory):
    sent = False
    for name in sorted((n for n in os.listdir(directory) if n.isascii() and n.isdigit() and int(n) > 0), key=int):
        pid = int(name)
        mark = read_mark(os.path.join(directory, name))
        if mark is None or mark[0] != pid or mark[3] != session:
            print(f'送らなかった {pid} 印が合わない', flush=True)
            continue
        try:
            actual = (pid, parent_of(pid), os.getpgid(pid), os.getsid(pid))
            if actual != mark:
                raise ProcessLookupError
            os.kill(pid, signal.SIGUSR2)
        except OSError:
            print(f'送らなかった {pid} プロセスが合わない', flush=True)
            continue
        sent = True
        print(f'送った {pid}', flush=True)
    return sent


if mode == 'STACKS':
    sys.exit(0 if send_stacks(sys.argv[3]) else 1)
listed = mode == 'LIST'
sig = None if mode in ('ALIVE', 'LIST') else getattr(signal, 'SIG' + mode)
found = False
columns = 'pid=,ppid=,pgid=,stat=,etime=,command=' if listed else 'pid=,stat='
listing = subprocess.run(['ps', '-A', '-o', columns], capture_output=True, text=True).stdout
for line in listing.splitlines():
    fields = line.split(maxsplit=5)
    stat_at = 3 if listed else 1
    if len(fields) <= stat_at or (fields[stat_at].startswith('Z') and not listed):
        continue
    pid = int(fields[0])
    try:
        if os.getsid(pid) != session:
            continue
        found = True
        if listed:
            print(' '.join(fields), flush=True)
        if sig is not None:
            os.kill(pid, sig)
    except OSError:
        pass
sys.exit(0 if found else 1)
