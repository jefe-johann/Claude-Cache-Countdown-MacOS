#!/usr/bin/env bash
# Background countdown ticker for Warp terminal.
# Updates the terminal tab title with the remaining cache time every second.
# Launched by the Stop hook, killed by the UserPromptSubmit hook.
#
# Usage: cache-timer-bg.sh <session_id> <tty_device>
#
# Writes its PID to cache-timer-<session_id>.pid for cleanup.
# Exits automatically when the 5-minute cache TTL expires.

set -euo pipefail

SESSION_ID="${1:-}"
TTY_DEV="${2:-}"
[ -z "$SESSION_ID" ] && exit 0
[ -z "$TTY_DEV" ] && exit 0
[ -w "$TTY_DEV" ] || exit 0

STATE_DIR="$HOME/.claude/state"
TIMER_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.json"
PID_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.pid"

[ -f "$TIMER_FILE" ] || exit 0

# Read timestamp and project name from timer file
ts=$(grep -o '"timestamp":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4) || exit 0
project=$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
ts_clean=$(echo "$ts" | sed 's/\.[0-9]*Z$//')
ts_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null) || exit 0

# Write PID file for cleanup by the resume hook
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

while true; do
    now=$(date -u +%s)
    remaining=$(( 300 - (now - ts_epoch) ))

    if [ "$remaining" -le 0 ]; then
        # Cache expired — restore title to just project name
        printf '\033]0;%s\007' "$project" > "$TTY_DEV" 2>/dev/null || true
        break
    fi

    mins=$(( remaining / 60 ))
    secs=$(( remaining % 60 ))
    if [ -n "$project" ]; then
        printf '\033]0;⏱ %d:%02d | %s\007' "$mins" "$secs" "$project" > "$TTY_DEV" 2>/dev/null || true
    else
        printf '\033]0;⏱ %d:%02d\007' "$mins" "$secs" > "$TTY_DEV" 2>/dev/null || true
    fi

    sleep 1
done
