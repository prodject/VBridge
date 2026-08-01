package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

type outboundRequest struct {
	Action    string `json:"action"`
	Host      string `json:"host"`
	User      string `json:"user"`
	Password  string `json:"password"`
	Port      int    `json:"port"`
	Kind      string `json:"kind,omitempty"`
	ProxyHost string `json:"proxyHost,omitempty"`
	ProxyPort int    `json:"proxyPort,omitempty"`
	Login     string `json:"login,omitempty"`
	Secret    string `json:"secret,omitempty"`
	LocalPort int    `json:"localPort,omitempty"`
	SSHPort   int    `json:"sshPort,omitempty"`
	DNS       string `json:"dns,omitempty"`
	MTU       int    `json:"mtu,omitempty"`
}

type outboundResponse struct {
	OK      bool   `json:"ok"`
	Status  string `json:"status"`
	Message string `json:"message"`
	Output  string `json:"output"`
}

//export VBridgeWGServerOutbound
func VBridgeWGServerOutbound(configJSON *C.char) *C.char {
	if configJSON == nil {
		return outboundCString(outboundResponse{OK: false, Status: "error", Message: "empty outbound config"})
	}
	var req outboundRequest
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &req); err != nil {
		return outboundCString(outboundResponse{OK: false, Status: "error", Message: "invalid outbound JSON: " + err.Error()})
	}
	resp := runOutbound(req)
	return outboundCString(resp)
}

func outboundCString(resp outboundResponse) *C.char {
	data, err := json.Marshal(resp)
	if err != nil {
		return C.CString(`{"ok":false,"status":"error","message":"failed to encode outbound response","output":""}`)
	}
	return C.CString(string(data))
}

func runOutbound(req outboundRequest) outboundResponse {
	req.Action = strings.TrimSpace(strings.ToLower(req.Action))
	req.Host = strings.TrimSpace(req.Host)
	req.User = strings.TrimSpace(req.User)
	req.Kind = strings.TrimSpace(strings.ToLower(req.Kind))
	req.ProxyHost = strings.TrimSpace(req.ProxyHost)
	req.Login = strings.TrimSpace(req.Login)
	if req.User == "" {
		req.User = "root"
	}
	if req.Port == 0 {
		req.Port = 22
	}
	if req.Host == "" {
		return outboundResponse{OK: false, Status: "error", Message: "server host is empty"}
	}
	if req.Password == "" {
		return outboundResponse{OK: false, Status: "error", Message: "SSH password is empty"}
	}

	client, err := dialDeploySSH(deployRequest{Host: req.Host, User: req.User, Password: req.Password, Port: req.Port})
	if err != nil {
		return outboundResponse{OK: false, Status: "error", Message: "SSH connect failed: " + err.Error()}
	}
	defer client.Close()

	command, timeout, err := req.command()
	if err != nil {
		return outboundResponse{OK: false, Status: "error", Message: err.Error()}
	}
	output, err := runSSHCommand(client, rootDeployCommand(command, req.Password), timeout)
	if err != nil {
		return outboundResponse{OK: false, Status: "error", Message: friendlyOutboundError(output, err), Output: output}
	}
	message := successOutboundMessage(req.Action)
	return outboundResponse{OK: true, Status: "success", Message: message, Output: output}
}

func (r outboundRequest) command() (string, time.Duration, error) {
	switch r.Action {
	case "status":
		return outboundStatusScript(), 25 * time.Second, nil
	case "diagnostics":
		return outboundDiagnosticsScript(), 40 * time.Second, nil
	case "direct":
		return outboundDisableScript(), 30 * time.Second, nil
	case "external_check":
		if err := validateExternalProxy(r); err != nil {
			return "", 0, err
		}
		return externalProxyCheckScript(r.Kind, r.ProxyHost, r.ProxyPort, r.Login, r.Secret), 25 * time.Second, nil
	case "external_enable":
		if err := validateExternalProxy(r); err != nil {
			return "", 0, err
		}
		return externalProxyEnableScript(r.Kind, r.ProxyHost, r.ProxyPort, r.Login, r.Secret), 3 * time.Minute, nil
	case "warp_check":
		return freeWarpCheckScript(false), 35 * time.Second, nil
	case "warp_restart":
		return freeWarpCheckScript(true), 40 * time.Second, nil
	case "warp_install":
		mtu := r.MTU
		if mtu == 0 {
			mtu = 1280
		}
		return freeWarpInstallScript(mtu), 5 * time.Minute, nil
	case "warp_reset":
		return resetFreeWarpScript(), 45 * time.Second, nil
	case "warp_delete":
		return deleteFreeWarpScript(), 30 * time.Second, nil
	case "wireguard_vps_enable":
		if err := validateWireGuardVPS(r); err != nil {
			return "", 0, err
		}
		return wireGuardVPSApplyScript(r), 4 * time.Minute, nil
	case "wireguard_vps_check":
		return wireGuardVPSCheckScript(), 30 * time.Second, nil
	case "wireguard_vps_remove":
		return wireGuardVPSRemoveScript(), 40 * time.Second, nil
	case "local_install":
		if r.Login == "" || r.Secret == "" {
			return "", 0, fmt.Errorf("local proxy login and password are required")
		}
		port := r.LocalPort
		if port == 0 {
			port = 1080
		}
		if port < 1 || port > 65533 {
			return "", 0, fmt.Errorf("local proxy port must be between 1 and 65533")
		}
		return localProxyInstallScript(r.Login, r.Secret, port), 4 * time.Minute, nil
	case "local_check":
		return localProxyCheckScript(), 20 * time.Second, nil
	case "local_stop":
		return localProxyRemoveScript(false), 20 * time.Second, nil
	case "local_remove":
		return localProxyRemoveScript(true), 30 * time.Second, nil
	default:
		return "", 0, fmt.Errorf("unsupported outbound action %q", r.Action)
	}
}

