"""Hash host file types, permissions, contents, and symlink targets."""
import hashlib
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
blocked = Path(sys.argv[2]) if sys.argv[2] else None
blocked_mode = blocked.lstat().st_mode if blocked else None
if blocked:
    blocked.chmod(stat.S_IMODE(blocked_mode) | stat.S_IRWXU)
try:
    rows = []
    for directory, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(directory) / name
            mode = blocked_mode if path == blocked else path.lstat().st_mode
            detail = ''
            if stat.S_ISLNK(mode):
                detail = os.readlink(path)
            elif stat.S_ISREG(mode):
                detail = hashlib.sha256(path.read_bytes()).hexdigest()
            rows.append((str(path.relative_to(root)), mode, detail))
    print(hashlib.sha256(repr(sorted(rows)).encode()).hexdigest())
finally:
    if blocked:
        blocked.chmod(stat.S_IMODE(blocked_mode))
