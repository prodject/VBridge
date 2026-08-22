#!/bin/sh

set -eu

WORK_DIR="/opt/vbridge-csqtt"
CONFIG_DIR="$WORK_DIR/config"
LOG_FILE="/var/log/csqtt-install.log"
PEER_PORT="${CSQTT_PEER_PORT:-46000}"
WEB_PORT="${CSQTT_WEB_PORT:-46002}"
CLIENT_CIDR="${CSQTT_CLIENT_CIDR:-10.66.67.0/24}"
OPEN_FIREWALL="${CSQTT_OPEN_FIREWALL:-1}"
ENABLE_TCPMSS="${CSQTT_ENABLE_TCPMSS:-1}"
SSH_PORT="${CSQTT_SSH_PORT:-22}"
WEB_USER="${CSQTT_WEB_USER:-admin}"
WEB_PASS="${CSQTT_WEB_PASS:-}"
PRESERVE_CONFIG="${CSQTT_PRESERVE_CONFIG:-0}"

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "error: run as root"
        exit 1
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log "[*] Installing Docker"
        apt-get update
        apt-get install -y curl ca-certificates git
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
    fi
    apt-get install -y docker-compose-plugin
    systemctl enable --now docker
}

cleanup_firewall_rules() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    WAN_IFACE=$(ip -o route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -z "$WAN_IFACE" ]; then
        WAN_IFACE="eth0"
    fi

    iptables -t nat -C POSTROUTING -s "$CSQTT_CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null && \
        iptables -t nat -D POSTROUTING -s "$CSQTT_CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE || true

    iptables -C INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT || true

    iptables -C INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT 2>/dev/null && \
        iptables -D INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT || true

    if [ -n "$CSQTT_SSH_PORT" ]; then
        iptables -C INPUT -p tcp --dport "$CSQTT_SSH_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT 2>/dev/null && \
            iptables -D INPUT -p tcp --dport "$CSQTT_SSH_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT || true
    fi

    iptables -t mangle -C FORWARD -s "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
        iptables -t mangle -D FORWARD -s "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true

    iptables -t mangle -C FORWARD -d "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
        iptables -t mangle -D FORWARD -d "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
}

write_assets() {
    mkdir -p "$WORK_DIR" "$CONFIG_DIR"
    install -m 755 /tmp/csqtt "$WORK_DIR/csqtt"

    cat >"$WORK_DIR/Dockerfile" <<'EOF'
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    iproute2 \
    ca-certificates \
    curl \
    procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /etc/csqtt
COPY csqtt /usr/local/bin/csqtt
RUN chmod +x /usr/local/bin/csqtt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENV CSQTT_PEER_PORT=46000 \
    CSQTT_WEB_PORT=46002 \
    CSQTT_CLIENT_CIDR=10.66.67.0/24 \
    CSQTT_ENABLE_TCPMSS=1 \
    CSQTT_OPEN_FIREWALL=1 \
    CSQTT_ARGS=""
EXPOSE 46000/udp
EXPOSE 46002/tcp
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat >"$WORK_DIR/docker-compose.yml" <<'EOF'
version: '3.8'
services:
  csqtt:
    build: .
    container_name: csqtt-vpn
    restart: always
    init: true
    platform: linux/amd64
    privileged: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    network_mode: ${CSQTT_NETWORK_MODE:-host}
    environment:
      - CSQTT_PEER_PORT=${CSQTT_PEER_PORT:-46000}
      - CSQTT_WEB_PORT=${CSQTT_WEB_PORT:-46002}
      - CSQTT_ARGS=${CSQTT_ARGS:-}
      - CSQTT_CLIENT_CIDR=${CSQTT_CLIENT_CIDR:-10.66.67.0/24}
      - CSQTT_ENABLE_TCPMSS=${CSQTT_ENABLE_TCPMSS:-1}
      - CSQTT_OPEN_FIREWALL=${CSQTT_OPEN_FIREWALL:-1}
      - CSQTT_SSH_PORT=${CSQTT_SSH_PORT:-}
    volumes:
      - ./config:/etc/csqtt
EOF

    cat >"$WORK_DIR/entrypoint.sh" <<'EOF'
#!/bin/sh
set -e
CONFIG_DIR="/etc/csqtt"
IFACE="csqtt1"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/csqtt.env" ]; then
    set -a
    . "$CONFIG_DIR/csqtt.env"
    set +a
fi
CSQTT_PEER_PORT="${CSQTT_PEER_PORT:-46000}"
CSQTT_WEB_PORT="${CSQTT_WEB_PORT:-46002}"
CSQTT_CLIENT_CIDR="${CSQTT_CLIENT_CIDR:-10.66.67.0/24}"
CSQTT_ENABLE_TCPMSS="${CSQTT_ENABLE_TCPMSS:-1}"
CSQTT_OPEN_FIREWALL="${CSQTT_OPEN_FIREWALL:-1}"
CSQTT_SSH_PORT="${CSQTT_SSH_PORT:-}"
ip link del "$IFACE" 2>/dev/null || true
for old_iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep '^csqtp' || true); do
    ip link del "$old_iface" 2>/dev/null || true
