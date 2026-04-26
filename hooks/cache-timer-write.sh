#!/usr/bin/env bash
# Stop hook for Claude Code - writes a cache timer file when the agent stops.
# The status line reads this file to show how long until the cache expires.
#
# Install: Add to ~/.claude/settings.json under hooks.Stop
#
# Works on macOS and Linux.
# No dependencies beyond bash and standard Unix tools.

set -euo pipefail

# $PPID here is the Claude CLI process that invoked this hook.
CLAUDE_PID="${PPID:-0}"

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
            *Terminal*|*iTerm*|*alacritty*|*wezterm*|*kitty*|*Warp*)
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
            *terminal*|*tmux*|*screen*|*alacritty*|*wezterm*|*kitty*|*konsole*|*gnome-t*|*[Ww]arp*)
                HOST_PID=$_pid; break ;;
        esac
        _pid=$_ppid
    done
fi

# Write timer file
printf '{"timestamp":"%s","timestamp_epoch_ns":%s,"session_id":"%s","project":"%s","host_pid":%d,"claude_pid":%d,"stopped":true,"cwd":"%s"}' \
    "$TIMESTAMP" "$TIMESTAMP_EPOCH_NS" "$SESSION_ID" "$PROJECT" "$HOST_PID" "$CLAUDE_PID" "${CWD_JSON:-}" > "$TIMER_FILE"
countdown_debug_log stop "wrote timer session=$SESSION_ID project=$PROJECT host_pid=$HOST_PID claude_pid=$CLAUDE_PID file=$TIMER_FILE"

exit 0
