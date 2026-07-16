#!/bin/sh
set -eu

HEALTHCHECK_FILE="/tmp/failure_count"
MAX_FAILURES=6
WG_CONF_RUNTIME="/run/amnezia/wg0.conf"
WG_CONF_FALLBACK="/etc/amnezia/amneziawg/wg0.conf"
WG_CONF="${WG_CONF_RUNTIME}"

if [ ! -f "${WG_CONF}" ]; then
    WG_CONF="${WG_CONF_FALLBACK}"
fi

if [ ! -f "$HEALTHCHECK_FILE" ]; then
    echo 0 > "$HEALTHCHECK_FILE"
fi
FAILURE_COUNT=$(cat "$HEALTHCHECK_FILE")

if [ -n "${HEALTH_URL_CHECK:-}" ]; then
    HOST="${HEALTH_URL_CHECK}"
else
    if [ -z "${DISABLE_TUNNEL_MODE:-}" ]; then
        PEER=$(grep -i "^Endpoint" "${WG_CONF}" | head -n1 | cut -d'=' -f2 | tr -d ' ')
        HOST=$(echo "$PEER" | rev | cut -d':' -f2- | rev | sed 's/^\[//;s/\]$//')
    else
        HOST=$(grep -i "^AllowedIPs" "${WG_CONF}" | head -n1 | cut -d'=' -f2 | tr -d ' ' | awk -F',' '{print $1}' | awk -F'/' '{print $1}')
    fi
fi

if [ -z "${HOST}" ]; then
    exit 1
fi

# Ping with 5s timeout (Docker healthcheck waits max 10s)
if awg show wg0 > /dev/null 2>&1 && ping -I wg0 -c 1 -W 5 "$HOST" > /dev/null 2>&1; then
    if [ "$FAILURE_COUNT" != "0" ]; then
        echo 0 > "$HEALTHCHECK_FILE"
    fi
    exit 0
else
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    echo "$FAILURE_COUNT" > "$HEALTHCHECK_FILE"
    
    if [ "$FAILURE_COUNT" -ge "$MAX_FAILURES" ]; then
        echo "---Healthcheck failed ${MAX_FAILURES} times, restarting tunnel...---"
        awg-quick down wg0 > /dev/null 2>&1
        sleep 2
        awg-quick up "${WG_CONF}" > /dev/null 2>&1
        echo 0 > "$HEALTHCHECK_FILE"
    fi
    exit 1
fi