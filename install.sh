#!/usr/bin/env bash
# Install Claude Cache Countdown
# Adds the Stop and UserPromptSubmit hooks to your Claude Code settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
STOP_HOOK="$SCRIPT_DIR/hooks/cache-timer-write.sh"
RESUME_HOOK="$SCRIPT_DIR/hooks/cache-timer-resume.sh"
STATUSLINE_HOOK="$SCRIPT_DIR/hooks/statusline-cost.sh"

echo "Claude Cache Countdown Installer"
echo "================================"
echo ""

# Check prerequisites
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

chmod +x "$STOP_HOOK" "$RESUME_HOOK" "$STATUSLINE_HOOK"

# Create state directory
mkdir -p "$HOME/.claude/state"

echo "Stop hook:      $STOP_HOOK"
echo "Resume hook:    $RESUME_HOOK"
echo "Status line:    $STATUSLINE_HOOK"
echo "Ticker:         $SCRIPT_DIR/cache_countdown.py"
echo ""

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Creating $SETTINGS_FILE..."
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{}' > "$SETTINGS_FILE"
fi

# Add hooks to settings.json
echo "Adding hooks to $SETTINGS_FILE..."
python3 -c "
import json, sys

settings_path = '$SETTINGS_FILE'
stop_cmd = 'bash $STOP_HOOK'
resume_cmd = 'bash $RESUME_HOOK'
statusline_cmd = 'bash $STATUSLINE_HOOK'
original_cmd_file = '$HOME/.claude/state/cache-countdown-original-statusline.txt'

with open(settings_path, 'r') as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})
changed = False

# Add Stop hook
stop_hooks = hooks.setdefault('Stop', [])
already = any('cache-timer-write' in h.get('command', '')
              for entry in stop_hooks for h in entry.get('hooks', []))
if not already:
    stop_hooks.append({
        'matcher': '',
        'hooks': [{'type': 'command', 'command': stop_cmd, 'timeout': 5}]
    })
    print('  Added Stop hook.')
    changed = True
else:
    print('  Stop hook already installed.')

# Add UserPromptSubmit hook
submit_hooks = hooks.setdefault('UserPromptSubmit', [])
already = any('cache-timer-resume' in h.get('command', '')
              for entry in submit_hooks for h in entry.get('hooks', []))
if not already:
    submit_hooks.append({
        'matcher': '',
        'hooks': [{'type': 'command', 'command': resume_cmd, 'timeout': 5}]
    })
    print('  Added UserPromptSubmit hook.')
    changed = True
else:
    print('  UserPromptSubmit hook already installed.')

# Add status line wrapper
import os
sl = settings.get('statusLine', {})
current_sl_cmd = sl.get('command', '') if isinstance(sl, dict) else ''
ocf = os.path.expandvars(original_cmd_file)

if 'statusline-cost' in current_sl_cmd:
    print('  Status line wrapper already installed.')
else:
    # Back up existing status line command if there is one
    if current_sl_cmd:
        os.makedirs(os.path.dirname(ocf), exist_ok=True)
        with open(ocf, 'w') as bf:
            bf.write(current_sl_cmd)
        print(f'  Backed up existing status line to {ocf}')
    settings['statusLine'] = {
        'type': 'command',
        'command': statusline_cmd
    }
    print('  Installed status line cost wrapper.')
    changed = True

if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)

print()
"

echo "Installation complete!"
echo ""
echo "To start the countdown ticker, run:"
echo "  python3 $SCRIPT_DIR/cache_countdown.py"
echo ""
echo "Or add an alias to your shell profile:"
echo "  alias cache-ticker='python3 $SCRIPT_DIR/cache_countdown.py'"
echo ""
echo "The countdown appears when a Claude Code session stops."
echo "It disappears when you send a new message (cache refreshes)."
echo "Restart Claude Code to load the new hooks."