func validateExternalProxy(r outboundRequest) error {
	if r.Kind != "socks5" && r.Kind != "http" {
		return fmt.Errorf("proxy type must be socks5 or http")
	}
	if r.ProxyHost == "" {
		return fmt.Errorf("proxy host is empty")
	}
	if ip := net.ParseIP(r.ProxyHost); ip == nil {
		for _, label := range strings.Split(r.ProxyHost, ".") {
			if label == "" {
				return fmt.Errorf("proxy host is invalid")
			}
		}
	}
	if r.ProxyPort < 1 || r.ProxyPort > 65535 {
		return fmt.Errorf("proxy port must be between 1 and 65535")
	}
	if (r.Login == "") != (r.Secret == "") {
		return fmt.Errorf("provide both proxy login and password, or leave both empty")
	}
	return nil
}

func validateWireGuardVPS(r outboundRequest) error {
	if strings.TrimSpace(r.ProxyHost) == "" {
		return fmt.Errorf("other server host is empty")
	}
	if strings.TrimSpace(r.Login) == "" {
		return fmt.Errorf("other server user is empty")
	}
	if strings.TrimSpace(r.Secret) == "" {
		return fmt.Errorf("other server SSH password is empty")
	}
	if r.SSHPort < 1 || r.SSHPort > 65535 {
		return fmt.Errorf("other server SSH port must be between 1 and 65535")
	}
	if r.ProxyPort < 1 || r.ProxyPort > 65535 {
		return fmt.Errorf("other server WireGuard port must be between 1 and 65535")
	}
	return nil
}

func successOutboundMessage(action string) string {
	switch action {
	case "status":
		return "Outbound status loaded."
	case "diagnostics":
		return "Outbound diagnostics loaded."
	case "direct":
		return "Direct outbound mode enabled."
	case "external_check":
		return "External proxy check completed."
	case "external_enable":
		return "External proxy enabled."
	case "warp_check":
		return "WARP check completed."
	case "warp_restart":
		return "WARP restarted and checked."
	case "warp_install":
		return "Free WARP installed or restored."
	case "warp_reset":
		return "WARP registration reset."
	case "warp_delete":
		return "WARP deleted."
	case "wireguard_vps_enable":
		return "Other server outbound enabled."
	case "wireguard_vps_check":
		return "Other server outbound check completed."
	case "wireguard_vps_remove":
		return "Other server outbound removed."
	case "local_install":
		return "Local proxy installed or updated."
	case "local_check":
		return "Local proxy check completed."
	case "local_stop":
		return "Local proxy stopped."
	case "local_remove":
		return "Local proxy removed."
	default:
		return "Outbound action completed."
	}
}

func friendlyOutboundError(output string, err error) string {
	lower := strings.ToLower(output)
	switch {
	case strings.Contains(lower, "wdtt_error=external_proxy_check_failed"):
		return "The server could not reach the test site through the external proxy."
	case strings.Contains(lower, "wdtt_error=external_proxy_service_inactive"):
		return "The external proxy redirect service failed to start on the server."
	case strings.Contains(lower, "wdtt_error=external_proxy_route_install_failed"):
		return "The server could not install redirect rules for the external proxy."
	case strings.Contains(lower, "wdtt_error=external_proxy_apply_failed"):
		return "The external proxy started, but WDTT traffic could not pass through it."
	case strings.Contains(lower, "wdtt_error=warp_mode_not_active"):
		return "Free WARP is not the active outbound mode on this server."
	case strings.Contains(lower, "wdtt_error=warp_account_missing"):
		return "The WARP account is missing on the server."
	case strings.Contains(lower, "wdtt_error=warp_profile_missing"):
		return "The WARP WireGuard profile is missing on the server."
	case strings.Contains(lower, "wdtt_error=warp_trace_check_failed"):
		return "Cloudflare did not confirm warp=on/plus for this server."
	case strings.Contains(lower, "wdtt_error=local_proxy_service_inactive"):
		return "The local proxy service failed to start on the server."
	case strings.Contains(lower, "wdtt_error=local_proxy_check_failed"):
		return "The local proxy did not pass the connectivity check."
	case strings.Contains(lower, "wdtt_error=3proxy_install_failed"):
		return "3proxy could not be installed on the server."
	case strings.Contains(lower, "wdtt_error=systemd_required"):
		return "This outbound mode requires systemd on the server."
	default:
		return "Outbound action failed: " + err.Error()
	}
}

