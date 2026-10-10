package turnbind

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-apple/pkg/proxy"
	"golang.zx2c4.com/wireguard/conn"
)

func TestCloseWakesReceiver(t *testing.T) {
	p := proxy.NewProxy(proxy.Config{})
	defer p.Stop()
	b := NewTURNBind(p)
	receivers, _, err := b.open(0)
	if err != nil {
		t.Fatal(err)
	}

	result := make(chan error, 1)
	go func() {
		_, err := receivers[0]([][]byte{make([]byte, 64)}, make([]int, 1), make([]conn.Endpoint, 1))
		result <- err
	}()
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	if err := b.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}

	select {
	case err := <-result:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("receiver error = %v, want net.ErrClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("receiver did not wake after Close")
	}
}
