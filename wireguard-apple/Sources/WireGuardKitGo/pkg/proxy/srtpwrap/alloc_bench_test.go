package srtpwrap

import (
	"context"
	"errors"
	"net"
	"os"
	"testing"
	"time"
)

// alloc_bench_test.go — Mac-side allocation benchmark for the SRTP transport.
//
// Why this exists: the 2026-05-29 build-145 plain-SRTP speedtest reproduced the
// silent jetsam and FALSIFIED the rtpCh-bloat hypothesis (rtpch-peak ≤53/4096,
// recvch 0/256). The real signal was a GC death-spiral (~55 GC/s) driven by
// per-packet allocation on the SRTP receive path: heap grew to ~310k live
// objects / 33 MB under speedtest (~3× the WRAP path) → rss → 50 MB jetsam.
//
// Those allocations are pure Go (pion/rtp, pion/srtp, our copies, and the proxy
// recv goroutine's per-Read SetReadDeadline) and reproduce identically off
// device — so we localize them here on the Mac with -benchmem + pprof instead
// of the slow deploy→speedtest→sysdiagnose loop. The iOS 50 MB ceiling is
// irrelevant: we measure the allocation RATE (allocs/op), which is what feeds
// the spiral; the ceiling is just where the rate eventually kills us.
//
// Run:
//   go test ./pkg/proxy/srtpwrap -run '^$' -bench . -benchmem -benchtime 2s
//   go test ./pkg/proxy/srtpwrap -run '^$' -bench 'ClientReceive$' -benchmem \
//       -memprofile /tmp/srtp_mem.out -benchtime 2s
//   go tool pprof -alloc_objects -top -nodecount=20 /tmp/srtp_mem.out  # where allocs happen
//   go tool pprof -inuse_objects -top -nodecount=20 /tmp/srtp_mem.out  # what stays live (retention)
//
// What the deltas mean:
//   - allocs/op on ClientReceive ≫ a few  → per-packet churn; at production
//     rates (allocs/op × pps × NumConns) this is the GC spiral.
//   - allocs/op(ClientReceive) − allocs/op(ClientReceiveNoDeadline) = the cost
//     of the recv goroutine's per-Read SetReadDeadline. setDl (srtp.go) does
//     make(chan struct{}) + time.AfterFunc(30s) per call, and each AfterFunc
//     timer stays pending in the runtime timer heap for the full 30s → a prime
//     suspect for BOTH the churn and the 310k-object retention plateau.

const benchPayloadLen = 1200 // representative WG record carried over the tunnel

// newBenchPair sets up a real DTLS+SRTP session over loopback UDP (no TURN, no
// device) and returns the client conn + the accepted server conn. The handshake
// runs once, before the caller's b.ResetTimer().
func newBenchPair(tb testing.TB) (client, server net.Conn, cleanup func()) {
	tb.Helper()
	srv, err := Listen(&net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		tb.Fatalf("srtpwrap.Listen: %v", err)
	}
	uc, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		_ = srv.Close()
		tb.Fatalf("client udp listen: %v", err)
	}

	type accRes struct {
		c   net.Conn
		err error
	}
	accCh := make(chan accRes, 1)
	go func() {
		c, aerr := srv.Accept(context.Background())
		accCh <- accRes{c, aerr}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), HandshakeTimeout)
	defer cancel()
	client, err = Client(ctx, uc, srv.Addr(), nil)
	if err != nil {
		_ = uc.Close()
		_ = srv.Close()
		tb.Fatalf("srtpwrap.Client handshake: %v", err)
	}
	ar := <-accCh
	if ar.err != nil {
		_ = client.Close()
		_ = uc.Close()
		_ = srv.Close()
		tb.Fatalf("srtpwrap.Server.Accept: %v", ar.err)
	}
	server = ar.c

	cleanup = func() {
		_ = client.Close()
		_ = server.Close()
		_ = srv.Close()
		_ = uc.Close()
	}
	return client, server, cleanup
}

// BenchmarkSRTPWrite measures the encode/send path: rtp.Packet build + MarshalTo
// + EncryptRTP + underlay.WriteTo. The server demux drains its socket in the
// background (its rtpCh fills and drops), so no server-side decode runs.
func BenchmarkSRTPWrite(b *testing.B) {
	client, _, cleanup := newBenchPair(b)
	defer cleanup()

	payload := make([]byte, benchPayloadLen)
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := client.Write(payload); err != nil {
			b.Fatalf("client.Write: %v", err)
		}
	}
}

