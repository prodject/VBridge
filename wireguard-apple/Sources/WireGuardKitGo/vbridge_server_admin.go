package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

const wdttStableAdminScript = `import base64, json, os, sys, time

CONFIG_DIR = "/etc/wdtt"
DB_PATH = os.path.join(CONFIG_DIR, "passwords.json")
DEFAULT_PORTS = "56000,56001,9000"

def fail(message, code=1):
    print(json.dumps({"ok": False, "status": "error", "message": message}, ensure_ascii=False))
    sys.exit(code)

def normalize_ports(value):
    parts = [p.strip() for p in str(value or "").split(",")]
    if len(parts) != 3:
        fail("Ports must contain exactly 3 comma-separated numbers")
    normalized = []
    for idx, part in enumerate(parts, start=1):
        if not part.isdigit():
            fail(f"Port #{idx} must be a number from 1 to 65535")
        port = int(part)
        if port < 1 or port > 65535:
            fail(f"Port #{idx} must be a number from 1 to 65535")
        normalized.append(str(port))
    return ",".join(normalized)

def normalize_password(value):
    value = str(value or "").strip()
    if not value:
        fail("client password is empty")
    if len(value) > 128:
        fail("client password is too long")
    return value

def normalize_label(value):
    return " ".join(str(value or "").strip().split())[:64]

def normalize_vk_hash(value):
    return str(value or "").strip()

def load_db():
    if not os.path.exists(DB_PATH):
        fail(f"no_passwords_json: {DB_PATH}")
    with open(DB_PATH, "r", encoding="utf-8") as fh:
        db = json.load(fh)
    if not isinstance(db.get("passwords"), dict):
        db["passwords"] = {}
    if not isinstance(db.get("devices"), dict):
        db["devices"] = {}
    if not str(db.get("default_ports") or "").strip():
        db["default_ports"] = DEFAULT_PORTS
    return db

def save_db(db):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp_path = DB_PATH + ".admin.tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(db, fh, ensure_ascii=False, indent=2)
    os.replace(tmp_path, DB_PATH)

def entry_status(entry, now):
    expires_at = int(entry.get("expires_at") or 0)
    if expires_at > 0 and expires_at <= now:
        return "expired"
    if entry.get("is_deactivated"):
        return "deactivated"
    if str(entry.get("device_id") or "").strip():
        return "active"
    return "new"

def build_password_info(password, entry, now):
    return {
        "password": password,
        "label": str(entry.get("label") or ""),
        "vk_hash": str(entry.get("vk_hash") or ""),
        "ports": str(entry.get("ports") or DEFAULT_PORTS),
        "status": entry_status(entry, now),
        "expires_at": int(entry.get("expires_at") or 0),
        "down_bytes": int(entry.get("down_bytes") or 0),
        "up_bytes": int(entry.get("up_bytes") or 0),
        "device_id": str(entry.get("device_id") or ""),
    }

def sorted_password_rows(passwords, now):
    rows = [build_password_info(password, entry or {}, now) for password, entry in passwords.items()]
    rows.sort(key=lambda item: ((item["label"] or item["password"]).lower(), item["password"].lower()))
    return rows

def require_entry(db, password):
    entry = db["passwords"].get(password)
    if not isinstance(entry, dict):
        fail("пароль не найден")
    return entry

def cleanup_orphan_devices(db):
    used = set()
    for entry in db["passwords"].values():
        if not isinstance(entry, dict):
            continue
        device_id = str(entry.get("device_id") or "").strip()
        if device_id:
            used.add(device_id)
    devices = db.get("devices") or {}
    if not isinstance(devices, dict):
        devices = {}
    removed = 0
    for device_id in list(devices.keys()):
        if device_id not in used:
            removed += 1
            devices.pop(device_id, None)
    db["devices"] = devices
    return removed

payload = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
action = str(payload.get("action") or "").strip().lower()
main_password = str(payload.get("mainPassword") or "").strip()
db = load_db()
if not main_password:
    fail("main password is empty")
if str(db.get("main_password") or "").strip() != main_password:
    fail("главный пароль администратора не совпадает")
passwords = db["passwords"]
now = int(time.time())

if action == "list":
    print(json.dumps({
        "ok": True,
        "status": "success",
        "message": "",
        "state": {"ok": True, "passwords": sorted_password_rows(passwords, now)}
    }, ensure_ascii=False))
    sys.exit(0)

if action == "create":
    client_password = str(payload.get("clientPassword") or "").strip()
    if client_password:
        client_password = normalize_password(client_password)
    else:
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
        for _ in range(64):
            candidate = "".join(alphabet[int.from_bytes(os.urandom(1), "big") % len(alphabet)] for _ in range(16))
            if candidate != main_password and candidate not in passwords:
                client_password = candidate
                break
        if not client_password:
            fail("не удалось создать уникальный пароль")
    if client_password == main_password:
        fail("пароль клиента не должен совпадать с главным паролем")
    if client_password in passwords:
        fail("клиент с таким паролем уже существует")
    days = int(payload.get("days") or 0)
    if days < 0 or days > 365:
        fail("days должен быть 0..365")
    expires_at_raw = payload.get("expiresAt")
    expires_at = 0
    if expires_at_raw is not None:
        expires_at = int(expires_at_raw or 0)
        if expires_at > 0 and expires_at <= now:
            fail("срок импортируемого клиента уже истёк")
    elif days > 0:
        expires_at = now + days * 24 * 60 * 60
    entry = {
        "device_id": "",
        "expires_at": expires_at,
        "down_bytes": 0,
        "up_bytes": 0,
        "label": normalize_label(payload.get("label")),
        "vk_hash": normalize_vk_hash(payload.get("vkHash")),
        "ports": normalize_ports(payload.get("ports") or db.get("default_ports") or DEFAULT_PORTS),
    }
    passwords[client_password] = entry
    save_db(db)
    print(json.dumps({
        "ok": True,
        "status": "success",
        "message": "Клиент создан",
        "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}
    }, ensure_ascii=False))
    sys.exit(0)

client_password = normalize_password(payload.get("clientPassword"))
entry = require_entry(db, client_password)

if action == "delete":
    device_id = str(entry.get("device_id") or "").strip()
    if device_id:
        entry["device_id"] = ""
        if device_id in db["devices"]:
            db["devices"].pop(device_id, None)
    passwords.pop(client_password, None)
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Клиент удалён", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "unbind":
    device_id = str(entry.get("device_id") or "").strip()
    if device_id:
        entry["device_id"] = ""
        if device_id in db["devices"]:
            db["devices"].pop(device_id, None)
        history = entry.get("bind_history")
        if not isinstance(history, list):
            history = []
        history.append({"device_id": device_id, "unbound_at": now, "event_at": now, "status": "unbound"})
        entry["bind_history"] = history[-50:]
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Устройство отвязано", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "activate":
    expires_at = int(entry.get("expires_at") or 0)
    if expires_at > 0 and expires_at <= now:
        fail("срок действия клиента истёк")
    entry["is_deactivated"] = False
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Клиент активирован", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "deactivate":
    entry["is_deactivated"] = True
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Клиент отключён", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "set-label":
    entry["label"] = normalize_label(payload.get("label"))
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Название обновлено", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "set-hash":
    entry["vk_hash"] = normalize_vk_hash(payload.get("vkHash"))
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "VK-хеш обновлён", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "set-ports":
    entry["ports"] = normalize_ports(payload.get("ports"))
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Порты ссылки обновлены", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "set-password":
    new_password = normalize_password(payload.get("newPassword"))
    if new_password == client_password:
        fail("новый пароль совпадает с текущим")
    if new_password == main_password:
        fail("пароль клиента не должен совпадать с главным паролем")
    if new_password in passwords:
        fail("клиент с таким паролем уже существует")
    passwords[new_password] = entry
    passwords.pop(client_password, None)
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Пароль клиента изменён", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "set-expiry":
    expires_at_raw = payload.get("expiresAt")
    if expires_at_raw is not None:
        new_expires_at = int(expires_at_raw or 0)
        if new_expires_at < 0:
            fail("expires-at должен быть 0 или будущим unix timestamp")
        if new_expires_at > 0 and new_expires_at <= now:
            fail("новый срок действия уже истёк")
    else:
        days = int(payload.get("days") or 0)
        if days < 0 or days > 365:
            fail("days должен быть 0..365")
        new_expires_at = 0 if days == 0 else now + days * 24 * 60 * 60
    entry["expires_at"] = new_expires_at
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Срок обновлён", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "update-client":
    entry["label"] = normalize_label(payload.get("label"))
    entry["vk_hash"] = normalize_vk_hash(payload.get("vkHash"))
    entry["ports"] = normalize_ports(payload.get("ports") or db.get("default_ports") or DEFAULT_PORTS)
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Клиент обновлён", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "cleanup-expired":
    changed = False
    for password in list(passwords.keys()):
        entry = passwords.get(password)
        if not isinstance(entry, dict):
            continue
        expires_at = int(entry.get("expires_at") or 0)
        if expires_at > 0 and expires_at <= now:
            device_id = str(entry.get("device_id") or "").strip()
            if device_id:
                entry["device_id"] = ""
                db["devices"].pop(device_id, None)
            changed = True
    if changed:
        save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": "Истёкшие клиенты обработаны", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

if action == "cleanup-orphans":
    removed = cleanup_orphan_devices(db)
    save_db(db)
    print(json.dumps({"ok": True, "status": "success", "message": f"Удалено orphan devices: {removed}", "state": {"ok": True, "passwords": sorted_password_rows(passwords, int(time.time()))}}, ensure_ascii=False))
    sys.exit(0)

fail(f"unsupported server admin action {action!r}")`

