#!/usr/bin/env bash
# Background countdown ticker for Warp terminal.
# Polls the timer file every second and updates the tab title:
#   stopped=false  →  no title updates (Warp owns the tab title while Claude is working)
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
OS_NAME="$(uname -s)"

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

# Sound alert state — each fires once per countdown
_beeped_120=false
_beeped_60=false
_beeped_30=false

_beep() {
    local count="$1"
    (
        for (( i=0; i<count; i++ )); do
            /usr/bin/afplay /System/Library/Sounds/Ping.aiff >/dev/null 2>&1 || true
            if [ "$i" -lt $((count - 1)) ]; then
                sleep 0.3 || true
            fi
        done
    ) >/dev/null 2>&1 &
}

# Write title — exits the script if the TTY becomes unwritable (tab closed)
_write_title() {
    printf '\033]0;%s\007' "$1" > "$TTY_DEV" 2>/dev/null || exit 0
}

# Disabled for now: actively reasserting a custom title while Claude is the
# foreground process causes heavy flicker in Warp. Keeping this helper around
# makes it easier to revisit that approach later.
_active_title() {
    local project="$1"
    local separator="|"

    # Warp appears more willing to reclaim a static title than one that is
    # still changing. Alternate the separator so each active-state write is a
    # distinct title without looking like a countdown has started.
    if [ $(( $(date -u +%s) % 2 )) -eq 1 ]; then
        separator="·"
    fi

    if [ -n "$project" ]; then
        printf '⏱ 5:00 %s %s' "$separator" "$project"
    else
        printf '⏱ 5:00'
    fi
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
    # Exit if timer file was deleted (session ended or cleaned up)
    [ -f "$TIMER_FILE" ] || exit 0

    # Exit if a new session started (e.g. /clear)
    if [ -n "$CONV_DIR" ] && [ -d "$CONV_DIR" ]; then
        for _jf in "$CONV_DIR"/*.jsonl; do
            [ -f "$_jf" ] || continue
            [ "$(basename "$_jf" .jsonl)" = "$SESSION_ID" ] && continue
            _mtime=$(_mtime_epoch "$_jf" 2>/dev/null) || continue
            if [ "$_mtime" -gt "$START_EPOCH" ]; then
                _write_title "$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")"
                exit 0
            fi
        done
    fi

    stopped=$(grep -o '"stopped":[a-z]*' "$TIMER_FILE" 2>/dev/null | cut -d: -f2 || echo "true")
    project=$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")

    if [ "$stopped" = "false" ]; then
        # Claude is working — reset alert state for next countdown
        _beeped_120=false
        _beeped_60=false
        _beeped_30=false
        # Disabled for now: letting Warp own the active-session title avoids
        # a back-and-forth flicker while Claude is still responding.
        #
        # _write_title "$(_active_title "$project")"
    else
        # Claude stopped — show countdown, or project name if expired
        ts=$(grep -o '"timestamp":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || echo "")
        if [ -n "$ts" ]; then
            ts_epoch=$(_timestamp_epoch "$ts")
            now=$(date -u +%s)
            remaining=$(( 300 - (now - ts_epoch) ))
            if [ "$remaining" -gt 0 ]; then
                # Sound alerts at key thresholds
                if [ "$remaining" -le 120 ] && [ "$_beeped_120" = "false" ]; then
                    _beeped_120=true
                    _beep 1
                fi
                if [ "$remaining" -le 60 ] && [ "$_beeped_60" = "false" ]; then
                    _beeped_60=true
                    _beep 2
                fi
                if [ "$remaining" -le 30 ] && [ "$_beeped_30" = "false" ]; then
                    _beeped_30=true
                    _beep 3
                fi

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
