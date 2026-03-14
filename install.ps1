# Install Claude Cache Countdown (Windows / PowerShell 7)
# Adds the Stop and UserPromptSubmit hooks to your Claude Code settings.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SettingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
$StopHook = Join-Path $ScriptDir "hooks\cache-timer-write.ps1"
$ResumeHook = Join-Path $ScriptDir "hooks\cache-timer-resume.ps1"

Write-Host "Claude Cache Countdown Installer" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "Error: python is required but not found." -ForegroundColor Red
    exit 1
}

# Create state directory
$stateDir = Join-Path $env:USERPROFILE ".claude\state"
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

Write-Host "Stop hook:   $StopHook"
Write-Host "Resume hook: $ResumeHook"
Write-Host "Ticker:      $(Join-Path $ScriptDir 'cache_countdown.py')"
Write-Host ""

# Create settings.json if missing
if (-not (Test-Path $SettingsFile)) {
    Write-Host "Creating $SettingsFile..."
    $settingsDir = Split-Path $SettingsFile -Parent
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }
    Set-Content $SettingsFile "{}" -Encoding UTF8
}

# Read settings
$settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

# Ensure hooks object exists
if (-not $settings.hooks) {
    $settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

$changed = $false

# Add Stop hook
$stopCmd = "pwsh.exe -NoProfile -File `"$StopHook`""
$hasStop = $false
if ($settings.hooks.Stop) {
    foreach ($entry in $settings.hooks.Stop) {
        foreach ($h in $entry.hooks) {
            if ($h.command -match "cache-timer-write") { $hasStop = $true }
        }
    }
}
if (-not $hasStop) {
    $stopEntry = @{
        matcher = ""
        hooks = @(@{ type = "command"; command = $stopCmd; timeout = 5 })
    }
    if (-not $settings.hooks.Stop) {
        $settings.hooks | Add-Member -NotePropertyName "Stop" -NotePropertyValue @($stopEntry) -Force
    } else {
        $settings.hooks.Stop += $stopEntry
    }
    Write-Host "  Added Stop hook." -ForegroundColor Green
    $changed = $true
} else {
    Write-Host "  Stop hook already installed."
}

# Add UserPromptSubmit hook
$resumeCmd = "pwsh.exe -NoProfile -File `"$ResumeHook`""
$hasResume = $false
if ($settings.hooks.UserPromptSubmit) {
    foreach ($entry in $settings.hooks.UserPromptSubmit) {
        foreach ($h in $entry.hooks) {
            if ($h.command -match "cache-timer-resume") { $hasResume = $true }
        }
    }
}
if (-not $hasResume) {
    $resumeEntry = @{
        matcher = ""
        hooks = @(@{ type = "command"; command = $resumeCmd; timeout = 5 })
    }
    if (-not $settings.hooks.UserPromptSubmit) {
        $settings.hooks | Add-Member -NotePropertyName "UserPromptSubmit" -NotePropertyValue @($resumeEntry) -Force
    } else {
        $settings.hooks.UserPromptSubmit += $resumeEntry
    }
    Write-Host "  Added UserPromptSubmit hook." -ForegroundColor Green
    $changed = $true
} else {
    Write-Host "  UserPromptSubmit hook already installed."
}

if ($changed) {
    $settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsFile -Encoding UTF8
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "To start the countdown ticker, run:"
Write-Host "  python `"$(Join-Path $ScriptDir 'cache_countdown.py')`" --display windows" -ForegroundColor Yellow
Write-Host ""
Write-Host "Or add to your PowerShell profile:"
Write-Host "  function cache-ticker { python `"$(Join-Path $ScriptDir 'cache_countdown.py')`" --display windows @args }" -ForegroundColor Yellow
Write-Host ""
Write-Host "The countdown appears when a Claude Code session stops."
Write-Host "It disappears when you send a new message."
Write-Host "Restart Claude Code to load the new hooks."
