#!/usr/bin/env bash
# Background countdown ticker for Warp terminal.
# Polls the timer file every second and updates the tab title:
#   stopped=false  →  project name (Claude is working)
#   stopped=true   →  ⏱ M:SS | project (counting down to cache expiry)
#   expired        →  project name (cache expired, idle)
#
# Runs for the lifetime of the session. Launched once by the first Stop hook;
# stays alive across prompt cycles rather than being killed/relaunched each time.
#
# Usage: cache-timer-bg.sh <session_id> <tty_device>

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

# Detect /clear: watch the project's conversation directory for new sessions.
# If a different session's JSONL is modified after we launched, exit.
_cwd=$(grep -o '"cwd":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
CONV_DIR=""
if [ -n "$_cwd" ]; then
    CONV_DIR="$HOME/.claude/projects/$(echo "$_cwd" | tr '/_' '-')"
fi
START_EPOCH=$(date -u +%s)

echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# Write title — exits the script if the TTY becomes unwritable (tab closed)
_write_title() {
    printf '\033]0;%s\007' "$1" > "$TTY_DEV" 2>/dev/null || exit 0
}

while true; do
    # Exit if timer file was deleted (session ended or cleaned up)
    [ -f "$TIMER_FILE" ] || exit 0

    # Exit if a new session started (e.g. /clear)
    if [ -n "$CONV_DIR" ] && [ -d "$CONV_DIR" ]; then
        for _jf in "$CONV_DIR"/*.jsonl; do
            [ -f "$_jf" ] || continue
            [ "$(basename "$_jf" .jsonl)" = "$SESSION_ID" ] && continue
            _mtime=$(stat -f %m "$_jf" 2>/dev/null) || continue
            if [ "$_mtime" -gt "$START_EPOCH" ]; then
                _write_title "$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")"
                exit 0
            fi
        done
    fi

    stopped=$(grep -o '"stopped":[a-z]*' "$TIMER_FILE" 2>/dev/null | cut -d: -f2 || echo "true")
    project=$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")

    if [ "$stopped" = "false" ]; then
        # Claude is working — hold the title to the project name
        _write_title "$project"
    else
        # Claude stopped — show countdown, or project name if expired
        ts=$(grep -o '"timestamp":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
        if [ -n "$ts" ]; then
            ts_clean=$(echo "$ts" | sed 's/\.[0-9]*Z$//')
            ts_epoch=$(date -juf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null || echo "0")
            now=$(date -u +%s)
            remaining=$(( 300 - (now - ts_epoch) ))
            if [ "$remaining" -gt 0 ]; then
                mins=$(( remaining / 60 ))
                secs=$(( remaining % 60 ))
                if [ -n "$project" ]; then
                    printf '\033]0;⏱ %d:%02d | %s\007' "$mins" "$secs" "$project" > "$TTY_DEV" 2>/dev/null || exit 0
                else
                    printf '\033]0;⏱ %d:%02d\007' "$mins" "$secs" > "$TTY_DEV" 2>/dev/null || exit 0
                fi
            else
                _write_title "$project"
            fi
        else
            _write_title "$project"
        fi
    fi

    sleep 1
done
