#!/usr/bin/env bash
# Shared config loader for Claude Cache Countdown scripts.

COUNTDOWN_CONFIG_FILE="${COUNTDOWN_CONFIG_FILE:-$HOME/.claude/countdown.conf}"
COUNTDOWN_DEFAULT_TTL_SECONDS=300
COUNTDOWN_DEFAULT_ENABLE_ALERTS=true
COUNTDOWN_DEFAULT_ALERT_60S_SOUND="/System/Library/Sounds/Sosumi.aiff"
COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE=dollars
COUNTDOWN_DEFAULT_DEBUG=false
COUNTDOWN_DEFAULT_DEBUG_LOG_FILE="$HOME/.claude/state/cache-countdown-debug.log"

countdown_load_config() {
    CACHE_TTL_SECONDS="$COUNTDOWN_DEFAULT_TTL_SECONDS"
    ENABLE_ALERTS="$COUNTDOWN_DEFAULT_ENABLE_ALERTS"
    ALERT_60S_SOUND="$COUNTDOWN_DEFAULT_ALERT_60S_SOUND"
    STATUSLINE_DISPLAY_MODE="$COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE"
    COUNTDOWN_DEBUG="$COUNTDOWN_DEFAULT_DEBUG"
    COUNTDOWN_DEBUG_LOG_FILE="$COUNTDOWN_DEFAULT_DEBUG_LOG_FILE"

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

countdown_now_epoch_ns() {
    local ns
    ns=$(date -u +%s%N 2>/dev/null || true)
    case "$ns" in
        ''|*[!0-9]*)
            printf '%s000000000\n' "$(date -u +%s)"
            ;;
        *)
            printf '%s\n' "$ns"
            ;;
    esac
}

countdown_iso_from_epoch_ns() {
    local epoch_ns="${1:-0}"
    local seconds
    local nanos
    local base

    case "$epoch_ns" in
        ''|*[!0-9]*) epoch_ns=0 ;;
    esac

    seconds=$(( epoch_ns / 1000000000 ))
    nanos=$(( epoch_ns % 1000000000 ))

    case "$(uname -s)" in
        Darwin) base=$(date -u -r "$seconds" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "1970-01-01T00:00:00") ;;
        Linux) base=$(date -u -d "@$seconds" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "1970-01-01T00:00:00") ;;
        *) base=$(date -u +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "1970-01-01T00:00:00") ;;
    esac

    printf '%s.%09dZ\n' "$base" "$nanos"
}
