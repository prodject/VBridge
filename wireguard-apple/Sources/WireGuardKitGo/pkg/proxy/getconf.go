// SPDX-License-Identifier: MIT

package proxy

// GETCONF: the one-time WireGuard auto-provisioning step of the WRAP-A
// (amurcanov-compatible) transport. After the WRAP-A + DTLS handshake comes
// up, the client sends a plaintext control line over the DTLS conn:
//
//	GETCONF:<clientPort>|<deviceID>|<password>
//
// and the server replies with a WireGuard INI it minted for this device
// (Curve25519 keypair + an IP from its 10.66.66.0/24 pool), or one of the
// sentinel error strings NOCONF / DENIED:<reason>. WireGuard packets then
// flow directly over the same DTLS conn — there is NO READY handshake (the
// 1-byte transport keepalive is handled in the WG pump, not here).
//
// Verified byte-for-byte against the live server 2026-06-03 (tools/wrapa_test
// M2). Full protocol spec: reference_amurcanov_wrap_format.md.
//
// Architecture note: the server's INI carries `Endpoint=127.0.0.1:<port>`,
// which is amurcanov's Android-loopback artefact (his app runs WG over a
// local socket → proxy). It is IRRELEVANT to us — our WireGuard routes via a
// custom conn.Bind (pkg/turnbind) with an already-fake endpoint, so we take
// ONLY the crypto from GETCONF and drop the Endpoint line. The clientPort we
// send is a throwaway the server only echoes back.

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// wrapAGetconfPort is the placeholder local WG port sent in GETCONF. The
// server only echoes it into the (discarded) Endpoint line, so the value is
// arbitrary; we use WireGuard's default for familiarity.
const wrapAGetconfPort = "51820"

// WrapAProvision is the WireGuard configuration the amurcanov server mints
// for our device via GETCONF. It is populated once per tunnel (the first
// runWrapASession to complete GETCONF wins) and consumed by the bridge to
// build the WG UAPI config + the iOS network settings (address/dns/mtu).
type WrapAProvision struct {
	// PrivateKeyHex is our (server-minted) WireGuard private key, hex.
	PrivateKeyHex string `json:"private_key_hex"`
	// PeerPublicKeyHex is the server's WireGuard public key, hex.
	PeerPublicKeyHex string `json:"peer_public_key_hex"`
	// Address is the tunnel interface address in CIDR form (e.g.
	// "10.66.66.2/32"). Applied to the iOS NEPacketTunnelNetworkSettings,
	// NOT the UAPI.
	Address string `json:"address"`
	// DNS is the server-suggested DNS resolver (e.g. "1.1.1.1").
	DNS string `json:"dns"`
	// MTU is the server-suggested tunnel MTU (e.g. 1280).
	MTU int `json:"mtu"`
	// KeepaliveSec is the WireGuard persistent-keepalive interval.
	KeepaliveSec int `json:"keepalive_sec"`
}

// UAPIConfig renders the WireGuard UAPI configuration string for IpcSet from
// the provisioned crypto. The endpoint is intentionally a throwaway loopback
// address — our turnbind conn.Bind ignores it and routes every WG packet
// through the TURN/WRAP-A transport in-process (see pkg/turnbind/bind.go and
// the TunnelManager "fake endpoint" comment). Only the keys + keepalive are
// load-bearing.
func (wp *WrapAProvision) UAPIConfig() string {
	keepalive := wp.KeepaliveSec
	if keepalive <= 0 {
		keepalive = 25
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", wp.PrivateKeyHex)
	fmt.Fprintf(&b, "public_key=%s\n", wp.PeerPublicKeyHex)
	b.WriteString("allowed_ip=0.0.0.0/0\n")
	b.WriteString("endpoint=127.0.0.1:" + wrapAGetconfPort + "\n")
	fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", keepalive)
	return b.String()
}

// doGetconf performs the GETCONF control exchange over an established WRAP-A
// DTLS conn and returns the parsed provision. Every WRAP-A conn must call
// this as its FIRST message (the server sniffs the first datagram) before
// any WireGuard traffic flows; the response is idempotent per deviceID, so
// all conns receive the same crypto.
func doGetconf(conn net.Conn, deviceID, password string) (*WrapAProvision, error) {
	if deviceID == "" {
		return nil, errors.New("getconf: empty deviceID")
	}
	if password == "" {
		return nil, errors.New("getconf: empty password")
	}

	req := fmt.Sprintf("GETCONF:%s|%s|%s", wrapAGetconfPort, deviceID, password)
	_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write([]byte(req)); err != nil {
		_ = conn.SetWriteDeadline(time.Time{})
		return nil, fmt.Errorf("getconf: write: %w", err)
	}
	_ = conn.SetWriteDeadline(time.Time{})

	buf := make([]byte, 4096)
	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	n, err := conn.Read(buf)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		return nil, fmt.Errorf("getconf: read: %w", err)
	}
	resp := strings.TrimSpace(string(buf[:n]))

	switch {
	case resp == "NOCONF":
		return nil, errors.New("getconf: server returned NOCONF (no config for this device)")
	case strings.HasPrefix(resp, "DENIED:"):
		// DENIED:wrong_password / DENIED:expired / DENIED:device_mismatch
		return nil, fmt.Errorf("getconf: denied: %s", strings.TrimPrefix(resp, "DENIED:"))
	}

	prov, err := parseWGINIToProvision(resp)
	if err != nil {
		return nil, fmt.Errorf("getconf: %w (resp %q)", err, truncate(resp, 120))
	}
	return prov, nil
}

// parseWGINIToProvision parses the server's WireGuard INI into a
// WrapAProvision, converting the base64 keys to hex (UAPI wants hex). The
// Endpoint line is deliberately ignored.
func parseWGINIToProvision(ini string) (*WrapAProvision, error) {
	wp := &WrapAProvision{DNS: "1.1.1.1", MTU: 1280, KeepaliveSec: 25}
	var privB64, pubB64 string
	for _, ln := range strings.Split(ini, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(ln), "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		switch k {
		case "PrivateKey":
			privB64 = v
		case "PublicKey":
			pubB64 = v
		case "Address":
			wp.Address = v
		case "DNS":
			wp.DNS = strings.TrimSpace(strings.Split(v, ",")[0])
		case "MTU":
			if _, err := fmt.Sscanf(v, "%d", &wp.MTU); err != nil || wp.MTU <= 0 {
				wp.MTU = 1280
			}
		case "PersistentKeepalive":
			if _, err := fmt.Sscanf(v, "%d", &wp.KeepaliveSec); err != nil || wp.KeepaliveSec <= 0 {
				wp.KeepaliveSec = 25
			}
		}
	}
	if privB64 == "" || pubB64 == "" || wp.Address == "" {
		return nil, errors.New("INI missing PrivateKey/PublicKey/Address")
	}
	var err error
	if wp.PrivateKeyHex, err = keyB64toHex(privB64); err != nil {
		return nil, fmt.Errorf("PrivateKey: %w", err)
	}
	if wp.PeerPublicKeyHex, err = keyB64toHex(pubB64); err != nil {
		return nil, fmt.Errorf("PublicKey: %w", err)
	}
	return wp, nil
}

// keyB64toHex decodes a standard-base64 WireGuard key into lowercase hex.
func keyB64toHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("key not 32 bytes (%d)", len(raw))
	}
	return hex.EncodeToString(raw), nil
}
