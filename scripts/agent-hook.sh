#!/bin/bash
# agent-island 桥：ZCode hooks 事件 → ~/.cache/agent-island/events.jsonl（单行追加）
# 设计约束（勿破坏）：单次执行 <50ms（hook 是同步的，拖慢会拖慢 agent）；
# 不记录 prompt 正文/工具参数/文件路径——只留事件类型、会话 id、工具名、项目目录名
DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-island"
mkdir -p "$DIR"
/usr/bin/python3 -c '
import json, sys, os, time, fcntl
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
event = {
    "ts": time.time(),
    "event": payload.get("hook_event_name") or "",
    "session_id": payload.get("session_id") or "",
    "tool": payload.get("tool_name") or "",
    "project": os.path.basename(payload.get("cwd") or "") or "",
}
line = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
with open(sys.argv[1], "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(line)
    fcntl.flock(f, fcntl.LOCK_UN)
' "$DIR/events.jsonl"
exit 0
