package main

import (
	"strings"
	"testing"
)

func TestWDTTUpdateCommandRequiresPreserveMode(t *testing.T) {
	request := deployRequest{
		DeployKind: "wdtt-plus",
		Action:     "update_preserve",
		DTLSPort:   56000,
		WGPort:     56001,
		Port:       22,
	}
	command := request.remoteCommand()
	for _, required := range []string{
		"WDTT_INSTALL_MODE=preserve",
		"WDTT_PRESERVE_DATA=1",
		"bash /tmp/vbridge-wdtt-deploy.sh install",
	} {
		if !strings.Contains(command, required) {
			t.Fatalf("update command missing %q: %s", required, command)
		}
	}
}

func TestWDTTFreshInstallDoesNotEnablePreserveMode(t *testing.T) {
	request := deployRequest{
		DeployKind: "wdtt-plus",
		Action:     "install",
		DTLSPort:   56000,
		WGPort:     56001,
		Port:       22,
	}
	command := request.remoteCommand()
	if strings.Contains(command, "WDTT_INSTALL_MODE=preserve") ||
		strings.Contains(command, "WDTT_PRESERVE_DATA=1") {
		t.Fatalf("fresh install unexpectedly enables preserve mode: %s", command)
	}
}

func TestWDTTExistingTunIsPlusOnly(t *testing.T) {
	for _, action := range []string{"install", "update_preserve"} {
		for _, kind := range []string{"wdtt", "wdtt-plus"} {
			request := deployRequest{
				DeployKind: kind, Action: action,
				DTLSPort: 56000, WGPort: 56001, Port: 22,
				WDTTExistingTunEnabled: true, WDTTExistingTunName: "tun0",
			}
			command := request.remoteCommand()
			if strings.Contains(command, "-existing-tun") != (kind == "wdtt-plus") {
				t.Fatalf("%s/%s has incompatible TUN arguments: %s", kind, action, command)
			}
		}
	}
}
