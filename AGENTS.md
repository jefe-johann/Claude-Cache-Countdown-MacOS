# Codex-cache-countdown

Installed tool for tracking Anthropic prompt cache TTL (5-minute expiry) across Codex sessions.

## What's installed

- **Hooks** in `~/.Codex/settings.json`: Stop hook writes timer state and launches background ticker; UserPromptSubmit hook kills ticker and resets state
- **Timer files**: written per-session to `~/.Codex/state/cache-timer-{session_id}.json`
- **Background ticker** (`hooks/cache-timer-bg.sh`): launched by the Stop hook, updates the Warp tab title with `⏱ M:SS` every second via terminal escape codes written to the real TTY device

## How it works

1. Codex finishes responding → Stop hook writes `stopped=true` timer file, discovers TTY device (walks process tree for real `/dev/ttysXXX`), launches `cache-timer-bg.sh` in background
2. Background ticker updates Warp tab title every second: `⏱ 4:59`, `⏱ 4:58`, ...
3. Timer expires → ticker clears tab title and exits
4. User sends new prompt → UserPromptSubmit hook kills ticker, clears tab title, writes `stopped=false`

## Why tab title, not status line

The Codex status line only re-runs on assistant messages, permission mode changes, and vim mode toggles — no periodic refresh. The Warp tab title is updated by a background process writing OSC escape codes (`\033]0;...\007`) directly to the TTY device.

## Key detail: TTY discovery

Hook subprocesses have no controlling terminal (`/dev/tty` fails). Both hooks walk up the process tree via `ps -o tty=` to find the real TTY (e.g. `/dev/ttys003`) of the parent Codex/shell process and write there.

## Status line: cost at risk

`hooks/statusline-cost.sh` wraps the user's existing `statusLine` command and appends `$X.XX at risk` — the cost delta between a cache hit and a cache miss for the current context size.

- Token data comes from `context_window.current_usage` in the statusLine JSON input
- Pricing: `$5.75/MTok` delta (≤200K tokens), `$11.50/MTok` (>200K) — matches Opus 4.6 pricing
- The original statusLine command is backed up to `~/.Codex/state/cache-countdown-original-statusline.txt` during install

## Timer file format

```json
{"timestamp": "2026-04-09T23:14:13.000Z", "session_id": "...", "project": "...", "host_pid": 0, "stopped": true, "cwd": "..."}
```

Note: `host_pid` is always 0 for Warp (not detected by the hooks). Stale timer files from closed sessions may accumulate in `~/.Codex/state/` and can be deleted manually.
