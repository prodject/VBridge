// Package srtpwrap provides a thin SRTP-over-DTLS adapter used by the
// turn_srtp_test diagnostic tools. It exposes two entry points:
//
//   - Client(ctx, underlay, remote) -> net.Conn that performs the DTLS
//     handshake on top of an existing PacketConn (e.g. a TURN-relayed
//     conn returned by pion/turn) and returns a wrapper that frames
//     every Write call as one RTP/SRTP packet (PayloadType 100 — used
//     to imitate VP8 WebRTC video) and decrypts incoming SRTP packets
//     on Read.
//
//   - Listen(ctx, addr) -> *Server, then srv.Accept() to yield one
//     net.Conn per new source address. Server demultiplexes incoming
//     UDP packets by first-byte range (DTLS 20..63, RTP 128..191) so
//     that one listening socket can handle many simultaneous clients.
//
// Independent implementation written from the relevant RFCs (RFC 3550
// for RTP framing, RFC 3711 for SRTP, RFC 5764 for DTLS-SRTP key
// derivation) and the public APIs of pion/dtls + pion/rtp + pion/srtp.
// No code copied from any GPL-licensed third party.
package srtpwrap

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/rtp"
	"github.com/pion/srtp/v3"
)

// pktPool recycles []byte slices used to hand off freshly-read packets
// from the demux goroutine to wrappedConn.Read (via rtpCh / dtlsCh).
// Before this pool, every packet allocated a fresh []byte: at ~2400
// packets/sec under a 25 Mbps SRTP-tunnel speedtest, that's ~5 MB/sec
// of garbage generated just from this hand-off plus another 5 MB/sec
// from the symmetric hand-off in runSRTPSession.recv (proxy.go:4157).
// The resulting heap-alloc spikes (28 MB observed 2026-05-24 build 132
// at 18:02:16) pushed phys_footprint past the iOS NE per-process limit
// and triggered JETSAM_REASON_MEMORY_PERPROCESSLIMIT (RC=7 NS=1).
//
// 2048-byte capacity covers max expected wire-format packet (~1280 WG
// MTU + ~22 bytes RTP/SRTP framing + ChannelData overhead + slack).
// Slices are returned with full cap restored so Get always sees a
// 2048-byte backing array regardless of last Get caller's reslice.
//
// Build 133.
var pktPool = sync.Pool{
	New: func() interface{} {
		return make([]byte, 2048)
	},
}

// pktPoolGet returns a slice of length n backed by a pool buffer of
// cap 2048 (or larger via runtime growth from prior Put callers that
// returned an enlarged buffer). Caller is responsible for pktPoolPut
// once the slice is no longer needed.
func pktPoolGet(n int) []byte {
	b := pktPool.Get().([]byte)
	if cap(b) < n {
		// Rare: a previous caller stored a smaller buffer somehow.
		// Allocate one big enough.
		b = make([]byte, n)
	}
	return b[:n]
}

// pktPoolPut returns a slice to the pool. The slice is restored to its
// full backing-array length before storage so subsequent Get calls
// always see a fixed-capacity buffer.
func pktPoolPut(b []byte) {
	if b == nil {
		return
	}
	pktPool.Put(b[:cap(b)])
}


const (
	// PayloadType for the synthetic RTP wrapper. 100 is the dynamic-range
	// value commonly assigned to VP8 in WebRTC SDP offers, so receivers
	// that classify by payload type see "looks like VP8 video".
	PayloadType uint8 = 100

	// MTU caps DTLS record + RTP+SRTP payload at a size that still fits
	// inside a single IP/UDP datagram after TURN ChannelData wrapping
	// (4 bytes) and IPv4/UDP headers (~28 bytes).
	MTU = 1200

	// HandshakeTimeout bounds a single DTLS handshake attempt.
	HandshakeTimeout = 10 * time.Second
)

// IsDTLS reports whether b looks like the first byte of a DTLS record
// (ContentType range 20..63 per RFC 9147 + RFC 5764 demux table).
func IsDTLS(b byte) bool { return b >= 20 && b <= 63 }

