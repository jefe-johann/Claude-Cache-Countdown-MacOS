#!/usr/bin/env bash
# Background countdown ticker for Warp terminal.
# Polls the timer file every second and updates the tab title only while
# the cache is actively draining.
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
OS_NAME="$(uname -s)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=hooks/countdown-config.sh
. "$SCRIPT_DIR/countdown-config.sh"

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

# Sound alert state — fires once per countdown
_beeped_60=false

_alert_60s() {
    if [ "$ENABLE_ALERTS" != "true" ]; then
        return 0
    fi

    if [ -n "$ALERT_60S_SOUND" ] && [ -f "$ALERT_60S_SOUND" ] && command -v afplay >/dev/null 2>&1; then
        afplay "$ALERT_60S_SOUND" >/dev/null 2>&1 &
    else
        printf '\a' > "$TTY_DEV" 2>/dev/null || true
    fi
}

_write_title() {
    local title="$1"
    # Emit both common title channels so Warp's newer session UIs have the
    # best chance of picking up the countdown label.
    printf '\033]0;%s\007\033]2;%s\007' "$title" "$title" > "$TTY_DEV" 2>/dev/null || exit 0
}

_mtime_epoch() {
    local path="$1"
    case "$OS_NAME" in
        Darwin) stat -f %m "$path" ;;
        Linux) stat -c %Y "$path" ;;
        *) return 1 ;;
    esac
}

_timestamp_epoch() {
    local ts="$1"
    local ts_clean
    ts_clean=$(echo "$ts" | sed 's/\.[0-9]*Z$//')

    case "$OS_NAME" in
        Darwin) date -juf "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null || echo "0" ;;
        Linux) date -u -d "${ts_clean} UTC" +%s 2>/dev/null || echo "0" ;;
        *) echo "0" ;;
    esac
}

while true; do
    countdown_load_config

    # Exit if timer file was deleted (session ended or cleaned up)
    [ -f "$TIMER_FILE" ] || exit 0

    # Exit if a new session started (e.g. /clear)
    if [ -n "$CONV_DIR" ] && [ -d "$CONV_DIR" ]; then
        for _jf in "$CONV_DIR"/*.jsonl; do
            [ -f "$_jf" ] || continue
            [ "$(basename "$_jf" .jsonl)" = "$SESSION_ID" ] && continue
            _mtime=$(_mtime_epoch "$_jf" 2>/dev/null) || continue
            if [ "$_mtime" -gt "$START_EPOCH" ]; then
                exit 0
            fi
        done
    fi

    stopped=$(grep -o '"stopped":[a-z]*' "$TIMER_FILE" 2>/dev/null | cut -d: -f2 || echo "true")
    project=$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")

    if [ "$stopped" = "false" ]; then
        # Claude is working — reset alert state for next countdown
        _beeped_60=false
    else
        # Claude stopped — show countdown while cache is still active
        ts=$(grep -o '"timestamp":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
        if [ -n "$ts" ]; then
            ts_epoch=$(_timestamp_epoch "$ts")
            now=$(date -u +%s)
            remaining=$(( CACHE_TTL_SECONDS - (now - ts_epoch) ))
            if [ "$remaining" -gt 0 ]; then
                if [ "$remaining" -le 60 ] && [ "$_beeped_60" = "false" ]; then
                    _beeped_60=true
                    _alert_60s
                fi

                mins=$(( remaining / 60 ))
                secs=$(( remaining % 60 ))
                if [ -n "$project" ]; then
                    _write_title "$(printf '⏱ %d:%02d | %s' "$mins" "$secs" "$project")"
                else
                    _write_title "$(printf '⏱ %d:%02d' "$mins" "$secs")"
                fi
            fi
        fi
    fi

    sleep 1
done
