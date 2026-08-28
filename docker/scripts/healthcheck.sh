#!/bin/sh
set -eu

MAX_HANDSHAKE_AGE="${MAX_HANDSHAKE_AGE:-180}"

awg show wg0 > /dev/null 2>&1 || exit 1

NOW=$(date +%s)
LATEST=0

for TS in $(awg show wg0 latest-handshakes | awk '{print $2}'); do
    [ "$TS" -gt "$LATEST" ] && LATEST="$TS"
done

[ "$LATEST" -gt 0 ] || exit 1
[ $((NOW - LATEST)) -le "$MAX_HANDSHAKE_AGE" ]
