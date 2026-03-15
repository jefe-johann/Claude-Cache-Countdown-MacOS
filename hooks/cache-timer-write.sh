#!/usr/bin/env bash
# Stop hook for Claude Code - writes a cache timer file when the agent stops.
# The countdown ticker reads this file to show how long until the cache expires.
#
# Install: Add to ~/.claude/settings.json under hooks.Stop
#
# Works on macOS, Linux, and Windows (Git Bash/MSYS).
# No dependencies beyond bash and standard Unix tools.

set -euo pipefail

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

# State directory
STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

TIMER_FILE="$STATE_DIR/cache-timer-${SESSION_ID}.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

# Find host PID: walk up process tree looking for a terminal emulator.
# The host PID is the process directly under the terminal emulator,
# which is the process that owns the console/tab.
# This is optional - set to 0 if detection fails. Only needed for
# the Windows Terminal display backend.
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

# Write timer file immediately (before context parsing which may be slow)
printf '{"timestamp":"%s","session_id":"%s","project":"%s","host_pid":%d,"stopped":true}' \
    "$TIMESTAMP" "$SESSION_ID" "$PROJECT" "$HOST_PID" > "$TIMER_FILE"

# Best-effort: read context size for cost display
# Tier 1: statusline data file
# Tier 2: transcript file (last entry with token usage)
CONTEXT_TOKENS=0
EXCEEDS_200K=false

SL_FILE="$STATE_DIR/statusline-data-${SESSION_ID}.json"
if [ -f "$SL_FILE" ]; then
    # Extract token counts from statusline data
    _input=$(grep -o '"input_tokens":[0-9]*' "$SL_FILE" 2>/dev/null | tail -1 | grep -o '[0-9]*' || echo 0)
    _creation=$(grep -o '"cache_creation_input_tokens":[0-9]*' "$SL_FILE" 2>/dev/null | tail -1 | grep -o '[0-9]*' || echo 0)
    _read=$(grep -o '"cache_read_input_tokens":[0-9]*' "$SL_FILE" 2>/dev/null | tail -1 | grep -o '[0-9]*' || echo 0)
    CONTEXT_TOKENS=$(( ${_input:-0} + ${_creation:-0} + ${_read:-0} ))
    if grep -q '"exceeds_200k_tokens":true' "$SL_FILE" 2>/dev/null; then
        EXCEEDS_200K=true
    fi
fi

if [ "$CONTEXT_TOKENS" -eq 0 ] && [ -n "$CWD" ]; then
    # Tier 2: parse transcript
    PROJECT_SLUG=$(echo "$CWD" | sed 's|[/\\]|-|g; s|:||g; s|^-||')
    TRANSCRIPT="$HOME/.claude/projects/$PROJECT_SLUG/${SESSION_ID}.jsonl"
    if [ -f "$TRANSCRIPT" ]; then
        _line=$(grep 'cache_read_input_tokens' "$TRANSCRIPT" 2>/dev/null | tail -1)
        if [ -n "$_line" ]; then
            _input=$(echo "$_line" | grep -o '"input_tokens":[0-9]*' | head -1 | grep -o '[0-9]*' || echo 0)
            _creation=$(echo "$_line" | grep -o '"cache_creation_input_tokens":[0-9]*' | head -1 | grep -o '[0-9]*' || echo 0)
            _read=$(echo "$_line" | grep -o '"cache_read_input_tokens":[0-9]*' | head -1 | grep -o '[0-9]*' || echo 0)
            CONTEXT_TOKENS=$(( ${_input:-0} + ${_creation:-0} + ${_read:-0} ))
            if [ "$CONTEXT_TOKENS" -gt 200000 ]; then
                EXCEEDS_200K=true
            fi
        fi
    fi
fi

if [ "$CONTEXT_TOKENS" -gt 0 ]; then
    printf '{"timestamp":"%s","session_id":"%s","project":"%s","host_pid":%d,"stopped":true,"context_tokens":%d,"exceeds_200k":%s}' \
        "$TIMESTAMP" "$SESSION_ID" "$PROJECT" "$HOST_PID" "$CONTEXT_TOKENS" "$EXCEEDS_200K" > "$TIMER_FILE"
fi

exit 0
