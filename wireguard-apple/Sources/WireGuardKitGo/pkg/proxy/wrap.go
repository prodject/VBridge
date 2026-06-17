// SPDX-License-Identifier: MIT

package proxy

// SRTP-mimicry layer for the DTLS-over-TURN data path.
//
// Background: VK's TURN relays run a payload classifier that detects
// DTLS+WireGuard traffic patterns inside ChannelData and tags the
// destination (peer_ip, peer_port) endpoint, after which all traffic
// to that endpoint is throttled / blackholed / shaped (varies since
// the 2026-05-18 DPI update). The classifier appears to forward
// SRTP-shaped ChannelData on a fast path while down-classing anomalous
// payloads.
//
// This file wraps every UDP datagram on the wire to look like SRTP:
//
//   [12B RTP header | 12B explicit nonce | AEAD ciphertext | 16B tag]
//
// RTP header (RFC 3550):
//   byte 0  : 0x80           V=2, P=0, X=0, CC=0
//   byte 1  : 0x6F           M=0, PT=111 (opus, typical voice PT)
//   byte 2-3: seq16 BE       monotonic, init random
//   byte 4-7: ts32 BE        monotonic, init random, +960 per packet (20ms @ 48kHz)
//   byte 8-11: SSRC          random per-conn, MSB encodes direction
//
// 12B explicit nonce = 4B sessionID || 8B counter (BE). sessionID MSB
// matches SSRC MSB (direction bit: server=1, client=0). counter starts
// at a random uint64 and increments per packet. AAD = first 24 bytes
// (RTP header || nonce). AEAD = ChaCha20-Poly1305 with the shared
// 32-byte key (no subkey derivation).
//
// Fixed overhead per packet: 40 bytes (12 RTP + 12 nonce + 16 tag).
//
// Activated by Config.UseWrap=true (with Config.UseSrtp=false). Server
// side must run with matching -wrap-srtp + -wrap-key flags. Without
// matching cipher state on both sides, AEAD Open fails immediately on
// every packet — handshake never completes. Per-conn state (seq, ts,
// SSRC, sessionID, counter) is independent on each side; only the key
// and direction bit need to be coordinated.
//
// Wire format reference: github.com/samosvalishe/vk-turn-proxy@cd14d25
// (independent reimplementation; no code copied due to license).

import (
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"sync/atomic"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	// wrapKeyLen is the ChaCha20-Poly1305 key length (256-bit).
	wrapKeyLen = 32

	// wrapRTPHdrLen is the fixed RTP-style header size.
	wrapRTPHdrLen = 12

	// wrapNonceLen is the explicit per-packet nonce (ChaCha20-Poly1305
	// requires 12 bytes).
	wrapNonceLen = 12

	// wrapTagLen is the Poly1305 authentication tag length.
	wrapTagLen = 16

	// wrapHeaderLen is the AAD region size (RTP header || nonce).
	wrapHeaderLen = wrapRTPHdrLen + wrapNonceLen // 24

	// wrapOverhead is the total bytes added on the wire per packet.
	wrapOverhead = wrapHeaderLen + wrapTagLen // 40

	// wrapRTPVersion = V=2, P=0, X=0, CC=0.
	wrapRTPVersion byte = 0x80

	// wrapRTPPT = M=0, PT=111 (opus — typical voice payload type).
	wrapRTPPT byte = 0x6F

	// wrapTSStep is the RTP timestamp increment per packet (20ms @ 48kHz).
	wrapTSStep uint32 = 960
)

// wrapConn holds the per-direction cipher state for one TURN-relayed
// PacketConn. seq/ts/counter increment atomically per Seal call so the
// TX and RX goroutines on the same conn can each hold their own
// wrapConn without contention. The AEAD object itself is stateless and
// thread-safe (a single chacha20poly1305.New result can be shared).
type wrapConn struct {
	aead      cipher.AEAD
	sessionID [4]byte // 4B prefix of explicit nonce; MSB = direction
	ssrc      [4]byte // RTP SSRC bytes; MSB = direction
	counter   atomic.Uint64
	seq       atomic.Uint32 // RTP seq lives in low 16 bits
	timestamp atomic.Uint32 // RTP timestamp (full 32 bits)
}

