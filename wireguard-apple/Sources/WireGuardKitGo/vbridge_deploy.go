package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/crypto/ssh"
)

type deployRequest struct {
	Action           string `json:"action"`
	Host             string `json:"host"`
	User             string `json:"user"`
	Password         string `json:"password"`
	Port             int    `json:"port"`
	DeployScript     string `json:"deployScriptPath"`
	ServerBinary     string `json:"serverBinaryPath"`
	MainPassword     string `json:"mainPassword"`
	AdminID          string `json:"adminId"`
	BotToken         string `json:"botToken"`
	DTLSPort         int    `json:"dtlsPort"`
	WGPort           int    `json:"wgPort"`
	DNS1             string `json:"dns1"`
	DNS2             string `json:"dns2"`
	MaxPasswords     int    `json:"maxPasswords"`
	MaxWorkersPerAccess int `json:"maxWorkersPerAccess"`
	MaxHandshakes    int    `json:"maxHandshakes"`
	HandshakeRate    int    `json:"handshakeRate"`
	MaxClientMbps    int    `json:"maxClientMbps"`
	StateArchiveBase64 string `json:"stateArchiveBase64"`
}

type deployResponse struct {
	OK             bool   `json:"ok"`
	Status         string `json:"status"`
	Message        string `json:"message"`
	Output         string `json:"output"`
	ServerConnected bool   `json:"serverConnected"`
	WDTTInstalled  bool   `json:"wdttInstalled"`
	ReadyToConnect bool   `json:"readyToConnect"`
	DTLSPort       int    `json:"dtlsPort,omitempty"`
	WGPort         int    `json:"wgPort,omitempty"`
	DNS1           string `json:"dns1,omitempty"`
	DNS2           string `json:"dns2,omitempty"`
	MainPassword   string `json:"mainPassword,omitempty"`
	AdminID        string `json:"adminId,omitempty"`
	BotToken       string `json:"botToken,omitempty"`
}

type deployStatusChecks struct {
	ServerConnected bool
	WDTTInstalled  bool
	ReadyToConnect bool
	DTLSPort       int
	WGPort         int
	DNS1           string
	DNS2           string
	MainPassword   string
	AdminID        string
	BotToken       string
	MaxPasswords   int
	MaxWorkersPerAccess int
	MaxHandshakes  int
	HandshakeRate  int
	MaxClientMbps  int
}

