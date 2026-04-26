#!/usr/bin/env bash
# Uninstall Claude Cache Countdown
# Reverses install.sh: removes hooks, restores prior statusLine, and deletes
# this tool's runtime artifacts. Leaves the repo clone alone.

set -uo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.claude/state"
CONFIG_FILE="$HOME/.claude/countdown.conf"
ORIGINAL_CMD_FILE="$STATE_DIR/cache-countdown-original-statusline.txt"
DEBUG_LOG_FILE="$STATE_DIR/cache-countdown-debug.log"

ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: bash uninstall.sh [--yes] [--dry-run]

  --yes      Skip the confirmation prompt.
  --dry-run  Print the actions that would be taken; change nothing.
  -h, --help Show this message.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required to safely rewrite $SETTINGS_FILE." >&2
    echo "Install python3 and re-run, or remove the cache-timer-write.sh / cache-timer-resume.sh" >&2
    echo "hook entries (and the statusline-cost.sh statusLine) from $SETTINGS_FILE by hand." >&2
    exit 1
fi

PREFIX=""
if [ "$DRY_RUN" -eq 1 ]; then
    PREFIX="[dry-run] "
fi

echo "Claude Cache Countdown Uninstaller"
echo "=================================="
echo ""
echo "This will:"
echo "  - Remove the project's Stop and UserPromptSubmit hooks from $SETTINGS_FILE"
echo "  - Restore your prior statusLine command if a backup exists, otherwise remove ours"
echo "  - Stop any running cache-alert-watch.sh processes and legacy cache-timer-bg.sh processes started by this tool"
echo "  - Delete $CONFIG_FILE"
echo "  - Delete $STATE_DIR/cache-timer-*.json, cache-alert-*.pid, legacy cache-timer-*.pid, the original-statusline backup, and the debug log"
echo ""
echo "It will NOT:"
echo "  - Delete the repository clone"
echo "  - Touch unrelated Claude settings, hooks, or files"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run mode: no changes will be made."
    echo ""
fi

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    if [ -t 0 ]; then
        printf "Continue? [y/N]: "
        read -r reply
        case "${reply:-N}" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 0 ;;
        esac
    else
        echo "No interactive TTY detected; pass --yes to confirm non-interactively."
        exit 1
    fi
fi

EXIT_CODE=0

# ---------------------------------------------------------------------------
# Settings cleanup
# ---------------------------------------------------------------------------

