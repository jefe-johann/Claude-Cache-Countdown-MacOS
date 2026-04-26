Note: if you happen to find this organically, this project is a work in progress, there are some kinks I'm still working out!

# Claude Cache Countdown

A live cache-expiry countdown for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions, so you know exactly how long you have before your prompt cache drains and your next message gets *expensive*.

![Cache countdown in terminal tabs](img/Screenshot%202026-03-14%20035733.png)

## Why it exists

Anthropic caches your conversation context for 5 minutes by default (1 hour on Claude Max). Cache hits cost about 90% less than re-sending the full context. The moment your agent stops responding, that cache starts silently draining — and if your next message lands one second too late, you pay the full re-cache price.

**One concrete example:** a 500K-token session that lands inside the cache window costs about **$0.50**. Miss the window and the same message costs **$6.25**. Being one second late cost you $5.75.

This tool puts the countdown right on your terminal tab so you never get surprised by it.

## What it does

- **Live tab-title countdown** — a background process takes over your terminal tab title while the cache is draining, then flips to a clear expired warning when the window closes.
- **Cost-at-risk in your status line** — shows the live dollar value (or token count) of what you'd pay if your cache expired right now, embedded in Claude Code's native bottom status line.
- **Configurable alerts** — optional sound when 60 seconds remain.
- **Multi-session aware** — tracks separate countdowns across multiple Claude Code tabs.
- **Warp-friendly** — keeps Warp's normal auto-title behavior during active responses, and only takes over when the cache starts draining.
- **No background daemon** — the ticker only runs while a countdown is active, then exits.

Built and used on macOS. Linux should work in theory but is currently untested.

## Install

```bash
git clone <your-fork-or-local-url>
cd claude-cache-countdown

bash install.sh
```

The installer adds the hooks and status line wrapper to your Claude Code settings, scaffolds a config file at `~/.claude/countdown.conf`, and prompts you to pick a TTL profile (Pro/Standard 5min, or Max 1hr). Restart Claude Code to load the changes.

If you'd rather wire things up by hand, see [docs/manual-install.md](docs/manual-install.md).

## Configure

The installer writes `~/.claude/countdown.conf` with sensible defaults — most people won't need to touch it. Edit the file if you want to switch TTL profiles, change the status line display, or customize alerts:

```bash
CACHE_TTL_SECONDS=300
STATUSLINE_DISPLAY_MODE=dollars
ENABLE_ALERTS=true
ALERT_60S_SOUND="/System/Library/Sounds/Glass.aiff"
COUNTDOWN_DEBUG=false
COUNTDOWN_DEBUG_LOG_FILE="$HOME/.claude/state/cache-countdown-debug.log"
WARP_AGENT_STATUS_NUDGE=true
```

- `CACHE_TTL_SECONDS=300` — Pro / Standard 5-minute TTL (default)
- `CACHE_TTL_SECONDS=3600` — Claude Max 1-hour TTL
- `STATUSLINE_DISPLAY_MODE=dollars` — show the re-cache cost delta, like `$5.75 at risk`
- `STATUSLINE_DISPLAY_MODE=tokens` — show the cached prompt size instead, like `500K tokens at risk`
- `ENABLE_ALERTS=false` — disable the 60-second alert
- `ALERT_60S_SOUND` — any readable sound file on macOS; falls back to a terminal bell if playback is unavailable
- `COUNTDOWN_DEBUG=true` — enable verbose hook/ticker logging while debugging Warp behavior
- `COUNTDOWN_DEBUG_LOG_FILE` — override the debug log path if you want it somewhere else
- `WARP_AGENT_STATUS_NUDGE=false` — disable the Warp-specific stale permission-title reset

## How it works

```
Claude Code session is working...
    |
    v
Agent stops
    |
    v
Stop hook --------> sets stopped=true, timestamp=now, starts background ticker
    |
    v
Background ticker -> polls the timer file a few times per second and writes `⏱ M:SS | project` to the real TTY when the visible second changes
    |
    v
Cache expires -----> writes `⚠️ | project`
    |
    v
User sends new message
    |
    v
Resume hook ------> sets stopped=false, terminal takes the tab title back
```

While the agent is working, every API call resets the cache, so the countdown only matters once the agent stops. For protocol details, custom hooks, or non-Claude-Code integrations, see [docs/extending.md](docs/extending.md).

### Cost at risk

The status line wrapper reads Claude Code's status line JSON, computes the cost delta between a cache hit and a cache miss for your current context, and appends it to the bar. By default it shows money (`$5.75 at risk`); set `STATUSLINE_DISPLAY_MODE=tokens` to show cache size (`500K tokens at risk`) instead.

If you switch to the 1-hour Max TTL profile, the status line uses the higher 1-hour cache write delta automatically.

## Prompt caching reference

Skip this section unless you want the math behind the cost numbers.

| TTL | Write cost | Read cost | How to use |
|-----|-----------|-----------|------------|
| 5 minutes (default) | 1.25x base | 0.1x base | Default profile in `countdown.conf` |
| 1 hour (opt-in) | 2x base | 0.1x base | Set `CACHE_TTL_SECONDS=3600` when your Claude plan/runtime uses the 1-hour TTL |

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

Crossing the 200K threshold doubles the cost of the entire request, not just the overflow. These numbers are input token costs only — output tokens ($25-37.50/MTok) are billed the same regardless of cache state.

- Cache reads are 90% cheaper than uncached input
- Each API call that hits the cache resets the TTL timer
- Cache hits also improve latency (faster time-to-first-token) and don't count against rate limits
- Claude Max subscribers: cost is flat-rate, but cache still affects latency and rate limits. Set `CACHE_TTL_SECONDS=3600` so the countdown matches your cache profile.

See [Anthropic's prompt caching docs](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching) for details.

### Best practice: keep your context small

As your context window grows, so does your financial risk if the cache expires. Two native Claude Code commands help:

- **/compact** — compresses conversation history while preserving key information. Smaller cache means a smaller penalty if it expires.
- **/clear** — wipes the session entirely. Use it when you finish a major task and move on, so you're not paying to cache irrelevant history.

## Troubleshooting

**Warp shows the at-risk status line but not the live countdown title:** restart Claude Code so the updated Stop hook relaunches the ticker with the right environment. If the tab is stuck showing `Wants to run ...`, keep `WARP_AGENT_STATUS_NUDGE=true`; the hook sends Warp's structured "Claude stopped" signal through the real TTY before writing the countdown title.

If you need deeper visibility, set `COUNTDOWN_DEBUG=true` in `~/.claude/countdown.conf`, reproduce the issue, and inspect `~/.claude/state/cache-countdown-debug.log`. The log captures whether the Stop hook fired, which TTY it selected, whether a ticker launched, and whether title writes failed.

For deeper integration questions, see [docs/extending.md](docs/extending.md).

## Requirements

- Python 3
- Claude Code CLI with hooks support

## Acknowledgments

This project was heavily inspired by [KatsuJinCode/claude-cache-countdown](https://github.com/KatsuJinCode/claude-cache-countdown) by Julian Switzer. Julian's project laid the brilliant groundwork for using Claude Code hooks to track cache state. This repository takes those core concepts and rebuilds the core engine in Bash for a seamless, zero-window terminal experience.

## License

MIT
