#!/usr/bin/env python3
"""Basic tests for cache_countdown.py"""
import json
import os
import sys
import tempfile
import shutil
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Patch STATE_DIR before importing
TEST_DIR = Path(tempfile.mkdtemp(prefix="cache-countdown-test-"))

import cache_countdown
cache_countdown.STATE_DIR = TEST_DIR

passed = 0
failed = 0

def test(name, condition):
    global passed, failed
    if condition:
        print(f"  PASS  {name}")
        passed += 1
    else:
        print(f"  FAIL  {name}")
        failed += 1


def write_timer(session_id, project="testapp", seconds_ago=0, host_pid=0, stopped=True):
    ts = datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)
    data = {
        "timestamp": ts.isoformat(),
        "session_id": session_id,
        "project": project,
        "host_pid": host_pid,
    }
    if stopped is not None:
        data["stopped"] = stopped
    path = TEST_DIR / f"cache-timer-{session_id}.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


# --- Tests ---

print("\n=== format_countdown ===")
test("5:00 at full TTL", cache_countdown.format_countdown(300) == "5:00")
test("4:55 at 295s", cache_countdown.format_countdown(295) == "4:55")
test("0:01 at 1s", cache_countdown.format_countdown(1) == "0:01")
test("0:00 at 0s", cache_countdown.format_countdown(0) == "COLD")
test("COLD at negative", cache_countdown.format_countdown(-5) == "COLD")

print("\n=== get_icon ===")
test("green at >50%", cache_countdown.get_icon(200, 295) == "\U0001f7e2")
test("yellow at 20-50%", cache_countdown.get_icon(100, 295) == "\U0001f7e1")
test("red at <20%", cache_countdown.get_icon(30, 295) == "\U0001f534")
test("snowflake at 0", cache_countdown.get_icon(0, 295) == "\u2744")
test("snowflake at negative", cache_countdown.get_icon(-10, 295) == "\u2744")

print("\n=== read_cache_timers ===")
# Clean slate
for f in TEST_DIR.glob("cache-timer-*.json"):
    f.unlink()

test("empty dir returns empty list", len(cache_countdown.read_cache_timers()) == 0)

write_timer("sess-1", "projectA", seconds_ago=60)
test("reads one timer file", len(cache_countdown.read_cache_timers()) == 1)

write_timer("sess-2", "projectB", seconds_ago=120)
test("reads two timer files", len(cache_countdown.read_cache_timers()) == 2)

sessions = cache_countdown.read_cache_timers()
s1 = [s for s in sessions if s["session_id"] == "sess-1"][0]
test("correct project name", s1["project"] == "projectA")
test("stopped is True", s1["stopped"] is True)

print("\n=== compute_remaining ===")
write_timer("sess-fresh", seconds_ago=10)
sessions = cache_countdown.read_cache_timers()
fresh = [s for s in sessions if s["session_id"] == "sess-fresh"][0]
remaining = cache_countdown.compute_remaining(fresh, 295)
test("fresh timer has ~285s remaining", 280 < remaining < 290)

write_timer("sess-old", seconds_ago=400)
sessions = cache_countdown.read_cache_timers()
old = [s for s in sessions if s["session_id"] == "sess-old"][0]
remaining = cache_countdown.compute_remaining(old, 295)
test("expired timer has negative remaining", remaining < 0)

print("\n=== three states ===")
for f in TEST_DIR.glob("cache-timer-*.json"):
    f.unlink()

write_timer("stopped-sess", stopped=True, seconds_ago=60)
write_timer("active-sess", stopped=False, seconds_ago=0)
write_timer("unknown-sess", stopped=None, seconds_ago=30)

sessions = cache_countdown.read_cache_timers()
stopped = [s for s in sessions if s["session_id"] == "stopped-sess"][0]
active = [s for s in sessions if s["session_id"] == "active-sess"][0]
unknown = [s for s in sessions if s["session_id"] == "unknown-sess"][0]

test("stopped=True detected", stopped["stopped"] is True)
test("stopped=False detected", active["stopped"] is False)
test("stopped=None detected", unknown["stopped"] is None)

print("\n=== timer file lifecycle ===")
for f in TEST_DIR.glob("cache-timer-*.json"):
    f.unlink()

# Stop creates file
path = write_timer("lifecycle-test", stopped=True)
test("stop creates timer file", path.exists())

# Resume deletes file
path.unlink()
test("resume deletes timer file", not path.exists())
test("no sessions after delete", len(cache_countdown.read_cache_timers()) == 0)

print("\n=== malformed files ===")
bad_path = TEST_DIR / "cache-timer-bad.json"
bad_path.write_text("not json at all", encoding="utf-8")
test("malformed JSON is skipped", len(cache_countdown.read_cache_timers()) == 0)
bad_path.unlink()

bad_path.write_text('{"session_id":"x"}', encoding="utf-8")
test("missing timestamp is skipped", len(cache_countdown.read_cache_timers()) == 0)
bad_path.unlink()

# --- Cleanup ---
shutil.rmtree(TEST_DIR, ignore_errors=True)

print(f"\n{'='*40}")
print(f"Results: {passed} passed, {failed} failed")
if failed > 0:
    sys.exit(1)
print("All tests passed.")
