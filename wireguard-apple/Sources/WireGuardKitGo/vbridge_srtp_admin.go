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

type srtpAdminRequest struct {
	Action   string `json:"action"`
	Host     string `json:"host"`
	User     string `json:"user"`
	Password string `json:"password"`
	Port     int    `json:"port"`
	Label    string `json:"label,omitempty"`
	ClientID string `json:"clientId,omitempty"`
}

type srtpAdminClient struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Address   string `json:"address"`
	PublicKey string `json:"public_key"`
	CreatedAt int64  `json:"created_at"`
	Config    string `json:"config"`
}

type srtpAdminResponse struct {
	OK      bool              `json:"ok"`
	Message string            `json:"message"`
	Clients []srtpAdminClient `json:"clients,omitempty"`
	Output  string            `json:"output,omitempty"`
}

//export VBridgeWGSRTPAdmin
func VBridgeWGSRTPAdmin(configJSON *C.char) *C.char {
	if configJSON == nil {
		return srtpAdminCString(srtpAdminResponse{OK: false, Message: "empty SRTP admin config"})
	}
	var req srtpAdminRequest
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &req); err != nil {
		return srtpAdminCString(srtpAdminResponse{OK: false, Message: "invalid SRTP admin JSON: " + err.Error()})
	}
	return srtpAdminCString(runSRTPAdmin(req))
}

func srtpAdminCString(response srtpAdminResponse) *C.char {
	data, err := json.Marshal(response)
	if err != nil {
		return C.CString(`{"ok":false,"message":"failed to encode SRTP admin response"}`)
	}
	return C.CString(string(data))
}

func runSRTPAdmin(req srtpAdminRequest) srtpAdminResponse {
	req.Action = strings.TrimSpace(strings.ToLower(req.Action))
	req.Host = strings.TrimSpace(req.Host)
	req.User = strings.TrimSpace(req.User)
	req.Label = strings.TrimSpace(req.Label)
	req.ClientID = strings.TrimSpace(req.ClientID)
	if req.User == "" {
		req.User = "root"
	}
	if req.Port == 0 {
		req.Port = 22
	}
	if req.Host == "" || req.Password == "" {
		return srtpAdminResponse{OK: false, Message: "server host or SSH password is empty"}
	}
	client, err := dialDeploySSH(deployRequest{Host: req.Host, User: req.User, Password: req.Password, Port: req.Port})
	if err != nil {
		return srtpAdminResponse{OK: false, Message: "SSH connect failed: " + err.Error()}
	}
	defer client.Close()

	var command string
	switch req.Action {
	case "list":
		command = "/usr/local/sbin/vbridge-srtp-client list"
	case "create":
		label := base64.StdEncoding.EncodeToString([]byte(req.Label))
		command = fmt.Sprintf("/usr/local/sbin/vbridge-srtp-client create %s", shellQuoteDeploy(label))
	case "delete":
		if req.ClientID == "" {
			return srtpAdminResponse{OK: false, Message: "SRTP client ID is empty"}
		}
		command = fmt.Sprintf("/usr/local/sbin/vbridge-srtp-client delete %s", shellQuoteDeploy(req.ClientID))
	default:
		return srtpAdminResponse{OK: false, Message: "unsupported SRTP admin action"}
	}

	stdoutText, stderrText, cmdErr := runSSHCommandSeparated(client, rootDeployCommand(command, req.Password), 45*time.Second)
	var response srtpAdminResponse
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdoutText)), &response); err != nil {
		message := "SRTP server returned invalid admin response"
		if cmdErr != nil {
			message = "SRTP admin failed: " + cmdErr.Error()
		}
		return srtpAdminResponse{OK: false, Message: message, Output: strings.TrimSpace(stdoutText + "\n" + stderrText)}
	}
	if cmdErr != nil || !response.OK {
		if response.Message == "" && cmdErr != nil {
			response.Message = "SRTP admin failed: " + cmdErr.Error()
		}
		response.OK = false
	}
	response.Output = strings.TrimSpace(stderrText)
	return response
}