type serverAdminRequest struct {
	Action         string `json:"action"`
	Host           string `json:"host"`
	User           string `json:"user"`
	Password       string `json:"password"`
	Port           int    `json:"port"`
	MainPassword   string `json:"mainPassword"`
	ClientPassword string `json:"clientPassword,omitempty"`
	Label          string `json:"label,omitempty"`
	VKHash         string `json:"vkHash,omitempty"`
	Ports          string `json:"ports,omitempty"`
	Days           int    `json:"days,omitempty"`
	ExpiresAt      *int64 `json:"expiresAt,omitempty"`
	NewPassword    string `json:"newPassword,omitempty"`
}

type serverAdminResponse struct {
	OK      bool   `json:"ok"`
	Status  string `json:"status"`
	Message string `json:"message"`
	Output  string `json:"output,omitempty"`
	State   *serverAdminState `json:"state,omitempty"`
}

type serverAdminState struct {
	OK        bool                      `json:"ok"`
	Message   string                    `json:"message,omitempty"`
	Passwords []serverAdminPasswordInfo `json:"passwords,omitempty"`
}

type serverAdminPasswordInfo struct {
	Password  string `json:"password"`
	Label     string `json:"label,omitempty"`
	VKHash    string `json:"vk_hash,omitempty"`
	Ports     string `json:"ports,omitempty"`
	Status    string `json:"status,omitempty"`
	ExpiresAt int64  `json:"expires_at,omitempty"`
	DownBytes int64  `json:"down_bytes,omitempty"`
	UpBytes   int64  `json:"up_bytes,omitempty"`
	DeviceID  string `json:"device_id,omitempty"`
}

