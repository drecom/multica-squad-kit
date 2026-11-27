#!/usr/bin/env python3
"""Codex の役に渡すフックの信頼の値を、app-server の hooks/list から読む。

使い方: codex-hooks.py <CODEX_HOME> <ガードの置き場> <上限の秒> [<人の config.toml>]

役と同じ -c の引数で app-server を起こし、キットの 2 つのフック（PreToolUse と Stop）の
鍵と currentHash を読む。値はフックの定義（コマンドのパスと matcher）から決まる。
標準出力は、1 行目が状態、2 行目が詳細、3 行目から [hooks.state."<鍵>"] の TOML である。
  ok        2 つのフックの値を読めた。詳細は、人の config.toml を渡したときだけ trusted か untrusted
  launch    Codex を起動できなかった
  failed    hooks/list を読めなかった（詳細に理由の分類。Codex の出力は写さない）
  missing   一覧にキットのフックがない（詳細に足りないフック）
設計は docs/agent-guards.md の「フックの信頼」が決める。
"""
import json
import os
import select
import signal
import subprocess
import sys
import time

MATCHER = "^(Bash|shell|exec_command|local_shell)$"
# 役の引数は lib/project.sh の project_desired_args が作る。この 2 つは同じ値でなければならない。
EVENTS = (("preToolUse", "pre-tool-use"), ("stop", "stop"))


def hook_args(guard):
    pre = 'hooks.PreToolUse=[{matcher="%s",hooks=[{type="command",command=%s}]}]' % (MATCHER, json.dumps(guard + "/pre-tool-use"))
    stop = 'hooks.Stop=[{hooks=[{type="command",command=%s}]}]' % json.dumps(guard + "/stop")
    return ["codex", "app-server", "--listen", "stdio://", "-c", pre, "-c", stop]


class Failed(Exception):
    pass


def read_response(child, wanted, deadline, buffer):
    # 期限付きで読み、行は渡された buffer（bytearray）に組み立てる。選ぶ待ちと行の組み立てが同じ
    # バッファを使うので、通知と応答が 1 回の書き込みで届いても、残りの行を取りこぼさない。
    # 通知や別の ID の行は読み飛ばす。
    fd = child.stdout.fileno()
    while True:
        newline = buffer.find(b"\n")
        if newline < 0:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failed("timeout")
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise Failed("timeout")
            chunk = os.read(fd, 65536)
            if not chunk:
                raise Failed("closed")
            buffer.extend(chunk)
            continue
        line = bytes(buffer[:newline])
        del buffer[:newline + 1]
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict) and message.get("id") == wanted:
            if "error" in message:
                raise Failed("error")
            return message.get("result")


def list_hooks(home, guard, seconds):
    try:
        child = subprocess.Popen(hook_args(guard), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, env=dict(os.environ, CODEX_HOME=home),
                                 start_new_session=True)
    except OSError:
        return "launch", None
    deadline = time.monotonic() + seconds
    buffer = bytearray()
    try:
        def send(message):
            child.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            child.stdin.flush()

        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "multica-squad-kit", "version": "0"}}})
        read_response(child, 1, deadline, buffer)
        send({"method": "initialized"})
        send({"id": 2, "method": "hooks/list", "params": {"cwds": [os.getcwd()]}})
        return "ok", read_response(child, 2, deadline, buffer)
    except (Failed, OSError, ValueError):
        return "failed", None
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            child.stdin.close()
        except OSError:
            pass
        child.stdout.close()
        child.wait()


def find_kit_hooks(result, guard):
    """一覧から、キットの 2 つのフックの (鍵, currentHash) を探す。見つからないイベント名を返す。"""
    entries = []
    if isinstance(result, dict):
        for item in result.get("data") or []:
            if isinstance(item, dict):
                entries.extend(item.get("hooks") or [])
    found = {}
    for event, script in EVENTS:
        wanted = guard + "/" + script
        for entry in entries:
            if not isinstance(entry, dict) or entry.get("eventName") != event or entry.get("command") != wanted:
                continue
            key, current = entry.get("key"), entry.get("currentHash")
            if isinstance(key, str) and key and isinstance(current, str) and current:
                found[event] = (key, current)
                break
    return found, [event for event, _ in EVENTS if event not in found]


def render(found):
    lines = []
    for event, _ in EVENTS:
        key, current = found[event]
        lines += ["[hooks.state.%s]" % json.dumps(key), "trusted_hash = %s" % json.dumps(current)]
    return "\n".join(lines)


def trusted(config_path, found):
    try:
        import tomllib
        with open(config_path, "rb") as source:
            config = tomllib.load(source)
    except (ImportError, OSError, ValueError):
        return False
    hooks = config.get("hooks")
    state = hooks.get("state") if isinstance(hooks, dict) else None
    if not isinstance(state, dict):
        return False
    for key, current in found.values():
        entry = state.get(key)
        if not isinstance(entry, dict) or entry.get("trusted_hash") != current:
            return False
    return True


def main(argv):
    home, guard, seconds = argv[1], argv[2], float(argv[3])
    config = argv[4] if len(argv) > 4 else ""
    status, result = list_hooks(home, guard, seconds)
    if status != "ok":
        print(status)
        print("")
        return
    found, missing = find_kit_hooks(result, guard)
    if missing:
        print("missing")
        print(",".join(missing))
        return
    print("ok")
    print(("trusted" if trusted(config, found) else "untrusted") if config else "")
    print(render(found))


if __name__ == "__main__":
    main(sys.argv)