func outboundPrelude() string {
	return `
set -e
WDTT_SUBNET="$(ip -4 route show dev wdtt0 scope link 2>/dev/null | awk '{print $1; exit}')"
[ -n "$WDTT_SUBNET" ] || WDTT_SUBNET="10.66.66.0/24"
WDTT_IFACE="wdtt0"
WDTT_TABLE="100"
WDTT_WG_IFACE="wg-wdtt-exit"
mkdir -p /etc/wdtt /etc/wdtt/outbound /etc/wdtt-plus/wg-exit
wdtt_test_source() {
  ip -4 -o addr show dev "$WDTT_IFACE" scope global 2>/dev/null | awk '{split($4, value, "/"); print value[1]; exit}'
}
wdtt_install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@" >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@" >/dev/null
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install -y "$@" >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@" >/dev/null
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "$@" >/dev/null
  else
    return 1
  fi
}
wdtt_install_redsocks_tools() {
  wdtt_install_pkg redsocks curl iptables psmisc iproute2 || wdtt_install_pkg redsocks curl iptables psmisc iproute || true
}
wdtt_clear_external_out() {
  systemctl disable --now wdtt-warp-watchdog.timer 2>/dev/null || true
  systemctl disable --now wdtt-wg-exit.service 2>/dev/null || true
  if command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -D PREROUTING -i "$WDTT_IFACE" -p tcp -j WDTT_PROXY_OUT 2>/dev/null; do :; done
    iptables -t nat -F WDTT_PROXY_OUT 2>/dev/null || true
    iptables -t nat -X WDTT_PROXY_OUT 2>/dev/null || true
    while iptables -t nat -D POSTROUTING -s "$WDTT_SUBNET" -o "$WDTT_WG_IFACE" -m comment --comment WDTT_EXIT -j MASQUERADE 2>/dev/null; do :; done
  fi
  while ip rule del from "$WDTT_SUBNET" table "$WDTT_TABLE" priority 100 2>/dev/null; do :; done
  ip route flush table "$WDTT_TABLE" 2>/dev/null || true
  systemctl disable --now wdtt-redsocks 2>/dev/null || systemctl stop wdtt-redsocks 2>/dev/null || true
  rm -f /run/wdtt-redsocks.pid 2>/dev/null || true
  if ! wg-quick down "$WDTT_WG_IFACE" 2>/dev/null; then
    ip link delete "$WDTT_WG_IFACE" 2>/dev/null || true
  fi
}
wdtt_write_mode() {
  mode="$1"
  detail="$2"
  cat >/etc/wdtt/outbound.json <<EOF
{
  "outboundMode": "$mode",
  "detail": "$detail",
  "wdttSubnet": "$WDTT_SUBNET",
  "interface": "$WDTT_IFACE",
  "routingTable": $WDTT_TABLE,
  "updatedAt": "$(date -Is)"
}
EOF
}
`
}

func outboundStatusScript() string {
	return outboundPrelude() + `
MODE="direct"
DETAIL="direct outbound through this server"
if [ -f /etc/wdtt/outbound.json ]; then
  MODE="$(grep -o '"outboundMode"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/wdtt/outbound.json | sed 's/.*"outboundMode"[[:space:]]*:[[:space:]]*"//;s/".*//' | head -1)"
  DETAIL="$(grep -o '"detail"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/wdtt/outbound.json | sed 's/.*"detail"[[:space:]]*:[[:space:]]*"//;s/".*//' | head -1)"
fi
echo "Mode: ${MODE:-direct}"
echo "Detail: ${DETAIL:-direct outbound through this server}"
echo "WDTT subnet: $WDTT_SUBNET"
echo "WDTT interface: $WDTT_IFACE"
SERVER_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo unknown)"
echo "Server public IP: $SERVER_IP"
if systemctl is-active wdtt-3proxy >/dev/null 2>&1; then echo "Local proxy service: active"; else echo "Local proxy service: inactive"; fi
if systemctl is-active wdtt-redsocks >/dev/null 2>&1; then echo "External proxy service: active"; else echo "External proxy service: inactive"; fi
if systemctl is-active wdtt-wg-exit.service >/dev/null 2>&1; then echo "WireGuard exit service: active"; else echo "WireGuard exit service: inactive"; fi
if [ "${MODE:-}" = "warp_free" ]; then
  TEST_SOURCE="$(wdtt_test_source)"
  WARP_TRACE=""
  [ -n "$TEST_SOURCE" ] && WARP_TRACE="$(curl -4fsS --interface "$TEST_SOURCE" --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  WARP_STATE="$(printf '%s\n' "$WARP_TRACE" | sed -n 's/^warp=//p' | head -n 1)"
  echo "Cloudflare WARP: ${WARP_STATE:-check failed}"
fi
`
}

func outboundDiagnosticsScript() string {
	return outboundStatusScript() + `
echo
echo "Routing rules:"
ip rule show 2>/dev/null | grep -E '100|wdtt|10\.66\.66' || echo "No dedicated WDTT rules."
echo
echo "Table 100 routes:"
ip route show table 100 2>/dev/null || echo "Table 100 is empty."
echo
echo "NAT rules:"
iptables -t nat -S 2>/dev/null | grep -E 'WDTT_PROXY_OUT|WDTT_EXIT|WDTT_LOCAL_PROXY' || echo "No WDTT outbound NAT rules."
`
}

func outboundDisableScript() string {
	return outboundPrelude() + `
wdtt_clear_external_out
wdtt_write_mode "direct" "direct outbound through this server"
echo "Direct outbound mode restored."
`
}

func externalProxyCheckScript(kind, host string, port int, login, password string) string {
	scheme := "http"
	if kind == "socks5" {
		scheme = "socks5h"
	}
	proxyURI := fmt.Sprintf("%s://%s:%d", scheme, host, port)
	return `
command -v curl >/dev/null 2>&1 || { echo WDTT_ERROR=curl_not_installed; exit 2; }
PROXY_URI=` + shellQuoteDeploy(proxyURI) + `
PROXY_LOGIN=` + shellQuoteDeploy(login) + `
PROXY_PASSWORD=` + shellQuoteDeploy(password) + `
if [ -n "$PROXY_LOGIN" ]; then
  IP="$(curl --proxy "$PROXY_URI" --proxy-user "$PROXY_LOGIN:$PROXY_PASSWORD" -4fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
else
  IP="$(curl --proxy "$PROXY_URI" -4fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
fi
[ -n "$IP" ] || { echo WDTT_ERROR=external_proxy_check_failed; exit 3; }
echo "External proxy check passed. Exit IP: $IP"
`
}

