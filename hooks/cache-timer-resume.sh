#!/usr/bin/env bash
# UserPromptSubmit hook for Claude Code
# Clears the stopped state when the user sends a new prompt.
# This tells the ticker the session is active again (cache is being refreshed).
#
# Install: Add to ~/.claude/settings.json under hooks.UserPromptSubmit

set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

TIMER_FILE="$HOME/.claude/state/cache-timer-${SESSION_ID}.json"
if [ ! -f "$TIMER_FILE" ]; then
    exit 0
fi

# Clear stopped state, update timestamp
python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    with open('$TIMER_FILE', 'r') as f:
        data = json.load(f)
    data['stopped'] = False
    data['timestamp'] = datetime.now(timezone.utc).isoformat()
    data.pop('stopped_at', None)
    with open('$TIMER_FILE', 'w') as f:
        json.dump(data, f)
except Exception:
    pass
"

exit 0