// IsRTP reports whether b looks like the first byte of an RTP/SRTP
// packet (version-2 in top 2 bits → 128..191).
func IsRTP(b byte) bool { return b >= 128 && b <= 191 }

// ─── Client ───────────────────────────────────────────────────────────────

// Client performs a DTLS-SRTP handshake on top of an existing
// PacketConn talking to remote, and returns a net.Conn whose Read/Write
// methods carry user payload framed as RTP and encrypted as SRTP.
//
// underlay can be any net.PacketConn — including a TURN-relayed conn
// returned by pion/turn's client.Allocate().
func Client(ctx context.Context, underlay net.PacketConn, remote net.Addr, rxDepthGauge *atomic.Int64) (net.Conn, error) {
	if underlay == nil {
		return nil, errors.New("srtpwrap: underlay is nil")
	}
	if remote == nil {
		return nil, errors.New("srtpwrap: remote is nil")
	}

	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		return nil, fmt.Errorf("srtpwrap: cert gen: %w", err)
	}

	dtlsCh := make(chan []byte, 64)
	rtpCh := make(chan []byte, 4096)
	// Decouple demux's ctx from caller's ctx. Production callers commonly
	// wrap their parent ctx with a short handshake-timeout context (10s)
	// and `cancel()` it the instant srtpwrap.Client returns — see
	// pkg/proxy/proxy.go setupSRTPSession. If demuxCtx inherited from
	// that ctx, the demux goroutine would die the moment handshake
	// completed, before wrappedConn.Read could pull any post-handshake
	// SRTP packet off rtpCh. The bug looked like "iPhone never receives
	// server's response" but was actually "demux silently exited 1ms
	// after handshake done, RTP packets dropped on the floor".
	//
	// Demux must outlive the handshake. Its lifetime is bound to
	// wrappedConn.Close (which calls stopDemux=demuxCancel below) plus
	// the explicit demuxCancel() calls on this function's error paths.
	// Using context.Background() as the demux's parent makes that
	// boundary explicit — only Close ends the demux.
	demuxCtx, demuxCancel := context.WithCancel(context.Background())
	go runDemuxFromPacketConn(demuxCtx, underlay, dtlsCh, rtpCh, rxDepthGauge)

	adapter := &packetConnAdapter{
		raw:    underlay,
		ch:     dtlsCh,
		addr:   remote,
		closed: make(chan struct{}),
	}

	// pion/dtls v3.x Client()/Server() only set up the Conn — the
	// handshake itself runs lazily on first Read/Write OR via an
	// explicit HandshakeContext call. Call it explicitly so we
	// control timeout + so ConnectionState is populated when we
	// extract SRTP keys below.
	dconn, err := dtls.Client(adapter, remote, &dtls.Config{
		Certificates:         []tls.Certificate{cert},
		ExtendedMasterSecret: dtls.RequireExtendedMasterSecret,
		SRTPProtectionProfiles: []dtls.SRTPProtectionProfile{
			dtls.SRTP_AES128_CM_HMAC_SHA1_80,
		},
		InsecureSkipVerify: true,
	})
	if err != nil {
		_ = adapter.Close()
		demuxCancel()
		return nil, fmt.Errorf("srtpwrap: dtls client init: %w", err)
	}
	hsCtx, hsCancel := context.WithTimeout(ctx, HandshakeTimeout)
	hsErr := dconn.HandshakeContext(hsCtx)
	hsCancel()
	if hsErr != nil {
		_ = dconn.Close()
		_ = adapter.Close()
		demuxCancel()
		return nil, fmt.Errorf("srtpwrap: dtls client handshake: %w", hsErr)
	}

	wrap, err := newWrappedConn(underlay, remote, dconn, rtpCh, true /*isClient*/, demuxCancel)
	if err != nil {
		_ = dconn.Close()
		_ = adapter.Close()
		demuxCancel()
		return nil, fmt.Errorf("srtpwrap: post-handshake setup: %w", err)
	}
	return wrap, nil
}