func externalProxyEnableScript(kind, host string, port int, login, password string) string {
	redsocksType := "http-connect"
	if kind == "socks5" {
		redsocksType = "socks5"
	}
	return outboundPrelude() + `
PROXY_KIND=` + shellQuoteDeploy(kind) + `
REDSOCKS_TYPE=` + shellQuoteDeploy(redsocksType) + `
PROXY_HOST=` + shellQuoteDeploy(host) + `
PROXY_PORT=` + strconv.Itoa(port) + `
PROXY_LOGIN=` + shellQuoteDeploy(login) + `
PROXY_PASSWORD=` + shellQuoteDeploy(password) + `
wdtt_install_redsocks_tools
REDSOCKS_BIN="$(command -v redsocks || true)"
[ -n "$REDSOCKS_BIN" ] || { echo WDTT_ERROR=redsocks_not_installed; exit 2; }
command -v iptables >/dev/null 2>&1 || { echo WDTT_ERROR=iptables_required; exit 2; }
PROXY_IP="$(getent ahostsv4 "$PROXY_HOST" | awk '{print $1; exit}')"
[ -n "$PROXY_IP" ] || PROXY_IP="$PROXY_HOST"
wdtt_clear_external_out
cat >/etc/wdtt/redsocks.conf <<EOF
base {
  log_info = on;
  log = "file:/var/log/wdtt-redsocks.log";
  daemon = on;
  redirector = iptables;
}
redsocks {
  local_ip = 0.0.0.0;
  local_port = 12345;
  ip = $PROXY_IP;
  port = $PROXY_PORT;
  type = $REDSOCKS_TYPE;
EOF
if [ -n "$PROXY_LOGIN" ]; then
  printf '  login = "%s";\n' "$PROXY_LOGIN" >>/etc/wdtt/redsocks.conf
  printf '  password = "%s";\n' "$PROXY_PASSWORD" >>/etc/wdtt/redsocks.conf
fi
cat >>/etc/wdtt/redsocks.conf <<EOF
}
EOF
chmod 600 /etc/wdtt/redsocks.conf
mkdir -p /usr/local/lib/wdtt
cat >/usr/local/lib/wdtt/redsocks-routes <<EOF
#!/bin/sh
set -eu
action="\${1:-}"
cleanup() {
  while iptables -t nat -D PREROUTING -i wdtt0 -p tcp -j WDTT_PROXY_OUT 2>/dev/null; do :; done
  iptables -t nat -F WDTT_PROXY_OUT 2>/dev/null || true
  iptables -t nat -X WDTT_PROXY_OUT 2>/dev/null || true
}
if [ "\$action" = down ]; then cleanup; exit 0; fi
[ "\$action" = up ] || exit 2
cleanup
iptables -t nat -N WDTT_PROXY_OUT
for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
  iptables -t nat -A WDTT_PROXY_OUT -d "\$net" -j RETURN
done
[ -n "$PROXY_IP" ] && iptables -t nat -A WDTT_PROXY_OUT -d "$PROXY_IP" -j RETURN
iptables -t nat -A WDTT_PROXY_OUT -p tcp -j REDIRECT --to-ports 12345
iptables -t nat -A PREROUTING -i wdtt0 -p tcp -j WDTT_PROXY_OUT
EOF
chmod 700 /usr/local/lib/wdtt/redsocks-routes
cat >/etc/systemd/system/wdtt-redsocks.service <<EOF
[Unit]
Description=WDTT external proxy redirector
After=network-online.target wdtt.service
Wants=network-online.target

[Service]
Type=forking
ExecStart=$REDSOCKS_BIN -c /etc/wdtt/redsocks.conf -p /run/wdtt-redsocks.pid
ExecStartPost=/usr/local/lib/wdtt/redsocks-routes up
ExecStopPost=/usr/local/lib/wdtt/redsocks-routes down
PIDFile=/run/wdtt-redsocks.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable wdtt-redsocks >/dev/null
systemctl restart wdtt-redsocks >/dev/null || { echo WDTT_ERROR=external_proxy_service_inactive; exit 3; }
systemctl is-active --quiet wdtt-redsocks || { echo WDTT_ERROR=external_proxy_service_inactive; exit 3; }
wdtt_write_mode "external_proxy" "$PROXY_KIND://$PROXY_HOST:$PROXY_PORT"
echo "External proxy enabled for WDTT TCP traffic."
`
}

func freeWarpCheckScript(restart bool) string {
	restartFlag := "0"
	if restart {
		restartFlag = "1"
	}
	return outboundPrelude() + `
MODE="$(sed -n 's/.*"outboundMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/wdtt/outbound.json 2>/dev/null | head -n 1)"
[ "$MODE" = "warp_free" ] || { echo WDTT_ERROR=warp_mode_not_active; exit 3; }
[ -f /etc/wdtt-plus/warp/wgcf-account.toml ] || { echo WDTT_ERROR=warp_account_missing; exit 3; }
[ -f /etc/wireguard/wg-wdtt-exit.conf ] || { echo WDTT_ERROR=warp_profile_missing; exit 3; }
if [ ` + restartFlag + ` = 1 ]; then
  systemctl restart wdtt-wg-exit.service >/dev/null 2>&1 || { echo WDTT_ERROR=wireguard_not_active; exit 3; }
  sleep 4
fi
TEST_SOURCE="$(wdtt_test_source)"
[ -n "$TEST_SOURCE" ] || { echo WDTT_ERROR=wdtt_test_source_missing; exit 3; }
TRACE="$(curl -4fsS --interface "$TEST_SOURCE" --connect-timeout 8 --max-time 25 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
printf '%s\n' "$TRACE" | grep -Eq '^warp=(on|plus)$' || { echo WDTT_ERROR=warp_trace_check_failed; exit 3; }
echo "WARP check passed."
printf '%s\n' "$TRACE" | sed -n 's/^warp=/Cloudflare warp: /p' | head -n 1
`
}

