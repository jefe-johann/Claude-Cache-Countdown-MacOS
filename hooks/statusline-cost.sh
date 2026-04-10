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
        ORIGINAL_OUTPUT=$(echo "$INPUT" | bash -c "$original_cmd" 2>/dev/null) || true
    fi
fi

# --- Compute cache cost-at-risk ---
COST_STR=""
if command -v jq &>/dev/null; then
    input_tokens=$(echo "$INPUT" | jq -r '.context_window.current_usage.input_tokens // 0' 2>/dev/null) || input_tokens=0
    cache_create=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0' 2>/dev/null) || cache_create=0
    cache_read=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0' 2>/dev/null) || cache_read=0

    total=$(( input_tokens + cache_create + cache_read ))

    if [ "$total" -gt 0 ] 2>/dev/null; then
        # Opus pricing: >200K tokens uses higher tier
        # delta_per_mtok: write_cost - read_cost
        #   <=200K: $6.25 - $0.50 = $5.75
        #   >200K:  $12.50 - $1.00 = $11.50
        if [ "$total" -gt 200000 ]; then
            # $11.50 per MTok — use integer math: cost_cents = total * 1150 / 1000000
            cost_cents=$(( total * 1150 / 1000000 ))
        else
            # $5.75 per MTok — cost_cents = total * 575 / 1000000
            cost_cents=$(( total * 575 / 1000000 ))
        fi

        if [ "$cost_cents" -gt 0 ]; then
            dollars=$(( cost_cents / 100 ))
            cents=$(( cost_cents % 100 ))
            COST_STR=$(printf '$%d.%02d at risk' "$dollars" "$cents")
        fi
    fi
fi

# --- Combine output ---
if [ -n "$ORIGINAL_OUTPUT" ] && [ -n "$COST_STR" ]; then
    printf '%s | %s' "$ORIGINAL_OUTPUT" "$COST_STR"
elif [ -n "$ORIGINAL_OUTPUT" ]; then
    printf '%s' "$ORIGINAL_OUTPUT"
elif [ -n "$COST_STR" ]; then
    printf '%s' "$COST_STR"
fi
