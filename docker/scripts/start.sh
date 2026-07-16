#!/bin/sh
set -eu

echo "---Starting Amnezia Gateway...---"
exec /opt/amnezia/scripts/start-wg.sh