SETTINGS_RESULT="not-found"
if [ -f "$SETTINGS_FILE" ]; then
    echo "${PREFIX}Editing $SETTINGS_FILE..."
    SETTINGS_RESULT=$(
        SETTINGS_FILE="$SETTINGS_FILE" \
        ORIGINAL_CMD_FILE="$ORIGINAL_CMD_FILE" \
        DRY_RUN="$DRY_RUN" \
        python3 <<'PY'
import json
import os
import sys
import tempfile

settings_path = os.environ["SETTINGS_FILE"]
original_cmd_file = os.environ["ORIGINAL_CMD_FILE"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"

OWNED_HOOK_BASENAMES = ("cache-timer-write.sh", "cache-timer-resume.sh")
OWNED_STATUSLINE_BASENAME = "statusline-cost.sh"

results = {
    "settings": "ok",
    "stop_removed": 0,
    "submit_removed": 0,
    "statusline": "unchanged",
}


def emit():
    for k, v in results.items():
        print(f"{k}={v}")
    # Sentinel: confirms the script ran to completion. The bash side treats
    # missing `done=1` as a partial/aborted run rather than success.
    print("done=1")


try:
    with open(settings_path, "r", encoding="utf-8") as f:
        settings = json.load(f)
except json.JSONDecodeError:
    results["settings"] = "invalid-json"
    emit()
    sys.exit(0)
except OSError as exc:
    results["settings"] = f"read-error:{exc.__class__.__name__}"
    emit()
    sys.exit(0)

if not isinstance(settings, dict):
    results["settings"] = "invalid-shape"
    emit()
    sys.exit(0)

changed = False


def is_owned_hook_command(cmd: str) -> bool:
    return any(name in cmd for name in OWNED_HOOK_BASENAMES)


def clean_hook_section(section_name: str) -> int:
    """Strip owned hook commands from settings['hooks'][section_name]. Returns count removed."""
    global changed
    hooks_root = settings.get("hooks")
    if not isinstance(hooks_root, dict):
        return 0
    entries = hooks_root.get(section_name)
    if not isinstance(entries, list):
        return 0

    removed = 0
    new_entries = []
    for entry in entries:
        if not isinstance(entry, dict):
            new_entries.append(entry)
            continue
        inner = entry.get("hooks")
        if not isinstance(inner, list):
            new_entries.append(entry)
            continue
        kept_inner = []
        for hook in inner:
            cmd = ""
            if isinstance(hook, dict):
                cmd = hook.get("command", "") or ""
            if isinstance(hook, dict) and is_owned_hook_command(cmd):
                removed += 1
                continue
            kept_inner.append(hook)
        if len(kept_inner) != len(inner):
            changed = True
        if kept_inner:
            entry["hooks"] = kept_inner
            new_entries.append(entry)
        else:
            # Drop the now-empty matcher entry entirely.
            changed = True

    if new_entries:
        hooks_root[section_name] = new_entries
    else:
        if section_name in hooks_root:
            del hooks_root[section_name]
            changed = True

    return removed


results["stop_removed"] = clean_hook_section("Stop")
results["submit_removed"] = clean_hook_section("UserPromptSubmit")

# Drop empty top-level hooks object.
if isinstance(settings.get("hooks"), dict) and not settings["hooks"]:
    del settings["hooks"]
    changed = True

# Status line cleanup.
sl = settings.get("statusLine")
if isinstance(sl, dict):
    current_cmd = sl.get("command", "") or ""
    if OWNED_STATUSLINE_BASENAME in current_cmd:
        original_cmd = ""
        if os.path.isfile(original_cmd_file):
            try:
                with open(original_cmd_file, "r", encoding="utf-8") as f:
                    original_cmd = f.read().strip()
            except OSError:
                original_cmd = ""
        if original_cmd:
            settings["statusLine"] = {"type": "command", "command": original_cmd}
            results["statusline"] = "restored"
        else:
            del settings["statusLine"]
            results["statusline"] = "removed"
        changed = True

if changed and not dry_run:
    try:
        dir_name = os.path.dirname(settings_path) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=dir_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(settings, f, indent=2)
                f.write("\n")
            os.replace(tmp_path, settings_path)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except OSError as exc:
        results["settings"] = f"write-error:{exc.__class__.__name__}"

emit()
PY
    )
else
    echo "${PREFIX}$SETTINGS_FILE not found; skipping settings cleanup."
fi

# Parse python results.
SETTINGS_STATUS="not-found"
STOP_REMOVED=0
SUBMIT_REMOVED=0
STATUSLINE_RESULT="unchanged"
PYTHON_DONE=0
if [ -n "$SETTINGS_RESULT" ] && [ "$SETTINGS_RESULT" != "not-found" ]; then
    while IFS='=' read -r k v; do
        case "$k" in
            settings) SETTINGS_STATUS="$v" ;;
            stop_removed) STOP_REMOVED="$v" ;;
            submit_removed) SUBMIT_REMOVED="$v" ;;
            statusline) STATUSLINE_RESULT="$v" ;;
            done) PYTHON_DONE="$v" ;;
        esac
    done <<< "$SETTINGS_RESULT"

    if [ "$PYTHON_DONE" != "1" ]; then
        echo "  Warning: settings cleanup did not complete (python helper aborted before finishing)."
        echo "  Inspect $SETTINGS_FILE and remove any remaining cache-timer-write.sh / cache-timer-resume.sh"
        echo "  hooks and the statusline-cost.sh statusLine entry by hand."
        SETTINGS_STATUS="incomplete"
        EXIT_CODE=1
    fi
fi

if [ "$SETTINGS_STATUS" = "invalid-json" ]; then
    echo "  Warning: $SETTINGS_FILE is not valid JSON; settings were not modified."
    echo "  Remove the Stop/UserPromptSubmit hook entries that reference cache-timer-write.sh and cache-timer-resume.sh by hand,"
    echo "  and the statusLine entry that references statusline-cost.sh."
    EXIT_CODE=1
elif [[ "$SETTINGS_STATUS" == write-error:* ]] || [[ "$SETTINGS_STATUS" == read-error:* ]] || [ "$SETTINGS_STATUS" = "invalid-shape" ]; then
    echo "  Warning: could not safely rewrite $SETTINGS_FILE ($SETTINGS_STATUS)."
    EXIT_CODE=1
fi

# ---------------------------------------------------------------------------
# Process cleanup (kill alert watchers and legacy title tickers)
# ---------------------------------------------------------------------------

PROCS_STOPPED=0
PIDS_REMOVED=0

PIDS_KEPT=0

