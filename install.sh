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

# Disabled for now: we tried claiming the Warp tab title during active Claude
# responses too, but in practice that created a lot of title flicker. Keeping
# the installer logic here in a commented block makes it easy to revisit later.
: <<'WARP_AUTO_TITLE_DISABLED'
# Warp terminal: add shell integration to disable auto-title during Claude sessions
SHELL_RC=""
SHELL_NAME="$(basename "${SHELL:-}")"
case "$SHELL_NAME" in
    zsh)  SHELL_RC="$HOME/.zshrc" ;;
    bash) SHELL_RC="$HOME/.bashrc" ;;
esac

if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && [ -n "${WARP_SESSION_ID:-}" ]; then
    if [ "$SHELL_NAME" = "zsh" ]; then
        WARP_SNIPPET=$(cat <<'WARP_EOF'
# claude-cache-countdown: disable Warp auto-title while Claude Code runs
# so the cache countdown timer can control the tab title.
# Only activates inside Warp; no-op in other terminals.
if [ -n "${WARP_SESSION_ID:-}" ]; then
    _claude_cache_countdown_preexec() {
        case "$1" in
            claude|claude\ *|command\ claude|command\ claude\ *|nocorrect\ claude|nocorrect\ claude\ *|*/claude|*/claude\ *|command\ */claude|command\ */claude\ *|nocorrect\ */claude|nocorrect\ */claude\ *)
                export WARP_DISABLE_AUTO_TITLE=true
                export CLAUDE_CACHE_COUNTDOWN_WARP_TITLE_OWNED=1
                ;;
        esac
    }

    _claude_cache_countdown_precmd() {
        if [ -n "${CLAUDE_CACHE_COUNTDOWN_WARP_TITLE_OWNED:-}" ]; then
            unset WARP_DISABLE_AUTO_TITLE
            unset CLAUDE_CACHE_COUNTDOWN_WARP_TITLE_OWNED
        fi
    }

    typeset -ga preexec_functions precmd_functions
    if (( ${preexec_functions[(Ie)_claude_cache_countdown_preexec]} == 0 )); then
        preexec_functions+=(_claude_cache_countdown_preexec)
    fi
    if (( ${precmd_functions[(Ie)_claude_cache_countdown_precmd]} == 0 )); then
        precmd_functions+=(_claude_cache_countdown_precmd)
    fi
fi
WARP_EOF
)

        WARP_OLD_SNIPPET=$(cat <<'WARP_EOF'
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
)
    else
        WARP_SNIPPET=$(cat <<'WARP_EOF'
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
)
        WARP_OLD_SNIPPET=""
    fi

    if grep -q '_claude_cache_countdown_preexec\|WARP_DISABLE_AUTO_TITLE' "$SHELL_RC" 2>/dev/null; then
        if [ "$SHELL_NAME" = "zsh" ] && grep -q '_claude_cache_countdown_preexec' "$SHELL_RC" 2>/dev/null; then
            echo "Warp auto-title integration already installed in $SHELL_RC."
        elif [ "$SHELL_NAME" = "zsh" ] && python3 - "$SHELL_RC" "$WARP_OLD_SNIPPET" "$WARP_SNIPPET" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text(encoding="utf-8")

if old in text and new not in text:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    sys.exit(0)

sys.exit(1)
PY
        then
            echo "Updated Warp auto-title integration in $SHELL_RC."
            echo "  Run 'source $SHELL_RC' or open a new tab to activate."
        else
            echo "Warp auto-title integration already present in $SHELL_RC."
        fi
    else
        echo ""
        echo "Claude Cache puts the countdown timer in your Warp tab title. Warp can auto-generate tab names from the foreground command, which can fight the timer while Claude is running. Would you like to add shell integration to $SHELL_RC to prevent Warp from overwriting the custom title during Claude sessions? (y/n)"
        read -n 1 -r </dev/tty
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Adding Warp auto-title integration to $SHELL_RC..."
            printf '\n%s\n' "$WARP_SNIPPET" >> "$SHELL_RC"
            echo "  Added to $SHELL_RC"
            echo "  Run 'source $SHELL_RC' or open a new tab to activate."
        else
            echo "Skipping shell integration. You can always add it manually later."
        fi
    fi
fi
WARP_AUTO_TITLE_DISABLED

echo ""
echo "Installation complete!"
echo ""
echo "The background ticker starts automatically when Claude Code stops."
echo "The countdown appears when a Claude Code session stops."
echo "It disappears when you send a new message (cache refreshes)."
echo "Restart Claude Code to load the new hooks."
