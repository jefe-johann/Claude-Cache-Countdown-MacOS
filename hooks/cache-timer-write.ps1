# cache-timer-stop.ps1 - Stop hook for Claude Code (Windows / PowerShell 7)
# Marks the cache timer file as "stopped" so the external ticker knows
# the cache is now genuinely draining and should show the countdown.
#
# Self-sufficient: discovers host PID independently so sessions WITHOUT
# a status line wrapper still get tracked.
#
# Install: Add to ~/.claude/settings.json under hooks.Stop
param()

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$hookInput = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($hookInput)) { exit 0 }

try {
    $data = $hookInput | ConvertFrom-Json
} catch { exit 0 }

$sid = $data.session_id
if (-not $sid) { exit 0 }

$stateDir = Join-Path $env:USERPROFILE ".claude\state"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$cacheTimerPath = Join-Path $stateDir "cache-timer-$sid.json"

# Read existing timer file if present
$timerData = @{}
if (Test-Path $cacheTimerPath) {
    try {
        $existing = Get-Content $cacheTimerPath -Raw | ConvertFrom-Json
        $existing.PSObject.Properties | ForEach-Object { $timerData[$_.Name] = $_.Value }
    } catch {
        $timerData = @{}
    }
}

# Discover project name if not already known
if (-not $timerData["project"]) {
    if ($data.cwd) {
        $timerData["project"] = Split-Path -Leaf $data.cwd
    } elseif ($env:CLAUDE_PROJECT_DIR) {
        $timerData["project"] = Split-Path -Leaf $env:CLAUDE_PROJECT_DIR
    } else {
        $timerData["project"] = "unknown"
    }
}

# Mark as stopped - timestamp is NOW (when the cache starts draining)
# WRITE IMMEDIATELY before PID walk, which can cold-start WMI and timeout
$timerData["stopped"] = $true
$timerData["timestamp"] = (Get-Date -Format "o")
$timerData["session_id"] = $sid

$timerData | ConvertTo-Json -Compress | Set-Content $cacheTimerPath -Force

# Best-effort: read context size from statusline data or transcript
# Tier 1: statusline data (written by statusline wrapper)
# Tier 2: transcript file (last entry with cache_read_input_tokens)
$contextTokens = 0
$exceeds200k = $false

$slData = Join-Path $stateDir "statusline-data-$sid.json"
if (Test-Path $slData) {
    try {
        $sl = Get-Content $slData -Raw | ConvertFrom-Json
        $usage = $sl.context_window.current_usage
        if ($usage) {
            $contextTokens = [int]($usage.input_tokens ?? 0) + [int]($usage.cache_creation_input_tokens ?? 0) + [int]($usage.cache_read_input_tokens ?? 0)
            $exceeds200k = [bool]($sl.exceeds_200k_tokens ?? $false)
        }
    } catch {}
}

if ($contextTokens -eq 0) {
    # Tier 2: parse transcript. Derive path from cwd + session_id.
    try {
        $cwd = $data.cwd
        if ($cwd) {
            $projectSlug = ($cwd -replace '[/\\]', '-' -replace ':', '').TrimStart('-')
            $transcriptDir = Join-Path $env:USERPROFILE ".claude\projects\$projectSlug"
            $transcriptPath = Join-Path $transcriptDir "$sid.jsonl"
            if (Test-Path $transcriptPath) {
                # Read last 20 lines, find last one with cache_read_input_tokens
                $lines = Get-Content $transcriptPath -Tail 20 -ErrorAction SilentlyContinue
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    if ($lines[$i] -match 'cache_read_input_tokens') {
                        try {
                            $entry = $lines[$i] | ConvertFrom-Json
                            $u = $entry.message.usage
                            if ($u) {
                                $contextTokens = [int]($u.input_tokens ?? 0) + [int]($u.cache_creation_input_tokens ?? 0) + [int]($u.cache_read_input_tokens ?? 0)
                                if ($u.service_tier -eq "standard") { $exceeds200k = $false } else { $exceeds200k = ($contextTokens -gt 200000) }
                                break
                            }
                        } catch {}
                    }
                }
            }
        }
    } catch {}
}

if ($contextTokens -gt 0) {
    $timerData["context_tokens"] = $contextTokens
    $timerData["exceeds_200k"] = $exceeds200k
    $timerData | ConvertTo-Json -Compress | Set-Content $cacheTimerPath -Force
}

# Best-effort: discover host PID if not already known (child of WindowsTerminal)
# This is expensive on first call (WMI cold start) and optional - only used for
# Windows Terminal tab title display. If it times out, the timer file is already written.
if (-not $timerData["host_pid"] -or $timerData["host_pid"] -eq 0) {
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess()
        for ($i = 0; $i -lt 10; $i++) {
            $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).ParentProcessId
            if (-not $ppid) { break }
            $pp = [System.Diagnostics.Process]::GetProcessById($ppid)
            if ($pp.ProcessName -eq "WindowsTerminal") {
                $timerData["host_pid"] = $p.Id
                break
            }
            $p = $pp
        }
        # Re-write with PID if we found it
        $timerData | ConvertTo-Json -Compress | Set-Content $cacheTimerPath -Force
    } catch {}
}

exit 0
