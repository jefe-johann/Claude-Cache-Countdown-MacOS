# Extending Claude Cache Countdown

The tool is split into three small pieces that communicate through simple JSON files in `~/.claude/state/`:

- **Hooks** — write and update one JSON file per session
- **Background ticker** — reads a session's timer file and updates the terminal tab title
- **Status line wrapper** — appends the cost-at-risk segment to Claude Code's status line

This separation makes it easy to swap any piece for your own implementation, or drive the countdown from something other than Claude Code entirely.

## Timer file format

The Stop hook writes one JSON file per session to `~/.claude/state/cache-timer-{session_id}.json`:

```json
{
  "timestamp": "2026-03-14T10:35:00.000Z",
  "session_id": "e861c4a2-5b5a-4eb3-99cd-e71c9e6b6983",
  "project": "myapp",
  "host_pid": 12345,
  "stopped": true,
  "cwd": "/Users/you/code/myapp"
}
```

| Field | Meaning |
|-------|---------|
| `timestamp` | When the state last changed (UTC ISO 8601) |
| `session_id` | Claude Code session identifier; used as the filename suffix |
| `project` | Display label for the tab title (typically the basename of `cwd`) |
| `host_pid` | PID of the terminal-tab process; `0` if detection failed. Used for per-tab session tracking |
| `stopped` | `true` = cache draining (show countdown), `false` = agent working (release the title) |
| `cwd` | Session's working directory |

The ticker calculates `remaining = CACHE_TTL_SECONDS - (now - timestamp)`. It polls a few times per second so slight scheduler drift does not skip visible countdown seconds, and only rewrites the tab title when the displayed text changes. When `stopped` is `false`, the ticker stops writing custom titles so the terminal can reclaim them.

Stale files from sessions that ended abruptly accumulate here and can be deleted manually.

## Writing your own hooks

If you want to wire the countdown into something other than Claude Code's hooks, you only need two actions:

1. **On session stop:** write `~/.claude/state/cache-timer-{session_id}.json` with `stopped: true` and `timestamp` set to now.
2. **On user input or session resume:** update the same file with `stopped: false` and `timestamp` set to now.

Optional but useful fields:

- `host_pid` — enables per-tab session tracking and lets the ticker kill stale tickers on the same TTY. Set to `0` if you can't detect it.
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

You'll need to launch `hooks/cache-timer-bg.sh` yourself in this case — the included Stop hook is what normally launches it.

## Adapting to non-Warp terminals

The ticker writes OSC escape codes (`\033]0;...\007`) directly to the discovered TTY device, which most terminal emulators honor for tab titles. For Warp specifically, the Stop hook launches the background ticker with `WARP_DISABLE_AUTO_TITLE=true` set in the ticker process only — that keeps Warp's normal auto-title behavior while Claude is responding, and gives the countdown clean ownership of the title during cache-drain time.

If you're on a different terminal, you can usually leave that env var alone; the OSC writes go to the TTY directly and your terminal will pick them up. If your terminal has its own auto-title behavior that fights the countdown, look for an equivalent of `WARP_DISABLE_AUTO_TITLE` for your environment.