func deleteFreeWarpScript() string {
	return outboundPrelude() + `
MODE="$(sed -n 's/.*"outboundMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/wdtt/outbound.json 2>/dev/null | head -n 1)"
systemctl disable --now wdtt-warp-watchdog.timer wdtt-warp-watchdog.service 2>/dev/null || true
if [ "$MODE" = "warp_free" ]; then
  wdtt_clear_external_out
  rm -f /etc/wireguard/wg-wdtt-exit.conf /etc/wdtt-plus/wg-exit/wg-wdtt-exit.conf
  wdtt_write_mode "direct" "direct outbound"
fi
rm -rf /etc/wdtt-plus/warp
rm -f /usr/local/bin/wgcf /usr/local/bin/wgcf.previous /usr/local/lib/wdtt/warp-watchdog
rm -f /etc/systemd/system/wdtt-warp-watchdog.service /etc/systemd/system/wdtt-warp-watchdog.timer
systemctl daemon-reload 2>/dev/null || true
echo "Free WARP removed."
`
}

func resetFreeWarpScript() string {
	return outboundPrelude() + `
WARP_DIR=/etc/wdtt-plus/warp
MODE="$(sed -n 's/.*"outboundMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/wdtt/outbound.json 2>/dev/null | head -n 1)"
systemctl disable --now wdtt-warp-watchdog.timer wdtt-warp-watchdog.service 2>/dev/null || true
if [ "$MODE" = "warp_free" ]; then
  wdtt_clear_external_out
  wdtt_write_mode "direct" "WARP registration reset"
fi
rm -f "$WARP_DIR"/wgcf-account.toml "$WARP_DIR"/wgcf-account.toml.invalid-* \
  "$WARP_DIR"/wgcf-profile.raw.conf "$WARP_DIR"/wgcf-profile.conf \
  "$WARP_DIR"/selected.env "$WARP_DIR"/health.env
chmod 700 "$WARP_DIR" 2>/dev/null || true
echo "WARP registration reset. Verified wgcf was kept on the server."
`
}

func freeWarpInstallScript(mtu int) string {
	if mtu < 1280 || mtu > 1500 {
		mtu = 1280
	}
	return outboundPrelude() + `
WARP_MTU=` + strconv.Itoa(mtu) + `
BACKUP_DIR="/tmp/vbridge-warp-backup-$(date +%s)"
mkdir -p "$BACKUP_DIR" /etc/wdtt-plus/warp /etc/wdtt-plus/wg-exit /etc/wireguard
[ -f /etc/wireguard/wg-wdtt-exit.conf ] && cp -f /etc/wireguard/wg-wdtt-exit.conf "$BACKUP_DIR/wg.conf"
[ -f /etc/wdtt/outbound.json ] && cp -f /etc/wdtt/outbound.json "$BACKUP_DIR/outbound.json"
trap 'status=$?; if [ $status -ne 0 ]; then wdtt_clear_external_out; [ -f "$BACKUP_DIR/wg.conf" ] && cp -f "$BACKUP_DIR/wg.conf" /etc/wireguard/wg-wdtt-exit.conf || rm -f /etc/wireguard/wg-wdtt-exit.conf; [ -f "$BACKUP_DIR/outbound.json" ] && cp -f "$BACKUP_DIR/outbound.json" /etc/wdtt/outbound.json || rm -f /etc/wdtt/outbound.json; fi; rm -rf "$BACKUP_DIR"' EXIT
wdtt_install_pkg wireguard-tools curl ca-certificates iptables iproute2 || true
command -v wg-quick >/dev/null 2>&1 || { echo WDTT_ERROR=wireguard_tools_required; exit 2; }
command -v curl >/dev/null 2>&1 || { echo WDTT_ERROR=warp_download_tools_missing; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo WDTT_ERROR=warp_checksum_tool_missing; exit 2; }
if [ ! -x /usr/local/bin/wgcf ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.26/wgcf_2.2.26_linux_amd64"; WGCF_SHA="8d1f3f0cbeb5341d0f0d1342c092fd2a8d0f8cd6fa0dfa50f5e3df7f34131f39" ;;
    aarch64|arm64) WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v2.2.26/wgcf_2.2.26_linux_arm64"; WGCF_SHA="" ;;
    *) echo WDTT_ERROR=warp_unsupported_arch; exit 2 ;;
  esac
  TMP_WGCF="$(mktemp)"
  curl -fsSL --connect-timeout 15 --max-time 180 -o "$TMP_WGCF" "$WGCF_URL" || { echo WDTT_ERROR=warp_wgcf_download_failed; exit 2; }
  if [ -n "$WGCF_SHA" ]; then
    [ "$(sha256sum "$TMP_WGCF" | awk '{print $1}')" = "$WGCF_SHA" ] || { echo WDTT_ERROR=warp_wgcf_download_failed; exit 2; }
  fi
  install -m 700 "$TMP_WGCF" /usr/local/bin/wgcf
  rm -f "$TMP_WGCF"
fi
WARP_DIR=/etc/wdtt-plus/warp
ACCOUNT="$WARP_DIR/wgcf-account.toml"
RAW_PROFILE="$WARP_DIR/wgcf-profile.raw.conf"
SAFE_PROFILE="$WARP_DIR/wgcf-profile.conf"
mkdir -p "$WARP_DIR"
chmod 700 "$WARP_DIR"
if [ -f "$ACCOUNT" ]; then
  /usr/local/bin/wgcf --config "$ACCOUNT" status >/dev/null 2>&1 || mv "$ACCOUNT" "$ACCOUNT.invalid-$(date +%s)"
fi
if [ ! -f "$ACCOUNT" ]; then
  /usr/local/bin/wgcf --config "$ACCOUNT" register --accept-tos --name "VBridge" --model "VBridge Server" >/tmp/vbridge-wgcf-register.log 2>&1 || { echo WDTT_ERROR=warp_registration_failed; exit 3; }
fi
/usr/local/bin/wgcf --config "$ACCOUNT" generate --profile "$RAW_PROFILE" >/tmp/vbridge-wgcf-generate.log 2>&1 || { echo WDTT_ERROR=warp_profile_generation_failed; exit 3; }
grep -Eq '^[[:space:]]*Endpoint[[:space:]]*=' "$RAW_PROFILE" || { echo WDTT_ERROR=warp_profile_invalid; exit 3; }
awk -v mtu="$WARP_MTU" '
BEGIN { in_interface=0 }
/^[[:space:]]*\[Interface\][[:space:]]*$/ { print "[Interface]"; print "Table = off"; print "MTU = " mtu; in_interface=1; next }
/^[[:space:]]*\[/ { in_interface=0; print; next }
/^[[:space:]]*(Table|MTU|DNS|PreUp|PostUp|PreDown|PostDown)[[:space:]]*=/ { next }
{ print }
' "$RAW_PROFILE" >"$SAFE_PROFILE"
install -m 600 "$SAFE_PROFILE" /etc/wireguard/wg-wdtt-exit.conf
install -m 600 "$SAFE_PROFILE" /etc/wdtt-plus/wg-exit/wg-wdtt-exit.conf
systemctl disable --now wdtt-redsocks 2>/dev/null || true
wg-quick down wg-wdtt-exit 2>/dev/null || true
wg-quick up wg-wdtt-exit >/dev/null 2>&1 || { echo WDTT_ERROR=wireguard_not_active; exit 3; }
while ip rule del from "$WDTT_SUBNET" table "$WDTT_TABLE" priority 100 2>/dev/null; do :; done
ip route flush table "$WDTT_TABLE" 2>/dev/null || true
ip rule add from "$WDTT_SUBNET" table "$WDTT_TABLE" priority 100
ip route add default dev "$WDTT_WG_IFACE" table "$WDTT_TABLE"
iptables -t nat -D POSTROUTING -s "$WDTT_SUBNET" -o "$WDTT_WG_IFACE" -m comment --comment WDTT_EXIT -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "$WDTT_SUBNET" -o "$WDTT_WG_IFACE" -m comment --comment WDTT_EXIT -j MASQUERADE
cat >/etc/systemd/system/wdtt-wg-exit.service <<EOF
[Unit]
Description=VBridge outbound WireGuard exit
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up wg-wdtt-exit
ExecStop=/usr/bin/wg-quick down wg-wdtt-exit

[Install]
WantedBy=multi-user.target
EOF
if [ ! -x /usr/bin/wg-quick ] && [ -x /usr/local/bin/wg-quick ]; then
  sed -i 's#/usr/bin/wg-quick#/usr/local/bin/wg-quick#g' /etc/systemd/system/wdtt-wg-exit.service
fi
systemctl daemon-reload
systemctl enable wdtt-wg-exit.service >/dev/null 2>&1 || true
wdtt_write_mode "warp_free" "free Cloudflare WARP"
TEST_SOURCE="$(wdtt_test_source)"
[ -n "$TEST_SOURCE" ] || { echo WDTT_ERROR=wdtt_test_source_missing; exit 3; }
TRACE="$(curl -4fsS --interface "$TEST_SOURCE" --connect-timeout 8 --max-time 25 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
printf '%s\n' "$TRACE" | grep -Eq '^warp=(on|plus)$' || { echo WDTT_ERROR=warp_trace_check_failed; exit 3; }
mkdir -p "$WARP_DIR"
printf 'WARP_MTU=%s\n' "$WARP_MTU" >"$WARP_DIR/selected.env"
chmod 600 "$WARP_DIR/selected.env"
echo "Free WARP installed and verified."
`
}

