#!/usr/bin/env bash
# Status line wrapper for Claude Code — appends countdown and at-risk segments,
# and fires the 60-second alert sound directly (no separate watcher process).
#
# Reads the same JSON stdin that Claude Code sends to statusLine commands.
# If an original status line command was saved during install, runs it first
# and appends countdown/cost segments. Otherwise outputs only those segments.
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

# --- Compute countdown and cache risk display, fire alert if due ---
COUNTDOWN_SEGMENTS=$(
    INPUT_JSON="$INPUT" \
    CACHE_TTL_SECONDS="$CACHE_TTL_SECONDS" \
    STATUSLINE_DISPLAY_MODE="$STATUSLINE_DISPLAY_MODE" \
    ENABLE_ALERTS="$ENABLE_ALERTS" \
    ALERT_60S_SOUND="$ALERT_60S_SOUND" \
    STATE_DIR="$STATE_DIR" \
    python3 <<'PY' 2>/dev/null || true
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

try:
    payload = json.loads(os.environ["INPUT_JSON"])
except Exception:
    raise SystemExit(0)

def as_int(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0

ttl_seconds = as_int(os.environ.get("CACHE_TTL_SECONDS"))
segments = []
expired = False

def iso_to_epoch_ns(value):
    try:
        ts = str(value).strip()
        if ts.endswith("Z"):
            ts = ts[:-1]
        frac = "0"
        if "." in ts:
            ts, frac = ts.split(".", 1)
        frac = (frac + "000000000")[:9]
        dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        return int(dt.timestamp()) * 1_000_000_000 + int(frac)
    except Exception:
        return 0

session_id = payload.get("session_id") or ""
state_dir = Path(os.environ.get("STATE_DIR") or (Path.home() / ".claude" / "state"))
remaining_seconds = None
timer_stopped = False

if session_id and ttl_seconds > 0:
    timer_file = state_dir / f"cache-timer-{session_id}.json"
    try:
        timer = json.loads(timer_file.read_text(encoding="utf-8"))
    except Exception:
        timer = {}

    if timer.get("stopped") is True:
        timer_stopped = True
        stopped_ns = as_int(timer.get("timestamp_epoch_ns")) or iso_to_epoch_ns(timer.get("timestamp", ""))
        if stopped_ns > 0:
            remaining_ns = (ttl_seconds * 1_000_000_000) - (time.time_ns() - stopped_ns)
            if remaining_ns > 0:
                remaining_seconds = (remaining_ns + 999_999_999) // 1_000_000_000
                mins, secs = divmod(remaining_seconds, 60)
                segments.append(f"⏱ {mins}:{secs:02d} cache")
            else:
                expired = True
                segments.append("⚠️ Cache Expired")

usage = ((payload.get("context_window") or {}).get("current_usage") or {})

input_tokens = as_int(usage.get("input_tokens"))
cache_create = as_int(usage.get("cache_creation_input_tokens"))
cache_read = as_int(usage.get("cache_read_input_tokens"))
total = input_tokens + cache_create + cache_read

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

if total > 0:
    # Opus 4.7 bills the full 1M context window at standard pricing — no
    # 200K cliff. Rate is the cache-write-minus-cache-read delta in cents
    # per million tokens, TTL-aware.
    rate_cents = 950 if ttl_seconds == 3600 else 575

    cost_cents = total * rate_cents // 1_000_000
    display_mode = os.environ.get("STATUSLINE_DISPLAY_MODE", "dollars")

    if display_mode == "tokens":
        suffix = "tokens expired" if expired else "tokens at risk"
        risk_str = f"{format_tokens(total)} {suffix}"
    elif cost_cents > 0:
        suffix = "recache cost" if expired else "at risk"
        risk_str = f"${cost_cents // 100}.{cost_cents % 100:02d} {suffix}"
    else:
        risk_str = ""

    if risk_str:
        if cost_cents > 1000:
            risk_str = colorize(risk_str, "31")
        elif cost_cents > 500:
            risk_str = colorize(risk_str, "38;5;208" if supports_256 else "33")
        elif cost_cents > 250:
            risk_str = colorize(risk_str, "33")
        segments.append(risk_str)

# ---------------------------------------------------------------------------
# Alert firing — replaces the old cache-alert-watch.sh background watcher.
# Fires at most once per Stop cycle. The marker file is cleared by the
# UserPromptSubmit hook (cache-timer-resume.sh) and the SessionStart /clear
# hook (cache-timer-clear.sh) so a fresh cycle can fire again.
# ---------------------------------------------------------------------------
def _maybe_fire_alert():
    if os.environ.get("ENABLE_ALERTS", "true") != "true":
        return
    if not session_id or not timer_stopped:
        return
    if remaining_seconds is None or remaining_seconds > 60 or remaining_seconds <= 0:
        return
    # Don't fire if there's nothing actually at risk — covers post-/clear
    # ticks where the timer file lingers but context_window has been reset.
    if total <= 0:
        return

    sound = os.environ.get("ALERT_60S_SOUND") or ""
    if not sound or not shutil.which("afplay") or not os.path.isfile(sound):
        return

    marker = state_dir / f"cache-alert-fired-{session_id}.flag"
    try:
        # O_EXCL gives us atomic "create only if absent" — two concurrent
        # status-line refreshes can't both fire the sound.
        fd = os.open(str(marker), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return
    except OSError:
        return
    try:
        os.write(fd, b"")
    finally:
        os.close(fd)

    try:
        subprocess.Popen(
            ["afplay", sound],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        # If we couldn't actually launch afplay, drop the marker so a future
        # tick can retry rather than silently swallowing the alert.
        try:
            marker.unlink()
        except OSError:
            pass

_maybe_fire_alert()

print(" | ".join(segments), end="")
PY
)

# --- Combine output ---
if [ -n "$ORIGINAL_OUTPUT" ] && [ -n "$COUNTDOWN_SEGMENTS" ]; then
    printf '%s | %s' "$ORIGINAL_OUTPUT" "$COUNTDOWN_SEGMENTS"
elif [ -n "$ORIGINAL_OUTPUT" ]; then
    printf '%s' "$ORIGINAL_OUTPUT"
elif [ -n "$COUNTDOWN_SEGMENTS" ]; then
    printf '%s' "$COUNTDOWN_SEGMENTS"
fi
