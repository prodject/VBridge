#!/bin/bash

set -euo pipefail

ACTION="${1:-install}"
SRTP_DTLS_PORT="${SRTP_DTLS_PORT:-57000}"
SRTP_WG_PORT="${SRTP_WG_PORT:-57001}"
SRTP_DNS1="${SRTP_DNS1:-1.1.1.1}"
SRTP_DNS2="${SRTP_DNS2:-1.0.0.1}"
INSTALL_LOG=/var/log/srtp-install.log

exec > >(tee -a "$INSTALL_LOG") 2>&1

uninstall() {
    systemctl disable --now vbridge-srtp.service 2>/dev/null || true
    systemctl disable --now wg-quick@srtp0.service 2>/dev/null || true
    rm -f /etc/systemd/system/vbridge-srtp.service /etc/wireguard/srtp0.conf
    rm -f /etc/sysctl.d/99-vbridge-srtp.conf
    rm -rf /etc/vbridge-srtp
    rm -f /usr/local/bin/vbridge-srtp-server
    systemctl daemon-reload
    echo "SRTP uninstalled"
}

status() {
    systemctl status vbridge-srtp.service --no-pager -n 20 || true
    systemctl status wg-quick@srtp0.service --no-pager -n 20 || true
    [ -f /etc/vbridge-srtp/client.conf ] && {
        echo "Client WireGuard configuration:"
        cat /etc/vbridge-srtp/client.conf
        echo "Use SRTP mode, server ${SRTP_PUBLIC_HOST:-SERVER_IP}:$SRTP_DTLS_PORT, and your VK call URL in the client."
    }
}

if [ "$ACTION" = uninstall ]; then uninstall; exit 0; fi
if [ "$ACTION" = status ]; then status; exit 0; fi
[ "$ACTION" = install ] || { echo "error: unsupported action $ACTION"; exit 1; }

command -v apt-get >/dev/null 2>&1 || { echo "error: Debian/Ubuntu is required"; exit 1; }
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iptables

install -d -m 700 /etc/vbridge-srtp /etc/wireguard
install -m 755 /tmp/srtp-server /usr/local/bin/vbridge-srtp-server

if [ ! -s /etc/vbridge-srtp/server.key ]; then
    umask 077
    wg genkey > /etc/vbridge-srtp/server.key
    wg pubkey < /etc/vbridge-srtp/server.key > /etc/vbridge-srtp/server.pub
    wg genkey > /etc/vbridge-srtp/client.key
    wg pubkey < /etc/vbridge-srtp/client.key > /etc/vbridge-srtp/client.pub
fi

SERVER_PRIVATE=$(cat /etc/vbridge-srtp/server.key)
SERVER_PUBLIC=$(cat /etc/vbridge-srtp/server.pub)
CLIENT_PRIVATE=$(cat /etc/vbridge-srtp/client.key)
CLIENT_PUBLIC=$(cat /etc/vbridge-srtp/client.pub)

cat > /etc/wireguard/srtp0.conf <<EOF
[Interface]
Address = 10.66.68.1/24
ListenPort = $SRTP_WG_PORT
PrivateKey = $SERVER_PRIVATE
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.66.68.0/24 -o \$(ip route show default | awk 'NR==1 {print \$5}') -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.66.68.0/24 -o \$(ip route show default | awk 'NR==1 {print \$5}') -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC
AllowedIPs = 10.66.68.2/32
EOF
chmod 600 /etc/wireguard/srtp0.conf

cat > /etc/vbridge-srtp/client.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = 10.66.68.2/32
DNS = $SRTP_DNS1, $SRTP_DNS2

[Peer]
PublicKey = $SERVER_PUBLIC
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:9000
PersistentKeepalive = 25
EOF
chmod 600 /etc/vbridge-srtp/client.conf

cat > /etc/systemd/system/vbridge-srtp.service <<EOF
[Unit]
Description=VBridge SRTP transport server
After=network-online.target wg-quick@srtp0.service
Wants=network-online.target
Requires=wg-quick@srtp0.service

[Service]
ExecStart=/usr/local/bin/vbridge-srtp-server -listen 0.0.0.0:$SRTP_DTLS_PORT -connect 127.0.0.1:$SRTP_WG_PORT -srtp -logfile /var/log/srtp.server.log
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

sysctl -w net.ipv4.ip_forward=1
cat > /etc/sysctl.d/99-vbridge-srtp.conf <<EOF
net.ipv4.ip_forward=1
EOF
systemctl daemon-reload
systemctl enable wg-quick@srtp0.service vbridge-srtp.service
systemctl restart wg-quick@srtp0.service vbridge-srtp.service
echo "SRTP installed on UDP $SRTP_DTLS_PORT"
status