// ─── Server ───────────────────────────────────────────────────────────────

// Server listens on a UDP socket and yields one wrapped conn per new
// source address.
type Server struct {
	raw    *net.UDPConn
	out    chan net.Conn
	errCh  chan error
	closed chan struct{}

	cert tls.Certificate

	mu       sync.Mutex
	sessions map[string]*serverSession
}

type serverSession struct {
	dtlsCh chan []byte
	rtpCh  chan []byte
}

// Listen opens the UDP socket and starts the demultiplexer goroutine.
func Listen(addr *net.UDPAddr) (*Server, error) {
	raw, err := net.ListenUDP("udp", addr)
	if err != nil {
		return nil, fmt.Errorf("srtpwrap: listen %s: %w", addr, err)
	}
	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("srtpwrap: cert gen: %w", err)
	}
	s := &Server{
		raw:      raw,
		out:      make(chan net.Conn, 16),
		errCh:    make(chan error, 1),
		closed:   make(chan struct{}),
		cert:     cert,
		sessions: make(map[string]*serverSession),
	}
	go s.demux()
	return s, nil
}

// Addr returns the local UDP address.
func (s *Server) Addr() net.Addr { return s.raw.LocalAddr() }

// Accept blocks until a new session has finished its DTLS handshake.
func (s *Server) Accept(ctx context.Context) (net.Conn, error) {
	select {
	case c, ok := <-s.out:
		if !ok {
			return nil, io.EOF
		}
		return c, nil
	case err := <-s.errCh:
		return nil, err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.closed:
		return nil, net.ErrClosed
	}
}

// Close stops the demux loop and closes the UDP socket.
func (s *Server) Close() error {
	select {
	case <-s.closed:
		return nil
	default:
		close(s.closed)
	}
	return s.raw.Close()
}

func (s *Server) demux() {
	buf := make([]byte, 2048)
	for {
		n, src, err := s.raw.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-s.closed:
				return
			default:
				// transient — try to keep going
				continue
			}
		}
		if n == 0 {
			continue
		}
		key := src.String()
		s.mu.Lock()
		sess, ok := s.sessions[key]
		if !ok {
			sess = &serverSession{
				dtlsCh: make(chan []byte, 64),
				rtpCh:  make(chan []byte, 4096),
			}
			s.sessions[key] = sess
			s.mu.Unlock()
			go s.handshakeAndPublish(src, sess)
		} else {
			s.mu.Unlock()
		}
		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		switch {
		case IsDTLS(pkt[0]):
			select {
			case sess.dtlsCh <- pkt:
			default:
			}
		case IsRTP(pkt[0]):
			select {
			case sess.rtpCh <- pkt:
			default:
			}
		}
	}
}

func (s *Server) handshakeAndPublish(src net.Addr, sess *serverSession) {
	adapter := &packetConnAdapter{
		raw:    s.raw,
		ch:     sess.dtlsCh,
		addr:   src,
		closed: make(chan struct{}),
	}
	dconn, err := dtls.Server(adapter, src, &dtls.Config{
		Certificates:         []tls.Certificate{s.cert},
		ExtendedMasterSecret: dtls.RequireExtendedMasterSecret,
		SRTPProtectionProfiles: []dtls.SRTPProtectionProfile{
			dtls.SRTP_AES128_CM_HMAC_SHA1_80,
		},
	})
	if err != nil {
		_ = adapter.Close()
		s.mu.Lock()
		delete(s.sessions, src.String())
		s.mu.Unlock()
		return
	}
	// Explicit handshake — pion/dtls Server() returns before
	// handshake runs (handshake is lazy on first Read/Write).
	hsCtx, hsCancel := context.WithTimeout(context.Background(), HandshakeTimeout)
	hsErr := dconn.HandshakeContext(hsCtx)
	hsCancel()
	if hsErr != nil {
		_ = dconn.Close()
		_ = adapter.Close()
		s.mu.Lock()
		delete(s.sessions, src.String())
		s.mu.Unlock()
		return
	}
	wrap, err := newWrappedConn(s.raw, src, dconn, sess.rtpCh, false /*isClient*/, nil)
	if err != nil {
		_ = dconn.Close()
		_ = adapter.Close()
		s.mu.Lock()
		delete(s.sessions, src.String())
		s.mu.Unlock()
		return
	}
	wrap.onClose = func() {
		s.mu.Lock()
		delete(s.sessions, src.String())
		s.mu.Unlock()
	}
	select {
	case s.out <- wrap:
	case <-s.closed:
		_ = wrap.Close()
	}
}

