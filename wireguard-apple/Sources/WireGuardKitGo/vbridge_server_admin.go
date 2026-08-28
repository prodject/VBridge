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
)

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
