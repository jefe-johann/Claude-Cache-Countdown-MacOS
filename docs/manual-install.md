# Manual Installation

If you prefer not to use the installer, you can wire up the hooks yourself. You'll need Python 3 for the status line wrapper.

## 1. Add the hooks

Three hooks are required:

- **Stop** — writes the timer file when the agent finishes responding
- **UserPromptSubmit** — resets the timer (and the alert marker) when you send a new message
- **SessionStart** — drops the timer file and alert marker when you run `/clear`, so the now-invalidated cache stops driving the countdown and the alert. The script no-ops for `startup` and `resume`.

Add all three to `~/.claude/settings.json`, replacing `/path/to/claude-cache-countdown` with the actual path to your clone:

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
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash '/path/to/claude-cache-countdown/hooks/cache-timer-clear.sh'",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

There is no separate display or alert process to run — Claude Code refreshes the status line every second, and the status line plays the 60-second sound itself when alerts are enabled.

## 2. Add the status line wrapper

The status line wrapper appends the countdown and at-risk cost or token count to Claude Code's native bottom bar. Add it to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash '/path/to/claude-cache-countdown/hooks/statusline-cost.sh'",
    "refreshInterval": 1
  }
}
```

If you already have a `statusLine` configured, back up your existing command first. The wrapper checks for a backup at `~/.claude/state/cache-countdown-original-statusline.txt` and chains to it automatically if found — write the old command there before switching.

## 3. Create the config file

Create `~/.claude/countdown.conf`:

```bash
# Cache TTL in seconds.
#   300  = Pro / Standard (5 minutes)
#   3600 = Max (1 hour)
CACHE_TTL_SECONDS=300

# Status line display mode.
#   dollars = show the estimated re-cache cost delta
#   tokens  = show the cached prompt size instead
STATUSLINE_DISPLAY_MODE=dollars

# Enable or disable the 60-second alert sound.
ENABLE_ALERTS=true

# Sound file played when 60 seconds remain. macOS only.
ALERT_60S_SOUND="/System/Library/Sounds/Glass.aiff"

# Enable verbose hook logging while debugging.
COUNTDOWN_DEBUG=false

# Optional override for the debug log path.
COUNTDOWN_DEBUG_LOG_FILE="$HOME/.claude/state/cache-countdown-debug.log"
```

See [Configure](../README.md#configure) in the main readme for what each option does.

## 4. Make the scripts executable

```bash
chmod +x /path/to/claude-cache-countdown/hooks/*.sh
```

## 5. Restart Claude Code

Hooks are loaded at startup. Restart Claude Code after editing `~/.claude/settings.json` for the changes to take effect.

## Uninstall

`bash uninstall.sh` from the repo root reverses these steps for you. It:

- Removes any Stop/UserPromptSubmit/SessionStart hook commands that reference `cache-timer-write.sh`, `cache-timer-resume.sh`, or `cache-timer-clear.sh` (matched by basename, so manual installs from a different path are still cleaned up)
- Restores the prior `statusLine` from `~/.claude/state/cache-countdown-original-statusline.txt` if it exists, otherwise removes the wrapper entry
- Deletes `~/.claude/countdown.conf`, the timer files, alert markers, legacy PID files, the status line backup, and the debug log
- Stops any leftover `cache-alert-watch.sh` or `cache-timer-bg.sh` processes from older versions
- Leaves the repo clone alone

Use `--dry-run` to preview the actions, or `--yes` to skip the interactive confirmation. The script does not delete `~/.claude/state/` itself, only this tool's files inside it.
