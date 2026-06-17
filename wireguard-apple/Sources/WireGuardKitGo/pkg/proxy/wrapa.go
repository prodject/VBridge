// SPDX-License-Identifier: MIT

package proxy

// WRAP-A: amurcanov-compatible RTP-obfuscation layer for the "SRTP-WRAP-A"
// 4th client transport mode (Config.UseWrapA=true).
//
// This is a SEPARATE wire format from pkg/proxy/wrap.go (the samosvalishe
// SRTP-WRAP used by our own servers). It exists solely to interoperate with
// amurcanov's proxy-turn-vk-android server, which ships an Android client
// only — users keep asking how to reach it from iOS. Despite the "SRTP" in
// the UI name, amurcanov's masking is NOT SRTP: it is a plain RTP-framed
// ChaCha20-Poly1305 envelope wrapping the bytes of a plain DTLS session
// (UDP/VK-TURN → WRAP-A → plain DTLS → { GETCONF | WireGuard }).
//
// Wire format (verbatim from amurcanov v1.2.2 go_client/obfs.go + wrap.go,
// proven byte-correct end-to-end against the live server 2026-06-03 via
// tools/wrapa_test — see open_task_amurcanov_wrap_a_mode.md):
//
//	byte 0    : 0xA0            V=2, P=1 (RTP padding present)
//	byte 1    : PT & 0x7F       payload type 111
//	byte 2-3  : seq16 BE        initSeq + count (mod 2^16)
//	byte 4-7  : ts32 BE         initTs + 960*count + (count>>16)
//	byte 8-11 : SSRC BE         random per-conn, constant
//	byte 12.. : ChaCha20-Poly1305 ciphertext || 16B tag
//	... pad   : 0..(PaddingMax-1) random bytes
//	last byte : padTotal        (= padRand+1, RFC 3550 §5.1 trailing pad len)
//
// AEAD: ChaCha20-Poly1305. Nonce is IMPLICIT (derived from RTP fields, NOT
// on the wire): SSRC(4) || seq(2) || 0x0000 || ts(4). AAD = the 12-byte RTP
// header only. Key = HKDF-SHA256(password, salt="WDTT-WRAP-v1",
// info="rtp-obfs/chacha20poly1305"), 32 bytes. The SAME password also
// authenticates the GETCONF control exchange (see getconf.go).
//
// Differences vs wrap.go that make this a distinct format (any one breaks
// Poly1305 auth): implicit RTP-derived nonce (vs explicit 12B on wire),
// 12-byte AAD (vs 24), RTP trailing padding (vs none), HKDF-from-password
// key (vs raw 32B), byte0=0xA0/P=1 (vs 0x80/P=0).
//
// The ts carry term (count>>16) is amurcanov's v1.2.0 fix for a nonce-reuse
// vuln (his implicit nonce repeated every 2^26 packets ≈ 67 GB without it);
// we mirror it for wire compatibility. Interop-only — our own conn recycling
// makes the period irrelevant. See reference_amurcanov_wrap_format.md.

