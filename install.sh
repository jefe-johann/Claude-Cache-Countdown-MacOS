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
ALERT_HOOK="$SCRIPT_DIR/hooks/cache-alert-watch.sh"
CONFIG_FILE="$HOME/.claude/countdown.conf"

echo "Claude Cache Countdown Installer"
echo "================================"
echo

case "$(uname -s)" in
    Darwin) ;;
    Linux)
        echo "Note: Linux support is implemented but lightly tested."
        echo
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

missing_hooks=()
for hook in "$STOP_HOOK" "$RESUME_HOOK" "$STATUSLINE_HOOK" "$ALERT_HOOK"; do
    [ -f "$hook" ] || missing_hooks+=("$hook")
done
if [ "${#missing_hooks[@]}" -gt 0 ]; then
    echo "Error: required hook script(s) not found:"
    for hook in "${missing_hooks[@]}"; do
        echo "  $hook"
    done
    echo "Your checkout looks incomplete. Re-clone or 'git pull' and try again."
    exit 1
fi

chmod +x "$STOP_HOOK" "$RESUME_HOOK" "$STATUSLINE_HOOK" "$ALERT_HOOK"

# Create state directory
mkdir -p "$STATE_DIR"

echo "Stop hook:      $STOP_HOOK"
echo "Resume hook:    $RESUME_HOOK"
echo "Status line:    $STATUSLINE_HOOK"
echo "Alert watcher:  $ALERT_HOOK   (launched on demand by Stop hook; not wired into settings.json)"
echo "Config:         $CONFIG_FILE"
echo

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating $SETTINGS_FILE..."
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

mkdir -p "$(dirname "$CONFIG_FILE")"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating $CONFIG_FILE..."
    echo
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

    config_tmp="${CONFIG_FILE}.tmp.$$"
    trap 'rm -f "$config_tmp"' EXIT
    cat > "$config_tmp" <<EOF
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

# Enable verbose hook and alert watcher logging while debugging.
COUNTDOWN_DEBUG=false

# Optional override for the debug log path.
COUNTDOWN_DEBUG_LOG_FILE="$HOME/.claude/state/cache-countdown-debug.log"
EOF
    mv "$config_tmp" "$CONFIG_FILE"
    trap - EXIT
    echo "  Wrote $CONFIG_FILE"
else
    echo "Keeping existing config at $CONFIG_FILE"
fi

echo "Stopping any legacy title tickers..."
shopt -s nullglob
for pidfile in "$STATE_DIR"/cache-timer-*.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
        if echo "$cmd" | grep -q "cache-timer-bg.sh"; then
            kill "$pid" 2>/dev/null || true
            echo "  Stopped legacy title ticker pid=$pid"
        fi
    fi
    rm -f "$pidfile"
done
shopt -u nullglob

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
import sys

settings_path = os.environ["SETTINGS_FILE"]
stop_cmd = f"bash {shlex.quote(os.environ['STOP_HOOK'])}"
resume_cmd = f"bash {shlex.quote(os.environ['RESUME_HOOK'])}"
statusline_cmd = f"bash {shlex.quote(os.environ['STATUSLINE_HOOK'])}"
original_cmd_file = os.environ["ORIGINAL_CMD_FILE"]

try:
    with open(settings_path, "r", encoding="utf-8") as f:
        settings = json.load(f)
except json.JSONDecodeError as exc:
    sys.stderr.write(
        f"Error: {settings_path} is not valid JSON ({exc.msg} at line {exc.lineno}, "
        f"col {exc.colno}).\nFix the file (or remove it to start fresh) and re-run "
        f"the installer.\n"
    )
    sys.exit(1)

hooks = settings.setdefault("hooks", {})
changed = False
warnings = []


def _matching_commands(entries, marker):
    return [
        hook.get("command", "")
        for entry in entries
        for hook in entry.get("hooks", [])
        if marker in hook.get("command", "")
    ]