//export VBridgeWGServerAdmin
func VBridgeWGServerAdmin(configJSON *C.char) *C.char {
	if configJSON == nil {
		return serverAdminCString(serverAdminResponse{OK: false, Status: "error", Message: "empty server admin config"})
	}
	var req serverAdminRequest
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &req); err != nil {
		return serverAdminCString(serverAdminResponse{OK: false, Status: "error", Message: "invalid server admin JSON: " + err.Error()})
	}
	resp := runServerAdmin(req)
	return serverAdminCString(resp)
}

func serverAdminCString(resp serverAdminResponse) *C.char {
	data, err := json.Marshal(resp)
	if err != nil {
		return C.CString(`{"ok":false,"status":"error","message":"failed to encode server admin response"}`)
	}
	return C.CString(string(data))
}

func runServerAdmin(req serverAdminRequest) serverAdminResponse {
	req.Action = strings.TrimSpace(strings.ToLower(req.Action))
	req.Host = strings.TrimSpace(req.Host)
	req.User = strings.TrimSpace(req.User)
	req.MainPassword = strings.TrimSpace(req.MainPassword)
	req.ClientPassword = strings.TrimSpace(req.ClientPassword)
	req.Label = strings.TrimSpace(req.Label)
	req.VKHash = strings.TrimSpace(req.VKHash)
	req.Ports = strings.TrimSpace(req.Ports)
	req.NewPassword = strings.TrimSpace(req.NewPassword)
	if req.User == "" {
		req.User = "root"
	}
	if req.Port == 0 {
		req.Port = 22
	}
	if req.Host == "" {
		return serverAdminResponse{OK: false, Status: "error", Message: "server host is empty"}
	}
	if req.Password == "" {
		return serverAdminResponse{OK: false, Status: "error", Message: "SSH password is empty"}
	}
	if req.MainPassword == "" {
		return serverAdminResponse{OK: false, Status: "error", Message: "main password is empty"}
	}
	client, err := dialDeploySSH(deployRequest{
		Host: req.Host, User: req.User, Password: req.Password, Port: req.Port,
	})
	if err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "SSH connect failed: " + err.Error()}
	}
	defer client.Close()

	args, err := req.adminArgs()
	if err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: err.Error()}
	}
	if stableResp, handled := runStableServerAdmin(client, req); handled {
		return stableResp
	}
	socketRequest, err := json.Marshal(map[string]any{
		"main_password": req.MainPassword,
		"args":          args,
	})
	if err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "failed to encode admin socket request: " + err.Error()}
	}
	socketPayload := base64.StdEncoding.EncodeToString(socketRequest)
	command := rootDeployCommand(fmt.Sprintf(`python3 -c %s`,
		shellQuoteDeploy(fmt.Sprintf(`import base64, socket, sys
payload = base64.b64decode(%q)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(15)
sock.connect(%q)
sock.sendall(payload)
sock.shutdown(socket.SHUT_WR)
chunks = []
while True:
    chunk = sock.recv(65536)
    if not chunk:
        break
    chunks.append(chunk)
sys.stdout.buffer.write(b"".join(chunks))
`, socketPayload, "/run/wdtt/admin.sock"))), req.Password)
	stdoutText, stderrText, cmdErr := runSSHCommandSeparated(client, command, 70*time.Second)
	text := stdoutText
	if strings.TrimSpace(stderrText) != "" {
		if text != "" && !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		text += stderrText
	}
	jsonText := extractTrailingJSONObject(stdoutText)

	var state serverAdminState
	if jsonText != "" {
		if err := json.Unmarshal([]byte(jsonText), &state); err == nil {
			if cmdErr != nil || !state.OK {
				message := strings.TrimSpace(state.Message)
				if message == "" && cmdErr != nil {
					message = "server admin failed: " + cmdErr.Error()
				}
				return serverAdminResponse{OK: false, Status: "error", Message: message, Output: text, State: &state}
			}
			return serverAdminResponse{OK: true, Status: "success", Message: strings.TrimSpace(state.Message), Output: text, State: &state}
		}
	}

	if cmdErr != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "server admin failed: " + cmdErr.Error(), Output: text}
	}
	if err := json.Unmarshal([]byte(stdoutText), &state); err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "server returned invalid admin JSON", Output: text}
	}
	if !state.OK {
		return serverAdminResponse{OK: false, Status: "error", Message: strings.TrimSpace(state.Message), Output: text, State: &state}
	}
	return serverAdminResponse{OK: true, Status: "success", Message: strings.TrimSpace(state.Message), Output: text, State: &state}
}

