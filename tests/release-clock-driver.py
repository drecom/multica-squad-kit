"""FIFO の出来事を全順序で受け、公開処理へ決めた時刻を返す。"""
from contextlib import ExitStack
import os
from pathlib import Path
import select
import signal
import subprocess
import sys

case = Path(sys.argv[1])
times = [int(value) for value in sys.argv[2].split(',') if value]
command = sys.argv[4:]
assert sys.argv[3] == '--'
names = {key: case / key for key in ('clock-events', 'clock-ticks', 'watch-start', 'watch-release')}
for path in names.values():
    os.mkfifo(path)
with ExitStack() as stack:
    opened = {key: os.open(path, os.O_RDWR) for key, path in names.items()}
    for fd in opened.values():
        stack.callback(os.close, fd)
    environment = {**os.environ,
                   'CLOCK_STUB_EVENTS': str(names['clock-events']),
                   'CLOCK_STUB_TICKS': str(names['clock-ticks']),
                   'GH_WATCH_STARTED': str(names['watch-start']),
                   'GH_WATCH_RELEASE': str(names['watch-release'])}
    wrapped = ['/bin/bash', '-c', 'status=0; "$@" || status=$?; printf "end %s\\n" "$status" >"$CLOCK_STUB_EVENTS"; exit "$status"', '_', *command]
    proc = subprocess.Popen(wrapped, env=environment)
    buffers = {opened['clock-events']: b'', opened['watch-start']: b''}
    now = 0
    ticks = 0
    released = False
    views = []
    events = []
    ended = False
    while not ended:
        ready, _, _ = select.select(list(buffers), [], [])
        for fd in ready:
            buffers[fd] += os.read(fd, 4096)
            while b'\n' in buffers[fd]:
                raw, buffers[fd] = buffers[fd].split(b'\n', 1)
                line = raw.decode()
                if fd == opened['watch-start']:
                    _, watch, release = line.split()
                    (case / 'gh/watch-process').write_text(f'{watch} {release}\n')
                    if os.environ.get('RELEASE_CLOCK_INTERRUPT'):
                        os.kill(int(release), signal.SIGTERM)
                        os.write(opened['clock-ticks'], b'0\n')
                    continue
                events.append(line)
                if line == 'view':
                    views.append(str(now))
                elif line.startswith('sleep '):
                    if ticks < len(times):
                        now = times[ticks]
                        ticks += 1
                    elif not released and not os.environ.get('RELEASE_CLOCK_INTERRUPT'):
                        os.write(opened['watch-release'], b'x\n')
                        released = True
                    os.write(opened['clock-ticks'], f'{now}\n'.encode())
                    if ticks == len(times) and len(times) > 1 and times[-1] == times[-2] and not released:
                        os.write(opened['watch-release'], b'x\n')
                        released = True
                elif line.startswith('end '):
                    ended = True
                else:
                    raise ValueError('知らない時計の出来事')
    status = proc.wait()
    (case / 'view-times').write_text(' '.join(views))
    (case / 'clock-events.log').write_text('\n'.join(events) + '\n')
    (case / 'find-waits').write_text(str(events.count('sleep 1')) + '\n')
sys.exit(status)
