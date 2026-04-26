#!/usr/bin/env bash
# Background countdown ticker for Warp terminal.
# Polls the timer file several times per second and updates the tab title
# only while the cache is actively draining.
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
countdown_load_config

[ -f "$TIMER_FILE" ] || exit 0
SCRIPT_MTIME=$(countdown_file_mtime_epoch "$SCRIPT_DIR/cache-timer-bg.sh" 2>/dev/null || echo "0")

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
countdown_debug_log bg "start session=$SESSION_ID tty=$TTY_DEV timer_file=$TIMER_FILE warp_disable_auto_title=${WARP_DISABLE_AUTO_TITLE:-unset}"

# Sound alert state — fires once per countdown
_beeped_60=false
_last_phase=""
_last_bucket=""
_sent_warp_stop=false
_last_title=""

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
    if ! printf '\033]0;%s\007\033]2;%s\007' "$title" "$title" > "$TTY_DEV" 2>/dev/null; then
        countdown_debug_log bg "title write failed session=$SESSION_ID tty=$TTY_DEV title=$title"
        exit 0
    fi
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

while true; do
    _sleep_interval=0.2
    countdown_load_config

    _current_script_mtime=$(countdown_file_mtime_epoch "$SCRIPT_DIR/cache-timer-bg.sh" 2>/dev/null || echo "$SCRIPT_MTIME")
    if [ "$SCRIPT_MTIME" -gt 0 ] && [ "$_current_script_mtime" -gt "$SCRIPT_MTIME" ]; then
        countdown_debug_log bg "reexec on script update session=$SESSION_ID tty=$TTY_DEV"
        exec bash "$SCRIPT_DIR/cache-timer-bg.sh" "$SESSION_ID" "$TTY_DEV"
    fi

    # Exit if timer file was deleted (session ended or cleaned up)
    [ -f "$TIMER_FILE" ] || exit 0

    # Exit if a new session started (e.g. /clear)
    if [ -n "$CONV_DIR" ] && [ -d "$CONV_DIR" ]; then
        for _jf in "$CONV_DIR"/*.jsonl; do
            [ -f "$_jf" ] || continue
            [ "$(basename "$_jf" .jsonl)" = "$SESSION_ID" ] && continue
            _mtime=$(countdown_file_mtime_epoch "$_jf" 2>/dev/null) || continue
            if [ "$_mtime" -gt "$START_EPOCH" ]; then
                countdown_debug_log bg "exit on clear session=$SESSION_ID tty=$TTY_DEV"
                exit 0
            fi
        done
    fi

    stopped=$(grep -o '"stopped":[a-z]*' "$TIMER_FILE" 2>/dev/null | cut -d: -f2 || echo "true")
    project=$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")

    if [ "$stopped" = "false" ]; then
        # Claude is working — reset alert state for next countdown
        _beeped_60=false
        _sent_warp_stop=false
        if [ "$_last_phase" != "active" ]; then
            _last_phase="active"
            _last_bucket=""
            _last_title=""
            countdown_debug_log bg "active session=$SESSION_ID tty=$TTY_DEV"
        fi
    else
        # Claude stopped — show countdown while cache is still active
        ts=$(grep -o '"timestamp":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
        ts_epoch_ns=$(grep -o '"timestamp_epoch_ns":[0-9]*' "$TIMER_FILE" 2>/dev/null | head -1 | grep -o '[0-9]*' || echo "")
        if [ -n "$ts" ]; then
            if [ -z "$ts_epoch_ns" ]; then
                ts_epoch_ns=$(_timestamp_epoch_ns "$ts")
            fi
            now_ns=$(countdown_now_epoch_ns)
            remaining_ns=$(( (CACHE_TTL_SECONDS * 1000000000) - (now_ns - ts_epoch_ns) ))
            if [ "$remaining_ns" -gt 0 ]; then
                _sleep_interval=0.05
                remaining=$(( (remaining_ns + 999999999) / 1000000000 ))
                _bucket=$(( remaining / 15 ))
                if [ "$_last_phase" != "countdown" ] || [ "$_last_bucket" != "$_bucket" ]; then
                    _last_phase="countdown"
                    _last_bucket="$_bucket"
                    countdown_debug_log bg "countdown session=$SESSION_ID tty=$TTY_DEV remaining=$remaining"
                fi
                if [ "$_sent_warp_stop" = "false" ]; then
                    _sent_warp_stop=true
                    countdown_warp_agent_stop_notify "$TTY_DEV" "$SESSION_ID" "$_cwd" "$project"
                fi
                if [ "$remaining" -le 60 ] && [ "$_beeped_60" = "false" ]; then
                    _beeped_60=true
                    _alert_60s
                    countdown_debug_log bg "alert-60s session=$SESSION_ID tty=$TTY_DEV"
                fi

                mins=$(( remaining / 60 ))
                secs=$(( remaining % 60 ))
                if [ -n "$project" ]; then
                    _title=$(printf '⏱ %d:%02d | %s' "$mins" "$secs" "$project")
                else
                    _title=$(printf '⏱ %d:%02d' "$mins" "$secs")
                fi

                # Poll tightly enough that scheduler drift is not visible, but
                # only rewrite the title when the displayed text changes.
                if [ "$_title" != "$_last_title" ]; then
                    _write_title "$_title"
                    _last_title="$_title"
                fi
            elif [ "$_last_phase" != "expired" ]; then
                _last_phase="expired"
                _last_bucket=""
                if [ -n "$project" ]; then
                    _title=$(printf '⚠️ | %s' "$project")
                else
                    _title='⚠️'
                fi
                _write_title "$_title"
                _last_title="$_title"
                countdown_debug_log bg "expired session=$SESSION_ID tty=$TTY_DEV"
            fi
        fi
    fi

    sleep "$_sleep_interval" 2>/dev/null || sleep 1
done