func runStableServerAdmin(sshClient *ssh.Client, req serverAdminRequest) (serverAdminResponse, bool) {
	probeCommand := rootDeployCommand(`[ -S /run/wdtt/admin.sock ] && printf 'present' || printf 'missing'`, req.Password)
	stdoutText, _, cmdErr := runSSHCommandSeparated(sshClient, probeCommand, 10*time.Second)
	if cmdErr == nil && strings.TrimSpace(stdoutText) == "present" {
		return serverAdminResponse{}, false
	}
	payloadData, err := json.Marshal(req)
	if err != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "failed to encode stable admin payload: " + err.Error()}, true
	}
	command := rootDeployCommand(
		fmt.Sprintf(
			`python3 -c %s %s`,
			shellQuoteDeploy(wdttStableAdminScript),
			shellQuoteDeploy(base64.StdEncoding.EncodeToString(payloadData)),
		),
		req.Password,
	)
	stdoutText, stderrText, cmdErr = runSSHCommandSeparated(sshClient, command, 70*time.Second)
	text := stdoutText
	if strings.TrimSpace(stderrText) != "" {
		if text != "" && !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		text += stderrText
	}
	var response serverAdminResponse
	if err := json.Unmarshal([]byte(stdoutText), &response); err != nil {
		message := "stable WDTT admin returned invalid JSON"
		if cmdErr != nil {
			message = "server admin failed: " + cmdErr.Error()
		}
		return serverAdminResponse{OK: false, Status: "error", Message: message, Output: text}, true
	}
	response.Output = text
	if cmdErr != nil && response.OK {
		response.OK = false
		response.Status = "error"
		if strings.TrimSpace(response.Message) == "" {
			response.Message = "server admin failed: " + cmdErr.Error()
		}
	}
	if response.Status == "" {
		if response.OK {
			response.Status = "success"
		} else {
			response.Status = "error"
		}
	}
	return response, true
}

