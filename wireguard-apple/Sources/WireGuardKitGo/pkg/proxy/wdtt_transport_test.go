package proxy

import (
	"encoding/binary"
	"testing"
)

func TestSupportsWDTTUplink(t *testing.T) {
	config := "# WDTT_TRANSPORTS=other,uplink2\n[Interface]\nAddress=10.66.66.2/32"
	if !supportsWDTTUplink(config) {
		t.Fatal("uplink2 capability was not detected")
	}
	if supportsWDTTUplink("[Interface]\nAddress=10.66.66.2/32") {
		t.Fatal("legacy config unexpectedly enabled uplink2")
	}
}

func TestWDTTFrameAndAck(t *testing.T) {
	payload := []byte{4, 0, 0, 0, 1, 2, 3}
	frame := frameWDTT(nil, payload, wdttData, 17)
	if len(frame) != wdttFrameHeader+len(payload) || string(frame[:4]) != "WDU2" {
		t.Fatalf("invalid frame: %x", frame)
	}
	if frame[4] != wdttData || binary.BigEndian.Uint64(frame[8:16]) != 17 {
		t.Fatalf("invalid frame header: %x", frame[:16])
	}

	ack := make([]byte, 24)
	copy(ack, "WDA2")
	binary.BigEndian.PutUint64(ack[8:16], 18)
	binary.BigEndian.PutUint64(ack[16:24], 17)
	expected, received, ok := parseWDTTAck(ack)
	if !ok || expected != 18 || received != 17 {
		t.Fatalf("invalid parsed ack: expected=%d received=%d ok=%v", expected, received, ok)
	}
}

func TestWDTTUplinkMutesLossyPath(t *testing.T) {
	path := &wdttUplinkPath{adaptive: true}
	path.next = 80
	ack := make([]byte, 24)
	copy(ack, "WDA2")
	binary.BigEndian.PutUint64(ack[8:16], 80)
	binary.BigEndian.PutUint64(ack[16:24], 60)
	if !path.noteAck(ack) {
		t.Fatal("delivery acknowledgement was not consumed")
	}
	if path.usable() {
		t.Fatal("lossy path remained eligible")
	}
}
