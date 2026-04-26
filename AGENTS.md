# claude-cache-countdown

Live countdown for Anthropic's prompt-cache TTL (5-min default, 1-hr on Max), surfaced in Claude Code's status line with a `$X.XX at risk` segment. macOS-first; Linux works but is lightly tested.

## Architecture

Three pieces communicate via per-session JSON at `~/.claude/state/cache-timer-{session_id}.json`:

1. **Stop hook** — `hooks/cache-timer-write.sh`. Writes the timer file with `stopped=true` and launches the alert watcher.
2. **UserPromptSubmit hook** — `hooks/cache-timer-resume.sh`. Flips the same file to `stopped=false` so the countdown disappears and any alert watcher exits.
3. **Status line wrapper** — `hooks/statusline-cost.sh`. Runs every second via `statusLine.refreshInterval`, reads the timer file for the current `session_id`, and appends `⏱ M:SS cache` or `⚠️ Cache Expired` plus the at-risk cost/tokens.
4. **Alert watcher** — `hooks/cache-alert-watch.sh`. Watches one stopped timer file and plays `ALERT_60S_SOUND` once when 60 seconds remain. It never writes to the TTY.

The status line wrapper still chains the user's existing `statusLine` command when one was backed up to `~/.claude/state/cache-countdown-original-statusline.txt`.

## Files to know

- `hooks/countdown-config.sh` — shared helpers used everywhere: `countdown_load_config`, `countdown_now_epoch_ns`, `countdown_iso_from_epoch_ns`, `countdown_debug_log`. Source this from any new script.
- `install.sh` / `uninstall.sh` — wire/unwire everything into `~/.claude/settings.json`. Idempotent.
- `~/.claude/countdown.conf` — user-facing config (TTL, display mode, alerts, debug). Loaded by `countdown_load_config`.
- `docs/extending.md` — timer-file JSON schema and how to drive the countdown without Claude Code.
- `docs/manual-install.md` — settings.json snippets for hand-wiring.
- `README.md` — pricing math, troubleshooting, user-facing overview.

## Gotchas

- **Status line refresh**: installer must set `statusLine.refreshInterval` to `1`; without it the timer will not tick while Claude Code is idle.
- **No TTY writes**: the migration intentionally avoids tab-title escapes, terminal bells, and Warp-specific OSC nudges. Keep alerts sound-file based.
- **Alert watcher lifetime**: the watcher is short-lived and exits after playing once, when the timer file disappears, when `stopped=false`, or when the TTL expires.
- **Pricing tiers in `statusline-cost.sh`**: Opus 4.6 has a hard cliff at 200K tokens. Rates are TTL-aware (5-min vs 1-hour profile) and tier-aware — keep both in sync if pricing changes.
- **Stale state**: timer and alert PID files in `~/.claude/state/` accumulate from abrupt session ends. `uninstall.sh` cleans them; manual deletion is safe.
