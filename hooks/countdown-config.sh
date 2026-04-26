#!/usr/bin/env bash
# Shared config loader for Claude Cache Countdown scripts.

COUNTDOWN_CONFIG_FILE="${COUNTDOWN_CONFIG_FILE:-$HOME/.claude/countdown.conf}"
COUNTDOWN_DEFAULT_TTL_SECONDS=300
COUNTDOWN_DEFAULT_ENABLE_ALERTS=true
COUNTDOWN_DEFAULT_ALERT_60S_SOUND="/System/Library/Sounds/Sosumi.aiff"
COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE=dollars
COUNTDOWN_DEFAULT_DEBUG=false
COUNTDOWN_DEFAULT_DEBUG_LOG_FILE="$HOME/.claude/state/cache-countdown-debug.log"
COUNTDOWN_DEFAULT_WARP_AGENT_STATUS_NUDGE=true

countdown_load_config() {
    CACHE_TTL_SECONDS="$COUNTDOWN_DEFAULT_TTL_SECONDS"
    ENABLE_ALERTS="$COUNTDOWN_DEFAULT_ENABLE_ALERTS"
    ALERT_60S_SOUND="$COUNTDOWN_DEFAULT_ALERT_60S_SOUND"
    STATUSLINE_DISPLAY_MODE="$COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE"
    COUNTDOWN_DEBUG="$COUNTDOWN_DEFAULT_DEBUG"
    COUNTDOWN_DEBUG_LOG_FILE="$COUNTDOWN_DEFAULT_DEBUG_LOG_FILE"
    WARP_AGENT_STATUS_NUDGE="$COUNTDOWN_DEFAULT_WARP_AGENT_STATUS_NUDGE"

    if [ -f "$COUNTDOWN_CONFIG_FILE" ]; then
        set +u
        # shellcheck disable=SC1090
        . "$COUNTDOWN_CONFIG_FILE"
        set -u
    fi

    case "${CACHE_TTL_SECONDS:-}" in
        ''|*[!0-9]*)
            CACHE_TTL_SECONDS="$COUNTDOWN_DEFAULT_TTL_SECONDS"
            ;;
        *)
            if [ "$CACHE_TTL_SECONDS" -le 0 ]; then
                CACHE_TTL_SECONDS="$COUNTDOWN_DEFAULT_TTL_SECONDS"
            fi
            ;;
    esac

    case "${ENABLE_ALERTS:-}" in
        true|false) ;;
        *)
            ENABLE_ALERTS="$COUNTDOWN_DEFAULT_ENABLE_ALERTS"
            ;;
    esac

    if [ -z "${ALERT_60S_SOUND:-}" ]; then
        ALERT_60S_SOUND="$COUNTDOWN_DEFAULT_ALERT_60S_SOUND"
    fi

    case "${STATUSLINE_DISPLAY_MODE:-}" in
        dollars|tokens) ;;
        *)
            STATUSLINE_DISPLAY_MODE="$COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE"
            ;;
    esac

    case "${COUNTDOWN_DEBUG:-}" in
        true|false) ;;
        *)
            COUNTDOWN_DEBUG="$COUNTDOWN_DEFAULT_DEBUG"
            ;;
    esac

    if [ -z "${COUNTDOWN_DEBUG_LOG_FILE:-}" ]; then
        COUNTDOWN_DEBUG_LOG_FILE="$COUNTDOWN_DEFAULT_DEBUG_LOG_FILE"
    fi

    case "${WARP_AGENT_STATUS_NUDGE:-}" in
        true|false) ;;
        *)
            WARP_AGENT_STATUS_NUDGE="$COUNTDOWN_DEFAULT_WARP_AGENT_STATUS_NUDGE"
            ;;
    esac
}

countdown_debug_log() {
    [ "${COUNTDOWN_DEBUG:-false}" = "true" ] || return 0

    local tag="${1:-debug}"
    shift || true
    local message="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    mkdir -p "$(dirname "$COUNTDOWN_DEBUG_LOG_FILE")" 2>/dev/null || true
    printf '%s [%s] %s\n' "$ts" "$tag" "$message" >> "$COUNTDOWN_DEBUG_LOG_FILE" 2>/dev/null || true
}

countdown_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

countdown_warp_structured_notifications_supported() {
    [ "${WARP_AGENT_STATUS_NUDGE:-true}" = "true" ] || return 1
    [ "${TERM_PROGRAM:-}" = "WarpTerminal" ] || return 1
    [ -n "${WARP_CLI_AGENT_PROTOCOL_VERSION:-}" ] || return 1
    [ -n "${WARP_CLIENT_VERSION:-}" ] || return 1

    # Match Warp's Claude plugin guard. Older March 2026 builds advertised the
    # protocol before structured agent notifications were actually reliable.
    local threshold=""
    case "$WARP_CLIENT_VERSION" in
        *stable*) threshold="v0.2026.03.25.08.24.stable_05" ;;
        *preview*) threshold="v0.2026.03.25.08.24.preview_05" ;;
    esac

    if [ -n "$threshold" ] && [[ ! "$WARP_CLIENT_VERSION" > "$threshold" ]]; then
        return 1
    fi

    return 0
}

countdown_warp_agent_stop_notify() {
    local tty_dev="${1:-}"
    local session_id="${2:-}"
    local cwd="${3:-}"
    local project="${4:-}"

    countdown_warp_structured_notifications_supported || return 0
    [ -n "$tty_dev" ] && [ -w "$tty_dev" ] || return 0

    local protocol_version="${WARP_CLI_AGENT_PROTOCOL_VERSION:-1}"
    case "$protocol_version" in
        ''|*[!0-9]*) protocol_version=1 ;;
        *)
            if [ "$protocol_version" -gt 1 ]; then
                protocol_version=1
            fi
            ;;
    esac

    local payload
    payload=$(printf '{"v":%d,"agent":"claude","event":"stop","session_id":"%s","cwd":"%s","project":"%s","query":"","response":"","transcript_path":""}' \
        "$protocol_version" \
        "$(countdown_json_escape "$session_id")" \
        "$(countdown_json_escape "$cwd")" \
        "$(countdown_json_escape "$project")")

    if printf '\033]777;notify;warp://cli-agent;%s\007' "$payload" > "$tty_dev" 2>/dev/null; then
        countdown_debug_log warp "sent agent stop session=$session_id tty=$tty_dev"
    else
        countdown_debug_log warp "agent stop write failed session=$session_id tty=$tty_dev"
    fi
}