if [ -d "$STATE_DIR" ]; then
    shopt -s nullglob
    for pidfile in "$STATE_DIR"/cache-alert-*.pid "$STATE_DIR"/cache-timer-*.pid; do
        [ -e "$pidfile" ] || continue
        pid=$(tr -d '[:space:]' < "$pidfile" 2>/dev/null)
        expected_cmd=""
        label="process"
        case "$(basename "$pidfile")" in
            cache-alert-*.pid)
                expected_cmd="cache-alert-watch.sh"
                label="alert watcher"
                ;;
            cache-timer-*.pid)
                expected_cmd="cache-timer-bg.sh"
                label="legacy title ticker"
                ;;
        esac

        # Three cases:
        #   1. pid is alive AND command matches expected → kill + remove pidfile.
        #   2. pid is alive but command does NOT match → unrelated process now
        #      owns this pid. Leave both the process and the pidfile alone so
        #      the user can investigate.
        #   3. pid is missing/dead → pidfile is stale, remove it.
        process_alive=0
        cmd_matches=0
        cmd=""
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            process_alive=1
            cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
            if [ -n "$expected_cmd" ] && echo "$cmd" | grep -Fq "$expected_cmd"; then
                cmd_matches=1
            fi
        fi

        if [ "$process_alive" -eq 1 ] && [ "$cmd_matches" -eq 0 ]; then
            echo "  Skipping pid=$pid in $pidfile — running command does not match $expected_cmd:"
            echo "    $cmd"
            echo "  Leaving $pidfile in place; remove it manually if the process is unrelated."
            PIDS_KEPT=$((PIDS_KEPT + 1))
            continue
        fi

        if [ "$process_alive" -eq 1 ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "${PREFIX}Would stop $label pid=$pid"
            else
                kill "$pid" 2>/dev/null || true
            fi
            PROCS_STOPPED=$((PROCS_STOPPED + 1))
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "${PREFIX}Would remove $pidfile"
        else
            rm -f "$pidfile"
        fi
        PIDS_REMOVED=$((PIDS_REMOVED + 1))
    done
    shopt -u nullglob
fi

# ---------------------------------------------------------------------------
# File cleanup
# ---------------------------------------------------------------------------

CONFIG_REMOVED="not-found"
if [ -f "$CONFIG_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "${PREFIX}Would remove $CONFIG_FILE"
    else
        rm -f "$CONFIG_FILE"
    fi
    CONFIG_REMOVED="removed"
fi

ORIGINAL_REMOVED="not-found"
if [ -f "$ORIGINAL_CMD_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "${PREFIX}Would remove $ORIGINAL_CMD_FILE"
    else
        rm -f "$ORIGINAL_CMD_FILE"
    fi
    ORIGINAL_REMOVED="removed"
fi

DEBUG_LOG_REMOVED="not-found"
if [ -f "$DEBUG_LOG_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "${PREFIX}Would remove $DEBUG_LOG_FILE"
    else
        rm -f "$DEBUG_LOG_FILE"
    fi
    DEBUG_LOG_REMOVED="removed"
fi

TIMER_FILES_REMOVED=0
if [ -d "$STATE_DIR" ]; then
    shopt -s nullglob
    for f in "$STATE_DIR"/cache-timer-*.json; do
        [ -e "$f" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "${PREFIX}Would remove $f"
        else
            rm -f "$f"
        fi
        TIMER_FILES_REMOVED=$((TIMER_FILES_REMOVED + 1))
    done
    shopt -u nullglob
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Summary"
echo "-------"
case "$SETTINGS_STATUS" in
    ok)
        if [ "$STOP_REMOVED" -gt 0 ]; then
            echo "  Stop hook commands removed: $STOP_REMOVED"
        else
            echo "  Stop hook: not found"
        fi
        if [ "$SUBMIT_REMOVED" -gt 0 ]; then
            echo "  UserPromptSubmit hook commands removed: $SUBMIT_REMOVED"
        else
            echo "  UserPromptSubmit hook: not found"
        fi
        case "$STATUSLINE_RESULT" in
            restored) echo "  Status line: restored from backup" ;;
            removed)  echo "  Status line: removed (no backup found)" ;;
            unchanged) echo "  Status line: left unchanged (does not point at this tool)" ;;
        esac
        ;;
    not-found)
        echo "  Settings file not present; nothing to clean from settings.json"
        ;;
    invalid-json)
        echo "  Settings file: not modified (invalid JSON)"
        ;;
    incomplete)
        echo "  Settings file: cleanup did not finish — see warning above"
        ;;
    *)
        echo "  Settings file: $SETTINGS_STATUS"
        ;;
esac

echo "  Config file ($CONFIG_FILE): $CONFIG_REMOVED"
echo "  Status line backup: $ORIGINAL_REMOVED"
echo "  Debug log: $DEBUG_LOG_REMOVED"
echo "  Timer files removed: $TIMER_FILES_REMOVED"
echo "  PID files removed: $PIDS_REMOVED"
if [ "$PIDS_KEPT" -gt 0 ]; then
    echo "  PID files left in place (pid alive, command unrecognized): $PIDS_KEPT"
fi
echo "  Background processes stopped: $PROCS_STOPPED"

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run complete. No changes were made."
else
    echo "Uninstall complete."
    echo "Restart Claude Code to fully unload hooks from any running sessions."
fi

exit "$EXIT_CODE"