type deployStateArchive struct {
	Format        string `json:"format"`
	Version       int    `json:"version"`
	ExportedAt    string `json:"exportedAt"`
	PasswordsJSON string `json:"passwordsJson"`
	WGKeysData    string `json:"wgKeysData,omitempty"`
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

	if req.Action == "status" {
		checks, text := checkDeployStatus(client)
		appendOutput(req.Action, text)
		return deployResponse{
			OK:              true,
			Status:          "success",
			Message:         "WDTT status checked",
			Output:          output.String(),
			ServerConnected: checks.ServerConnected,
			WDTTInstalled:  checks.WDTTInstalled,
			ReadyToConnect: checks.ReadyToConnect,
			DTLSPort:       checks.DTLSPort,
			WGPort:         checks.WGPort,
			DNS1:           checks.DNS1,
			DNS2:           checks.DNS2,
			MainPassword:   checks.MainPassword,
			AdminID:        checks.AdminID,
			BotToken:       checks.BotToken,
		}
	}

	if req.Action == "export_logs" {
		checks, text := checkDeployStatus(client)
		appendOutput("status", text)

		logText, commandErr := runSSHCommand(
			client,
			rootDeployCommand(exportServerLogsCommand(), req.Password),
			45*time.Second,
		)
		appendOutput("export logs", logText)
		if commandErr != nil {
			return deployResponse{
				OK:              false,
				Status:          "error",
				Message:         "server log export failed: " + commandErr.Error(),
				Output:          output.String(),
				ServerConnected: true,
				WDTTInstalled:   checks.WDTTInstalled,
				ReadyToConnect:  checks.ReadyToConnect,
				DTLSPort:        checks.DTLSPort,
				WGPort:          checks.WGPort,
				DNS1:            checks.DNS1,
				DNS2:            checks.DNS2,
				MainPassword:    checks.MainPassword,
				AdminID:         checks.AdminID,
				BotToken:        checks.BotToken,
			}
		}
		return deployResponse{
			OK:              true,
			Status:          "success",
			Message:         "Server logs exported",
			Output:          output.String(),
			ServerConnected: true,
			WDTTInstalled:   checks.WDTTInstalled,
			ReadyToConnect:  checks.ReadyToConnect,
			DTLSPort:        checks.DTLSPort,
			WGPort:          checks.WGPort,
			DNS1:            checks.DNS1,
			DNS2:            checks.DNS2,
			MainPassword:    checks.MainPassword,
			AdminID:         checks.AdminID,
			BotToken:        checks.BotToken,
		}
	}

	if req.Action == "export_state" {
		checks, text := checkDeployStatus(client)
		appendOutput("status", text)

		state, commandErr := exportDeployState(client, req.Password)
		if commandErr != nil {
			return deployResponse{
				OK:              false,
				Status:          "error",
				Message:         "server state export failed: " + commandErr.Error(),
				Output:          output.String(),
				ServerConnected: true,
				WDTTInstalled:   checks.WDTTInstalled,
				ReadyToConnect:  checks.ReadyToConnect,
				DTLSPort:        checks.DTLSPort,
				WGPort:          checks.WGPort,
				DNS1:            checks.DNS1,
				DNS2:            checks.DNS2,
				MainPassword:    checks.MainPassword,
				AdminID:         checks.AdminID,
				BotToken:        checks.BotToken,
			}
		}

		appendOutput("export state", "Server state archive prepared.")
		appendOutput("state archive", state)
		return deployResponse{
			OK:              true,
			Status:          "success",
			Message:         "Server state exported",
			Output:          output.String(),
			ServerConnected: true,
			WDTTInstalled:   checks.WDTTInstalled,
			ReadyToConnect:  checks.ReadyToConnect,
			DTLSPort:        checks.DTLSPort,
			WGPort:          checks.WGPort,
			DNS1:            checks.DNS1,
			DNS2:            checks.DNS2,
			MainPassword:    checks.MainPassword,
			AdminID:         checks.AdminID,
			BotToken:        checks.BotToken,
		}
	}

	if req.Action == "import_state" {
		checks, text := checkDeployStatus(client)
		appendOutput("status", text)

		archiveText, decodeErr := decodeStateArchive(req.StateArchiveBase64)
		if decodeErr != nil {
			return deployResponse{
				OK:              false,
				Status:          "error",
				Message:         "invalid server state archive: " + decodeErr.Error(),
				Output:          output.String(),
				ServerConnected: true,
				WDTTInstalled:   checks.WDTTInstalled,
				ReadyToConnect:  checks.ReadyToConnect,
			}
		}

		importText, commandErr := importDeployState(client, req.Password, archiveText)
		appendOutput("import state", importText)
		checks, checkText := checkDeployStatus(client)
		appendOutput("status", checkText)
		if commandErr != nil {
			return deployResponse{
				OK:              false,
				Status:          "error",
				Message:         "server state import failed: " + commandErr.Error(),
				Output:          output.String(),
				ServerConnected: true,
				WDTTInstalled:   checks.WDTTInstalled,
				ReadyToConnect:  checks.ReadyToConnect,
				DTLSPort:        checks.DTLSPort,
				WGPort:          checks.WGPort,
				DNS1:            checks.DNS1,
				DNS2:            checks.DNS2,
				MainPassword:    checks.MainPassword,
				AdminID:         checks.AdminID,
				BotToken:        checks.BotToken,
			}
		}

		return deployResponse{
			OK:              true,
			Status:          "success",
			Message:         "Server state imported",
			Output:          output.String(),
			ServerConnected: true,
			WDTTInstalled:   checks.WDTTInstalled,
			ReadyToConnect:  checks.ReadyToConnect,
			DTLSPort:        checks.DTLSPort,
			WGPort:          checks.WGPort,
			DNS1:            checks.DNS1,
			DNS2:            checks.DNS2,
			MainPassword:    checks.MainPassword,
			AdminID:         checks.AdminID,
			BotToken:        checks.BotToken,
		}
	}

	if req.Action == "cleanup_devices" {
		text, commandErr := runSSHCommand(
			client,
			rootDeployCommand(cleanupOrphanDevicesCommand(), req.Password),
			2*time.Minute,
		)
		appendOutput("cleanup devices", text)
		checks, checkText := checkDeployStatus(client)
		appendOutput("status", checkText)
		if commandErr != nil {
			return deployResponse{
				OK: false, Status: "error",
				Message: "device cleanup failed: " + commandErr.Error(),
				Output: output.String(), ServerConnected: true,
				WDTTInstalled: checks.WDTTInstalled, ReadyToConnect: checks.ReadyToConnect,
			}
		}
		return deployResponse{
			OK: true, Status: "success", Message: "Orphan WDTT devices cleaned",
			Output: output.String(), ServerConnected: true,
			WDTTInstalled: checks.WDTTInstalled, ReadyToConnect: checks.ReadyToConnect,
		}
	}

	if err := uploadDeployFile(client, req.DeployScript, "/tmp/vbridge-wdtt-deploy.sh", 0o755); err != nil {
		return deployResponse{
			OK:              false,
			Status:          "error",
			Message:         "deploy script upload failed: " + err.Error(),
			Output:          output.String(),
			ServerConnected: true,
		}
	}

	if req.Action == "install" || req.Action == "update_preserve" {
		if err := uploadDeployFile(client, req.ServerBinary, "/tmp/wdtt-server", 0o755); err != nil {
			return deployResponse{
				OK:              false,
				Status:          "error",
				Message:         "server binary upload failed: " + err.Error(),
				Output:          output.String(),
				ServerConnected: true,
			}
		}
	}

	command := req.remoteCommand()
	text, err := runSSHCommand(client, rootDeployCommand(command, req.Password), 15*time.Minute)
	appendOutput(req.Action, text)
	checks, checkText := checkDeployStatus(client)
	appendOutput("status", checkText)
	if err != nil {
		return deployResponse{
			OK:              false,
			Status:          "error",
			Message:         "remote deploy failed: " + err.Error(),
			Output:          output.String(),
			ServerConnected: checks.ServerConnected,
			WDTTInstalled:  checks.WDTTInstalled,
			ReadyToConnect: checks.ReadyToConnect,
			DTLSPort:       checks.DTLSPort,
			WGPort:         checks.WGPort,
			DNS1:           checks.DNS1,
			DNS2:           checks.DNS2,
			MainPassword:   checks.MainPassword,
			AdminID:        checks.AdminID,
			BotToken:       checks.BotToken,
		}
	}

	if strings.Contains(text, "error:") || strings.Contains(text, "[✗]") {
		return deployResponse{
			OK:              false,
			Status:          "error",
			Message:         "remote deploy reported an error",
			Output:          output.String(),
			ServerConnected: checks.ServerConnected,
			WDTTInstalled:  checks.WDTTInstalled,
			ReadyToConnect: checks.ReadyToConnect,
			DTLSPort:       checks.DTLSPort,
			WGPort:         checks.WGPort,
			DNS1:           checks.DNS1,
			DNS2:           checks.DNS2,
			MainPassword:   checks.MainPassword,
			AdminID:        checks.AdminID,
			BotToken:       checks.BotToken,
		}
	}

	return deployResponse{
		OK:              true,
		Status:          "success",
		Message:         "WDTT deploy completed",
		Output:          output.String(),
		ServerConnected: checks.ServerConnected,
		WDTTInstalled:  checks.WDTTInstalled,
		ReadyToConnect: checks.ReadyToConnect,
		DTLSPort:       checks.DTLSPort,
		WGPort:         checks.WGPort,
		DNS1:           checks.DNS1,
		DNS2:           checks.DNS2,
		MainPassword:   checks.MainPassword,
		AdminID:        checks.AdminID,
		BotToken:       checks.BotToken,
	}
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
	if r.MaxPasswords == 0 {
		r.MaxPasswords = 50
	}
	if r.MaxHandshakes == 0 {
		r.MaxHandshakes = 32
	}
	if r.HandshakeRate == 0 {
		r.HandshakeRate = 24
	}
	r.DNS1 = strings.TrimSpace(r.DNS1)
	r.DNS2 = strings.TrimSpace(r.DNS2)
}