func (r serverAdminRequest) adminArgs() ([]string, error) {
	switch r.Action {
	case "list":
		return []string{"list"}, nil
	case "create":
		args := []string{"create", "--days", fmt.Sprint(maxInt(0, minInt(r.Days, 365)))}
		if r.Label != "" {
			args = append(args, "--label", r.Label)
		}
		if r.VKHash != "" {
			args = append(args, "--vk-hash", r.VKHash)
		}
		if r.Ports != "" {
			args = append(args, "--ports", r.Ports)
		}
		if r.ClientPassword != "" {
			args = append(args, "--client-password", r.ClientPassword)
		}
		return args, nil
	case "delete", "unbind", "activate", "deactivate":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{r.Action, "--password", r.ClientPassword}, nil
	case "set-label":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{"set-label", "--password", r.ClientPassword, "--label", r.Label}, nil
	case "set-hash":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{"set-hash", "--password", r.ClientPassword, "--vk-hash", r.VKHash}, nil
	case "set-ports":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{"set-ports", "--password", r.ClientPassword, "--ports", r.Ports}, nil
	case "set-password":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		if r.NewPassword == "" {
			return nil, fmt.Errorf("new password is empty")
		}
		return []string{"set-password", "--password", r.ClientPassword, "--new-password", r.NewPassword}, nil
	case "set-expiry":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		if r.ExpiresAt != nil {
			return []string{"set-expiry", "--password", r.ClientPassword, "--expires-at", fmt.Sprint(*r.ExpiresAt)}, nil
		}
		return []string{"set-expiry", "--password", r.ClientPassword, "--days", fmt.Sprint(maxInt(0, minInt(r.Days, 365)))}, nil
	case "update-client":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		args := []string{"update-client", "--password", r.ClientPassword}
		if r.Label != "" {
			args = append(args, "--label", r.Label)
		}
		if r.VKHash != "" {
			args = append(args, "--vk-hash", r.VKHash)
		}
		if r.Ports != "" {
			args = append(args, "--ports", r.Ports)
		}
		return args, nil
	case "cleanup-expired":
		return []string{"cleanup-expired"}, nil
	case "cleanup-orphans":
		return []string{"cleanup-orphans"}, nil
	default:
		return nil, fmt.Errorf("unsupported server admin action %q", r.Action)
	}
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func extractTrailingJSONObject(text string) string {
	end := strings.LastIndexByte(text, '}')
	if end < 0 {
		return ""
	}
	depth := 0
	inString := false
	escaped := false
	start := -1
	for i := end; i >= 0; i-- {
		ch := text[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			if ch == '\\' {
				escaped = true
				continue
			}
			if ch == '"' {
				inString = false
			}
			continue
		}
		switch ch {
		case '"':
			inString = true
		case '}':
			depth++
		case '{':
			depth--
			if depth == 0 {
				start = i
				i = -1
			}
		}
	}
	if start < 0 || start > end {
		return ""
	}
	return strings.TrimSpace(text[start : end+1])
}
