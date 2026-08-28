#!/bin/sh
set -eu

awg show wg0 > /dev/null 2>&1
[ -n "$(awg show wg0 peers)" ]