import (
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const (
	// wrapAKeyLen is the ChaCha20-Poly1305 key length (256-bit).
	wrapAKeyLen = 32

	// wrapARTPHdrLen is the fixed RTP header / AAD size.
	wrapARTPHdrLen = 12

	// wrapAPayloadType is the RTP payload type amurcanov uses (111).
	wrapAPayloadType byte = 111

	// wrapAPaddingMax bounds the random RTP trailing padding (0..23 bytes
	// + 1 length byte). Matches amurcanov's ObfsConfig.PaddingMax.
	wrapAPaddingMax = 24

	// wrapATSStep is the RTP timestamp increment per packet.
	wrapATSStep uint32 = 960

	// wrapAMaxPacket sizes the reusable per-conn TX/RX buffers. DTLS records
	// over a TURN-relayed UDP path stay MTU-bounded (~1500 B); 2 KB leaves
	// headroom for the 12B header + 16B tag + up to 25B padding overhead.
	wrapAMaxPacket = 2048
)

// deriveWrapAKey derives the 32-byte ChaCha20-Poly1305 key from the shared
// password via HKDF-SHA256, matching amurcanov's wrap.go exactly. The salt
// and info strings are part of the wire contract and must not change.
func deriveWrapAKey(password string) ([]byte, error) {
	if password == "" {
		return nil, errors.New("wrap-a: empty password")
	}
	key := make([]byte, wrapAKeyLen)
	r := hkdf.New(sha256.New, []byte(password), []byte("WDTT-WRAP-v1"), []byte("rtp-obfs/chacha20poly1305"))
	if _, err := io.ReadFull(r, key); err != nil {
		return nil, fmt.Errorf("wrap-a: derive key: %w", err)
	}
	return key, nil
}

// wrapABuildNonce writes the 12-byte implicit nonce SSRC||seq||0x0000||ts
// into dst. The two zero bytes at [6:8] are part of amurcanov's format.
func wrapABuildNonce(dst *[12]byte, ssrc uint32, seq uint16, ts uint32) {
	binary.BigEndian.PutUint32(dst[0:4], ssrc)
	binary.BigEndian.PutUint16(dst[4:6], seq)
	dst[6] = 0
	dst[7] = 0
	binary.BigEndian.PutUint32(dst[8:12], ts)
}

// wrapAIsRTP reports whether wire looks like one of our WRAP-A packets
// (V=2, PT=111). Used to drop stray non-RTP datagrams on the read path.
func wrapAIsRTP(wire []byte) bool {
	return len(wire) >= 13 && (wire[0]>>6) == 2 && (wire[1]&0x7F) == wrapAPayloadType
}

// wrapAPacketConn wraps a base net.PacketConn (in production: conn1, the
// DTLS-transport end of the AsyncPacketPipe whose other end runTURN relays
// to VK TURN) with amurcanov's RTP obfuscation. A pion/dtls client runs on
// top of it, exactly as tools/wrapa_test layered DTLS over the raw UDP
// socket. WriteTo wraps; ReadFrom unwraps.
//
// Concurrency: pion/dtls may write from more than one goroutine (handshake
// flights + our WG send goroutine), so the TX path (counter + txBuf) is
// mutex-guarded. The RX path is single-reader in pion (one read loop) but
// guarded too for safety and to keep rxBuf reuse race-free. Buffers are
// reused per packet — no per-datagram allocation on the hot path (the
// per-packet alloc churn that caused the 2026-05 SRTP jetsam is exactly
// what we avoid here).
type wrapAPacketConn struct {
	base  net.PacketConn
	raddr net.Addr
	aead  cipher.AEAD
	ssrc  uint32

	txMu    sync.Mutex
	initSeq uint16
	initTs  uint32
	count   uint64
	txBuf   []byte

	rxMu  sync.Mutex
	rxBuf []byte
}

// newWrapAPacketConn builds a WRAP-A transport over base, addressed to
// raddr (the DTLS remote — ignored by the pipe but kept for net.PacketConn
// semantics). key must be 32 bytes (from deriveWrapAKey). Random per-conn
// SSRC / initial seq / initial timestamp mean a passive observer can't
// recover the packet count from the first datagram.
func newWrapAPacketConn(base net.PacketConn, raddr net.Addr, key []byte) (*wrapAPacketConn, error) {
	if len(key) != wrapAKeyLen {
		return nil, fmt.Errorf("wrap-a: key must be %d bytes (got %d)", wrapAKeyLen, len(key))
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, fmt.Errorf("wrap-a: aead init: %w", err)
	}
	var seed [10]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return nil, fmt.Errorf("wrap-a: rand init: %w", err)
	}
	return &wrapAPacketConn{
		base:    base,
		raddr:   raddr,
		aead:    aead,
		ssrc:    binary.BigEndian.Uint32(seed[0:4]),
		initSeq: binary.BigEndian.Uint16(seed[4:6]),
		initTs:  binary.BigEndian.Uint32(seed[6:10]),
		txBuf:   make([]byte, wrapAMaxPacket),
		rxBuf:   make([]byte, wrapAMaxPacket),
	}, nil
}

