# Manual Installation

If you prefer not to use the installer, you can wire up the hooks yourself. You'll need Python 3 for the status line wrapper.

## 1. Add the hooks

Two hooks are required:

- **Stop** — writes the timer file and launches the background ticker when the agent finishes responding
- **UserPromptSubmit** — resets the timer when you send a new message, handing title control back to Warp

Add both to `~/.claude/settings.json`, replacing `/path/to/claude-cache-countdown` with the actual path to your clone:

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

There is no separate ticker command to run — the Stop hook launches the background ticker automatically.

## 2. Add the status line wrapper

The status line wrapper appends the at-risk cost or token count to Claude Code's native bottom bar. Add it to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash '/path/to/claude-cache-countdown/hooks/statusline-cost.sh'"
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
```

See [Configuration](../README.md#config-file) in the main readme for what each option does.

## 4. Make the scripts executable

```bash
chmod +x /path/to/claude-cache-countdown/hooks/*.sh
```

## 5. Restart Claude Code

Hooks are loaded at startup. Restart Claude Code after editing `~/.claude/settings.json` for the changes to take effect.
