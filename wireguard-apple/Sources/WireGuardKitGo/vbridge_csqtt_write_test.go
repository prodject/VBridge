package main

import (
	"errors"
	"io"
	"net"
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
