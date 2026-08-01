package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestExternalProxyTransparentCheckDoesNotCaptureRootXrayTraffic(t *testing.T) {
	script := outboundBotPrelude()

	for _, expected := range []string{
		`WDTT_PROXY_TEST_SOURCE="$test_source"`,
		`iptables -t nat -I OUTPUT -s "$test_source" -p tcp -j WDTT_PROXY_TEST`,
		`curl --interface "$test_source"`,
	} {
		if !strings.Contains(script, expected) {
			t.Fatalf("outbound script does not contain %q", expected)
		}
	}

	legacyInsertion := `iptables -t nat -I OUTPUT -p tcp -m owner --uid-owner 0 -j WDTT_PROXY_TEST`
	if strings.Contains(script, legacyInsertion) {
		t.Fatalf("outbound script still captures every root TCP connection")
	}
}

func TestOutboundBotScriptsHaveValidBashSyntax(t *testing.T) {
	scripts := map[string]string{
		"local proxy install": localProxyInstallScript("wdttuser", "safePassword123", 1080),
		"local proxy check":   localProxyCheckScript(),
		"external proxy":      externalProxyEnableScript("socks5", "proxy.example.com", 1080, "user", "password"),
		"direct exit":         outboundDisableScript(),
		"status":              outboundStatusScript(),
	}
	for name, script := range scripts {
		t.Run(name, func(t *testing.T) {
			assertBashSyntax(t, script)
		})
	}
}

func TestLocalProxyUsesPinnedVerifiedReleaseAndPersistentFirewall(t *testing.T) {
	script := localProxyInstallScript("wdttuser", "safePassword123", 1080)

	for _, expected := range []string{
		`THREEPROXY_VERSION='0.9.7'`,
		botThreeProxySourceSHA256,
		"sha256sum 3proxy.tar.gz",
		"local-proxy-firewall",
		"ExecStartPost=/usr/local/lib/wdtt/local-proxy-firewall up",
		`--proxy-user "$PROXY_LOGIN:$PROXY_PASSWORD"`,
	} {
		if !strings.Contains(script, expected) {
			t.Fatalf("local proxy script does not contain %q", expected)
		}
	}
	if strings.Contains(script, "master.tar.gz") {
		t.Fatal("local proxy script still downloads mutable master.tar.gz")
	}
	if strings.Contains(script, `echo "SOCKS5: socks5://$PROXY_LOGIN:$PROXY_PASSWORD@`) {
		t.Fatal("local proxy result exposes the generated password")
	}
}

func TestExternalProxyUsesPersistentRoutesAndSeparateCredentials(t *testing.T) {
	script := externalProxyEnableScript("socks5", "proxy.example.com", 1080, "user", "password")

	for _, expected := range []string{
		"redsocks-routes",
		"ExecStartPost=/usr/local/lib/wdtt/redsocks-routes up",
		"ExecStopPost=/usr/local/lib/wdtt/redsocks-routes down",
		"WDTT_ERROR=external_proxy_route_install_failed",
	} {
		if !strings.Contains(script, expected) {
			t.Fatalf("external proxy script does not contain %q", expected)
		}
	}
}

func TestExternalProxyInputRejectsAmbiguousCredentials(t *testing.T) {
	if _, _, _, _, _, err := parseExternalProxyInput("socks5 proxy.example.com 1080 user:name password"); err == nil {
		t.Fatal("login with colon must be rejected")
	}
	if _, _, _, _, _, err := parseExternalProxyInput(`socks5 proxy.example.com 1080 user pass\"word`); err == nil {
		t.Fatal("credentials requiring config escaping must be entered from the app")
	}
}

func assertBashSyntax(t *testing.T, script string) {
	t.Helper()
	file, err := os.CreateTemp("", "wdtt-outbound-*.sh")
	if err != nil {
		t.Fatal(err)
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err := file.WriteString(script); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command("bash", "-n", name).CombinedOutput()
	if err != nil {
		t.Fatalf("bash -n failed: %v\n%s", err, output)
	}
}
