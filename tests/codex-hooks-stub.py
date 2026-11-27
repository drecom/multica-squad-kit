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
# mode は、"+" で区切って組み合わせられる（例: same-user+pre-disabled）。
modes = set(mode.split("+"))
with open(base + "/codex-hooks-calls", "a") as record:
    record.write(json.dumps({"home": os.environ.get("CODEX_HOME"), "args": args}) + "\n")
if "exit" in modes:
    sys.exit(1)
joined = " ".join(args)
commands = [json.loads(value) for value in re.findall(r'command=("(?:[^"\\]|\\.)*")', joined)]
matcher = re.search(r'matcher="([^"]*)"', joined).group(1)


def entry(event, snake, command, matcher_value, source):
    digest = hashlib.sha256(("%s|%s|%s" % (event, command, matcher_value)).encode()).hexdigest()
    place = "/<session-flags>" if source == "sessionFlags" else "/human"
    return {"key": "%s/config.toml:%s:0:0" % (place, snake), "eventName": event, "command": command,
            "matcher": matcher_value, "source": source, "currentHash": "sha256:" + digest, "trustStatus": "untrusted", "enabled": True}


hooks = [entry("preToolUse", "pre_tool_use", commands[0], matcher, "sessionFlags"),
         entry("stop", "stop", commands[1], None, "sessionFlags")]
# 人の設定のフックは、キットのフックと取り違えない。
foreign = entry("preToolUse", "pre_tool_use", "/human/other-hook", "^Bash$", "user")
if "empty" in modes:
    hooks = []
elif "pre-only" in modes:
    hooks = hooks[:1]
elif "stop-only" in modes:
    hooks = hooks[1:]
elif "other-command" in modes:
    hooks = [entry("preToolUse", "pre_tool_use", "/elsewhere/pre-tool-use", matcher, "sessionFlags"), hooks[1]]
if "pre-disabled" in modes:
    hooks[0]["enabled"] = False
elif "stop-disabled" in modes:
    hooks[1]["enabled"] = False
elif "no-enabled" in modes:
    del hooks[1]["enabled"]
for name, value in (("enabled-null", None), ("enabled-string", "true"), ("enabled-number", 1)):
    if name in modes:
        hooks[0]["enabled"] = value
if "wrong-matcher" in modes:
    hooks[0]["matcher"] = "^Bash$"
if "stop-matcher" in modes:
    hooks[1]["matcher"] = matcher
if "dup-session" in modes:
    hooks.append(dict(hooks[0], key="/<session-flags>/config.toml:pre_tool_use:1:0"))
# 同じコマンドを、別の source（人の設定・管理の設定）も持つ。先頭に置き、有効にも無効にもできる。
for source in ("user", "managed"):
    if "same-" + source in modes or "same-" + source + "-disabled" in modes:
        extra = [entry("preToolUse", "pre_tool_use", commands[0], matcher, source), entry("stop", "stop", commands[1], None, source)]
        for item in extra:
            item["enabled"] = "same-" + source + "-disabled" not in modes
        hooks = extra + hooks
    if "only-" + source in modes:
        hooks = [entry("preToolUse", "pre_tool_use", commands[0], matcher, source), entry("stop", "stop", commands[1], None, source)]
for line in sys.stdin:
    message = json.loads(line)
    ident = message.get("id")
    if message.get("method") == "initialize":
        reply = json.dumps({"id": ident, "result": {"userAgent": "stub"}})
        if "batched" in modes:
            # 通知と応答を、1 回の書き込みで届ける
            sys.stdout.write(json.dumps({"method": "notification"}) + "\n" + reply + "\n")
            sys.stdout.flush()
        else:
            print(reply, flush=True)
    elif message.get("method") == "hooks/list":
        if "hang" in modes:
            time.sleep(300)
        if "unreadable" in modes:
            print(json.dumps({"id": ident, "error": {"code": -32601, "message": "SYNTHETIC_SECRET_VALUE"}}), flush=True)
        elif "garbled" in modes:
            print("not json SYNTHETIC_SECRET_VALUE", flush=True)
            sys.exit(0)
        elif "batched" in modes:
            reply = json.dumps({"id": ident, "result": {"data": [{"cwd": os.getcwd(), "hooks": hooks + [foreign], "warnings": [], "errors": []}]}})
            sys.stdout.write(json.dumps({"method": "notification"}) + "\n" + reply + "\n")
            sys.stdout.flush()
        else:
            print(json.dumps({"id": ident, "result": {"data": [{"cwd": os.getcwd(), "hooks": hooks + [foreign], "warnings": [], "errors": []}]}}), flush=True)