// WriteTo wraps payload as a WRAP-A RTP packet and writes it to the base
// conn. Returns len(payload) on success (the application-layer byte count,
// not the wire size) so callers see DTLS-record accounting.
func (c *wrapAPacketConn) WriteTo(payload []byte, addr net.Addr) (int, error) {
	if len(payload) == 0 {
		return 0, errors.New("wrap-a: empty payload")
	}
	c.txMu.Lock()

	cnt := c.count
	c.count++
	seq := c.initSeq + uint16(cnt)
	ts := c.initTs + uint32(cnt)*wrapATSStep + uint32(cnt>>16)

	// Random RTP padding length in [1, wrapAPaddingMax].
	var rnd [1]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		c.txMu.Unlock()
		return 0, fmt.Errorf("wrap-a: rand pad: %w", err)
	}
	padRand := int(rnd[0]) % wrapAPaddingMax
	padTotal := padRand + 1

	outLen := wrapARTPHdrLen + len(payload) + chacha20poly1305.Overhead + padTotal
	if outLen > len(c.txBuf) {
		c.txMu.Unlock()
		return 0, fmt.Errorf("wrap-a: packet too large (%d > %d)", outLen, len(c.txBuf))
	}
	dst := c.txBuf

	dst[0] = 0x80 | 0x20 // V=2, P=1
	dst[1] = wrapAPayloadType & 0x7F
	binary.BigEndian.PutUint16(dst[2:4], seq)
	binary.BigEndian.PutUint32(dst[4:8], ts)
	binary.BigEndian.PutUint32(dst[8:12], c.ssrc)

	var nonce [12]byte
	wrapABuildNonce(&nonce, c.ssrc, seq, ts)
	// Seal in place: ciphertext+tag land at dst[12 : 12+len(payload)+16].
	// payload (the DTLS record) and dst (txBuf) are distinct buffers.
	c.aead.Seal(dst[wrapARTPHdrLen:wrapARTPHdrLen], nonce[:], payload, dst[:wrapARTPHdrLen])

	padStart := wrapARTPHdrLen + len(payload) + chacha20poly1305.Overhead
	if padRand > 0 {
		if _, err := rand.Read(dst[padStart : padStart+padRand]); err != nil {
			c.txMu.Unlock()
			return 0, fmt.Errorf("wrap-a: rand padbytes: %w", err)
		}
	}
	dst[outLen-1] = byte(padTotal)

	_, err := c.base.WriteTo(dst[:outLen], addr)
	c.txMu.Unlock()
	if err != nil {
		return 0, err
	}
	return len(payload), nil
}

// ReadFrom reads one WRAP-A packet from the base conn, unwraps it, and
// writes the recovered DTLS record into p. Non-RTP datagrams and packets
// that fail AEAD auth are skipped (VK relays occasionally inject probes).
// The returned addr is the fixed remote so the DTLS state machine sees a
// stable peer.
func (c *wrapAPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	c.rxMu.Lock()
	defer c.rxMu.Unlock()
	for {
		n, _, err := c.base.ReadFrom(c.rxBuf)
		if err != nil {
			return 0, c.raddr, err
		}
		if !wrapAIsRTP(c.rxBuf[:n]) {
			continue
		}
		m, uerr := c.wrapAUnwrap(c.rxBuf[:n], p)
		if uerr != nil {
			continue
		}
		return m, c.raddr, nil
	}
}

// wrapAUnwrap recovers the plaintext from a WRAP-A wire packet into dst and
// returns its length. Stateless (the nonce is derived from the wire's RTP
// fields), so safe to call without the TX lock.
func (c *wrapAPacketConn) wrapAUnwrap(wire, dst []byte) (int, error) {
	if len(wire) < 13 || (wire[0]>>6) != 2 {
		return 0, errors.New("wrap-a: bad packet")
	}
	seq := binary.BigEndian.Uint16(wire[2:4])
	ts := binary.BigEndian.Uint32(wire[4:8])
	ssrc := binary.BigEndian.Uint32(wire[8:12])

	payloadEnd := len(wire)
	if wire[0]&0x20 != 0 { // P bit: strip RTP trailing padding
		padLen := int(wire[len(wire)-1])
		if padLen == 0 || padLen > payloadEnd-wrapARTPHdrLen {
			return 0, fmt.Errorf("wrap-a: invalid padding %d", padLen)
		}
		payloadEnd -= padLen
	}
	if payloadEnd-wrapARTPHdrLen <= chacha20poly1305.Overhead {
		return 0, errors.New("wrap-a: no payload")
	}

	var nonce [12]byte
	wrapABuildNonce(&nonce, ssrc, seq, ts)
	plain, err := c.aead.Open(dst[:0], nonce[:], wire[wrapARTPHdrLen:payloadEnd], wire[:wrapARTPHdrLen])
	if err != nil {
		return 0, fmt.Errorf("wrap-a: auth: %w", err)
	}
	return len(plain), nil
}

func (c *wrapAPacketConn) Close() error                       { return c.base.Close() }
func (c *wrapAPacketConn) LocalAddr() net.Addr                { return c.base.LocalAddr() }
func (c *wrapAPacketConn) SetDeadline(t time.Time) error      { return c.base.SetDeadline(t) }
func (c *wrapAPacketConn) SetReadDeadline(t time.Time) error  { return c.base.SetReadDeadline(t) }
func (c *wrapAPacketConn) SetWriteDeadline(t time.Time) error { return c.base.SetWriteDeadline(t) }
