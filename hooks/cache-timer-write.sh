#!/usr/bin/env bash
# Stop hook for Claude Code - writes a cache timer file when the agent stops.
# The countdown ticker reads this file to show how long until the cache expires.
#
# Install: Add to ~/.claude/settings.json under hooks.Stop
#
# Works on macOS and Linux.
# No dependencies beyond bash and standard Unix tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=hooks/countdown-config.sh
. "$SCRIPT_DIR/countdown-config.sh"
countdown_load_config

# Read hook input from stdin
INPUT=$(cat)

# Extract session_id and cwd using grep/sed (no python3 dependency)
# Claude Code sends JSON like: {"session_id":"abc-123","cwd":"/path/to/project",...}
SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | cut -d'"' -f4)
PROJECT=$(basename "${CWD:-unknown}" 2>/dev/null || echo "unknown")
# Escape backslashes for JSON output
CWD_JSON=$(echo "$CWD" | sed 's/\\/\\\\/g')

# State directory
STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

TIMER_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.json"
TIMESTAMP_EPOCH_NS=$(countdown_now_epoch_ns)
TIMESTAMP=$(countdown_iso_from_epoch_ns "$TIMESTAMP_EPOCH_NS")

# Find host PID: walk up process tree looking for a terminal emulator.
# The host PID is the process directly under the terminal emulator,
# which is the process that owns the console/tab.
# This is optional - set to 0 if detection fails. It helps keep
# per-terminal session tracking stable.
HOST_PID=0

if [ "$(uname -s)" = "Darwin" ]; then
    # macOS: walk up via ps
    _pid=$$
    for _ in $(seq 1 10); do
        _ppid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ') || break
        [ -z "$_ppid" ] && break
        _name=$(ps -o comm= -p "$_ppid" 2>/dev/null | tr -d ' ') || break
        case "$_name" in
            *Terminal*|*iTerm*|*alacritty*|*wezterm*|*kitty*)
                HOST_PID=$_pid; break ;;
        esac
        _pid=$_ppid
    done
elif [ -d "/proc/$$" ]; then
    # Linux: walk up via /proc
    _pid=$$
    for _ in $(seq 1 10); do
        _ppid=$(awk '{print $4}' "/proc/$_pid/stat" 2>/dev/null) || break
        [ -z "$_ppid" ] || [ "$_ppid" = "0" ] && break
        _name=$(cat "/proc/$_ppid/comm" 2>/dev/null) || break
        case "$_name" in
            *terminal*|*tmux*|*screen*|*alacritty*|*wezterm*|*kitty*|*konsole*|*gnome-t*)
                HOST_PID=$_pid; break ;;
        esac
        _pid=$_ppid
    done
fi

# Write timer file
printf '{"timestamp":"%s","timestamp_epoch_ns":%s,"session_id":"%s","project":"%s","host_pid":%d,"stopped":true,"cwd":"%s"}' \
    "$TIMESTAMP" "$TIMESTAMP_EPOCH_NS" "$SESSION_ID" "$PROJECT" "$HOST_PID" "${CWD_JSON:-}" > "$TIMER_FILE"
countdown_debug_log stop "wrote timer session=$SESSION_ID project=$PROJECT host_pid=$HOST_PID file=$TIMER_FILE"

# Check if ticker is already running for this session
PID_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.pid"
_ticker_running=false
if [ -f "$PID_FILE" ]; then
    _old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
        _pid_mtime=$(countdown_file_mtime_epoch "$PID_FILE" 2>/dev/null || echo "0")
        _script_mtime=$(countdown_file_mtime_epoch "$SCRIPT_DIR/cache-timer-bg.sh" 2>/dev/null || echo "0")
        if [ "$_script_mtime" -gt "$_pid_mtime" ]; then
            kill "$_old_pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            countdown_debug_log stop "restarting ticker after script update session=$SESSION_ID pid=$_old_pid"
        else
            _ticker_running=true
            countdown_debug_log stop "ticker already running session=$SESSION_ID pid=$_old_pid"
        fi
    else
        rm -f "$PID_FILE"
        countdown_debug_log stop "removed stale pid file session=$SESSION_ID pid=${_old_pid:-unknown}"
    fi
fi

# Also kill any other tickers targeting the same TTY (from stale sessions)
# This prevents multiple tickers fighting over the same tab title
_kill_stale_tickers() {
    local tty="$1"
    for pf in "$STATE_DIR"/cache-timer-*.pid; do
        [ -f "$pf" ] || continue
        local pid
        pid=$(cat "$pf" 2>/dev/null) || continue
        [ -n "$pid" ] || continue
        # Check if this process is a cache-timer-bg.sh targeting our TTY
        local cmdline
        cmdline=$(ps -o args= -p "$pid" 2>/dev/null) || { rm -f "$pf"; continue; }
        if echo "$cmdline" | grep -q "cache-timer-bg.sh.*$tty"; then
            kill "$pid" 2>/dev/null || true
            rm -f "$pf"
        fi
    done
}

# Discover the actual TTY device by walking up the process tree.
# Hook subprocesses don't have a controlling terminal (/dev/tty fails),
# but the parent claude/shell process does — find it and write there.
_tty=""
_pid=$$
for _ in $(seq 1 15); do
    _t=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$_t" ] && [ "$_t" != "??" ]; then
        _tty="/dev/$_t"
        break
    fi
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_pid" ] || [ "$_pid" = "0" ] || [ "$_pid" = "1" ] && break
done

# Launch background ticker if not already running for this session
if [ -n "$_tty" ] && [ -w "$_tty" ]; then
    # Warp's Claude integration can occasionally hold onto a stale
    # "Wants to run ..." agent title. Send the same structured stop event
    # Warp's plugin uses, but through the real TTY we discovered above.
    countdown_warp_agent_stop_notify "$_tty" "$SESSION_ID" "$CWD" "$PROJECT"

    if [ "$_ticker_running" = "false" ]; then
        _kill_stale_tickers "$_tty"
        nohup env WARP_DISABLE_AUTO_TITLE=true bash "$SCRIPT_DIR/cache-timer-bg.sh" "$SESSION_ID" "$_tty" </dev/null >/dev/null 2>&1 &
        disown
        countdown_debug_log stop "launched ticker session=$SESSION_ID tty=$_tty warp_disable_auto_title=true"
    fi
else
    countdown_debug_log stop "no writable tty found session=$SESSION_ID tty=${_tty:-missing}"
fi

exit 0
