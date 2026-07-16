package proxy

import (
	"net"
	"testing"

	"github.com/pion/turn/v5"
)

func TestAddrFamilyFor(t *testing.T) {
	tests := []struct {
		name string
		peer *net.UDPAddr
		want turn.RequestedAddressFamily
	}{
		{name: "nil defaults to IPv4", want: turn.RequestedAddressFamilyIPv4},
		{name: "IPv4", peer: &net.UDPAddr{IP: net.ParseIP("192.0.2.1")}, want: turn.RequestedAddressFamilyIPv4},
		{name: "IPv6", peer: &net.UDPAddr{IP: net.ParseIP("2001:db8::1")}, want: turn.RequestedAddressFamilyIPv6},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := addrFamilyFor(test.peer); got != test.want {
				t.Fatalf("addrFamilyFor(%v) = %v, want %v", test.peer, got, test.want)
			}
		})
	}
}
