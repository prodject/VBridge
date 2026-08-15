package main

import (
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

func exportCSQTTLogsCommand() string {
	return strings.Join([]string{
		"set -eu",
		"echo '===== csqtt container ====='",
		"docker ps -a --filter name=csqtt-vpn 2>&1 || true",
		"echo",
		"echo '===== csqtt logs ====='",
		"if [ -d /opt/vbridge-csqtt ]; then cd /opt/vbridge-csqtt && docker compose logs --tail 400 2>&1; else echo 'csqtt install dir not found'; fi",
	}, "; ")
}

func checkCSQTTStatus(client *ssh.Client) (deployStatusChecks, string) {
	command := strings.Join([]string{
		"installed=0",
		"running=0",
		"peer_port=46000",
		"web_port=46002",
		"[ -x /opt/vbridge-csqtt/csqtt ] && [ -f /opt/vbridge-csqtt/docker-compose.yml ] && installed=1",
		"if [ -f /opt/vbridge-csqtt/.env ]; then . /opt/vbridge-csqtt/.env; fi",
		"[ -n \"${CSQTT_PEER_PORT:-}\" ] && peer_port=\"$CSQTT_PEER_PORT\" || true",
		"[ -n \"${CSQTT_WEB_PORT:-}\" ] && web_port=\"$CSQTT_WEB_PORT\" || true",
		"docker ps --filter name=csqtt-vpn --filter status=running -q 2>/dev/null | grep -q . && running=1 || true",
		"printf 'Server connected: yes\\n'",
		"if [ \"$installed\" = \"1\" ]; then printf 'CSQTT installed: yes\\n'; else printf 'CSQTT installed: no\\n'; fi",
		"if [ \"$installed\" = \"1\" ] && [ \"$running\" = \"1\" ]; then printf 'Ready to connect: yes\\n'; else printf 'Ready to connect: no\\n'; fi",
		"printf 'CSQTT_STATUS|installed=%s|running=%s|peer_port=%s|web_port=%s\\n' \"$installed\" \"$running\" \"$peer_port\" \"$web_port\"",
	}, "; ")

	text, err := runSSHCommand(client, command, 20*time.Second)
	if err != nil {
		return deployStatusChecks{ServerConnected: true}, text + "\nstatus check failed: " + err.Error()
	}

	checks := deployStatusChecks{ServerConnected: true}
	for _, line := range strings.Split(text, "\n") {
		if !strings.HasPrefix(line, "CSQTT_STATUS|") {
			continue
		}
		for _, part := range strings.Split(strings.TrimPrefix(line, "CSQTT_STATUS|"), "|") {
			pair := strings.SplitN(part, "=", 2)
			if len(pair) != 2 {
				continue
			}
			switch pair[0] {
			case "installed":
				checks.WDTTInstalled = pair[1] == "1"
			case "running":
				checks.ReadyToConnect = pair[1] == "1"
			case "peer_port":
				checks.DTLSPort = parseDeployPort(pair[1])
			case "web_port":
				checks.WGPort = parseDeployPort(pair[1])
			}
		}
	}

	checks.ReadyToConnect = checks.WDTTInstalled && checks.ReadyToConnect
	return checks, text
}