func (r deployRequest) validate() error {
	if r.Action != "install" && r.Action != "update_preserve" && r.Action != "uninstall" && r.Action != "status" && r.Action != "cleanup_devices" && r.Action != "export_logs" && r.Action != "export_state" && r.Action != "import_state" {
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
	if r.MaxPasswords < 1 {
		return fmt.Errorf("invalid max passwords %d", r.MaxPasswords)
	}
	if r.MaxWorkersPerAccess < 0 {
		return fmt.Errorf("invalid max workers per access %d", r.MaxWorkersPerAccess)
	}
	if r.MaxHandshakes < 1 {
		return fmt.Errorf("invalid max handshakes %d", r.MaxHandshakes)
	}
	if r.HandshakeRate < 1 {
		return fmt.Errorf("invalid handshake rate %d", r.HandshakeRate)
	}
	if r.MaxClientMbps < 0 {
		return fmt.Errorf("invalid max client mbps %d", r.MaxClientMbps)
	}
	if (r.Action == "install" || r.Action == "update_preserve" || r.Action == "uninstall") && r.DeployScript == "" {
		return errors.New("deploy script path is empty")
	}
	if (r.Action == "install" || r.Action == "update_preserve") && r.MainPassword == "" {
		return errors.New("WDTT main password is empty")
	}
	if (r.Action == "install" || r.Action == "update_preserve") && r.ServerBinary == "" {
		return errors.New("server binary path is empty")
	}
	if r.Action == "import_state" && strings.TrimSpace(r.StateArchiveBase64) == "" {
		return errors.New("server state archive is empty")
	}
	return nil
}

func cleanupOrphanDevicesCommand() string {
	return strings.Join([]string{
		"set -euo pipefail",
		"db=/etc/wdtt/passwords.json",
		"test -f \"$db\"",
		"command -v jq >/dev/null 2>&1 || { echo 'error: jq is required'; exit 1; }",
		"backup=\"${db}.backup-$(date +%Y%m%d-%H%M%S)\"",
		"systemctl stop wdtt",
		"trap 'systemctl start wdtt >/dev/null 2>&1 || true' EXIT",
		"cp -p \"$db\" \"$backup\"",
		"before=$(jq '.devices | length' \"$db\")",
		"jq '[.passwords[].device_id | select(. != \"\")] as $keep | .devices |= with_entries(select(.key as $id | $keep | index($id)))' \"$db\" > \"${db}.tmp\"",
		"chown --reference=\"$db\" \"${db}.tmp\" 2>/dev/null || true",
		"chmod --reference=\"$db\" \"${db}.tmp\" 2>/dev/null || chmod 600 \"${db}.tmp\"",
		"mv \"${db}.tmp\" \"$db\"",
		"after=$(jq '.devices | length' \"$db\")",
		"systemctl start wdtt",
		"trap - EXIT",
		"printf 'Devices before: %s\\nDevices after: %s\\nBackup: %s\\n' \"$before\" \"$after\" \"$backup\"",
	}, "; ")
}

func exportServerLogsCommand() string {
	return strings.Join([]string{
		"set -eu",
		"echo '===== wdtt service ====='",
		"systemctl status wdtt --no-pager -n 50 2>&1 || true",
		"echo",
		"echo '===== wdtt journal (current boot) ====='",
		"journalctl -u wdtt --no-pager -b -n 400 2>&1 || true",
		"echo",
		"echo '===== wdtt install log ====='",
		"if [ -f /var/log/wdtt-install.log ]; then tail -n 200 /var/log/wdtt-install.log 2>&1; else echo 'wdtt-install.log not found'; fi",
		"echo",
		"echo '===== kernel/network hints ====='",
		"ip addr show wdtt0 2>&1 || true",
		"echo",
		"ss -lunp | grep -E '(:56000|:56001|wdtt)' 2>&1 || true",
	}, "; ")
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
	case "update_preserve":
		args := strings.TrimSpace(strings.Join([]string{
			deployFlag("-password", r.MainPassword),
			deployFlag("-admin", r.AdminID),
			deployFlag("-bot-token", r.BotToken),
			deployFlag("-dns", deployDNSValue(r.DNS1, r.DNS2)),
		}, " "))
		return fmt.Sprintf(
			"env WDTT_PRESERVE_DATA=1 WDTT_MAX_PASSWORDS=%d WDTT_MAX_WORKERS_PER_ACCESS=%d WDTT_MAX_HANDSHAKES=%d WDTT_HANDSHAKE_RATE=%d WDTT_MAX_CLIENT_MBPS=%d WDTT_ARGS=%s WDTT_DTLS_PORT=%d WDTT_WG_PORT=%d WDTT_SSH_PORT=%d bash /tmp/vbridge-wdtt-deploy.sh install",
			r.MaxPasswords,
			r.MaxWorkersPerAccess,
			r.MaxHandshakes,
			r.HandshakeRate,
			r.MaxClientMbps,
			shellQuoteDeploy(args),
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
			"env WDTT_MAX_PASSWORDS=%d WDTT_MAX_WORKERS_PER_ACCESS=%d WDTT_MAX_HANDSHAKES=%d WDTT_HANDSHAKE_RATE=%d WDTT_MAX_CLIENT_MBPS=%d WDTT_ARGS=%s WDTT_DTLS_PORT=%d WDTT_WG_PORT=%d WDTT_SSH_PORT=%d bash /tmp/vbridge-wdtt-deploy.sh install",
			r.MaxPasswords,
			r.MaxWorkersPerAccess,
			r.MaxHandshakes,
			r.HandshakeRate,
			r.MaxClientMbps,
			shellQuoteDeploy(args),
			r.DTLSPort,
			r.WGPort,
			r.Port,
		)
	}
}

