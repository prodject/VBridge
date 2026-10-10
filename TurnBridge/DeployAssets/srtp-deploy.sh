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
    rm -f /usr/local/bin/vbridge-srtp-server /usr/local/sbin/vbridge-srtp-client
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
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iptables python3

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

cat > /etc/vbridge-srtp/server.env <<EOF
SRTP_WG_PORT=$SRTP_WG_PORT
SRTP_DNS1=$SRTP_DNS1
SRTP_DNS2=$SRTP_DNS2
EOF
chmod 600 /etc/vbridge-srtp/server.env

if [ ! -s /etc/vbridge-srtp/clients.json ]; then
    python3 - "$CLIENT_PRIVATE" "$CLIENT_PUBLIC" <<'PY'
import json, sys, time, uuid
private_key, public_key = sys.argv[1:3]
data = [{"id": str(uuid.uuid4()), "label": "Default", "address": "10.66.68.2", "private_key": private_key, "public_key": public_key, "created_at": int(time.time())}]
with open("/etc/vbridge-srtp/clients.json", "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
PY
    chmod 600 /etc/vbridge-srtp/clients.json
fi

cat > /usr/local/sbin/vbridge-srtp-client <<'PY'
#!/usr/bin/env python3
import base64, json, os, subprocess, sys, tempfile, time, uuid

ROOT = "/etc/vbridge-srtp"
DB = os.path.join(ROOT, "clients.json")
WG = "/etc/wireguard/srtp0.conf"

def fail(message):
    print(json.dumps({"ok": False, "message": message}, ensure_ascii=False))
    raise SystemExit(1)

def load():
    try:
        with open(DB, encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, list) else []
    except FileNotFoundError:
        return []

def save(clients):
    fd, path = tempfile.mkstemp(prefix="clients.", dir=ROOT)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(clients, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(path, 0o600)
        os.replace(path, DB)
    finally:
        if os.path.exists(path): os.unlink(path)

def env():
    result = {}
    try:
        with open(os.path.join(ROOT, "server.env"), encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.strip().split("=", 1)
                    result[key] = value
    except FileNotFoundError:
        pass
    return result

def client_config(client):
    settings = env()
    server_public = open(os.path.join(ROOT, "server.pub"), encoding="utf-8").read().strip()
    dns = ", ".join(filter(None, [settings.get("SRTP_DNS1", "1.1.1.1"), settings.get("SRTP_DNS2", "1.0.0.1")]))
    return f"""[Interface]
PrivateKey = {client['private_key']}
Address = {client['address']}/32
DNS = {dns}

[Peer]
PublicKey = {server_public}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:9000
PersistentKeepalive = 25
"""

def public_rows(clients):
    return [{"id": item["id"], "label": item.get("label", ""), "address": item["address"], "public_key": item["public_key"], "created_at": item.get("created_at", 0), "config": client_config(item)} for item in clients]

def reconcile(clients):
    settings = env()
    private_key = open(os.path.join(ROOT, "server.key"), encoding="utf-8").read().strip()
    port = settings.get("SRTP_WG_PORT", "57001")
    peers = "".join(f"\n[Peer]\n# VBridge client: {item['id']}\nPublicKey = {item['public_key']}\nAllowedIPs = {item['address']}/32\n" for item in clients)
    config = f"""[Interface]
Address = 10.66.68.1/24
ListenPort = {port}
PrivateKey = {private_key}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.66.68.0/24 -o $(ip route show default | awk 'NR==1 {{print $5}}') -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.66.68.0/24 -o $(ip route show default | awk 'NR==1 {{print $5}}') -j MASQUERADE
{peers}"""
    with open(WG, "w", encoding="utf-8") as handle:
        handle.write(config)
    os.chmod(WG, 0o600)
    subprocess.run(["systemctl", "restart", "wg-quick@srtp0.service"], check=True, stdout=subprocess.DEVNULL)

action = sys.argv[1] if len(sys.argv) > 1 else "list"
clients = load()
if action == "create":
    label = base64.b64decode(sys.argv[2]).decode("utf-8").strip() if len(sys.argv) > 2 else ""
    used = {item.get("address") for item in clients}
    address = next((f"10.66.68.{value}" for value in range(2, 255) if f"10.66.68.{value}" not in used), None)
    if not address: fail("SRTP address pool is full")
    private_key = subprocess.check_output(["wg", "genkey"], text=True).strip()
    public_key = subprocess.check_output(["wg", "pubkey"], input=private_key + "\n", text=True).strip()
    clients.append({"id": str(uuid.uuid4()), "label": label or f"Client {address.rsplit('.', 1)[1]}", "address": address, "private_key": private_key, "public_key": public_key, "created_at": int(time.time())})
    save(clients); reconcile(clients)
elif action == "delete":
    target = sys.argv[2] if len(sys.argv) > 2 else ""
    updated = [item for item in clients if item.get("id") != target]
    if len(updated) == len(clients): fail("SRTP client not found")
    clients = updated; save(clients); reconcile(clients)
elif action == "sync":
    reconcile(clients)
elif action != "list":
    fail("unsupported action")
print(json.dumps({"ok": True, "message": "OK", "clients": public_rows(clients)}, ensure_ascii=False))
PY
chmod 700 /usr/local/sbin/vbridge-srtp-client
/usr/local/sbin/vbridge-srtp-client sync >/dev/null

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
