#!/usr/bin/env bash
# Install Claude Cache Countdown
# Adds the Stop and UserPromptSubmit hooks to your Claude Code settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.claude/state"
STOP_HOOK="$SCRIPT_DIR/hooks/cache-timer-write.sh"
RESUME_HOOK="$SCRIPT_DIR/hooks/cache-timer-resume.sh"
STATUSLINE_HOOK="$SCRIPT_DIR/hooks/statusline-cost.sh"
TICKER_HOOK="$SCRIPT_DIR/hooks/cache-timer-bg.sh"

echo "Claude Cache Countdown Installer"
echo "================================"
echo ""

case "$(uname -s)" in
    Darwin) ;;
    Linux)
        echo "Note: Linux support is implemented but lightly tested."
        echo ""
        ;;
    *)
        echo "Error: this fork supports macOS and Linux only."
        exit 1
        ;;
esac

# Check prerequisites
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

chmod +x "$STOP_HOOK" "$RESUME_HOOK" "$STATUSLINE_HOOK" "$TICKER_HOOK"

# Create state directory
mkdir -p "$STATE_DIR"

echo "Stop hook:      $STOP_HOOK"
echo "Resume hook:    $RESUME_HOOK"
echo "Status line:    $STATUSLINE_HOOK"
echo "Ticker:         $SCRIPT_DIR/hooks/cache-timer-bg.sh"
echo ""

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating $SETTINGS_FILE..."
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

# Add hooks to settings.json
echo "Adding hooks to $SETTINGS_FILE..."
SETTINGS_FILE="$SETTINGS_FILE" \
STOP_HOOK="$STOP_HOOK" \
RESUME_HOOK="$RESUME_HOOK" \
STATUSLINE_HOOK="$STATUSLINE_HOOK" \
ORIGINAL_CMD_FILE="$STATE_DIR/cache-countdown-original-statusline.txt" \
python3 <<'PY'
import json
import os
import shlex

settings_path = os.environ["SETTINGS_FILE"]
stop_cmd = f"bash {shlex.quote(os.environ['STOP_HOOK'])}"
resume_cmd = f"bash {shlex.quote(os.environ['RESUME_HOOK'])}"
statusline_cmd = f"bash {shlex.quote(os.environ['STATUSLINE_HOOK'])}"
original_cmd_file = os.environ["ORIGINAL_CMD_FILE"]

with open(settings_path, "r", encoding="utf-8") as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
changed = False

# Add Stop hook
stop_hooks = hooks.setdefault("Stop", [])
already = any(
    "cache-timer-write" in hook.get("command", "")
    for entry in stop_hooks
    for hook in entry.get("hooks", [])
)
if not already:
    stop_hooks.append(
        {
            "matcher": "",
            "hooks": [{"type": "command", "command": stop_cmd, "timeout": 5}],
        }
    )
    print("  Added Stop hook.")
    changed = True
else:
    print("  Stop hook already installed.")

# Add UserPromptSubmit hook
submit_hooks = hooks.setdefault("UserPromptSubmit", [])
already = any(
    "cache-timer-resume" in hook.get("command", "")
    for entry in submit_hooks
    for hook in entry.get("hooks", [])
)
if not already:
    submit_hooks.append(
        {
            "matcher": "",
            "hooks": [{"type": "command", "command": resume_cmd, "timeout": 5}],
        }
    )
    print("  Added UserPromptSubmit hook.")
    changed = True
else:
    print("  UserPromptSubmit hook already installed.")

# Add status line wrapper
sl = settings.get("statusLine", {})
current_sl_cmd = sl.get("command", "") if isinstance(sl, dict) else ""

if "statusline-cost" in current_sl_cmd:
    print("  Status line wrapper already installed.")
else:
    if current_sl_cmd:
        os.makedirs(os.path.dirname(original_cmd_file), exist_ok=True)
        with open(original_cmd_file, "w", encoding="utf-8") as backup_file:
            backup_file.write(current_sl_cmd)
        print(f"  Backed up existing status line to {original_cmd_file}")
    settings["statusLine"] = {"type": "command", "command": statusline_cmd}
    print("  Installed status line cost wrapper.")
    changed = True

if changed:
    with open(settings_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")

print()
PY

# Warp terminal: add claude wrapper to disable auto-title during sessions
SHELL_RC=""
case "$(basename "${SHELL:-}")" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
esac

if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && [ -n "${WARP_SESSION_ID:-}" ]; then
    if grep -q 'WARP_DISABLE_AUTO_TITLE' "$SHELL_RC" 2>/dev/null; then
        echo "Warp auto-title wrapper already installed in $SHELL_RC."
    else
        echo ""
        echo "Claude Cache puts the countdown timer in your Warp tab title. When there's no timer active, warp will go back to its auto-generated title. This can cause an annoying back and forth. Would you like to add a wrapper to $SHELL_RC to prevent warp from overwriting the custom title? It will only be active in claude sessions, and disables at the end of the session. (y/n)"
        read -n 1 -r </dev/tty
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Adding Warp auto-title wrapper to $SHELL_RC..."
            cat >> "$SHELL_RC" << 'WARP_EOF'

# claude-cache-countdown: disable Warp auto-title while Claude Code runs
# so the cache countdown timer can control the tab title.
# Only activates inside Warp; no-op in other terminals.
if [ -n "${WARP_SESSION_ID:-}" ]; then
    claude() {
        export WARP_DISABLE_AUTO_TITLE=true
        command claude "$@"
        local _rc=$?
        unset WARP_DISABLE_AUTO_TITLE
        return $_rc
    }
fi
WARP_EOF
            echo "  Added to $SHELL_RC"
            echo "  Run 'source $SHELL_RC' or open a new tab to activate."
        else
            echo "Skipping wrapper installation. You can always add it manually later."
        fi
    fi
fi

echo ""
echo "Installation complete!"
echo ""
echo "The background ticker starts automatically when Claude Code stops."
echo "The countdown appears when a Claude Code session stops."
echo "It disappears when you send a new message (cache refreshes)."
echo "Restart Claude Code to load the new hooks."
