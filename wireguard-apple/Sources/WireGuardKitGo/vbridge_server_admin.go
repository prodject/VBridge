package main

/*
#include <stdlib.h>
*/
import "C"

import (
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
	State   *adminResponse `json:"state,omitempty"`
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
	command := fmt.Sprintf("/usr/local/bin/wdtt-server admin -main-password %s %s", shellQuoteDeploy(req.MainPassword), strings.Join(args, " "))
	text, cmdErr := runSSHCommand(client, command, 70*time.Second)
	if cmdErr != nil {
		return serverAdminResponse{OK: false, Status: "error", Message: "server admin failed: " + cmdErr.Error(), Output: text}
	}

	var state adminResponse
	if err := json.Unmarshal([]byte(text), &state); err != nil {
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
			args = append(args, "--label", shellQuoteDeploy(r.Label))
		}
		if r.VKHash != "" {
			args = append(args, "--vk-hash", shellQuoteDeploy(r.VKHash))
		}
		if r.Ports != "" {
			args = append(args, "--ports", shellQuoteDeploy(r.Ports))
		}
		if r.ClientPassword != "" {
			args = append(args, "--client-password", shellQuoteDeploy(r.ClientPassword))
		}
		return args, nil
	case "delete", "unbind", "activate", "deactivate":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{r.Action, "--password", shellQuoteDeploy(r.ClientPassword)}, nil
	case "set-label":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{"set-label", "--password", shellQuoteDeploy(r.ClientPassword), "--label", shellQuoteDeploy(r.Label)}, nil
	case "set-hash":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{"set-hash", "--password", shellQuoteDeploy(r.ClientPassword), "--vk-hash", shellQuoteDeploy(r.VKHash)}, nil
	case "set-ports":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		return []string{"set-ports", "--password", shellQuoteDeploy(r.ClientPassword), "--ports", shellQuoteDeploy(r.Ports)}, nil
	case "set-password":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		if r.NewPassword == "" {
			return nil, fmt.Errorf("new password is empty")
		}
		return []string{"set-password", "--password", shellQuoteDeploy(r.ClientPassword), "--new-password", shellQuoteDeploy(r.NewPassword)}, nil
	case "set-expiry":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		if r.ExpiresAt != nil {
			return []string{"set-expiry", "--password", shellQuoteDeploy(r.ClientPassword), "--expires-at", fmt.Sprint(*r.ExpiresAt)}, nil
		}
		return []string{"set-expiry", "--password", shellQuoteDeploy(r.ClientPassword), "--days", fmt.Sprint(maxInt(0, minInt(r.Days, 365)))}, nil
	case "update-client":
		if r.ClientPassword == "" {
			return nil, fmt.Errorf("client password is empty")
		}
		args := []string{"update-client", "--password", shellQuoteDeploy(r.ClientPassword)}
		if r.Label != "" {
			args = append(args, "--label", shellQuoteDeploy(r.Label))
		}
		if r.VKHash != "" {
			args = append(args, "--vk-hash", shellQuoteDeploy(r.VKHash))
		}
		if r.Ports != "" {
			args = append(args, "--ports", shellQuoteDeploy(r.Ports))
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

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