func exportDeployState(client *ssh.Client, password string) (string, error) {
	command := strings.Join([]string{
		"set -euo pipefail",
		"db=/etc/wdtt/passwords.json",
		"keys=/etc/wdtt/wg-keys.dat",
		"[ -f \"$db\" ] || { echo 'error: passwords.json not found'; exit 1; }",
		"db_b64=$(base64 < \"$db\" | tr -d '\\n')",
		"keys_b64=''",
		"[ -f \"$keys\" ] && keys_b64=$(base64 < \"$keys\" | tr -d '\\n') || true",
		`printf '{"format":"wdtt-plus-state","version":1,"exportedAt":"%s","passwordsJson":"%s","wgKeysData":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$db_b64" "$keys_b64"`,
	}, "; ")
	return runSSHCommand(client, rootDeployCommand(command, password), 45*time.Second)
}

func importDeployState(client *ssh.Client, password, archiveText string) (string, error) {
	if err := uploadDeployContent(client, []byte(archiveText), "/tmp/vbridge-wdtt-state.json", 0o600); err != nil {
		return "", err
	}
	pythonScript := strings.Join([]string{
		"import base64, json, pathlib",
		"archive = pathlib.Path('/tmp/vbridge-wdtt-state.json')",
		"data = json.loads(archive.read_text())",
		"if data.get('format') != 'wdtt-plus-state': raise SystemExit('invalid format')",
		"db_bytes = base64.b64decode(data.get('passwordsJson', ''))",
		"if not db_bytes: raise SystemExit('empty passwordsJson')",
		"pathlib.Path('/etc/wdtt').mkdir(parents=True, exist_ok=True)",
		"pathlib.Path('/etc/wdtt/passwords.json').write_bytes(db_bytes)",
		"wg_data = data.get('wgKeysData', '')",
		"wg_path = pathlib.Path('/etc/wdtt/wg-keys.dat')",
		"wg_path.write_bytes(base64.b64decode(wg_data)) if wg_data else (wg_path.unlink() if wg_path.exists() else None)",
	}, "; ")
	command := strings.Join([]string{
		"set -euo pipefail",
		"db=/etc/wdtt/passwords.json",
		"keys=/etc/wdtt/wg-keys.dat",
		"archive=/tmp/vbridge-wdtt-state.json",
		"python3 -c " + shellQuoteDeploy(pythonScript),
		"chmod 600 \"$db\"",
		"[ -f \"$keys\" ] && chmod 600 \"$keys\" || true",
		"systemctl restart wdtt >/dev/null 2>&1 || true",
		"rm -f \"$archive\"",
		"echo 'Server state imported into /etc/wdtt'",
	}, "; ")
	return runSSHCommand(client, rootDeployCommand(command, password), 2*time.Minute)
}