def _wire_hook(entries, marker, expected_cmd, label, timeout):
    """Add the hook iff no matching command exists. If a command containing
    `marker` already exists at a different path, warn and do not duplicate —
    the user likely has another checkout wired up."""
    global changed
    matches = _matching_commands(entries, marker)
    if any(cmd == expected_cmd for cmd in matches):
        print(f"  {label} already installed.")
        return
    if matches:
        warnings.append((label, expected_cmd, matches))
        print(f"  WARNING: {label} already wired at a different path:")
        for cmd in matches:
            print(f"    found:    {cmd}")
        print(f"    expected: {expected_cmd}")
        print(
            f"    Skipping to avoid duplicate hooks. Run that checkout's "
            f"uninstall.sh (or edit settings.json) first."
        )
        return
    entries.append(
        {
            "matcher": "",
            "hooks": [{"type": "command", "command": expected_cmd, "timeout": timeout}],
        }
    )
    print(f"  Added {label}.")
    changed = True


_wire_hook(hooks.setdefault("Stop", []), "cache-timer-write", stop_cmd, "Stop hook", 5)
_wire_hook(
    hooks.setdefault("UserPromptSubmit", []),
    "cache-timer-resume",
    resume_cmd,
    "UserPromptSubmit hook",
    5,
)

# Add status line wrapper
sl = settings.get("statusLine", {})
current_sl_cmd = sl.get("command", "") if isinstance(sl, dict) else ""

if "statusline-cost" in current_sl_cmd and current_sl_cmd != statusline_cmd:
    warnings.append(("Status line wrapper", statusline_cmd, [current_sl_cmd]))
    print("  WARNING: Status line wrapper already wired at a different path:")
    print(f"    found:    {current_sl_cmd}")
    print(f"    expected: {statusline_cmd}")
    print(
        "    Leaving existing statusLine in place. Run that checkout's "
        "uninstall.sh (or edit settings.json) first."
    )
elif "statusline-cost" in current_sl_cmd:
    if not isinstance(sl, dict):
        sl = {}
    refresh = sl.get("refreshInterval")
    # Only force refreshInterval when missing or non-positive — respect a user's
    # deliberate choice (e.g. higher value for battery / slow shells).
    if not isinstance(refresh, (int, float)) or refresh <= 0:
        sl["refreshInterval"] = 1
        settings["statusLine"] = sl
        print("  Set status line refreshInterval to 1 second.")
        changed = True
    else:
        print(f"  Status line wrapper already installed (refreshInterval={refresh}s).")
else:
    if current_sl_cmd:
        os.makedirs(os.path.dirname(original_cmd_file), exist_ok=True)
        if os.path.exists(original_cmd_file):
            print(
                f"  Existing backup at {original_cmd_file} kept (not overwritten); "
                f"current statusLine command discarded."
            )
        else:
            with open(original_cmd_file, "w", encoding="utf-8") as backup_file:
                backup_file.write(current_sl_cmd)
            print(f"  Backed up existing status line to {original_cmd_file}")
    settings["statusLine"] = {"type": "command", "command": statusline_cmd, "refreshInterval": 1}
    print("  Installed status line cost wrapper.")
    changed = True

if changed:
    tmp_path = f"{settings_path}.tmp.{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, settings_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise

print()
PY

echo
echo "Installation complete!"
echo
echo "The countdown appears in Claude Code's status line when a session stops."
echo "A small alert watcher plays the 60-second sound when alerts are enabled."
echo
echo "Tune behavior (TTL, alerts, sound, debug) in:"
echo "  $CONFIG_FILE"
if [ -f "$STATE_DIR/cache-countdown-original-statusline.txt" ]; then
    echo
    echo "Your previous statusLine command was backed up to:"
    echo "  $STATE_DIR/cache-countdown-original-statusline.txt"
fi
echo
echo "For non-standard ~/.claude layouts or hand-wiring, see:"
echo "  $SCRIPT_DIR/docs/manual-install.md"
echo
echo "Restart Claude Code to load the new hooks."
