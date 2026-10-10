package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

type csqttWriteTestConn struct {
	writeCount int
	writeErr   error
	deadline   time.Time
	cleared    bool
}

func (c *csqttWriteTestConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (c *csqttWriteTestConn) Close() error                     { return nil }
func (c *csqttWriteTestConn) LocalAddr() net.Addr              { return nil }
func (c *csqttWriteTestConn) RemoteAddr() net.Addr             { return nil }
func (c *csqttWriteTestConn) SetDeadline(time.Time) error      { return nil }
func (c *csqttWriteTestConn) SetReadDeadline(time.Time) error  { return nil }
func (c *csqttWriteTestConn) Write(payload []byte) (int, error) { return c.writeCount, c.writeErr }
func (c *csqttWriteTestConn) SetWriteDeadline(deadline time.Time) error {
	if deadline.IsZero() {
		c.cleared = true
	} else {
		c.deadline = deadline
	}
	return nil
}

func TestCSQTTWritePacketBoundsAndClearsDeadline(t *testing.T) {
	conn := &csqttWriteTestConn{writeCount: 3}
	worker := &csqttWorker{}
	started := time.Now()
	if err := worker.writePacket(conn, []byte("abc")); err != nil {
		t.Fatalf("writePacket: %v", err)
	}
	if conn.deadline.Before(started.Add(csqttWriteTimeout - 100*time.Millisecond)) {
		t.Fatalf("write deadline %s is earlier than expected", conn.deadline)
	}
	if !conn.cleared {
		t.Fatal("write deadline was not cleared")
	}
}

func TestCSQTTWritePacketPreservesWriteError(t *testing.T) {
	want := errors.New("relay unavailable")
	conn := &csqttWriteTestConn{writeErr: want}
	worker := &csqttWorker{}
	if err := worker.writePacket(conn, []byte("abc")); !errors.Is(err, want) {
		t.Fatalf("writePacket error = %v, want %v", err, want)
	}
}

func TestCSQTTWritePacketRejectsShortWrite(t *testing.T) {
	conn := &csqttWriteTestConn{writeCount: 2}
	worker := &csqttWorker{}
	if err := worker.writePacket(conn, []byte("abc")); !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("writePacket error = %v, want %v", err, io.ErrShortWrite)
	}
}

func TestCSQTTProvisionUsesWireRevisionThree(t *testing.T) {
	conn := &csqttProvisionTestConn{response: []byte("TUNCONF:10.66.67.2:1.1.1.1:0:stream-v2")}
	worker := &csqttWorker{
		id: 3,
		runtime: &csqttRuntime{
			localPort:   "9000",
			deviceID:    "device",
			password:    "password",
			generation:  7,
			salt:        "salt",
			workerCount: 18,
		},
	}
	if _, err := worker.requestProvision(conn); err != nil {
		t.Fatalf("requestProvision: %v", err)
	}
	want := "GETCONF:9000|device|password|7|salt|4|18|CSQTT-WIRE-3"
	if string(conn.written) != want {
		t.Fatalf("GETCONF = %q, want %q", conn.written, want)
	}
}

func TestCSQTTFlowFramesTCPAndLeavesUDPUnframed(t *testing.T) {
	dispatcher := &csqttDispatcher{senderID: 17, sequences: make(map[uint64]uint32)}
	tcp := csqttIPv4Packet(6, 0x02)
	first := dispatcher.framePacket(tcp)
	header, payload, ok := decodeCSQTTFlowFrame(first)
	if !ok || header.senderID != 17 || header.sequence != 0 || !bytes.Equal(payload, tcp) {
		t.Fatalf("invalid first TCP frame: header=%+v framed=%v", header, ok)
	}
	secondHeader, _, ok := decodeCSQTTFlowFrame(dispatcher.framePacket(tcp))
	if !ok || secondHeader.flowID != header.flowID || secondHeader.sequence != 1 {
		t.Fatalf("invalid second TCP frame: header=%+v framed=%v", secondHeader, ok)
	}
	udp := csqttIPv4Packet(17, 0)
	if framed := dispatcher.framePacket(udp); !bytes.Equal(framed, udp) {
		t.Fatal("UDP packet was unexpectedly framed")
	}
}

func TestCSQTTDownlinkReordersFlowFrames(t *testing.T) {
	runtime := &csqttRuntime{downlinkFlows: make(map[csqttFlowReassemblyKey]*csqttFlowReassemblyState)}
	frame := func(sequence uint32, payload string) []byte {
		packet := make([]byte, csqttFlowFrameLen+len(payload))
		copy(packet[:4], csqttFlowFrameMagic)
		binary.BigEndian.PutUint64(packet[4:12], 7)
		binary.BigEndian.PutUint64(packet[12:20], 9)
		binary.BigEndian.PutUint32(packet[20:24], sequence)
		copy(packet[csqttFlowFrameLen:], payload)
		return packet
	}
	if ready := runtime.acceptDownlinkPacket(frame(1, "second")); len(ready) != 0 {
		t.Fatalf("out-of-order packet released early: %q", ready)
	}
	ready := runtime.acceptDownlinkPacket(frame(0, "first"))
	if len(ready) != 2 || string(ready[0]) != "first" || string(ready[1]) != "second" {
		t.Fatalf("reordered packets = %q", ready)
	}
}

func TestCSQTTProtocolMismatchIsFatal(t *testing.T) {
	err := csqttDeniedError("DENIED:protocol_mismatch")
	if err == nil || !strings.Contains(err.Error(), "fatal_protocol") {
		t.Fatalf("protocol mismatch error = %v", err)
	}
}

type csqttProvisionTestConn struct {
	written  []byte
	response []byte
	read     bool
}

func (c *csqttProvisionTestConn) Read(payload []byte) (int, error) {
	if c.read {
		return 0, context.DeadlineExceeded
	}
	c.read = true
	return copy(payload, c.response), nil
}
func (c *csqttProvisionTestConn) Write(payload []byte) (int, error) {
	c.written = append(c.written[:0], payload...)
	return len(payload), nil
}
func (c *csqttProvisionTestConn) Close() error                     { return nil }
func (c *csqttProvisionTestConn) LocalAddr() net.Addr              { return nil }
func (c *csqttProvisionTestConn) RemoteAddr() net.Addr             { return nil }
func (c *csqttProvisionTestConn) SetDeadline(time.Time) error      { return nil }
func (c *csqttProvisionTestConn) SetReadDeadline(time.Time) error  { return nil }
func (c *csqttProvisionTestConn) SetWriteDeadline(time.Time) error { return nil }

func csqttIPv4Packet(protocol, tcpFlags byte) []byte {
	packet := make([]byte, 40)
	packet[0] = 0x45
	packet[9] = protocol
	copy(packet[12:16], []byte{10, 0, 0, 2})
	copy(packet[16:20], []byte{1, 1, 1, 1})
	if protocol == 6 {
		binary.BigEndian.PutUint16(packet[20:22], 1234)
		binary.BigEndian.PutUint16(packet[22:24], 443)
		packet[32] = 0x50
		packet[33] = tcpFlags
	}
	return packet
}
