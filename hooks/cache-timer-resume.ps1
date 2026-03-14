# UserPromptSubmit hook for Claude Code (Windows / PowerShell 7)
# Removes the cache timer file when the user sends a new prompt.
# No timer file = no countdown = cache is being refreshed by active work.
#
# Install: Add to ~/.claude/settings.json under hooks.UserPromptSubmit
param()

$ErrorActionPreference = "Continue"

$hookInput = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($hookInput)) { exit 0 }

try { $data = $hookInput | ConvertFrom-Json } catch { exit 0 }

$sid = $data.session_id
if (-not $sid) { exit 0 }

$timerPath = Join-Path $env:USERPROFILE ".claude\state\cache-timer-$sid.json"
Remove-Item $timerPath -Force -ErrorAction SilentlyContinue

exit 0