func randomBase64(n int) string {
	buf := make([]byte, n)
	_, _ = rand.Read(buf)
	return base64.RawURLEncoding.EncodeToString(buf)
}

func wireGuardVPSApplyScript(r outboundRequest) string {
	tx := randomBase64(9)
	foreignHost := shellQuoteDeploy(r.ProxyHost)
	foreignUser := shellQuoteDeploy(r.Login)
	foreignPass := shellQuoteDeploy(r.Secret)
	foreignSSHPort := strconv.Itoa(r.SSHPort)
	wgPort := strconv.Itoa(r.ProxyPort)
	dns := shellQuoteDeploy(strings.TrimSpace(r.DNS))
	return outboundPrelude() + `
TX=` + shellQuoteDeploy(tx) + `
FOREIGN_HOST=` + foreignHost + `
FOREIGN_USER=` + foreignUser + `
FOREIGN_PASS=` + foreignPass + `
FOREIGN_SSH_PORT=` + foreignSSHPort + `
WG_PORT=` + wgPort + `
WG_DNS=` + dns + `
CUR_BACKUP="/tmp/vbridge-wg-cur-${TX}"
mkdir -p "$CUR_BACKUP" /etc/wdtt-plus/wg-exit /etc/wireguard
[ -f /etc/wireguard/wg-wdtt-exit.conf ] && cp -f /etc/wireguard/wg-wdtt-exit.conf "$CUR_BACKUP/wg.conf"
[ -f /etc/wdtt/outbound.json ] && cp -f /etc/wdtt/outbound.json "$CUR_BACKUP/outbound.json"
rollback_current() {
  wdtt_clear_external_out
  [ -f "$CUR_BACKUP/wg.conf" ] && cp -f "$CUR_BACKUP/wg.conf" /etc/wireguard/wg-wdtt-exit.conf || rm -f /etc/wireguard/wg-wdtt-exit.conf
  [ -f "$CUR_BACKUP/outbound.json" ] && cp -f "$CUR_BACKUP/outbound.json" /etc/wdtt/outbound.json || rm -f /etc/wdtt/outbound.json
}
trap 'status=$?; if [ $status -ne 0 ]; then rollback_current; fi; rm -rf "$CUR_BACKUP"' EXIT
wdtt_install_pkg wireguard-tools iptables iproute2 openssh-client || true
sshpass -V >/dev/null 2>&1 || wdtt_install_pkg sshpass || true
command -v sshpass >/dev/null 2>&1 || { echo WDTT_ERROR=sshpass_required; exit 2; }
umask 077
mkdir -p /etc/wdtt-plus/wg-exit
wg genkey | tee /etc/wdtt-plus/wg-exit/private.key | wg pubkey >/etc/wdtt-plus/wg-exit/public.key
CUR_PUB="$(cat /etc/wdtt-plus/wg-exit/public.key)"
FOREIGN_SCRIPT=$(cat <<'EOS'
set -e
WG_PORT="$1"
CLIENT_PUB="$2"
mkdir -p /etc/wireguard /tmp/vbridge-foreign
apt-get update -y >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iptables >/dev/null 2>&1 || true
[ -f /etc/wireguard/wg-wdtt-exit.conf ] && cp -f /etc/wireguard/wg-wdtt-exit.conf /tmp/vbridge-foreign/wg.conf || true
[ -f /etc/sysctl.d/99-vbridge-exit-forward.conf ] && cp -f /etc/sysctl.d/99-vbridge-exit-forward.conf /tmp/vbridge-foreign/sysctl.conf || true
PRIV="$(wg genkey)"
PUB="$(printf '%s' "$PRIV" | wg pubkey)"
cat >/etc/wireguard/wg-wdtt-exit.conf <<EOF
[Interface]
Address = 10.77.77.1/30
ListenPort = $WG_PORT
PrivateKey = $PRIV

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.77.77.2/32,10.66.66.0/24
PersistentKeepalive = 25
EOF
printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-vbridge-exit-forward.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
EXT_IF="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i==\"dev\") {print $(i+1); exit}}')"
[ -n "$EXT_IF" ] || EXT_IF="eth0"
iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o "$EXT_IF" -m comment --comment WDTT_EXIT_FOREIGN -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$EXT_IF" -m comment --comment WDTT_EXIT_FOREIGN -j MASQUERADE
wg-quick down wg-wdtt-exit 2>/dev/null || true
wg-quick up wg-wdtt-exit >/dev/null 2>&1
echo "FOREIGN_PUB=$PUB"
EOS
)
FOREIGN_OUT="$(sshpass -p "$FOREIGN_PASS" ssh -o StrictHostKeyChecking=no -p "$FOREIGN_SSH_PORT" "$FOREIGN_USER@$FOREIGN_HOST" "bash -s -- '$WG_PORT' '$CUR_PUB'" <<<"$FOREIGN_SCRIPT" 2>&1)" || { echo "$FOREIGN_OUT"; echo WDTT_ERROR=wireguard_vps_foreign_setup_failed; exit 3; }
FOREIGN_PUB="$(printf '%s\n' "$FOREIGN_OUT" | sed -n 's/^FOREIGN_PUB=//p' | tail -n 1)"
[ -n "$FOREIGN_PUB" ] || { echo "$FOREIGN_OUT"; echo WDTT_ERROR=wireguard_vps_foreign_setup_failed; exit 3; }
cat >/etc/wireguard/wg-wdtt-exit.conf <<EOF
[Interface]
Address = 10.77.77.2/30
PrivateKey = $(cat /etc/wdtt-plus/wg-exit/private.key)
DNS = $(printf '%s' "$WG_DNS" | tr ',' ' ')
Table = off

[Peer]
PublicKey = $FOREIGN_PUB
Endpoint = $FOREIGN_HOST:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
install -m 600 /etc/wireguard/wg-wdtt-exit.conf /etc/wdtt-plus/wg-exit/wg-wdtt-exit.conf
wg-quick down wg-wdtt-exit 2>/dev/null || true
wg-quick up wg-wdtt-exit >/dev/null 2>&1 || { echo WDTT_ERROR=wireguard_not_active; exit 3; }
while ip rule del from "$WDTT_SUBNET" table "$WDTT_TABLE" priority 100 2>/dev/null; do :; done
ip route flush table "$WDTT_TABLE" 2>/dev/null || true
ip rule add from "$WDTT_SUBNET" table "$WDTT_TABLE" priority 100
ip route add default dev "$WDTT_WG_IFACE" table "$WDTT_TABLE"
iptables -t nat -D POSTROUTING -s "$WDTT_SUBNET" -o "$WDTT_WG_IFACE" -m comment --comment WDTT_EXIT -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s "$WDTT_SUBNET" -o "$WDTT_WG_IFACE" -m comment --comment WDTT_EXIT -j MASQUERADE
wdtt_write_mode "wireguard_vps" "other server $FOREIGN_HOST:$WG_PORT"
cat >/etc/wdtt/outbound-profile.env <<EOF
WG_VPS_HOST_B64=$(printf '%s' "$FOREIGN_HOST" | base64 | tr -d '\n')
WG_VPS_SSH_PORT=$FOREIGN_SSH_PORT
WG_VPS_USER_B64=$(printf '%s' "$FOREIGN_USER" | base64 | tr -d '\n')
WG_VPS_PASSWORD_B64=$(printf '%s' "$FOREIGN_PASS" | base64 | tr -d '\n')
WG_VPS_PORT=$WG_PORT
WG_VPS_DNS_B64=$(printf '%s' "$WG_DNS" | base64 | tr -d '\n')
UPDATED_AT=$(date -Is)
EOF
echo "Other server WireGuard outbound enabled."
`
}

