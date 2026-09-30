#!/bin/bash
# 安装/卸载 agent-island 的 ZCode hooks 桥：把 scripts/agent-hook.sh 复制到
# ~/.cache/agent-island/（路径稳定，不受 app 更新/源码目录变动影响），并在
# ~/.zcode/cli/config.json 注册七个事件（JSON 合并，保留既有 hooks/配置）。
# 用法：install-agent-hook.sh [install|uninstall|status]
set -euo pipefail
MODE="${1:-install}"
CONFIG="$HOME/.zcode/cli/config.json"
BRIDGE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-island"
HOOK_CMD="bash \"$BRIDGE_DIR/agent-hook.sh\""

if [[ "$MODE" == "install" ]]; then
  SRC="$(cd "$(dirname "$0")" && pwd)/agent-hook.sh"
  [[ -f "$SRC" ]] || { echo "找不到同目录的 agent-hook.sh"; exit 1; }
  mkdir -p "$BRIDGE_DIR" "$HOME/.zcode/cli"
  cp "$SRC" "$BRIDGE_DIR/agent-hook.sh"
  chmod +x "$BRIDGE_DIR/agent-hook.sh"
  # 写配置前备份一份
  [[ -f "$CONFIG" ]] && cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"
fi

/usr/bin/python3 - "$CONFIG" "$MODE" "$HOOK_CMD" <<'PYEOF'
import json, sys, os
config_path, mode, hook_cmd = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(config_path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except Exception as e:
    sys.exit(f"读取 {config_path} 失败: {e}（请手动检查后重试）")

events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
          "PostToolUse", "PostToolUseFailure", "Stop"]

def has_bridge(entries):
    return any(h.get("command") == hook_cmd
               for e in entries for h in e.get("hooks", []))

if mode == "status":
    installed = has_bridge(cfg.get("hooks", {}).get("events", {}).get("SessionStart", []))
    print("installed" if installed else "not-installed")
    sys.exit(0)

if mode == "install":
    hooks = cfg.setdefault("hooks", {})
    hooks["enabled"] = True   # 配置文件 hooks 默认禁用，必须显式打开
    ev = hooks.setdefault("events", {})
    added = 0
    for name in events:
        entries = ev.setdefault(name, [])
        if not has_bridge(entries):
            entries.append({"hooks": [{"type": "command", "command": hook_cmd, "timeoutMs": 3000}]})
            added += 1
    msg = f"已注册 {added}/7 个事件桥（重复注册自动跳过）"
else:
    hooks = cfg.get("hooks", {})
    ev = hooks.get("events", {})
    removed = 0
    for name in events:
        entries = ev.get(name, [])
        kept = [e for e in entries if not has_bridge([e])]
        removed += len(entries) - len(kept)
        if kept:
            ev[name] = kept
        else:
            ev.pop(name, None)
    if not ev:
        hooks.pop("events", None)
    if not hooks:
        cfg.pop("hooks", None)
    msg = f"已移除 {removed} 个事件桥注册"

tmp = config_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, config_path)
print(msg + " → " + config_path)
PYEOF
