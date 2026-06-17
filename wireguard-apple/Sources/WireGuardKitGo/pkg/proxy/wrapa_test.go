// SPDX-License-Identifier: MIT

package proxy

import (
	"bytes"
	"crypto/rand"
	"net"
	"testing"
	"time"

	"github.com/cbeuw/connutil"
)

var wrapATestAddr = &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}

// TestWrapARoundTrip checks that a packet wrapped by one wrapAPacketConn
// unwraps byte-identically on a second one sharing the same password-derived
// key — the core interop invariant (the wire format is symmetric; no
// direction bit, unlike wrap.go). Covers a range of payload sizes through the
// full WriteTo → AsyncPacketPipe → ReadFrom path including RTP padding.
func TestWrapARoundTrip(t *testing.T) {
	key, err := deriveWrapAKey("correct horse battery staple")
	if err != nil {
		t.Fatalf("deriveWrapAKey: %v", err)
	}
	a, b := connutil.AsyncPacketPipe()
	defer a.Close()
	defer b.Close()
	cli, err := newWrapAPacketConn(a, wrapATestAddr, key)
	if err != nil {
		t.Fatalf("client conn: %v", err)
	}
	srv, err := newWrapAPacketConn(b, wrapATestAddr, key)
	if err != nil {
		t.Fatalf("server conn: %v", err)
	}

	rd := make([]byte, 2048)
	for _, sz := range []int{1, 16, 100, 1200, 1400} {
		// Loop several packets so seq/ts/count progression is exercised
		// (the nonce derives from these — a wrong carry would break unwrap).
		for i := 0; i < 5; i++ {
			payload := make([]byte, sz)
			if _, err := rand.Read(payload); err != nil {
				t.Fatal(err)
			}
			if _, err := cli.WriteTo(payload, wrapATestAddr); err != nil {
				t.Fatalf("WriteTo sz=%d: %v", sz, err)
			}
			n, _, err := srv.ReadFrom(rd)
			if err != nil {
				t.Fatalf("ReadFrom sz=%d: %v", sz, err)
			}
			if !bytes.Equal(rd[:n], payload) {
				t.Fatalf("round-trip mismatch sz=%d: got %d bytes, want %d", sz, n, len(payload))
			}
		}
	}
}

// TestWrapAWrongKeyFails verifies a different password yields a key that fails
// AEAD auth — so a misconfigured client can't silently exchange garbage.
func TestWrapAWrongKeyFails(t *testing.T) {
	keyGood, _ := deriveWrapAKey("password-A")
	keyBad, _ := deriveWrapAKey("password-B")
	if bytes.Equal(keyGood, keyBad) {
		t.Fatal("distinct passwords produced identical keys")
	}
	a, b := connutil.AsyncPacketPipe()
	defer a.Close()
	defer b.Close()
	cli, _ := newWrapAPacketConn(a, wrapATestAddr, keyGood)
	srv, _ := newWrapAPacketConn(b, wrapATestAddr, keyBad)

	payload := []byte("hello wrap-a")
	if _, err := cli.WriteTo(payload, wrapATestAddr); err != nil {
		t.Fatalf("WriteTo: %v", err)
	}
	// The server reads the raw wire directly (ReadFrom would loop forever
	// skipping the auth failure) and confirms unwrap rejects it.
	wire := make([]byte, 2048)
	_ = b.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	n, _, err := b.ReadFrom(wire)
	if err != nil {
		t.Fatalf("raw ReadFrom: %v", err)
	}
	if !wrapAIsRTP(wire[:n]) {
		t.Fatalf("wrapped packet is not recognised as RTP")
	}
	if _, uerr := srv.wrapAUnwrap(wire[:n], make([]byte, 2048)); uerr == nil {
		t.Fatal("wrapAUnwrap accepted a packet sealed under a different key")
	}
}

// TestWrapAFormat asserts the fixed RTP header fields amurcanov's server keys
// its first-message sniff and unwrap on (V=2, P=1, PT=111).
func TestWrapAFormat(t *testing.T) {
	key, _ := deriveWrapAKey("fmt")
	a, b := connutil.AsyncPacketPipe()
	defer a.Close()
	defer b.Close()
	cli, _ := newWrapAPacketConn(a, wrapATestAddr, key)
	if _, err := cli.WriteTo([]byte("x"), wrapATestAddr); err != nil {
		t.Fatalf("WriteTo: %v", err)
	}
	wire := make([]byte, 2048)
	_ = b.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	n, _, err := b.ReadFrom(wire)
	if err != nil {
		t.Fatalf("ReadFrom: %v", err)
	}
	if got := wire[0]; got != 0xA0 {
		t.Fatalf("byte0 = %#x, want 0xA0 (V=2,P=1)", got)
	}
	if got := wire[1] & 0x7F; got != wrapAPayloadType {
		t.Fatalf("PT = %d, want %d", got, wrapAPayloadType)
	}
	if n < 13 {
		t.Fatalf("wire too short: %d", n)
	}
}
