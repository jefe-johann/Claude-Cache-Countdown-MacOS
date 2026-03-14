#!/usr/bin/env bash
# UserPromptSubmit hook for Claude Code
# Removes the cache timer file when the user sends a new prompt.
# No timer file = no countdown = cache is being refreshed by active work.
#
# Install: Add to ~/.claude/settings.json under hooks.UserPromptSubmit
#
# No dependencies beyond bash and standard Unix tools.

set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

rm -f "$HOME/.claude/state/cache-timer-${SESSION_ID}.json" 2>/dev/null

exit 0
