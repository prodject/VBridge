package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type csqttAdminRequest struct {
	Action         string `json:"action"`
	Host           string `json:"host"`
	User           string `json:"user"`
	Password       string `json:"password"`
	Port           int    `json:"port"`
	WebPort        int    `json:"webPort"`
	WebUser        string `json:"webUser"`
	WebPassword    string `json:"webPassword"`
	ClientPassword string `json:"clientPassword,omitempty"`
	Label          string `json:"label,omitempty"`
	Ports          string `json:"ports,omitempty"`
	Days           int    `json:"days,omitempty"`
}

//export VBridgeWGCSQTTAdmin
func VBridgeWGCSQTTAdmin(configJSON *C.char) *C.char {
	if configJSON == nil {
		return serverAdminCString(serverAdminResponse{OK: false, Status: "error", Message: "empty CSQTT admin config"})
	}
	var req csqttAdminRequest
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &req); err != nil {
		return serverAdminCString(serverAdminResponse{OK: false, Status: "error", Message: "invalid CSQTT admin JSON: " + err.Error()})
	}
	resp := runCSQTTAdmin(req)
	return serverAdminCString(resp)
}

func runCSQTTAdmin(req csqttAdminRequest) serverAdminResponse {
	req.Action = strings.TrimSpace(strings.ToLower(req.Action))
	req.Host = strings.TrimSpace(req.Host)
	req.User = strings.TrimSpace(req.User)
	req.WebUser = strings.TrimSpace(req.WebUser)
	req.WebPassword = strings.TrimSpace(req.WebPassword)
	req.ClientPassword = strings.TrimSpace(req.ClientPassword)
	req.Label = strings.TrimSpace(req.Label)
	req.Ports = strings.TrimSpace(req.Ports)
	if req.User == "" {
		req.User = "root"
	}
	if req.Port == 0 {
		req.Port = 22
	}
	if req.WebPort == 0 {
		req.WebPort = 46002
	}
	if req.WebUser == "" {
		req.WebUser = "admin"
	}
	if req.Host == "" {
		return serverAdminResponse{OK: false, Status: "error", Message: "server host is empty"}
	}
	if req.Password == "" {
		return serverAdminResponse{OK: false, Status: "error", Message: "SSH password is empty"}
	}
	if req.WebPassword == "" {
		return serverAdminResponse{OK: false, Status: "error", Message: "CSQTT web password is empty"}
	}

	client, err := dialDeploySSH(deployRequest{
		Host: req.Host, User: req.User, Password: req.Password, Port: req.Port,
	})
	if err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "SSH connect failed: " + err.Error()}
	}
	defer client.Close()

	payload, err := json.Marshal(req)
	if err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "failed to encode CSQTT admin payload: " + err.Error()}
	}
	payloadB64 := base64.StdEncoding.EncodeToString(payload)
	command := rootDeployCommand(fmt.Sprintf(`command -v python3 >/dev/null 2>&1 || { echo '{"status":500,"body":"python3 is not installed on the server"}'; exit 0; }; python3 -c %s`,
		shellQuoteDeploy(fmt.Sprintf(`import base64, json, ssl, sys, urllib.error, urllib.request, http.cookiejar

cfg = json.loads(base64.b64decode(%q))

def caesar_encode(value):
    data = value.encode("utf-8")
    shifted = bytes(((byte + 47) & 0xff) for byte in data)
    return "c1:" + base64.b64encode(shifted).decode("ascii")

def parse_ports(value):
    raw = [part.strip() for part in (value or "").split(",")]
    raw = [part for part in raw if part]
    defaults = [46000, 46001, 0]
    if not raw:
        return defaults
    ports = []
    for idx in range(3):
        if idx < len(raw):
            ports.append(int(raw[idx]))
        else:
            ports.append(defaults[idx])
    return ports[:3]

context = ssl._create_unverified_context()
jar = http.cookiejar.CookieJar()
https_opener = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=context),
    urllib.request.HTTPCookieProcessor(jar),
)
http_opener = urllib.request.build_opener(
    urllib.request.HTTPHandler(),
    urllib.request.HTTPCookieProcessor(jar),
)
base_url = ""
opener = None

def request(path, method="GET", body=None):
    headers = {"content-type": "application/json"}
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base_url + path, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=20) as resp:
            return resp.getcode(), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode("utf-8", "replace")

def try_login(candidate_url, candidate_opener):
    global base_url, opener
    base_url = candidate_url
    opener = candidate_opener
    return request("/api/login", "POST", {
        "user": caesar_encode(cfg["WebUser"]),
        "pass": caesar_encode(cfg["WebPassword"]),
    })

login_error = None
for candidate_url, candidate_opener in (
    (f"https://127.0.0.1:{cfg['WebPort']}", https_opener),
    (f"http://127.0.0.1:{cfg['WebPort']}", http_opener),
):
    try:
        status, body = try_login(candidate_url, candidate_opener)
    except Exception as err:
        login_error = str(err)
        continue
    if 200 <= status < 300:
        break
else:
    if login_error:
        sys.stdout.write(json.dumps({"status": 500, "body": login_error}))
    else:
        sys.stdout.write(json.dumps({"status": status, "body": body}))
    sys.exit(0)

action = cfg["Action"]
if action == "list":
    status, body = request("/api/clients")
elif action == "create":
    dtls_port, wg_port, local_port = parse_ports(cfg.get("Ports", ""))
    status, body = request("/api/clients", "POST", {
        "name": cfg.get("Label", ""),
        "days": int(cfg.get("Days", 30) or 0),
        "hash": "",
        "dtls_port": dtls_port,
        "wg_port": wg_port,
        "local_port": local_port,
    })
elif action == "update":
    password = urllib.parse.quote(cfg["ClientPassword"], safe="")
    dtls_port, wg_port, local_port = parse_ports(cfg.get("Ports", ""))
    status, body = request(f"/api/clients/{password}", "POST", {
        "name": cfg.get("Label", ""),
        "days": int(cfg.get("Days", 30) or 0),
        "hash": "",
        "dtls_port": dtls_port,
        "wg_port": wg_port,
        "local_port": local_port,
    })
elif action == "delete":
    password = urllib.parse.quote(cfg["ClientPassword"], safe="")
    status, body = request(f"/api/clients/{password}", "DELETE")
elif action == "unbind":
    password = urllib.parse.quote(cfg["ClientPassword"], safe="")
    status, body = request(f"/api/clients/{password}/unbind", "POST", {})
elif action in ("activate", "deactivate"):
    password = urllib.parse.quote(cfg["ClientPassword"], safe="")
    status, body = request(f"/api/clients/{password}/toggle", "POST", {})
else:
    status, body = 400, "unsupported action"

sys.stdout.write(json.dumps({"status": status, "body": body}))
`, payloadB64))), req.Password)

	text, cmdErr := runSSHCommand(client, command, 70*time.Second)
	if cmdErr != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "CSQTT admin failed: " + cmdErr.Error(), Output: text}
	}

	var envelope struct {
		Status int    `json:"status"`
		Body   string `json:"body"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &envelope); err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "CSQTT admin returned invalid JSON", Output: text}
	}
	if envelope.Status < 200 || envelope.Status >= 300 {
		message := strings.TrimSpace(envelope.Body)
		if message == "" {
			message = fmt.Sprintf("CSQTT admin HTTP %d", envelope.Status)
		}
		return serverAdminResponse{OK: false, Status: "error", Message: message, Output: text}
	}

	if req.Action == "list" {
		var clients []map[string]any
		if err := json.Unmarshal([]byte(envelope.Body), &clients); err != nil {
			return serverAdminResponse{OK: false, Status: "error", Message: "CSQTT clients response is invalid", Output: envelope.Body}
		}
		state := &serverAdminState{OK: true, Message: "CSQTT clients loaded"}
		for _, item := range clients {
			state.Passwords = append(state.Passwords, serverAdminPasswordInfo{
				Password:  asString(item["password"]),
				Label:     asString(item["name"]),
				VKHash:    firstNonEmptyString(item["vk_hashes"], item["vk_hash"]),
				Ports:     csqttPortsString(item),
				Status:    csqttClientStatus(item),
				ExpiresAt: asInt64(item["expires"]),
				DownBytes: asInt64(item["down"]),
				UpBytes:   asInt64(item["up"]),
				DeviceID:  asString(item["device_id"]),
			})
		}
		return serverAdminResponse{OK: true, Status: "success", Message: state.Message, Output: envelope.Body, State: state}
	}

	return serverAdminResponse{
		OK:      true,
		Status:  "success",
		Message: csqttSuccessMessage(req.Action),
		Output:  envelope.Body,
	}
}

func csqttClientStatus(item map[string]any) string {
	if value, ok := item["active"].(bool); ok && value {
		return "active"
	}
	return "inactive"
}

func csqttPortsString(item map[string]any) string {
	dtls := asInt(item["dtls_port"])
	wg := asInt(item["wg_port"])
	local := asInt(item["local_port"])
	if dtls == 0 && wg == 0 && local == 0 {
		return ""
	}
	return fmt.Sprintf("%d,%d,%d", dtls, wg, local)
}

func csqttSuccessMessage(action string) string {
	switch action {
	case "create":
		return "CSQTT client created."
	case "update":
		return "CSQTT client updated."
	case "delete":
		return "CSQTT client deleted."
	case "unbind":
		return "CSQTT client unbound."
	case "activate":
		return "CSQTT client toggled."
	case "deactivate":
		return "CSQTT client toggled."
	default:
		return "CSQTT management complete."
	}
}

func asString(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	default:
		return ""
	}
}

func asInt(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case int64:
		return int(typed)
	case string:
		parsed, _ := strconv.Atoi(strings.TrimSpace(typed))
		return parsed
	default:
		return 0
	}
}

func asInt64(value any) int64 {
	switch typed := value.(type) {
	case float64:
		return int64(typed)
	case int:
		return int64(typed)
	case int64:
		return typed
	case string:
		parsed, _ := strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
		return parsed
	default:
		return 0
	}
}

func firstNonEmptyString(values ...any) string {
	for _, value := range values {
		if text := asString(value); text != "" {
			return text
		}
	}
	return ""
}
