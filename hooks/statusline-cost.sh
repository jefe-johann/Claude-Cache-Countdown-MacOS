#!/usr/bin/env bash
# Status line wrapper for Claude Code — appends the configured at-risk segment.
#
# Reads the same JSON stdin that Claude Code sends to statusLine commands.
# If an original status line command was saved during install, runs it first
# and appends the at-risk segment. Otherwise outputs only the at-risk segment.
#
# Installed by install.sh. Original command backed up to:
#   ~/.claude/state/cache-countdown-original-statusline.txt

set -euo pipefail

STATE_DIR="$HOME/.claude/state"
ORIGINAL_CMD_FILE="$STATE_DIR/cache-countdown-original-statusline.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=hooks/countdown-config.sh
. "$SCRIPT_DIR/countdown-config.sh"
countdown_load_config

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

# --- Compute cache risk display ---
RISK_STR=$(
    INPUT_JSON="$INPUT" CACHE_TTL_SECONDS="$CACHE_TTL_SECONDS" STATUSLINE_DISPLAY_MODE="$STATUSLINE_DISPLAY_MODE" python3 <<'PY' 2>/dev/null || true
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

ttl_seconds = as_int(os.environ.get("CACHE_TTL_SECONDS"))
if ttl_seconds == 3600:
    rate_cents = 1900 if total > 200_000 else 950
else:
    rate_cents = 1150 if total > 200_000 else 575

cost_cents = total * rate_cents // 1_000_000
display_mode = os.environ.get("STATUSLINE_DISPLAY_MODE", "dollars")

term = os.environ.get("TERM", "")
colorterm = os.environ.get("COLORTERM", "")
supports_256 = "256" in term or colorterm in {"truecolor", "24bit"}

def colorize(text, code):
    if os.environ.get("NO_COLOR"):
        return text
    return f"\033[{code}m{text}\033[0m"

def format_tokens(token_count):
    if token_count >= 1_000_000:
        value = token_count / 1_000_000
        suffix = "M"
    elif token_count >= 1_000:
        value = token_count / 1_000
        suffix = "K"
    else:
        return f"{token_count:,}"

    if value.is_integer():
        return f"{int(value)}{suffix}"
    return f"{value:.1f}".rstrip("0").rstrip(".") + suffix

if display_mode == "tokens":
    risk_str = f"{format_tokens(total)} tokens at risk"
elif cost_cents > 0:
    risk_str = f"${cost_cents // 100}.{cost_cents % 100:02d} at risk"
else:
    risk_str = ""

if risk_str:
    if cost_cents > 1000:
        risk_str = colorize(risk_str, "31")
    elif cost_cents > 500:
        risk_str = colorize(risk_str, "38;5;208" if supports_256 else "33")
    elif cost_cents > 250:
        risk_str = colorize(risk_str, "33")
    print(risk_str, end="")
PY
)

# --- Combine output ---
if [ -n "$ORIGINAL_OUTPUT" ] && [ -n "$RISK_STR" ]; then
    printf '%s | %s' "$ORIGINAL_OUTPUT" "$RISK_STR"
elif [ -n "$ORIGINAL_OUTPUT" ]; then
    printf '%s' "$ORIGINAL_OUTPUT"
elif [ -n "$RISK_STR" ]; then
    printf '%s' "$RISK_STR"
fi
