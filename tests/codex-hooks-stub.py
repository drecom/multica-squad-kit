import hashlib
import json
import os
import re
import sys
import time

base, args = sys.argv[1], sys.argv[2:]
try:
    with open(base + "/codex-hooks") as source:
        mode = source.read().strip()
except OSError:
    mode = "ok"
with open(base + "/codex-hooks-calls", "a") as record:
    record.write(json.dumps({"home": os.environ.get("CODEX_HOME"), "args": args}) + "\n")
if mode == "exit":
    sys.exit(1)
joined = " ".join(args)
commands = [json.loads(value) for value in re.findall(r'command=("(?:[^"\\]|\\.)*")', joined)]
matcher = re.search(r'matcher="([^"]*)"', joined).group(1)


def entry(event, snake, command, matcher_value, source):
    digest = hashlib.sha256(("%s|%s|%s" % (event, command, matcher_value)).encode()).hexdigest()
    place = "/<session-flags>" if source == "sessionFlags" else "/human"
    return {"key": "%s/config.toml:%s:0:0" % (place, snake), "eventName": event, "command": command,
            "matcher": matcher_value, "source": source, "currentHash": "sha256:" + digest, "trustStatus": "untrusted"}


hooks = [entry("preToolUse", "pre_tool_use", commands[0], matcher, "sessionFlags"),
         entry("stop", "stop", commands[1], None, "sessionFlags")]
# 人の設定のフックは、キットのフックと取り違えない。
foreign = entry("preToolUse", "pre_tool_use", "/human/other-hook", "^Bash$", "user")
if mode == "empty":
    hooks = []
elif mode == "pre-only":
    hooks = hooks[:1]
elif mode == "stop-only":
    hooks = hooks[1:]
elif mode == "other-command":
    hooks = [entry("preToolUse", "pre_tool_use", "/elsewhere/pre-tool-use", matcher, "sessionFlags"), hooks[1]]
for line in sys.stdin:
    message = json.loads(line)
    ident = message.get("id")
    if message.get("method") == "initialize":
        reply = json.dumps({"id": ident, "result": {"userAgent": "stub"}})
        if mode == "batched":
            # 通知と応答を、1 回の書き込みで届ける
            sys.stdout.write(json.dumps({"method": "notification"}) + "\n" + reply + "\n")
            sys.stdout.flush()
        else:
            print(reply, flush=True)
    elif message.get("method") == "hooks/list":
        if mode == "hang":
            time.sleep(300)
        if mode == "unreadable":
            print(json.dumps({"id": ident, "error": {"code": -32601, "message": "SYNTHETIC_SECRET_VALUE"}}), flush=True)
        elif mode == "garbled":
            print("not json SYNTHETIC_SECRET_VALUE", flush=True)
            sys.exit(0)
        elif mode == "batched":
            reply = json.dumps({"id": ident, "result": {"data": [{"cwd": os.getcwd(), "hooks": hooks + [foreign], "warnings": [], "errors": []}]}})
            sys.stdout.write(json.dumps({"method": "notification"}) + "\n" + reply + "\n")
            sys.stdout.flush()
        else:
            print(json.dumps({"id": ident, "result": {"data": [{"cwd": os.getcwd(), "hooks": hooks + [foreign], "warnings": [], "errors": []}]}}), flush=True)
