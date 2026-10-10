package main

import (
	"strings"
	"testing"
)

func TestWarpChecksValidateManagedRouting(t *testing.T) {
	for name, script := range map[string]string{
		"check":   freeWarpCheckScript(false),
		"restart": freeWarpCheckScript(true),
		"install": freeWarpInstallScript(1280),
	} {
		t.Run(name, func(t *testing.T) {
			for _, required := range []string{
				"wdtt_warp_routing_ready",
				"WDTT_ERROR=warp_route_check_failed",
				`iptables -t nat -C POSTROUTING`,
			} {
				if !strings.Contains(script, required) {
					t.Fatalf("WARP script missing %q", required)
				}
			}
		})
	}
	installScript := freeWarpInstallScript(1280)
	if strings.Contains(installScript, "wg-quick down wg-wdtt-exit") {
		t.Fatal("WARP install still ignores failure while stopping the previous interface")
	}
}

func TestOutboundCleanupVerifiesInterfaceRemoval(t *testing.T) {
	script := outboundDisableScript()
	for _, required := range []string{
		`ip link show dev "$WDTT_WG_IFACE"`,
		"WDTT_ERROR=direct_cleanup_failed",
	} {
		if !strings.Contains(script, required) {
			t.Fatalf("cleanup script missing %q", required)
		}
	}
}