// newWrapConn returns a wrapConn keyed by `key` and oriented for the
// given side. Client sets the direction-bit (MSB of sessionID[0] and
// ssrc[0]) to 0; server sets it to 1. RTP seq, timestamp, SSRC and the
// nonce counter all start at random values so a passive observer
// cannot derive total packet count from the first packet of a session.
func newWrapConn(key []byte, isServer bool) (*wrapConn, error) {
	if len(key) != wrapKeyLen {
		return nil, fmt.Errorf("wrap: key must be %d bytes (got %d)", wrapKeyLen, len(key))
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, fmt.Errorf("wrap: aead init: %w", err)
	}
	w := &wrapConn{aead: aead}

	// One rand.Read for sessionID + SSRC + seq + ts (14 bytes used out
	// of 16 — keeps the syscall count down vs four separate Reads).
	var rnd [16]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return nil, fmt.Errorf("wrap: rand init: %w", err)
	}
	copy(w.sessionID[:], rnd[0:4])
	copy(w.ssrc[:], rnd[4:8])
	if isServer {
		w.sessionID[0] |= 0x80
		w.ssrc[0] |= 0x80
	} else {
		w.sessionID[0] &^= 0x80
		w.ssrc[0] &^= 0x80
	}
	w.seq.Store(uint32(binary.BigEndian.Uint16(rnd[8:10])))
	w.timestamp.Store(binary.BigEndian.Uint32(rnd[10:14]))

	// Separate Read for the 8-byte counter (different domain, lifetime).
	var cb [8]byte
	if _, err := rand.Read(cb[:]); err != nil {
		return nil, fmt.Errorf("wrap: counter rand: %w", err)
	}
	w.counter.Store(binary.BigEndian.Uint64(cb[:]))
	return w, nil
}

// wrapMaxWire is the maximum number of wire bytes for a given payload.
// Use to size destination buffers before Seal.
func wrapMaxWire(payloadLen int) int {
	return wrapOverhead + payloadLen
}

// wrapInto serialises one packet into `dst` in place. Returns the
// number of bytes written (always wrapOverhead+len(payload) on success).
// `dst` must be at least wrapMaxWire(len(payload)) bytes long.
//
// Callers that already own a per-conn TX buffer can keep reusing it
// across calls; wrapInto only writes the prefix bytes plus the AEAD
// output and does not retain a reference to `dst` after returning.
func (w *wrapConn) wrapInto(dst, payload []byte) (int, error) {
	wireLen := wrapOverhead + len(payload)
	if len(dst) < wireLen {
		return 0, errors.New("wrap: dst buffer too small")
	}

	// RTP header.
	dst[0] = wrapRTPVersion
	dst[1] = wrapRTPPT
	// seq.Add returns the new value; we want the pre-increment as the
	// header field. Subtracting 1 gives us a unique per-call value while
	// keeping the atomic ordering simple.
	seq := uint16(w.seq.Add(1) - 1)
	binary.BigEndian.PutUint16(dst[2:4], seq)
	ts := w.timestamp.Add(wrapTSStep) - wrapTSStep
	binary.BigEndian.PutUint32(dst[4:8], ts)
	copy(dst[8:12], w.ssrc[:])

	// Explicit nonce = sessionID || counter.
	noncePos := wrapRTPHdrLen
	copy(dst[noncePos:noncePos+4], w.sessionID[:])
	ctr := w.counter.Add(1) - 1
	binary.BigEndian.PutUint64(dst[noncePos+4:noncePos+wrapNonceLen], ctr)

	// AEAD seal in place. nonce + aad slices alias dst so the AEAD
	// implementation can read them without an extra copy.
	nonce := dst[noncePos : noncePos+wrapNonceLen]
	aad := dst[:wrapHeaderLen]
	ctPos := wrapHeaderLen
	copy(dst[ctPos:], payload)
	// Seal(dst[ctPos:ctPos], ...) appends to a zero-length slice rooted
	// at ctPos, which writes the ciphertext+tag in place over the
	// plaintext copy we just made + the 16 trailing bytes.
	w.aead.Seal(dst[ctPos:ctPos], nonce, dst[ctPos:ctPos+len(payload)], aad)

	return wireLen, nil
}

// unwrapPacket recovers the plaintext from a wire packet. Writes the
// plaintext into `dst` and returns its length on success. `dst` must be
// large enough for (len(wire) - wrapOverhead) bytes.
//
// Returns an error on AEAD failure (wrong key on either side, replayed
// nonce reused with different plaintext, tampered RTP header / nonce /
// ciphertext / tag). Callers should drop and continue rather than tear
// down the session on a per-packet AEAD failure — VK relays occasionally
// inject probe packets and our own ports may receive stray traffic.
func (w *wrapConn) unwrapPacket(wire, dst []byte) (int, error) {
	if len(wire) < wrapOverhead {
		return 0, errors.New("wrap: packet too short")
	}
	nonce := wire[wrapRTPHdrLen : wrapRTPHdrLen+wrapNonceLen]
	aad := wire[:wrapHeaderLen]
	ct := wire[wrapHeaderLen:]

	// Open with dst=ct[:0] would overwrite the wire buffer in place; to
	// preserve the wire slice (caller may want to log/inspect after a
	// failure) we allocate via Open's append semantics on a nil base,
	// then copy into the caller-owned dst. The temporary slice is small
	// enough (≤ MTU) to stay in the per-goroutine stack frame typically.
	plain, err := w.aead.Open(nil, nonce, ct, aad)
	if err != nil {
		return 0, fmt.Errorf("wrap: AEAD open: %w", err)
	}
	if len(plain) > len(dst) {
		return 0, errors.New("wrap: dst buffer too small")
	}
	copy(dst[:len(plain)], plain)
	return len(plain), nil
}