// ─── packetConnAdapter ────────────────────────────────────────────────────

// packetConnAdapter exposes a channel of demuxed DTLS bytes as a
// net.PacketConn so pion/dtls can read handshake records from it
// while RTP/SRTP traffic on the same UDP socket is routed elsewhere.
// Writes pass through unchanged to the underlying raw conn.
type packetConnAdapter struct {
	raw       net.PacketConn
	ch        chan []byte
	addr      net.Addr
	closed    chan struct{}
	closeOnce sync.Once

	mu    sync.Mutex
	dlExp time.Time
	dlCh  chan struct{}
}

func (a *packetConnAdapter) ReadFrom(b []byte) (int, net.Addr, error) {
	for {
		dl := a.deadlineCh()
		select {
		case pkt, ok := <-a.ch:
			if !ok {
				return 0, nil, net.ErrClosed
			}
			return copy(b, pkt), a.addr, nil
		case <-a.closed:
			return 0, nil, net.ErrClosed
		case <-dl:
			if a.deadlineExpired() {
				return 0, nil, os.ErrDeadlineExceeded
			}
		}
	}
}

func (a *packetConnAdapter) WriteTo(b []byte, _ net.Addr) (int, error) {
	return a.raw.WriteTo(b, a.addr)
}

func (a *packetConnAdapter) LocalAddr() net.Addr { return a.raw.LocalAddr() }

func (a *packetConnAdapter) SetDeadline(t time.Time) error {
	a.setDl(t)
	return nil
}

func (a *packetConnAdapter) SetReadDeadline(t time.Time) error {
	a.setDl(t)
	return nil
}

func (a *packetConnAdapter) SetWriteDeadline(t time.Time) error { return nil }

func (a *packetConnAdapter) Close() error {
	a.closeOnce.Do(func() { close(a.closed) })
	return nil
}

func (a *packetConnAdapter) deadlineCh() <-chan struct{} {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.dlCh == nil {
		a.dlCh = make(chan struct{})
	}
	return a.dlCh
}

func (a *packetConnAdapter) deadlineExpired() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return !a.dlExp.IsZero() && !time.Now().Before(a.dlExp)
}

func (a *packetConnAdapter) setDl(t time.Time) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.dlCh != nil {
		select {
		case <-a.dlCh:
		default:
			close(a.dlCh)
		}
	}
	a.dlCh = make(chan struct{})
	a.dlExp = t
	if !t.IsZero() {
		dur := time.Until(t)
		if dur <= 0 {
			close(a.dlCh)
			return
		}
		ch := a.dlCh
		// See wrappedConn.setDl for the long explanation of the race the
		// CAS-style check below avoids. Same bug pattern: a setDl chain
		// closes earlier dlCh inline, then the orphan timer for that
		// earlier ch eventually fires and double-closes.
		time.AfterFunc(dur, func() {
			a.mu.Lock()
			defer a.mu.Unlock()
			if a.dlCh != ch {
				return
			}
			select {
			case <-ch:
			default:
				close(ch)
			}
		})
	}
}

// ─── wrappedConn — the SRTP-encrypted net.Conn ────────────────────────────

