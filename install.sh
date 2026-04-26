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
CONFIG_FILE="$HOME/.claude/countdown.conf"

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
echo "Config:         $CONFIG_FILE"
echo ""

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating $SETTINGS_FILE..."
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

mkdir -p "$(dirname "$CONFIG_FILE")"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating $CONFIG_FILE..."
    echo ""
    echo "Select your cache TTL profile:"
    echo "  1) Pro / Standard (5 minutes)"
    echo "  2) Max (1 hour)"

    CACHE_TTL_SECONDS=300
    if [ -t 0 ]; then
        while true; do
            printf "Choice [1]: "
            read -r profile_choice

            case "${profile_choice:-1}" in
                1)
                    CACHE_TTL_SECONDS=300
                    break
                    ;;
                2)
                    CACHE_TTL_SECONDS=3600
                    break
                    ;;
                *)
                    echo "Please enter 1 or 2."
                    ;;
            esac
        done
    else
        echo "No interactive TTY detected; defaulting to Pro / Standard (5 minutes)."
    fi

    cat > "$CONFIG_FILE" <<EOF
# Claude Cache Countdown configuration
# Edit this file to customize countdown behavior.

# Cache TTL in seconds.
#   300  = Pro / Standard (5 minutes)
#   3600 = Max (1 hour)
CACHE_TTL_SECONDS=$CACHE_TTL_SECONDS

# Status line display mode.
#   dollars = show the estimated re-cache cost delta
#   tokens  = show the cached prompt size instead
STATUSLINE_DISPLAY_MODE=dollars

# Enable or disable the countdown alert.
ENABLE_ALERTS=true

# Sound file played once when 60 seconds remain.
ALERT_60S_SOUND="/System/Library/Sounds/Glass.aiff"
EOF
    echo "  Wrote $CONFIG_FILE"
else
    echo "Keeping existing config at $CONFIG_FILE"
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

echo ""
echo "Installation complete!"
echo ""
echo "The background ticker starts automatically when Claude Code stops."
echo "The countdown appears when a Claude Code session stops."
echo "Warp reclaims the tab title when the countdown is not active."
echo "Restart Claude Code to load the new hooks."
