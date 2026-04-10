#!/usr/bin/env bash
# Status line wrapper for Claude Code — appends cache cost-at-risk.
#
# Reads the same JSON stdin that Claude Code sends to statusLine commands.
# If an original status line command was saved during install, runs it first
# and appends the cost segment. Otherwise outputs only the cost.
#
# Installed by install.sh. Original command backed up to:
#   ~/.claude/state/cache-countdown-original-statusline.txt

set -euo pipefail

STATE_DIR="$HOME/.claude/state"
ORIGINAL_CMD_FILE="$STATE_DIR/cache-countdown-original-statusline.txt"

# Read full stdin (JSON from Claude Code)
INPUT=$(cat)

# --- Run original status line command, if any ---
ORIGINAL_OUTPUT=""
if [ -f "$ORIGINAL_CMD_FILE" ]; then
    original_cmd=$(cat "$ORIGINAL_CMD_FILE")
    if [ -n "$original_cmd" ]; then
        ORIGINAL_OUTPUT=$(printf '%s' "$INPUT" | bash -c "$original_cmd" 2>/dev/null) || true
    fi
fi

# --- Compute cache cost-at-risk ---
COST_STR=$(
    INPUT_JSON="$INPUT" python3 <<'PY' 2>/dev/null || true
import json
import os

try:
    payload = json.loads(os.environ["INPUT_JSON"])
except Exception:
    raise SystemExit(0)

usage = ((payload.get("context_window") or {}).get("current_usage") or {})

def as_int(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0

input_tokens = as_int(usage.get("input_tokens"))
cache_create = as_int(usage.get("cache_creation_input_tokens"))
cache_read = as_int(usage.get("cache_read_input_tokens"))
total = input_tokens + cache_create + cache_read

if total <= 0:
    raise SystemExit(0)

rate_cents = 1150 if total > 200_000 else 575
cost_cents = total * rate_cents // 1_000_000

term = os.environ.get("TERM", "")
colorterm = os.environ.get("COLORTERM", "")
supports_256 = "256" in term or colorterm in {"truecolor", "24bit"}

def colorize(text, code):
    if os.environ.get("NO_COLOR"):
        return text
    return f"\033[{code}m{text}\033[0m"

if cost_cents > 0:
    cost_str = f"${cost_cents // 100}.{cost_cents % 100:02d} at risk"
    if cost_cents > 1000:
        cost_str = colorize(cost_str, "31")
    elif cost_cents > 500:
        cost_str = colorize(cost_str, "38;5;208" if supports_256 else "33")
    elif cost_cents > 250:
        cost_str = colorize(cost_str, "33")
    print(cost_str, end="")
PY
)

# --- Combine output ---
if [ -n "$ORIGINAL_OUTPUT" ] && [ -n "$COST_STR" ]; then
    printf '%s | %s' "$ORIGINAL_OUTPUT" "$COST_STR"
elif [ -n "$ORIGINAL_OUTPUT" ]; then
    printf '%s' "$ORIGINAL_OUTPUT"
elif [ -n "$COST_STR" ]; then
    printf '%s' "$COST_STR"
fi
