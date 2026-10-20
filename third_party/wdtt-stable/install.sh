#!/usr/bin/env bash
# Установка wdtt-server на Ubuntu/Debian VPS: сборка из исходников, systemd-служба, порты.
# Запуск: sudo bash install.sh
set -euo pipefail

GO_VERSION="1.25.0"
BIN=/usr/local/bin/wdtt-server
CONF_DIR=/etc/wdtt
ENV_FILE=$CONF_DIR/wdtt.env
UNIT=/etc/systemd/system/wdtt.service
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Запусти через sudo: sudo bash install.sh"; exit 1; }

echo "== Сборка wdtt-server =="
if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$SRC_DIR":/build -w /build golang:1.25 bash -c \
        "go mod tidy && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags='-s -w' -o /build/wdtt-server ."
else
    apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
    TMP_GO=$(mktemp -d)
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -xz -C "$TMP_GO"
    (cd "$SRC_DIR" && "$TMP_GO/go/bin/go" mod tidy && \
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$TMP_GO/go/bin/go" build -ldflags='-s -w' -o wdtt-server .)
    rm -rf "$TMP_GO"
fi
install -m 755 "$SRC_DIR/wdtt-server" "$BIN"
rm -f "$SRC_DIR/wdtt-server"
echo "Установлено: $BIN"

echo
echo "== Настройка =="
mkdir -p "$CONF_DIR"
if [ -f "$ENV_FILE" ]; then
    echo "$ENV_FILE уже есть — оставляю текущие настройки."
else
    read -rp "Пароль владельца сервера (придумай длинный): " WDTT_PASSWORD
    read -rp "Токен Telegram-бота (от @BotFather): " WDTT_BOT_TOKEN
    read -rp "Твой Telegram ID (узнать у @userinfobot): " WDTT_ADMIN
    read -rp "DNS для клиентов [1.1.1.1,1.0.0.1]: " WDTT_DNS
    WDTT_DNS=${WDTT_DNS:-1.1.1.1,1.0.0.1}
    umask 077
    cat > "$ENV_FILE" <<EOF
WDTT_PASSWORD=$WDTT_PASSWORD
WDTT_BOT_TOKEN=$WDTT_BOT_TOKEN
WDTT_ADMIN=$WDTT_ADMIN
WDTT_DNS=$WDTT_DNS
WDTT_DTLS_PORT=56000
WDTT_WG_PORT=56001
EOF
    umask 022
fi
chmod 600 "$ENV_FILE"

cat > "$UNIT" <<'EOF'
[Unit]
Description=WDTT VPN Server
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/wdtt/wdtt.env
ExecStartPre=-/usr/bin/env bash -c "ip link show wdtt0 >/dev/null 2>&1 && ip link del wdtt0 || true"
ExecStartPre=-/usr/bin/env bash -c "command -v iptables >/dev/null || exit 0; for p in ${WDTT_DTLS_PORT} ${WDTT_WG_PORT}; do iptables -C INPUT -p udp --dport $$p -m comment --comment WDTT_MANAGED -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $$p -m comment --comment WDTT_MANAGED -j ACCEPT; done"
ExecStart=/usr/local/bin/wdtt-server -listen 0.0.0.0:${WDTT_DTLS_PORT} -wg-port ${WDTT_WG_PORT} -config-dir /etc/wdtt -password ${WDTT_PASSWORD} -dns ${WDTT_DNS} -admin ${WDTT_ADMIN} -bot-token ${WDTT_BOT_TOKEN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 56000/udp comment "WDTT DTLS" >/dev/null
    ufw allow 56001/udp comment "WDTT WireGuard" >/dev/null
    echo "ufw: открыты 56000/udp и 56001/udp"
fi

systemctl daemon-reload
systemctl enable --now wdtt >/dev/null
sleep 3
if systemctl is-active --quiet wdtt; then
    echo
    echo "Готово: wdtt-server работает. Напиши своему боту в Telegram /new — он выдаст ключ wdtt://..."
    echo "Логи: journalctl -u wdtt -f"
else
    echo "Служба не запустилась, смотри: journalctl -u wdtt -n 50"
    exit 1
fi