type wrappedConn struct {
	underlay net.PacketConn
	remote   net.Addr
	dtlsConn *dtls.Conn
	encCtx   *srtp.Context
	decCtx   *srtp.Context

	rxCh chan []byte
	ssrc uint32

	mu  sync.Mutex
	seq uint16
	ts  uint32

	closeOnce sync.Once
	closed    chan struct{}
	onClose   func()

	dlMu     sync.Mutex
	dlExp    time.Time
	dlCh     chan struct{}
	dlClosed bool        // dlCh currently closed? recreate before next arm (build 146)
	dlTimer  *time.Timer // single reusable deadline timer; Reset, not AfterFunc-per-call (build 146)

	// stopDemux is set on the client side so Close() unwinds the
	// background packet demux goroutine.
	stopDemux func()

	// Per-side reusable scratch buffers. rxDecBuf is owned by the Read
	// goroutine, txMarshalBuf + txEncBuf by the Write goroutine. No
	// mutex needed because runSRTPSession dedicates one goroutine to
	// Read and one to Write per wrappedConn — they don't race against
	// each other on these fields. Buffers grow on demand to the largest
	// packet ever seen on this conn, then stay sized for subsequent
	// reuse so the per-packet path becomes alloc-free on the steady
	// state. Cuts ~4 allocations per packet (DecryptRTP plaintext
	// output, RTP marshal output, SRTP encrypt output, plus the small
	// header struct internal allocs pion sometimes does).
	rxDecBuf     []byte
	txMarshalBuf []byte
	txEncBuf     []byte
}

func newWrappedConn(underlay net.PacketConn, remote net.Addr, dconn *dtls.Conn,
	rxCh chan []byte, isClient bool, stopDemux func(),
) (*wrappedConn, error) {
	state, ok := dconn.ConnectionState()
	if !ok {
		return nil, errors.New("srtpwrap: dtls connection state unavailable")
	}

	cfg := &srtp.Config{Profile: srtp.ProtectionProfileAes128CmHmacSha1_80}
	if err := cfg.ExtractSessionKeysFromDTLS(&state, isClient); err != nil {
		return nil, fmt.Errorf("srtpwrap: extract session keys: %w", err)
	}

	encCtx, err := srtp.CreateContext(cfg.Keys.LocalMasterKey, cfg.Keys.LocalMasterSalt, cfg.Profile)
	if err != nil {
		return nil, fmt.Errorf("srtpwrap: enc context: %w", err)
	}
	decCtx, err := srtp.CreateContext(cfg.Keys.RemoteMasterKey, cfg.Keys.RemoteMasterSalt, cfg.Profile)
	if err != nil {
		return nil, fmt.Errorf("srtpwrap: dec context: %w", err)
	}

	var ssrcB [4]byte
	if _, err := rand.Read(ssrcB[:]); err != nil {
		return nil, fmt.Errorf("srtpwrap: ssrc random: %w", err)
	}

	return &wrappedConn{
		underlay:  underlay,
		remote:    remote,
		dtlsConn:  dconn,
		encCtx:    encCtx,
		decCtx:    decCtx,
		rxCh:      rxCh,
		ssrc:      binary.BigEndian.Uint32(ssrcB[:]),
		closed:    make(chan struct{}),
		stopDemux: stopDemux,
	}, nil
}