// BenchmarkSRTPClientReceive measures the full client receive path EXACTLY as
// production drives it (proxy.go runSRTPSession recv goroutine): re-arm a 30s
// read deadline before every Read, then Read (demux hand-off → DecryptRTP →
// rtp.Header.Unmarshal → copy). Lock-step (one server Write per client Read) so
// loopback UDP can't overflow/drop. The server.Write allocs land on the encode
// call sites in pprof, distinct from the decode sites we care about.
func BenchmarkSRTPClientReceive(b *testing.B) {
	client, server, cleanup := newBenchPair(b)
	defer cleanup()

	payload := make([]byte, benchPayloadLen)
	buf := make([]byte, 2048)
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := server.Write(payload); err != nil {
			b.Fatalf("server.Write: %v", err)
		}
		// Mirrors proxy.go recv goroutine: per-Read 30s deadline re-arm.
		if err := client.SetReadDeadline(time.Now().Add(30 * time.Second)); err != nil {
			b.Fatalf("client.SetReadDeadline: %v", err)
		}
		if _, err := client.Read(buf); err != nil {
			b.Fatalf("client.Read: %v", err)
		}
	}
}

// BenchmarkSRTPClientReceiveNoDeadline is the same receive path WITHOUT the
// per-Read SetReadDeadline. allocs/op(ClientReceive) − allocs/op(this) isolates
// the cost of the recv goroutine's per-packet deadline re-arm.
func BenchmarkSRTPClientReceiveNoDeadline(b *testing.B) {
	client, server, cleanup := newBenchPair(b)
	defer cleanup()

	payload := make([]byte, benchPayloadLen)
	buf := make([]byte, 2048)
	// One long deadline armed BEFORE the timed loop (not per-Read), so a rare
	// loopback drop fails the bench instead of hanging, without adding per-op
	// deadline-arm allocs to the measurement.
	_ = client.SetReadDeadline(time.Now().Add(10 * time.Minute))
	b.SetBytes(int64(len(payload)))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := server.Write(payload); err != nil {
			b.Fatalf("server.Write: %v", err)
		}
		if _, err := client.Read(buf); err != nil {
			b.Fatalf("client.Read: %v", err)
		}
	}
}

// TestWrappedConnReadDeadline guards the build-146 reusable-timer setDl rewrite:
// a deadline must still fire (timeout), re-arming after a fired deadline must
// work (fresh dlCh + Reset), and a normal read after prior timeouts must still
// deliver data.
func TestWrappedConnReadDeadline(t *testing.T) {
	client, server, cleanup := newBenchPair(t)
	defer cleanup()
	buf := make([]byte, 2048)

	// 1) Short deadline, no incoming data → timeout at ~60ms.
	if err := client.SetReadDeadline(time.Now().Add(60 * time.Millisecond)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	start := time.Now()
	if _, err := client.Read(buf); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("expected deadline-exceeded, got %v", err)
	}
	if d := time.Since(start); d < 40*time.Millisecond || d > 2*time.Second {
		t.Fatalf("timeout fired after %v, expected ~60ms", d)
	}

	// 2) Re-arm after a fired deadline must work (fresh dlCh + timer Reset).
	if err := client.SetReadDeadline(time.Now().Add(60 * time.Millisecond)); err != nil {
		t.Fatalf("SetReadDeadline re-arm: %v", err)
	}
	if _, err := client.Read(buf); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("expected deadline-exceeded on re-arm, got %v", err)
	}

	// 3) After timeouts, a normal read with a future deadline still delivers.
	if err := client.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("SetReadDeadline future: %v", err)
	}
	payload := make([]byte, benchPayloadLen)
	if _, err := server.Write(payload); err != nil {
		t.Fatalf("server.Write: %v", err)
	}
	n, err := client.Read(buf)
	if err != nil {
		t.Fatalf("client.Read after timeouts: %v", err)
	}
	if n != benchPayloadLen {
		t.Fatalf("read %d bytes, want %d", n, benchPayloadLen)
	}
}
