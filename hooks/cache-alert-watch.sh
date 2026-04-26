#!/usr/bin/env bash
# Alert-only watcher for Claude Cache Countdown.
# Watches one session timer file and plays the 60-second sound once.

set -euo pipefail

SESSION_ID="${1:-}"
[ -z "$SESSION_ID" ] && exit 0

STATE_DIR="$HOME/.claude/state"
TIMER_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.json"
PID_FILE="$STATE_DIR/cache-alert-${SESSION_ID}.pid"
OS_NAME="$(uname -s)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=hooks/countdown-config.sh
. "$SCRIPT_DIR/countdown-config.sh"
countdown_load_config

[ "${ENABLE_ALERTS:-true}" = "true" ] || exit 0
[ -f "$TIMER_FILE" ] || exit 0

mkdir -p "$STATE_DIR"
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT
countdown_debug_log alert "start session=$SESSION_ID timer_file=$TIMER_FILE"

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

_timestamp_epoch_ns() {
    local ts="$1"
    local ts_clean
    local frac="0"
    local seconds

    ts_clean=$(echo "$ts" | sed 's/Z$//')
    if [[ "$ts_clean" == *.* ]]; then
        frac="${ts_clean##*.}"
        ts_clean="${ts_clean%%.*}"
    fi

    seconds=$(_timestamp_epoch "$ts_clean")
    case "$frac" in
        ''|*[!0-9]*) frac="0" ;;
    esac
    frac="${frac}000000000"
    frac="${frac:0:9}"

    printf '%s\n' $(( (seconds * 1000000000) + 10#$frac ))
}

_play_alert() {
    if [ -n "${ALERT_60S_SOUND:-}" ] && [ -r "$ALERT_60S_SOUND" ] && command -v afplay >/dev/null 2>&1; then
        afplay "$ALERT_60S_SOUND" >/dev/null 2>&1 &
        countdown_debug_log alert "played 60s sound session=$SESSION_ID sound=$ALERT_60S_SOUND"
    else
        countdown_debug_log alert "skipped sound session=$SESSION_ID sound=${ALERT_60S_SOUND:-missing}"
    fi
}

while true; do
    countdown_load_config
    [ "${ENABLE_ALERTS:-true}" = "true" ] || exit 0
    [ -f "$TIMER_FILE" ] || exit 0

    stopped=$(grep -o '"stopped":[a-z]*' "$TIMER_FILE" 2>/dev/null | cut -d: -f2 || echo "false")
    [ "$stopped" = "true" ] || exit 0

    # If Claude exited (e.g. user typed /quit), the cache the alert is
    # warning about is unreachable — don't fire the sound.
    claude_pid=$(grep -o '"claude_pid":[0-9]*' "$TIMER_FILE" 2>/dev/null | head -1 | grep -o '[0-9]*' || echo "0")
    if [ "${claude_pid:-0}" -gt 0 ] && ! kill -0 "$claude_pid" 2>/dev/null; then
        countdown_debug_log alert "exit on claude gone session=$SESSION_ID claude_pid=$claude_pid"
        exit 0
    fi

    ts_epoch_ns=$(grep -o '"timestamp_epoch_ns":[0-9]*' "$TIMER_FILE" 2>/dev/null | head -1 | grep -o '[0-9]*' || echo "")
    if [ -z "$ts_epoch_ns" ]; then
        ts=$(grep -o '"timestamp":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
        [ -n "$ts" ] || exit 0
        ts_epoch_ns=$(_timestamp_epoch_ns "$ts")
    fi

    now_ns=$(countdown_now_epoch_ns)
    remaining_ns=$(( (CACHE_TTL_SECONDS * 1000000000) - (now_ns - ts_epoch_ns) ))
    [ "$remaining_ns" -gt 0 ] || exit 0

    remaining=$(( (remaining_ns + 999999999) / 1000000000 ))
    if [ "$remaining" -le 60 ]; then
        _play_alert
        exit 0
    fi

    sleep 0.2 2>/dev/null || sleep 1
done
