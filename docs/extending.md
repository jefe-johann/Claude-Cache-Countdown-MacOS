# Extending Claude Cache Countdown

The tool is split into two small pieces that communicate through simple JSON files in `~/.claude/state/`:

- **Hooks** — write and update one JSON file per session
- **Status line wrapper** — reads the timer file, appends the countdown plus cost-at-risk segment to Claude Code's status line, and plays the 60-second sound once when the cache is about to expire (gated by a `cache-alert-fired-{session_id}.flag` marker)

This separation makes it easy to swap any piece for your own implementation, or drive the countdown from something other than Claude Code entirely.

## Timer file format

The Stop hook writes one JSON file per session to `~/.claude/state/cache-timer-{session_id}.json`:

```json
{
  "timestamp": "2026-03-14T10:35:00.123456789Z",
  "timestamp_epoch_ns": 1773484500123456789,
  "session_id": "e861c4a2-5b5a-4eb3-99cd-e71c9e6b6983",
  "project": "myapp",
  "host_pid": 12345,
  "claude_pid": 23456,
  "stopped": true,
  "cwd": "/Users/you/code/myapp"
}
```

| Field | Meaning |
|-------|---------|
| `timestamp` | When the state last changed (UTC ISO 8601) |
| `timestamp_epoch_ns` | Optional high-resolution Unix timestamp in nanoseconds. The status line uses this when present for smoother second boundaries |
| `session_id` | Claude Code session identifier; used as the filename suffix |
| `project` | Display label retained for integrations (typically the basename of `cwd`) |
| `host_pid` | PID of the terminal-tab process; `0` if detection failed. Used for per-tab session tracking |
| `claude_pid` | PID of the Claude CLI process that owns this session; `0` if unknown. Reserved for callers; the bundled status line ignores it (a `/quit` is naturally handled by Claude Code unloading the status line altogether) |
| `stopped` | `true` = cache draining (show countdown), `false` = agent working |
| `cwd` | Session's working directory |

The status line calculates remaining time from `timestamp_epoch_ns` when available, or falls back to `timestamp` for older/custom timer files. When the TTL expires, it shows `⚠️ Cache Expired`. When `stopped` is `false`, the countdown segment disappears.

Stale files from sessions that ended abruptly accumulate here and can be deleted manually.

## Writing your own hooks

If you want to wire the countdown into something other than Claude Code's hooks, you only need two actions:

1. **On session stop:** write `~/.claude/state/cache-timer-{session_id}.json` with `stopped: true` and `timestamp` set to now.
2. **On user input or session resume:** update the same file with `stopped: false` and `timestamp` set to now.

Optional but useful fields:

- `timestamp_epoch_ns` — improves countdown smoothness by preserving sub-second timing. If you omit it, the status line falls back to `timestamp`.
- `host_pid` — enables per-tab session tracking for stale timer cleanup. Set to `0` if you can't detect it.
- `claude_pid` — PID of the long-running process that owns the session. Not consumed by the bundled status line; left in the schema for callers who want to plug in their own watcher and need to detect a vanished host process.
- `cwd` — the session's working directory. Helps preserve project context and detect session resets.

## Driving the timer from a script

You don't need any hook integration at all to use the countdown. Any script can write the JSON file directly:

```bash
# Start a countdown (agent stopped, cache draining)
echo '{"timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","session_id":"manual","project":"myapp","host_pid":0,"stopped":true,"cwd":"'$PWD'"}' \
  > ~/.claude/state/cache-timer-manual.json

# Mark as active (agent working, cache refreshing)
echo '{"timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","session_id":"manual","project":"myapp","host_pid":0,"stopped":false,"cwd":"'$PWD'"}' \
  > ~/.claude/state/cache-timer-manual.json
```

For Claude Code status line display, the file suffix must match the current status line JSON `session_id`. The bundled status line plays the 60-second sound itself when it sees a stopped timer file with `≤ 60s` remaining and live token usage in the payload — no extra process needed. If you're driving the timer file from outside Claude Code, delete `~/.claude/state/cache-alert-fired-{session_id}.flag` whenever you reset the timer so the next cycle can fire fresh.

## Terminal compatibility

The status-line migration intentionally avoids direct TTY writes. There are no tab-title escape codes, terminal bells, or Warp-specific nudges. Sound alerts use `afplay` on macOS when the configured sound file is readable; otherwise the alert is skipped.
