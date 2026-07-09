package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/crypto/ssh"
)

type deployRequest struct {
	Action       string `json:"action"`
	Host         string `json:"host"`
	User         string `json:"user"`
	Password     string `json:"password"`
	Port         int    `json:"port"`
	DeployScript string `json:"deployScriptPath"`
	ServerBinary string `json:"serverBinaryPath"`
	MainPassword string `json:"mainPassword"`
	AdminID      string `json:"adminId"`
	BotToken     string `json:"botToken"`
	DTLSPort     int    `json:"dtlsPort"`
	WGPort       int    `json:"wgPort"`
	DNS1         string `json:"dns1"`
	DNS2         string `json:"dns2"`
}

type deployResponse struct {
	OK      bool   `json:"ok"`
	Status  string `json:"status"`
	Message string `json:"message"`
	Output  string `json:"output"`
}

//export VBridgeWGDeployServer
func VBridgeWGDeployServer(configJSON *C.char) *C.char {
	if configJSON == nil {
		return deployCString(deployResponse{OK: false, Status: "error", Message: "empty deploy config"})
	}

	var req deployRequest
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &req); err != nil {
		return deployCString(deployResponse{OK: false, Status: "error", Message: "invalid deploy JSON: " + err.Error()})
	}

	resp := runDeploy(req)
	return deployCString(resp)
}

func deployCString(resp deployResponse) *C.char {
	data, err := json.Marshal(resp)
	if err != nil {
		return C.CString(`{"ok":false,"status":"error","message":"failed to encode deploy response"}`)
	}
	return C.CString(string(data))
}

func runDeploy(req deployRequest) deployResponse {
	req.normalize()
	if err := req.validate(); err != nil {
		return deployResponse{OK: false, Status: "error", Message: err.Error()}
	}

	client, err := dialDeploySSH(req)
	if err != nil {
		return deployResponse{OK: false, Status: "error", Message: "SSH connect failed: " + err.Error()}
	}
	defer client.Close()

	var output strings.Builder
	appendOutput := func(label, text string) {
		if strings.TrimSpace(text) == "" {
			return
		}
		output.WriteString("== ")
		output.WriteString(label)
		output.WriteString(" ==\n")
		output.WriteString(text)
		if !strings.HasSuffix(text, "\n") {
			output.WriteByte('\n')
		}
	}

	if err := uploadDeployFile(client, req.DeployScript, "/tmp/vbridge-wdtt-deploy.sh", 0o755); err != nil {
		return deployResponse{OK: false, Status: "error", Message: "deploy script upload failed: " + err.Error(), Output: output.String()}
	}

	if req.Action == "install" {
		if err := uploadDeployFile(client, req.ServerBinary, "/tmp/wdtt-server", 0o755); err != nil {
			return deployResponse{OK: false, Status: "error", Message: "server binary upload failed: " + err.Error(), Output: output.String()}
		}
	}

	command := req.remoteCommand()
	text, err := runSSHCommand(client, rootDeployCommand(command, req.Password), 15*time.Minute)
	appendOutput(req.Action, text)
	if err != nil {
		return deployResponse{OK: false, Status: "error", Message: "remote deploy failed: " + err.Error(), Output: output.String()}
	}

	if strings.Contains(text, "error:") || strings.Contains(text, "[✗]") {
		return deployResponse{OK: false, Status: "error", Message: "remote deploy reported an error", Output: output.String()}
	}

	return deployResponse{OK: true, Status: "success", Message: "WDTT deploy completed", Output: output.String()}
}

func (r *deployRequest) normalize() {
	r.Action = strings.TrimSpace(strings.ToLower(r.Action))
	if r.Action == "" {
		r.Action = "install"
	}
	r.Host = strings.TrimSpace(r.Host)
	r.User = strings.TrimSpace(r.User)
	if r.User == "" {
		r.User = "root"
	}
	if r.Port == 0 {
		r.Port = 22
	}
	if r.DTLSPort == 0 {
		r.DTLSPort = 56000
	}
	if r.WGPort == 0 {
		r.WGPort = 56001
	}
	r.DNS1 = strings.TrimSpace(r.DNS1)
	r.DNS2 = strings.TrimSpace(r.DNS2)
}