func (c *wrappedConn) Read(b []byte) (int, error) {
	for {
		dl := c.deadlineCh()
		select {
		case pkt, ok := <-c.rxCh:
			if !ok {
				return 0, net.ErrClosed
			}
			// Reuse c.rxDecBuf for plaintext output. DecryptRTP appends
			// to the provided dst; passing an empty-but-cap'd slice of
			// our owned buffer keeps the decryption alloc-free once
			// the buffer has grown to the largest packet seen.
			if cap(c.rxDecBuf) < len(pkt) {
				c.rxDecBuf = make([]byte, 0, len(pkt)+64)
			}
			plain, err := c.decCtx.DecryptRTP(c.rxDecBuf[:0], pkt, nil)
			// pkt's encrypted payload was decrypted into c.rxDecBuf — pkt
			// itself is no longer needed regardless of err. Return to pool
			// before any return/continue (build 133).
			pktPoolPut(pkt)
			if err != nil {
				// SRTP decrypt failures should be rare in steady state
				// (would indicate key mismatch or replay-window issue).
				// Logged as a warning so it remains visible without
				// the per-packet noise that would result from logging
				// every successful decrypt.
				log.Printf("srtpwrap: wrappedConn.Read[%s]: DecryptRTP failed: %v (pkt %d bytes)", c.remote, err, len(pkt))
				continue
			}
			// plain shares backing with c.rxDecBuf; remember it grew so
			// the next iteration sees the larger capacity.
			c.rxDecBuf = plain[:0]
			var hdr rtp.Header
			n, err := hdr.Unmarshal(plain)
			if err != nil {
				log.Printf("srtpwrap: wrappedConn.Read[%s]: rtp.Unmarshal failed: %v (plain %d bytes)", c.remote, err, len(plain))
				continue
			}
			return copy(b, plain[n:]), nil
		case <-c.closed:
			return 0, net.ErrClosed
		case <-dl:
			if c.deadlineExpired() {
				return 0, os.ErrDeadlineExceeded
			}
		}
	}
}

func (c *wrappedConn) Write(b []byte) (int, error) {
	// Lock held for the entire method, not just the seq/ts increment.
	// runSRTPSession spawns TWO goroutines that both call srtpConn.Write
	// on the same wrappedConn: the probe sender (proxy.go:3901+, writes
	// 12-byte ping packets on ticker and on every wake event) and the
	// send goroutine (proxy.go:4018+, writes WG payload from sendCh).
	// pion's srtp.Context.EncryptRTP is NOT safe for concurrent use —
	// its HMAC-SHA1 keeps internal state across Sum() calls, and two
	// concurrent EncryptRTP calls corrupt that state. Build 125 panicked
	// in production on 2026-05-21 22:22:38 with "panic: d.nx != 0" from
	// crypto/sha1.(*digest).checkSum, triggered when a wake event fired
	// active-probe-on-wake at the same instant WG data was flowing.
	// The per-conn scratch buffers (txMarshalBuf, txEncBuf) added in
	// build 123 are also unsafe under concurrent Write — releasing the
	// lock early would let one Write call overwrite another's MarshalTo
	// target. Hold the lock through to the underlying socket WriteTo.
	c.mu.Lock()
	defer c.mu.Unlock()

	seq := c.seq
	ts := c.ts
	c.seq++
	c.ts += uint32(len(b))

	pkt := rtp.Packet{
		Header: rtp.Header{
			Version:        2,
			PayloadType:    PayloadType,
			SequenceNumber: seq,
			Timestamp:      ts,
			SSRC:           c.ssrc,
		},
		Payload: b,
	}
	// Reuse c.txMarshalBuf — pkt.MarshalTo writes the serialized RTP
	// header+payload into the supplied buffer. By sizing the buffer
	// once to MarshalSize() we avoid the allocation that pkt.Marshal()
	// would do per call.
	needSize := pkt.MarshalSize()
	if cap(c.txMarshalBuf) < needSize {
		c.txMarshalBuf = make([]byte, needSize+64)
	}
	rawLen, err := pkt.MarshalTo(c.txMarshalBuf[:needSize])
	if err != nil {
		return 0, fmt.Errorf("rtp marshal: %w", err)
	}
	raw := c.txMarshalBuf[:rawLen]
	// Reuse c.txEncBuf for SRTP-encrypted output. EncryptRTP appends
	// to the provided dst (plaintext + 10-byte HMAC-SHA1-80 tag for
	// our profile), so sizing once to rawLen+16 keeps the encryption
	// alloc-free in steady state.
	encSize := rawLen + 16
	if cap(c.txEncBuf) < encSize {
		c.txEncBuf = make([]byte, 0, encSize+64)
	}
	enc, err := c.encCtx.EncryptRTP(c.txEncBuf[:0], raw, nil)
	if err != nil {
		return 0, fmt.Errorf("srtp encrypt: %w", err)
	}
	c.txEncBuf = enc[:0]
	if _, err := c.underlay.WriteTo(enc, c.remote); err != nil {
		return 0, err
	}
	return len(b), nil
}

