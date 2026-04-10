# Claude Cache Countdown

Live prompt cache TTL countdown for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. 

> **Acknowledgments:** This project was heavily inspired by [KatsuJinCode/claude-cache-countdown](https://github.com/KatsuJinCode/claude-cache-countdown) by Julian Switzer. Julian's project laid the brilliant groundwork for using Claude Code hooks to track cache state. This repository takes those core concepts and rebuilds the core engine in Bash for a seamless, zero-window terminal experience.

With Claude Opus 4.6's **1 million token context window**, prompt caching has never been more important. Anthropic caches your conversation context server-side for 5 minutes. Cache hits cost 90% less. But when your agent stops, that cache is silently draining, and the stakes are high:

**At 500K tokens (a medium session in the premium pricing tier):**
- Standard cache hit within 5 minutes: **$0.50**
- Cache expired (re-write at 1.25x): **$6.25**
- **Being one second late costs you $5.75.**

And there's a pricing cliff: once your context exceeds 200K tokens, the *entire* request is billed at 2x the standard rate ($10/MTok instead of $5/MTok). A deep 900K session that loses its cache pays $11.25 to re-cache what would have cost $0.90 to read.

This tool shows you exactly how much time you have left.

We couldn't find anything else that does this. Prompt caching is well-documented by Anthropic, but as of March 2026 we're not aware of any tooling that provides live cache TTL visibility for Claude Code or other LLM CLI tools.

![Cache countdown in terminal tabs](img/Screenshot%202026-03-14%20035733.png)

## What it does

- **Fully Automatic Ticker**: A background bash process automatically takes over your terminal tab title exactly when it needs to, no extra python windows to manage.
- **Cost-At-Risk Statusline**: Automatically adds the live dollar value of your cache to Claude Code's native bottom status line.
- **Shows a live countdown** when your agent stops and the cache is draining
- **Warp Terminal Support**: Smoothly integrates with Warp by disabling its aggressive auto-title behavior during Claude sessions so the dynamic countdown can display in the tab title.
- Tracks multiple Claude Code sessions across tabs
- Bash-first runtime, with Python used by the installer and status line wrapper
- Built and used on macOS
- Linux should work in theory, but is currently untested

## Quick Start

### Automatic install

```bash
git clone <your-fork-or-local-url>
cd claude-cache-countdown

bash install.sh
```

The installer adds both hooks and the status line wrapper to your Claude Code settings. Restart Claude Code to load them.

### Manual install

Two hooks:
- **Stop** -- starts the countdown when the agent finishes
- **UserPromptSubmit** -- returns the tab title to the project name when you send a new message

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-cache-countdown/hooks/cache-timer-write.sh'",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-cache-countdown/hooks/cache-timer-resume.sh'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

The installer wires up the hooks, status line wrapper, and background ticker for you. There is no separate ticker command to run.

## How it works

```
Claude Code session is working...     (timer file has stopped=false, tab title shows project name)
    |
    v
Agent stops
    |
    v
Stop hook --------> sets stopped=true, timestamp=now, starts background ticker
    |
    v
Background ticker -> reads timer file every second and writes `⏱ M:SS | project` to the real TTY
    |
    v
User sends new message
    |
    v
Resume hook ------> sets stopped=false, tab title returns to project name
```

While the agent is working, every API call resets the cache. The countdown only matters once the agent stops and the cache begins draining.

### Cost at risk

The status line wrapper shows how much money is at stake if the cache expires. It reads Claude Code's current status line JSON and appends a segment like `$5.75 at risk`.

This is the delta between a cache hit and a cache miss (the extra money you pay because you were late). At 500K tokens on the premium tier, a cache hit costs $0.50 but a miss forces a $6.25 re-write, so you're risking $5.75.


---

The timer currently counts down from 300 seconds (5:00) based on when the Stop hook fires.

## Timer file format

The Stop hook writes one JSON file per session to `~/.claude/state/cache-timer-{session_id}.json`:

```json
{
  "timestamp": "2026-03-14T10:35:00.000Z",
  "session_id": "e861c4a2-5b5a-4eb3-99cd-e71c9e6b6983",
  "project": "myapp",
  "host_pid": 12345,
  "stopped": true
}
```

- `timestamp`: when the state last changed
- `stopped`: `true` = cache draining (show countdown), `false` = agent working (show project title)
- `host_pid`: PID of the process associated with the terminal tab (optional, used for per-tab tracking)

The ticker calculates `remaining = 300 - (now - timestamp)`.

The UserPromptSubmit hook sets `stopped` to `false` when the user resumes. The Stop hook sets it back to `true` when the agent finishes. Stale files can accumulate if sessions end abruptly and can be deleted manually.

## Adapting to your environment

The tool is split into three small pieces: **hooks** (write/update JSON files), **background ticker** (read one session's timer file and update the tab title), and **status line wrapper** (append the cost-at-risk segment). They communicate through simple JSON files in `~/.claude/state/`.

### Writing your own hooks

Two actions:

1. **On session stop:** Write `~/.claude/state/cache-timer-{session_id}.json` with `stopped` set to `true` and `timestamp` set to now.
2. **On user prompt:** Update the same file with `stopped` set to `false` and `timestamp` set to now.

Optional fields:
- `host_pid`: enables per-tab session tracking. Set to `0` if not needed.
- `cwd`: the session's working directory. Helps preserve project context and detect session resets.

### Using without hooks

You can create and update timer files yourself from any script:

```bash
# Start a countdown (agent stopped, cache draining)
echo '{"timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","session_id":"manual","project":"myapp","host_pid":0,"stopped":true,"cwd":"'$PWD'"}' \
  > ~/.claude/state/cache-timer-manual.json

# Mark as active (agent working, cache refreshing)
echo '{"timestamp":"'$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'","session_id":"manual","project":"myapp","host_pid":0,"stopped":false,"cwd":"'$PWD'"}' \
  > ~/.claude/state/cache-timer-manual.json
```

## Prompt caching reference

| TTL | Write cost | Read cost | How to use |
|-----|-----------|-----------|------------|
| 5 minutes (default) | 1.25x base | 0.1x base | Claude Code uses this automatically |
| 1 hour (opt-in) | 2x base | 0.1x base | Requires `"ttl": "1h"` in API call |

### Opus 4.6 pricing tiers

Opus 4.6 has a **pricing cliff at 200K tokens**. If your context exceeds 200K by even one token, the entire request is billed at the premium rate.

| Tier | Input | Cache write (1.25x) | Cache read (0.1x) |
|------|-------|--------------------|--------------------|
| Standard (up to 200K) | $5.00/MTok | $6.25/MTok | $0.50/MTok |
| Premium (200K to 1M) | $10.00/MTok | $12.50/MTok | $1.00/MTok |

### What a cache miss costs

| Context size | Tier | Cache hit | Cache miss (re-write) | Cost of being late |
|-------------|------|-----------|----------------------|-------------------|
| 100K | Standard | $0.05 | $0.63 | $0.58 |
| 200K | Standard | $0.10 | $1.25 | $1.15 |
| 201K | **Premium** | $0.20 | $2.51 | **$2.31** |
| 500K | Premium | $0.50 | $6.25 | **$5.75** |
| 900K | Premium | $0.90 | $11.25 | **$10.35** |
| 1M | Premium | $1.00 | $12.50 | **$11.50** |

Note the jump from 200K to 201K: crossing the threshold doubles the cost of the entire request, not just the overflow.

These numbers reflect **input token costs only**, which is what prompt caching affects. Output tokens ($25-37.50/MTok) are billed the same regardless of cache state.

- Cache reads are 90% cheaper than uncached input
- Each API call that hits the cache resets the TTL timer
- Cache hits improve latency (faster time-to-first-token)
- Cache hits don't count against rate limits
- For Claude Max subscribers: cost is flat-rate, but cache still affects latency and rate limits

See [Anthropic's prompt caching docs](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) for details.

## Requirements

- Python 3
- Claude Code CLI with hooks support

## License

MIT
