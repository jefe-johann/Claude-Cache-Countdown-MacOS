#!/usr/bin/env bash
# UserPromptSubmit hook for Claude Code
# Marks the cache timer as active (stopped=false) when the user sends a new prompt.
# This tells the status line and alert watcher that the cache is no longer
# draining while Claude is working.
#
# Creates the timer file if it doesn't exist yet.
# Also cleans up stale timer files from other sessions sharing the same host_pid.
#
# Install: Add to ~/.claude/settings.json under hooks.UserPromptSubmit
#
# No dependencies beyond bash and standard Unix tools.

set -euo pipefail

# $PPID is the Claude CLI process that invoked this hook. Recorded so a
# later Stop hook + alert watcher can detect a Claude exit (/quit).
CLAUDE_PID="${PPID:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=hooks/countdown-config.sh
. "$SCRIPT_DIR/countdown-config.sh"
countdown_load_config

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | cut -d'"' -f4)
PROJECT=$(basename "${CWD:-unknown}" 2>/dev/null || echo "unknown")
# Escape backslashes for JSON output
CWD_JSON=$(echo "$CWD" | sed 's/\\/\\\\/g')

STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

TIMER_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.json"
ALERT_MARKER="$STATE_DIR/cache-alert-fired-${SESSION_ID}.flag"
TIMESTAMP_EPOCH_NS=$(countdown_now_epoch_ns)
TIMESTAMP=$(countdown_iso_from_epoch_ns "$TIMESTAMP_EPOCH_NS")

# Clear the alert marker so the next Stop cycle can fire fresh.
rm -f "$ALERT_MARKER" 2>/dev/null || true

# Read existing fields if file exists, preserve them
HOST_PID=0
EXISTING_CWD=""
if [ -f "$TIMER_FILE" ]; then
    existing_pid=$(grep -o '"host_pid":[0-9]*' "$TIMER_FILE" 2>/dev/null | grep -o '[0-9]*' || true)
    if [ -n "$existing_pid" ]; then
        HOST_PID=$existing_pid
    fi
    existing_project=$(grep -o '"project":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || true)
    if [ -n "$existing_project" ]; then
        PROJECT=$existing_project
    fi
    EXISTING_CWD=$(grep -o '"cwd":"[^"]*"' "$TIMER_FILE" 2>/dev/null | cut -d'"' -f4 || true)
fi
# Prefer cwd from hook input, fall back to existing
FINAL_CWD="${CWD_JSON:-$EXISTING_CWD}"

# Write timer file with stopped=false FIRST (before any PID discovery)
printf '{"timestamp":"%s","timestamp_epoch_ns":%s,"session_id":"%s","project":"%s","host_pid":%d,"claude_pid":%d,"stopped":false,"cwd":"%s"}' \
    "$TIMESTAMP" "$TIMESTAMP_EPOCH_NS" "$SESSION_ID" "$PROJECT" "$HOST_PID" "$CLAUDE_PID" "$FINAL_CWD" > "$TIMER_FILE"
countdown_debug_log resume "marked active session=$SESSION_ID project=$PROJECT host_pid=$HOST_PID"

# Best-effort: discover host PID if not already known
if [ "$HOST_PID" -eq 0 ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        _pid=$$
        for _ in $(seq 1 10); do
            _ppid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ') || break
            [ -z "$_ppid" ] && break
            _name=$(ps -o comm= -p "$_ppid" 2>/dev/null | tr -d ' ') || break
            case "$_name" in
                *Terminal*|*iTerm*|*alacritty*|*wezterm*|*kitty*|*Warp*)
                    HOST_PID=$_pid; break ;;
            esac
            _pid=$_ppid
        done
    elif [ -d "/proc/$$" ]; then
        _pid=$$
        for _ in $(seq 1 10); do
            _ppid=$(awk '{print $4}' "/proc/$_pid/stat" 2>/dev/null) || break
            [ -z "$_ppid" ] || [ "$_ppid" = "0" ] && break
            _name=$(cat "/proc/$_ppid/comm" 2>/dev/null) || break
            case "$_name" in
                *terminal*|*tmux*|*screen*|*alacritty*|*wezterm*|*kitty*|*konsole*|*gnome-t*|*[Ww]arp*)
                    HOST_PID=$_pid; break ;;
            esac
            _pid=$_ppid
        done
    fi

    # Re-write with PID if we found it
    if [ "$HOST_PID" -ne 0 ]; then
        printf '{"timestamp":"%s","timestamp_epoch_ns":%s,"session_id":"%s","project":"%s","host_pid":%d,"claude_pid":%d,"stopped":false,"cwd":"%s"}' \
            "$TIMESTAMP" "$TIMESTAMP_EPOCH_NS" "$SESSION_ID" "$PROJECT" "$HOST_PID" "$CLAUDE_PID" "$FINAL_CWD" > "$TIMER_FILE"
        countdown_debug_log resume "updated host pid session=$SESSION_ID host_pid=$HOST_PID"
    fi
fi

# Clean up stale timer files from other sessions sharing the same host_pid
if [ "$HOST_PID" -ne 0 ]; then
    for f in "$STATE_DIR"/cache-timer-*.json; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "cache-timer-${SESSION_ID}.json" ] && continue
        other_pid=$(grep -o '"host_pid":[0-9]*' "$f" 2>/dev/null | grep -o '[0-9]*' || true)
        if [ "$other_pid" = "$HOST_PID" ]; then
            stale_session=$(basename "$f" .json)
            stale_session="${stale_session#cache-timer-}"
            rm -f "$f" "$STATE_DIR/cache-alert-fired-${stale_session}.flag" 2>/dev/null
            countdown_debug_log resume "removed stale timer file session=$SESSION_ID stale=$(basename "$f") host_pid=$HOST_PID"
        fi
    done
fi

exit 0