func uploadDeployContent(client *ssh.Client, data []byte, remotePath string, mode os.FileMode) error {
	cmd := fmt.Sprintf("cat > %s && chmod %o %s", shellQuoteDeploy(remotePath), mode.Perm(), shellQuoteDeploy(remotePath))
	_, err := runSSHCommandWithInput(client, cmd, data, 2*time.Minute)
	return err
}

func decodeStateArchive(value string) (string, error) {
	data, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil {
		return "", err
	}
	return string(data), nil
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

func checkDeployStatus(client *ssh.Client) (deployStatusChecks, string) {
	command := strings.Join([]string{
		"service_active=0",
		"binary_installed=0",
		"service_file=0",
		"iface_active=0",
		"systemctl is-active --quiet wdtt 2>/dev/null && service_active=1",
		"[ -x /usr/local/bin/wdtt-server ] && binary_installed=1",
		"[ -f /etc/systemd/system/wdtt.service ] && service_file=1",
		"ip link show wdtt0 >/dev/null 2>&1 && iface_active=1",
		"printf 'Server connected: yes\\n'",
		"if [ \"$binary_installed\" = \"1\" ] && [ \"$service_file\" = \"1\" ]; then printf 'WDTT installed: yes\\n'; else printf 'WDTT installed: no\\n'; fi",
		"if [ \"$service_active\" = \"1\" ] && [ \"$binary_installed\" = \"1\" ] && [ \"$service_file\" = \"1\" ] && [ \"$iface_active\" = \"1\" ]; then printf 'Ready to connect: yes\\n'; else printf 'Ready to connect: no\\n'; fi",
		"printf 'WDTT_STATUS|service_active=%s|binary_installed=%s|service_file=%s|iface_active=%s\\n' \"$service_active\" \"$binary_installed\" \"$service_file\" \"$iface_active\"",
		"if [ -f /etc/systemd/system/wdtt.service ]; then sed -n 's/^ExecStart=//p' /etc/systemd/system/wdtt.service | tail -n 1 | sed 's/^/WDTT_EXECSTART|/'; fi",
	}, "; ")

	text, err := runSSHCommand(client, command, 20*time.Second)
	if err != nil {
		return deployStatusChecks{ServerConnected: true}, text + "\nstatus check failed: " + err.Error()
	}

	checks := deployStatusChecks{ServerConnected: true}
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "WDTT_EXECSTART|") {
			mergeDeployStatusConfig(&checks, parseWDTTExecStart(strings.TrimPrefix(line, "WDTT_EXECSTART|")))
			continue
		}
		if !strings.HasPrefix(line, "WDTT_STATUS|") {
			continue
		}
		values := map[string]bool{}
		for _, part := range strings.Split(strings.TrimPrefix(line, "WDTT_STATUS|"), "|") {
			pair := strings.SplitN(part, "=", 2)
			if len(pair) == 2 {
				values[pair[0]] = pair[1] == "1"
			}
		}
		checks.WDTTInstalled = values["binary_installed"] && values["service_file"]
		checks.ReadyToConnect = checks.WDTTInstalled && values["service_active"] && values["iface_active"]
	}

	return checks, text
}

