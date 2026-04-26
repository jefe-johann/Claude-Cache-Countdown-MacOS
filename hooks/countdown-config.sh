#!/usr/bin/env bash
# Shared config loader for Claude Cache Countdown scripts.

COUNTDOWN_CONFIG_FILE="${COUNTDOWN_CONFIG_FILE:-$HOME/.claude/countdown.conf}"
COUNTDOWN_DEFAULT_TTL_SECONDS=300
COUNTDOWN_DEFAULT_ENABLE_ALERTS=true
COUNTDOWN_DEFAULT_ALERT_60S_SOUND="/System/Library/Sounds/Glass.aiff"
COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE=dollars

countdown_load_config() {
    CACHE_TTL_SECONDS="$COUNTDOWN_DEFAULT_TTL_SECONDS"
    ENABLE_ALERTS="$COUNTDOWN_DEFAULT_ENABLE_ALERTS"
    ALERT_60S_SOUND="$COUNTDOWN_DEFAULT_ALERT_60S_SOUND"
    STATUSLINE_DISPLAY_MODE="$COUNTDOWN_DEFAULT_STATUSLINE_DISPLAY_MODE"

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
}