func (c *wrappedConn) Close() error {
	var err error
	c.closeOnce.Do(func() {
		close(c.closed)
		if c.onClose != nil {
			c.onClose()
		}
		if c.dtlsConn != nil {
			err = c.dtlsConn.Close()
		}
		if c.stopDemux != nil {
			c.stopDemux()
		}
	})
	return err
}

func (c *wrappedConn) LocalAddr() net.Addr  { return c.underlay.LocalAddr() }
func (c *wrappedConn) RemoteAddr() net.Addr { return c.remote }

func (c *wrappedConn) SetDeadline(t time.Time) error {
	c.setDl(t)
	return nil
}
func (c *wrappedConn) SetReadDeadline(t time.Time) error {
	c.setDl(t)
	return nil
}
func (c *wrappedConn) SetWriteDeadline(_ time.Time) error { return nil }

func (c *wrappedConn) deadlineCh() <-chan struct{} {
	c.dlMu.Lock()
	defer c.dlMu.Unlock()
	if c.dlCh == nil {
		c.dlCh = make(chan struct{})
		c.dlClosed = false
	}
	return c.dlCh
}

func (c *wrappedConn) deadlineExpired() bool {
	c.dlMu.Lock()
	defer c.dlMu.Unlock()
	return !c.dlExp.IsZero() && !time.Now().Before(c.dlExp)
}

// setDl arms the read deadline. Build 146: a single reusable per-conn timer
// (time.Timer.Reset) replaces the previous make(chan)+time.AfterFunc-per-call
// design. The runSRTPSession recv goroutine re-arms the deadline before EVERY
// Read (proxy.go), so at speedtest packet rates the old design allocated a
// channel + a 30s-pending timer PER PACKET, and each pending timer's closure
// pinned its channel for the full 30s → ~310k live objects accumulated under
// load, the dominant driver of the GC death-spiral that pushed phys_footprint
// to the 50 MB iOS NE jetsam ceiling (confirmed 2026-05-29 via Mac pprof:
// setDl make(chan) + time.newTimer = 98.7% of inuse_objects). Reusing one timer
// makes steady-state re-arming allocation-free, and having only ONE timer makes
// the old "superseded timer double-closes" race structurally impossible.
func (c *wrappedConn) setDl(t time.Time) {
	c.dlMu.Lock()
	defer c.dlMu.Unlock()
	c.dlExp = t
	// Read selects on dlCh; it is only ever closed to signal expiry, then must
	// be replaced with a fresh open channel before the next arm. While the
	// deadline is repeatedly extended (the hot path), dlCh stays open and is
	// reused — zero allocation.
	if c.dlCh == nil || c.dlClosed {
		c.dlCh = make(chan struct{})
		c.dlClosed = false
	}
	if t.IsZero() {
		if c.dlTimer != nil {
			c.dlTimer.Stop()
		}
		return
	}
	dur := time.Until(t)
	if dur <= 0 {
		// Already past — signal immediately.
		close(c.dlCh)
		c.dlClosed = true
		if c.dlTimer != nil {
			c.dlTimer.Stop()
		}
		return
	}
	if c.dlTimer == nil {
		c.dlTimer = time.AfterFunc(dur, c.fireDeadline)
	} else {
		c.dlTimer.Reset(dur)
	}
}

