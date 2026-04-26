#!/usr/bin/env bash
# SessionStart hook for Claude Code.
# When the user runs /clear (source: "clear"), the prompt cache is invalidated
# but the session_id stays the same — so the timer file from the previous
# Stop still exists and would otherwise drive a stale countdown and a
# misleading "60-second" alert. Drop the timer file and any pending alert
# marker so the status line stops counting and nothing fires.
#
# No-op for source values other than "clear" — `startup` has no prior state
# to clean and `resume` legitimately restores a still-warm cache.
#
# Install: Add to ~/.claude/settings.json under hooks.SessionStart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=hooks/countdown-config.sh
. "$SCRIPT_DIR/countdown-config.sh"
countdown_load_config

INPUT=$(cat)

SOURCE=$(echo "$INPUT" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4)
[ "$SOURCE" = "clear" ] || exit 0

SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$SESSION_ID" ] || exit 0

STATE_DIR="$HOME/.claude/state"
TIMER_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.json"
ALERT_MARKER="$STATE_DIR/cache-alert-fired-${SESSION_ID}.flag"

rm -f "$TIMER_FILE" "$ALERT_MARKER" 2>/dev/null || true
countdown_debug_log clear "cleared timer + marker session=$SESSION_ID"

exit 0