func wireGuardVPSCheckScript() string {
	return outboundPrelude() + `
MODE="$(sed -n 's/.*"outboundMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/wdtt/outbound.json 2>/dev/null | head -n 1)"
[ "$MODE" = "wireguard_vps" ] || { echo WDTT_ERROR=wireguard_vps_not_active; exit 3; }
wg show "$WDTT_WG_IFACE" >/dev/null 2>&1 || { echo WDTT_ERROR=wireguard_not_active; exit 3; }
TEST_SOURCE="$(wdtt_test_source)"
[ -n "$TEST_SOURCE" ] || { echo WDTT_ERROR=wdtt_test_source_missing; exit 3; }
EXIT_IP="$(curl -4fsS --interface "$TEST_SOURCE" --connect-timeout 8 --max-time 20 https://api.ipify.org 2>/dev/null || true)"
echo "Other server outbound is active."
[ -n "$EXIT_IP" ] && echo "Exit IP: $EXIT_IP"
`
}

func wireGuardVPSRemoveScript() string {
	return outboundPrelude() + `
if [ -f /etc/wdtt/outbound-profile.env ]; then
  tmp_profile=/etc/wdtt/outbound-profile.env.tmp
  grep -v '^WG_VPS_' /etc/wdtt/outbound-profile.env >"$tmp_profile" 2>/dev/null || true
  mv "$tmp_profile" /etc/wdtt/outbound-profile.env
fi
MODE="$(sed -n 's/.*"outboundMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/wdtt/outbound.json 2>/dev/null | head -n 1)"
if [ "$MODE" = "wireguard_vps" ]; then
  wdtt_clear_external_out
  rm -f /etc/wireguard/wg-wdtt-exit.conf /etc/wdtt-plus/wg-exit/wg-wdtt-exit.conf
  wdtt_write_mode "direct" "direct outbound"
fi
echo "Other server outbound removed."
`
}