// fireDeadline runs (on the runtime timer goroutine) when the reusable deadline
// timer expires. It closes dlCh to wake a blocked Read, but only if the deadline
// genuinely elapsed and was not pushed into the future by a concurrent setDl (in
// which case the single timer was already Reset and will fire again later).
// dlMu serialises this against setDl; the dlExp + dlClosed guards make a stale
// fire a no-op and prevent close-of-closed.
func (c *wrappedConn) fireDeadline() {
	c.dlMu.Lock()
	defer c.dlMu.Unlock()
	if c.dlExp.IsZero() || time.Now().Before(c.dlExp) {
		return // superseded by a later/cleared deadline since this timer armed
	}
	if c.dlCh != nil && !c.dlClosed {
		close(c.dlCh)
		c.dlClosed = true
	}
}

// ─── client-side demux from a single-peer PacketConn ──────────────────────

func runDemuxFromPacketConn(ctx context.Context, raw net.PacketConn, dtlsCh, rtpCh chan<- []byte, rxDepthGauge *atomic.Int64) {
	// Cancellation pattern: ReadFrom blocks until a packet actually
	// arrives. To unblock on ctx cancellation, AfterFunc sets the read
	// deadline to "now" — the next ReadFrom returns immediately with a
	// timeout error, the for-loop sees ctx.Err() != nil and exits.
	//
	// Why this matters on iOS: the previous version polled with a 500ms
	// SetReadDeadline at the top of every loop iteration. With 30 conns
	// idle that produced 60 forced wakeups/sec for the relayedConn read
	// loop. iOS NetworkExtension monitors per-process CPU wakeup rate
	// and terminates extensions that exceed its budget; build 117/118
	// hit that ceiling at ~38s into every session, manifesting as a
	// sudden NEVPNStatus → 1 with no graceful stopTunnel. Blocking
	// ReadFrom with AfterFunc-driven cancellation has zero idle wakeups
	// — the goroutine actually sleeps until a packet arrives or until
	// the conn is being torn down. Matches the pattern legacy
	// runDTLSSession uses on its relayConn read loop (proxy.go:2786),
	// which never had this issue.
	stop := context.AfterFunc(ctx, func() {
		_ = raw.SetReadDeadline(time.Now())
	})
	defer stop()

	buf := make([]byte, 2048)
	for {
		n, _, err := raw.ReadFrom(buf)
		if err != nil {
			// If ctx is done, AfterFunc fired SetReadDeadline(now) to
			// unblock us. Exit cleanly without logging.
			if ctx.Err() != nil {
				return
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// Spurious timeout (e.g. caller called SetReadDeadline
			// before us). Clear and retry.
			var ne net.Error
			if errors.Is(err, os.ErrDeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout()) {
				_ = raw.SetReadDeadline(time.Time{})
				continue
			}
			log.Printf("srtpwrap: client-demux: ReadFrom error: %v", err)
			continue
		}
		if n == 0 {
			continue
		}
		// pktPoolGet returns a pool-backed slice; pktPoolPut on
		// wrappedConn.Read consumer side returns it after decrypt.
		// Saves ~5 MB/s of GC churn under speedtest load (build 133).
		pkt := pktPoolGet(n)
		copy(pkt, buf[:n])
		switch {
		case IsDTLS(pkt[0]):
			select {
			case dtlsCh <- pkt:
			case <-ctx.Done():
				pktPoolPut(pkt)
				return
			}
		case IsRTP(pkt[0]):
			select {
			case rtpCh <- pkt:
				// Build 145 diagnostic: record per-interval peak rtpCh depth
				// here at the producer so the gauge captures the true
				// high-water mark even while the consumer (wrappedConn.Read →
				// runSRTPSession recv) is blocked on a full recvCh — the exact
				// backpressure case the rtpCh-bloat hypothesis targets. Single
				// writer per conn; CAS-max against the gauge shared across conns.
				if rxDepthGauge != nil {
					if d := int64(len(rtpCh)); d > 0 {
						for {
							old := rxDepthGauge.Load()
							if d <= old || rxDepthGauge.CompareAndSwap(old, d) {
								break
							}
						}
					}
				}
			case <-ctx.Done():
				pktPoolPut(pkt)
				return
			}
		default:
			// Not DTLS, not RTP — drop. Return slice to pool.
			pktPoolPut(pkt)
		}
	}
}

