package proxy

import (
	"context"
	"errors"
	"net"
	"testing"
)

func TestReceivePacketUntilPrefersClosedDone(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := &Proxy{ctx: ctx, recvCh: make(chan []byte, 1)}
	p.recvCh <- []byte{1, 2, 3}
	done := make(chan struct{})
	close(done)

	for i := 0; i < 100; i++ {
		if n, err := p.ReceivePacketUntil(done, make([]byte, 8)); n != 0 || !errors.Is(err, net.ErrClosed) {
			t.Fatalf("closed receive %d = (%d, %v), want (0, net.ErrClosed)", i, n, err)
		}
	}
	if got := len(p.recvCh); got != 1 {
		t.Fatalf("closed receiver consumed queued data: queue length = %d", got)
	}
}
