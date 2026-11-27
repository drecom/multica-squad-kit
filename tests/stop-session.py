# セッションに属するプロセスへシグナルを送る。tests/run-one.sh と tests/run.sh が、テストを止めるために呼ぶ。
#
# 使い方: python3 -I tests/stop-session.py <セッションの ID> TERM|KILL|ALIVE|LIST
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
# pkill -s は macOS にないので、全プロセスの一覧から os.getsid() でセッションを引く。
# テストが別のプロセスグループに移した子も、同じセッションに残るので止められる。
import os
import signal
import subprocess
import sys

session = int(sys.argv[1])
mode = sys.argv[2]
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
