#!/bin/sh
set -eu

CONF_DIR="/etc/amnezia/amneziawg"
RUNTIME_DIR="/run/amnezia"
WG_RUNTIME_CONF="${RUNTIME_DIR}/wg0.conf"
PROXY_PID=""
PRINT_PUBLIC_IP="${PRINT_PUBLIC_IP:-0}"
PROXY_CONFIG_DEFAULT="/etc/3proxy/3proxy.cfg"
PROXY_CONFIG_CUSTOM="/etc/3proxy-ext/3proxy.custom.cfg"
PROXY_CONFIG="${PROXY_CONFIG_DEFAULT}"

cleanup() {
    if [ -n "${PROXY_PID}" ]; then
        kill "${PROXY_PID}" > /dev/null 2>&1 || true
    fi
    awg-quick down wg0 > /dev/null 2>&1 || true
}

trap 'cleanup' EXIT INT TERM

# 1. Find and select config
if [ ! -d "${CONF_DIR}" ]; then
    echo "---ERROR: Config directory '${CONF_DIR}' not found!---"
    exit 1
fi

if [ "$(find "${CONF_DIR}" -maxdepth 1 -type f -name "*.conf" | wc -l)" -eq 0 ]; then
    echo "---ERROR: No AmneziaWG .conf file found!---"
    exit 1
fi

if [ "${ENABLE_RANDOM:-0}" = "1" ]; then
    WG_CONF_FILE=$(find "${CONF_DIR}" -maxdepth 1 -type f -name "*.conf" ! -name "wg0.conf" | shuf -n 1 || true)
    [ -z "${WG_CONF_FILE}" ] && WG_CONF_FILE=$(find "${CONF_DIR}" -maxdepth 1 -type f -name "*.conf" | sort | head -1)
    echo "---Random AmneziaWG config selected: ${WG_CONF_FILE}---"
else
    WG_CONF_FILE=$(find "${CONF_DIR}" -maxdepth 1 -type f -name "*.conf" | sort | head -1)
    echo "---AmneziaWG config selected: ${WG_CONF_FILE}---"
fi

mkdir -p "${RUNTIME_DIR}" "${CONF_DIR}"
cp "${WG_CONF_FILE}" "${WG_RUNTIME_CONF}"

# 2. Configure DNS and networking
resolvconf -a control < /etc/resolv.conf > /dev/null 2>&1 || true
resolvconf -u > /dev/null 2>&1 || true

IP4GATEWAY=$(ip route | awk '/default/ { print $3 }' | head -1)
IP6GATEWAY=$(ip -6 route | awk '/default/ { print $3 }' | head -1)

# Allow local networks
iptables -I OUTPUT -d 192.168.0.0/16 -j ACCEPT
iptables -I OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -I OUTPUT -d 10.0.0.0/8 -j ACCEPT
ip6tables -I OUTPUT -d fc00::/7 -j ACCEPT
ip6tables -I OUTPUT -d fe80::/10 -j ACCEPT
ip6tables -I OUTPUT -d ff00::/8 -j ACCEPT

if [ -z "${DISABLE_TUNNEL_MODE:-}" ]; then
    grep -q "::/0" "${WG_RUNTIME_CONF}" || ip -6 route flush default
    grep -q "0.0.0.0/0" "${WG_RUNTIME_CONF}" || ip route flush default
fi

# 3. Start AmneziaWG
echo "---Starting Amnezia tunnel...---"
mkdir -p /dev/net
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun

if ! awg-quick up "${WG_RUNTIME_CONF}"; then
    echo "---FATAL: Failed to start AmneziaWG tunnel!---"
    exit 1
fi
echo "---AmneziaWG tunnel started successfully.---"

# 4. Tunnel firewall rules
if [ -z "${DISABLE_TUNNEL_MODE:-}" ]; then
    FWMARK=$(awg show wg0 fwmark)
    iptables -A OUTPUT ! -o wg0 -m mark ! --mark "$FWMARK" -m addrtype ! --dst-type LOCAL -j REJECT
    ip6tables -A OUTPUT ! -o wg0 -m mark ! --mark "$FWMARK" -m addrtype ! --dst-type LOCAL -j REJECT
fi

# 5. Check public IPs (optional, may slow startup)
if [ "${PRINT_PUBLIC_IP}" = "1" ]; then
    PUBLIC_IP4=$(wget -qO- -T 3 ipv4.icanhazip.com 2>/dev/null || echo "Unavailable")
    echo "Public IPv4: ${PUBLIC_IP4}"
    PUBLIC_IP6=$(wget -qO- -T 3 ipv6.icanhazip.com 2>/dev/null || echo "Unavailable")
    echo "Public IPv6: ${PUBLIC_IP6}"
fi

# 6. Add LAN bypass routes
if [ -n "${LAN_NETWORK:-}" ] && [ -n "${IP4GATEWAY}" ]; then
    OLD_IFS=${IFS}
    IFS=','
    for network in ${LAN_NETWORK}; do
        network=$(echo "$network" | xargs)
        [ -n "${network}" ] || continue
        ip route replace "${network}" via "$IP4GATEWAY" dev eth0 onlink || true
    done
    IFS=${OLD_IFS}
fi

if [ -n "${LAN_NETWORK6:-}" ] && [ -n "${IP6GATEWAY}" ]; then
    OLD_IFS=${IFS}
    IFS=','
    for network6 in ${LAN_NETWORK6}; do
        network6=$(echo "$network6" | xargs)
        [ -n "${network6}" ] || continue
        ip -6 route replace "$network6" via "$IP6GATEWAY" dev eth0 onlink || true
        ip6tables -C OUTPUT -d "$network6" -j ACCEPT 2>/dev/null || ip6tables -I OUTPUT -d "$network6" -j ACCEPT
    done
    IFS=${OLD_IFS}
fi

# 7. Start proxy
# Default config is used unless
# /etc/3proxy-ext/3proxy.custom.cfg exists (custom override).
if [ -s "${PROXY_CONFIG_CUSTOM}" ]; then
    PROXY_CONFIG="${PROXY_CONFIG_CUSTOM}"
fi

echo "---Starting 3proxy (SOCKS5:1080, HTTP:8080) using config: ${PROXY_CONFIG}---"
3proxy "${PROXY_CONFIG}" &
PROXY_PID="$!"

echo "---All services started. Container ready.---"
wait "${PROXY_PID}"