func mergeDeployStatusConfig(dst *deployStatusChecks, src deployStatusChecks) {
	if src.DTLSPort != 0 {
		dst.DTLSPort = src.DTLSPort
	}
	if src.WGPort != 0 {
		dst.WGPort = src.WGPort
	}
	if src.DNS1 != "" {
		dst.DNS1 = src.DNS1
	}
	if src.DNS2 != "" {
		dst.DNS2 = src.DNS2
	}
	if src.MainPassword != "" {
		dst.MainPassword = src.MainPassword
	}
	if src.AdminID != "" {
		dst.AdminID = src.AdminID
	}
	if src.BotToken != "" {
		dst.BotToken = src.BotToken
	}
}

func parseWDTTExecStart(execStart string) deployStatusChecks {
	var checks deployStatusChecks
	tokens := strings.Fields(execStart)
	for i := 0; i < len(tokens); i++ {
		if i+1 >= len(tokens) {
			continue
		}
		value := tokens[i+1]
		switch tokens[i] {
		case "-listen":
			checks.DTLSPort = parseDeployListenPort(value)
			i++
		case "-wg-port":
			checks.WGPort = parseDeployPort(value)
			i++
		case "-dns":
			dns := strings.SplitN(value, ",", 2)
			checks.DNS1 = strings.TrimSpace(dns[0])
			if len(dns) == 2 {
				checks.DNS2 = strings.TrimSpace(dns[1])
			}
			i++
		case "-password":
			checks.MainPassword = value
			i++
		case "-admin":
			checks.AdminID = value
			i++
		case "-bot-token":
			checks.BotToken = value
			i++
		}
	}
	return checks
}