func (r deployRequest) validate() error {
	if r.Action != "install" && r.Action != "uninstall" && r.Action != "status" {
		return fmt.Errorf("unsupported deploy action %q", r.Action)
	}
	if r.Host == "" {
		return errors.New("server host is empty")
	}
	if r.Password == "" {
		return errors.New("SSH password is empty")
	}
	if r.Port < 1 || r.Port > 65535 {
		return fmt.Errorf("invalid SSH port %d", r.Port)
	}
	if r.DTLSPort < 1 || r.DTLSPort > 65535 {
		return fmt.Errorf("invalid DTLS port %d", r.DTLSPort)
	}
	if r.WGPort < 1 || r.WGPort > 65535 {
		return fmt.Errorf("invalid WireGuard port %d", r.WGPort)
	}
	if r.DeployScript == "" {
		return errors.New("deploy script path is empty")
	}
	if r.Action == "install" && r.MainPassword == "" {
		return errors.New("WDTT main password is empty")
	}
	if r.Action == "install" && r.ServerBinary == "" {
		return errors.New("server binary path is empty")
	}
	return nil
}

func dialDeploySSH(req deployRequest) (*ssh.Client, error) {
	config := &ssh.ClientConfig{
		User: req.User,
		Auth: []ssh.AuthMethod{
			ssh.Password(req.Password),
			ssh.KeyboardInteractive(func(user, instruction string, questions []string, echos []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range answers {
					answers[i] = req.Password
				}
				return answers, nil
			}),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         20 * time.Second,
	}
	return ssh.Dial("tcp", net.JoinHostPort(req.Host, fmt.Sprint(req.Port)), config)
}

func uploadDeployFile(client *ssh.Client, localPath, remotePath string, mode os.FileMode) error {
	data, err := os.ReadFile(localPath)
	if err != nil {
		return err
	}

	cmd := fmt.Sprintf("cat > %s && chmod %o %s", shellQuoteDeploy(remotePath), mode.Perm(), shellQuoteDeploy(remotePath))
	_, err = runSSHCommandWithInput(client, cmd, data, 2*time.Minute)
	return err
}

func (r deployRequest) remoteCommand() string {
	switch r.Action {
	case "uninstall":
		return fmt.Sprintf(
			"env WDTT_DTLS_PORT=%d WDTT_WG_PORT=%d WDTT_SSH_PORT=%d bash /tmp/vbridge-wdtt-deploy.sh uninstall",
			r.DTLSPort,
			r.WGPort,
			r.Port,
		)
	case "status":
		return fmt.Sprintf(
			"env WDTT_DTLS_PORT=%d WDTT_WG_PORT=%d WDTT_SSH_PORT=%d bash /tmp/vbridge-wdtt-deploy.sh status",
			r.DTLSPort,
			r.WGPort,
			r.Port,
		)
	default:
		args := strings.TrimSpace(strings.Join([]string{
			deployFlag("-password", r.MainPassword),
			deployFlag("-admin", r.AdminID),
			deployFlag("-bot-token", r.BotToken),
			deployFlag("-dns", deployDNSValue(r.DNS1, r.DNS2)),
		}, " "))
		return fmt.Sprintf(
			"env WDTT_ARGS=%s WDTT_DTLS_PORT=%d WDTT_WG_PORT=%d WDTT_SSH_PORT=%d bash /tmp/vbridge-wdtt-deploy.sh install",
			shellQuoteDeploy(args),
			r.DTLSPort,
			r.WGPort,
			r.Port,
		)
	}
}

func deployFlag(name, value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	return name + " " + value
}

func deployDNSValue(dns1, dns2 string) string {
	parts := make([]string, 0, 2)
	for _, value := range []string{dns1, dns2} {
		value = strings.TrimSpace(value)
		if value != "" {
			parts = append(parts, value)
		}
	}
	return strings.Join(parts, ",")
}

func rootDeployCommand(command, password string) string {
	quotedCommand := shellQuoteDeploy(command)
	quotedPassword := shellQuoteDeploy(password)
	return "if [ \"$(id -u)\" = \"0\" ]; then bash -c " + quotedCommand + "; " +
		"elif command -v sudo >/dev/null 2>&1; then printf '%s\\n' " + quotedPassword + " | sudo -S bash -c " + quotedCommand + "; " +
		"else echo 'error: root privileges required and sudo not found'; exit 1; fi"
}

func runSSHCommand(client *ssh.Client, command string, timeout time.Duration) (string, error) {
	return runSSHCommandWithInput(client, command, nil, timeout)
}

func runSSHCommandWithInput(client *ssh.Client, command string, input []byte, timeout time.Duration) (string, error) {
	session, err := client.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	var combined bytes.Buffer
	session.Stdout = &combined
	session.Stderr = &combined
	if input != nil {
		session.Stdin = bytes.NewReader(input)
	}

	done := make(chan error, 1)
	go func() {
		done <- session.Run(command)
	}()

	select {
	case err := <-done:
		return combined.String(), err
	case <-time.After(timeout):
		_ = session.Close()
		return combined.String(), fmt.Errorf("timeout after %s", timeout)
	}
}

func shellQuoteDeploy(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

//export VBridgeWGFreeCString
func VBridgeWGFreeCString(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}
