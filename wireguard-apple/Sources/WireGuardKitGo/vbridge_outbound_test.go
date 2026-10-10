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
				"wdtt_warp_handshake_ready",
				"WDTT_ERROR=warp_route_check_failed",
				"WDTT_ERROR=warp_handshake_check_failed",
				`iptables -t nat -C POSTROUTING`,
				`ip -4 route get 1.1.1.1 from "$TEST_SOURCE"`,
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
		"wdtt_warp_cleanup_ready",
		`! ip rule show`,
		`! ip route show table "$WDTT_TABLE"`,
		"WDTT_ERROR=direct_cleanup_failed",
	} {
		if !strings.Contains(script, required) {
			t.Fatalf("cleanup script missing %q", required)
		}
	}
}

func TestWarpDeleteIsIdempotentAndRemovesSystemdUnit(t *testing.T) {
	script := deleteFreeWarpScript()
	for _, required := range []string{
		"wdtt_clear_warp_out",
		"/etc/systemd/system/wdtt-wg-exit.service",
		"systemctl daemon-reload",
		"systemctl reset-failed",
	} {
		if !strings.Contains(script, required) {
			t.Fatalf("WARP delete script missing %q", required)
		}
	}
	cleanup := strings.LastIndex(script, "\nwdtt_clear_warp_out\n")
	modeCheck := strings.LastIndex(script, `if [ "$MODE" = "warp_free" ]; then`)
	if cleanup < 0 || modeCheck < 0 || cleanup > modeCheck {
		t.Fatal("WARP delete must clean stale runtime before checking recorded mode")
	}
}

func TestWarpResetCleansStaleRuntimeWithoutChangingOtherOutboundMode(t *testing.T) {
	script := resetFreeWarpScript()
	cleanup := strings.LastIndex(script, "\nwdtt_clear_warp_out\n")
	modeCheck := strings.LastIndex(script, `if [ "$MODE" = "warp_free" ]; then`)
	if cleanup < 0 || modeCheck < 0 || cleanup > modeCheck {
		t.Fatal("WARP reset must clean stale runtime before checking recorded mode")
	}
	prelude := outboundPrelude()
	start := strings.Index(prelude, "wdtt_clear_warp_out() {")
	end := strings.Index(prelude, "wdtt_clear_external_out() {")
	if start < 0 || end <= start {
		t.Fatal("could not isolate WARP-only cleanup")
	}
	warpCleanup := prelude[start:end]
	if strings.Contains(warpCleanup, "wdtt-redsocks") || strings.Contains(warpCleanup, "WDTT_PROXY_OUT") {
		t.Fatal("WARP-only cleanup must preserve a different active outbound mode")
	}
}