func parseDeployListenPort(value string) int {
	if _, port, err := net.SplitHostPort(value); err == nil {
		return parseDeployPort(port)
	}
	if idx := strings.LastIndex(value, ":"); idx >= 0 && idx+1 < len(value) {
		return parseDeployPort(value[idx+1:])
	}
	return parseDeployPort(value)
}

func parseDeployPort(value string) int {
	port, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || port < 1 || port > 65535 {
		return 0
	}
	return port
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
	stdout, stderr, err := runSSHCommandSeparatedWithInput(client, command, input, timeout)
	return stdout + stderr, err
}

func runSSHCommandSeparated(client *ssh.Client, command string, timeout time.Duration) (string, string, error) {
	return runSSHCommandSeparatedWithInput(client, command, nil, timeout)
}

func runSSHCommandSeparatedWithInput(client *ssh.Client, command string, input []byte, timeout time.Duration) (string, string, error) {
	session, err := client.NewSession()
	if err != nil {
		return "", "", err
	}
	defer session.Close()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr
	if input != nil {
		session.Stdin = bytes.NewReader(input)
	}

	done := make(chan error, 1)
	go func() {
		done <- session.Run(command)
	}()

	select {
	case err := <-done:
		return stdout.String(), stderr.String(), err
	case <-time.After(timeout):
		_ = session.Close()
		return stdout.String(), stderr.String(), fmt.Errorf("timeout after %s", timeout)
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
