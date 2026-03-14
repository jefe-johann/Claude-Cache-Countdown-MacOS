#!/usr/bin/env bash
# UserPromptSubmit hook for Claude Code
# Removes the cache timer file when the user sends a new prompt.
# No timer file = no countdown = cache is being refreshed by active work.
#
# Install: Add to ~/.claude/settings.json under hooks.UserPromptSubmit

set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

TIMER_FILE="$HOME/.claude/state/cache-timer-${SESSION_ID}.json"
rm -f "$TIMER_FILE" 2>/dev/null

exit 0
