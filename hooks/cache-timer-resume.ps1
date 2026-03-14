# cache-timer-resume.ps1 - UserPromptSubmit hook for Claude Code (Windows / PowerShell 7)
# Clears the stopped state on the cache timer file when the user sends a new prompt.
# This tells the ticker the session is active again (cache is being refreshed).
#
# Also cleans up stale timer files from other sessions sharing the same host_pid,
# which happens when /clear or /reset creates a new session_id for the same tab.
#
# Install: Add to ~/.claude/settings.json under hooks.UserPromptSubmit
param()

$ErrorActionPreference = "Continue"

$hookInput = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($hookInput)) { exit 0 }

try { $data = $hookInput | ConvertFrom-Json } catch { exit 0 }

$sid = $data.session_id
if (-not $sid) { exit 0 }

$stateDir = Join-Path $env:USERPROFILE ".claude\state"
$timerPath = Join-Path $stateDir "cache-timer-$sid.json"
if (-not (Test-Path $timerPath)) { exit 0 }

try {
    $timer = Get-Content $timerPath -Raw | ConvertFrom-Json
    $ht = @{}
    $timer.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    $ht["stopped"] = $false
    $ht["timestamp"] = (Get-Date -Format "o")
    $ht.Remove("stopped_at")
    $ht | ConvertTo-Json -Compress | Set-Content $timerPath -Force

    # Clean up stale timer files from other sessions sharing the same host_pid.
    # This happens when /clear or /reset creates a new session_id for the same tab.
    $myPid = $ht["host_pid"]
    if ($myPid -and $myPid -ne 0) {
        Get-ChildItem (Join-Path $stateDir "cache-timer-*.json") -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne "cache-timer-$sid.json"
        } | ForEach-Object {
            try {
                $other = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($other.host_pid -eq $myPid) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }
} catch {}

exit 0