done
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
WAN_IFACE=$(ip -o route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [ -z "$WAN_IFACE" ]; then
    WAN_IFACE="eth0"
fi
iptables -t nat -C POSTROUTING -s "$CSQTT_CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$CSQTT_CLIENT_CIDR" -o "$WAN_IFACE" -j MASQUERADE
if [ "$CSQTT_OPEN_FIREWALL" = "1" ]; then
    iptables -C INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "$CSQTT_PEER_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT
    iptables -C INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$CSQTT_WEB_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT
    if [ -n "$CSQTT_SSH_PORT" ]; then
        iptables -C INPUT -p tcp --dport "$CSQTT_SSH_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$CSQTT_SSH_PORT" -m comment --comment CSQTT_DOCKER -j ACCEPT
    fi
fi
if [ "$CSQTT_ENABLE_TCPMSS" = "1" ]; then
    iptables -t mangle -C FORWARD -s "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A FORWARD -s "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -d "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A FORWARD -d "$CSQTT_CLIENT_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
ARGS=""
if [ -n "${CSQTT_WEB_PASS:-}" ]; then
    ARGS="$ARGS --web-pass ${CSQTT_WEB_PASS}"
fi
if [ -n "${CSQTT_WEB_USER:-}" ]; then
    ARGS="$ARGS --web-user ${CSQTT_WEB_USER}"
fi
exec /usr/local/bin/csqtt --listen "0.0.0.0:${CSQTT_PEER_PORT}" --web-port "${CSQTT_WEB_PORT}" --config-dir "$CONFIG_DIR" ${CSQTT_ARGS:-} $ARGS
EOF

    chmod 755 "$WORK_DIR/entrypoint.sh"

    if [ "$PRESERVE_CONFIG" != "1" ]; then
        rm -f "$CONFIG_DIR/csqtt.env"
    fi

    cat >"$WORK_DIR/.env" <<EOF
CSQTT_PEER_PORT=$PEER_PORT
CSQTT_WEB_PORT=$WEB_PORT
CSQTT_CLIENT_CIDR=$CLIENT_CIDR
CSQTT_ENABLE_TCPMSS=$ENABLE_TCPMSS
CSQTT_OPEN_FIREWALL=$OPEN_FIREWALL
CSQTT_SSH_PORT=$SSH_PORT
CSQTT_WEB_USER=$WEB_USER
CSQTT_WEB_PASS=$WEB_PASS
EOF
}

do_install() {
    ensure_docker
    write_assets
    cd "$WORK_DIR"
    docker compose up -d --build
    log "[ok] CSQTT installed"
}

do_uninstall() {
    if [ -d "$WORK_DIR" ]; then
        cd "$WORK_DIR"
        docker compose down --remove-orphans || true
    fi
    cleanup_firewall_rules
    rm -rf "$WORK_DIR"
    log "[ok] CSQTT uninstalled"
}

do_status() {
    installed=0
    running=0
    if [ -x "$WORK_DIR/csqtt" ] && [ -f "$WORK_DIR/docker-compose.yml" ]; then
        installed=1
    fi
    if docker ps --filter name=csqtt-vpn --filter status=running -q 2>/dev/null | grep -q .; then
        running=1
    fi
    echo "Server connected: yes"
    if [ "$installed" = "1" ]; then echo "CSQTT installed: yes"; else echo "CSQTT installed: no"; fi
    if [ "$installed" = "1" ] && [ "$running" = "1" ]; then echo "Ready to connect: yes"; else echo "Ready to connect: no"; fi
}

ensure_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

case "${1:-install}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
    *) echo "error: unknown action $1"; exit 1 ;;
esac