func localProxyInstallScript(login, password string, port int) string {
	httpPort := port + 1
	adminPort := port + 2
	return outboundPrelude() + `
command -v systemctl >/dev/null 2>&1 || { echo WDTT_ERROR=systemd_required; exit 2; }
wdtt_install_pkg curl ca-certificates tar gzip make gcc coreutils libc6-dev libssl-dev libpcre2-dev || true
command -v 3proxy >/dev/null 2>&1 || { echo WDTT_ERROR=3proxy_install_failed; exit 2; }
cat >/etc/wdtt/3proxy.cfg <<EOF
daemon
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users ` + shellQuoteDeploy(login)[1:len(shellQuoteDeploy(login))-1] + `:CL:` + shellQuoteDeploy(password)[1:len(shellQuoteDeploy(password))-1] + `
allow ` + shellQuoteDeploy(login)[1:len(shellQuoteDeploy(login))-1] + `
socks -p` + strconv.Itoa(port) + ` -i0.0.0.0 -e0.0.0.0
proxy -p` + strconv.Itoa(httpPort) + ` -i0.0.0.0 -e0.0.0.0
admin -p` + strconv.Itoa(adminPort) + ` -i0.0.0.0
EOF
chmod 600 /etc/wdtt/3proxy.cfg
cat >/etc/systemd/system/wdtt-3proxy.service <<EOF
[Unit]
Description=WDTT authenticated local proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/3proxy /etc/wdtt/3proxy.cfg
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
if [ ! -x /usr/bin/3proxy ] && [ -x /usr/local/bin/3proxy ]; then
  sed -i 's#/usr/bin/3proxy#/usr/local/bin/3proxy#' /etc/systemd/system/wdtt-3proxy.service
fi
systemctl daemon-reload
systemctl enable wdtt-3proxy >/dev/null
systemctl restart wdtt-3proxy >/dev/null || { echo WDTT_ERROR=local_proxy_service_inactive; exit 3; }
systemctl is-active --quiet wdtt-3proxy || { echo WDTT_ERROR=local_proxy_service_inactive; exit 3; }
SERVER_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
cat >/etc/wdtt/local-proxy.json <<EOF
{"enabled":true,"type":"socks5,http","host":"$SERVER_IP","socks5Port":` + strconv.Itoa(port) + `,"httpPort":` + strconv.Itoa(httpPort) + `,"webPort":` + strconv.Itoa(adminPort) + `,"login":` + shellQuoteDeploy(login) + `,"password":` + shellQuoteDeploy(password) + `}
EOF
echo "Local proxy installed."
echo "SOCKS5: socks5://` + login + `:********@$SERVER_IP:` + strconv.Itoa(port) + `"
`
}

func localProxyCheckScript() string {
	return `
[ -f /etc/wdtt/local-proxy.json ] || { echo WDTT_ERROR=local_proxy_config_not_found; exit 2; }
PROXY_PORT="$(grep -o '"socks5Port"[[:space:]]*:[[:space:]]*[0-9]*' /etc/wdtt/local-proxy.json | grep -o '[0-9]*' | head -1)"
PROXY_LOGIN="$(grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/wdtt/local-proxy.json | sed 's/.*"login"[[:space:]]*:[[:space:]]*"//;s/".*//' | head -1)"
PROXY_PASSWORD="$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/wdtt/local-proxy.json | sed 's/.*"password"[[:space:]]*:[[:space:]]*"//;s/".*//' | head -1)"
command -v curl >/dev/null 2>&1 || { echo WDTT_ERROR=curl_not_installed; exit 2; }
IP="$(curl --proxy-user "$PROXY_LOGIN:$PROXY_PASSWORD" --socks5-hostname "127.0.0.1:$PROXY_PORT" -4fsS --max-time 12 https://api.ipify.org 2>/dev/null || true)"
[ -n "$IP" ] || { echo WDTT_ERROR=local_proxy_check_failed; exit 3; }
echo "Local proxy check passed. Exit IP: $IP"
`
}

func localProxyRemoveScript(remove bool) string {
	if !remove {
		return `
systemctl stop wdtt-3proxy 2>/dev/null || true
systemctl is-active --quiet wdtt-3proxy 2>/dev/null && { echo WDTT_ERROR=local_proxy_service_still_active; exit 3; }
echo "Local proxy stopped."
`
	}
	return `
systemctl disable --now wdtt-3proxy 2>/dev/null || true
rm -f /etc/systemd/system/wdtt-3proxy.service /etc/wdtt/3proxy.cfg /etc/wdtt/local-proxy.json
systemctl daemon-reload 2>/dev/null || true
echo "Local proxy removed."
`
}
