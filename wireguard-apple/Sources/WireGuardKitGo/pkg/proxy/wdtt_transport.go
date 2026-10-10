package proxy

import (
	"context"
	"encoding/binary"
	"errors"
	"log"
	"net"
	"sync"
	"time"
)

const (
	wdttUplinkHello = "WDTT_UPLINK2"
	wdttUplinkAck   = "WDTT_TRANSPORT_OK1"
	wdttFrameHeader = 16
	wdttData        = byte(1)
	wdttProbe       = byte(2)
	wdttBypass      = byte(4)
)

// negotiateWDTTUplink opts into the v19 delivery-aware transport only after
// the authenticated GETCONF advertised it. Legacy servers keep receiving the
// old unframed stream.
func negotiateWDTTUplink(ctx context.Context, conn net.Conn) error {
	if _, err := conn.Write([]byte(wdttUplinkHello)); err != nil {
		return err
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	stop := context.AfterFunc(ctx, func() { _ = conn.SetReadDeadline(time.Now()) })
	defer stop()
	defer conn.SetReadDeadline(time.Time{})

	buf := make([]byte, 1600)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			return fmtTransportError("uplink negotiation", err)
		}
		if string(buf[:n]) == wdttUplinkAck {
			return nil
		}
		if n == 1 && buf[0] == 0 {
			continue
		}
		return errors.New("WDTT uplink negotiation returned an invalid acknowledgement")
	}
}

func fmtTransportError(op string, err error) error {
	return &wdttTransportError{op: op, err: err}
}

type wdttTransportError struct {
	op  string
	err error
}

func (e *wdttTransportError) Error() string { return e.op + ": " + e.err.Error() }
func (e *wdttTransportError) Unwrap() error { return e.err }

func frameWDTT(dst, payload []byte, kind byte, seq uint64) []byte {
	if len(payload) > 1440 || (kind != wdttData && kind != wdttProbe && kind != wdttBypass) {
		return nil
	}
	n := wdttFrameHeader + len(payload)
	if cap(dst) < n {
		dst = make([]byte, n)
	} else {
		dst = dst[:n]
		clear(dst[:wdttFrameHeader])
	}
	copy(dst, "WDU2")
	dst[4] = kind
	binary.BigEndian.PutUint64(dst[8:16], seq)
	copy(dst[16:], payload)
	return dst
}

func parseWDTTAck(packet []byte) (expected, received uint64, ok bool) {
	if len(packet) != 24 || string(packet[:4]) != "WDA2" || binary.BigEndian.Uint32(packet[4:8]) != 0 {
		return 0, 0, false
	}
	expected = binary.BigEndian.Uint64(packet[8:16])
	received = binary.BigEndian.Uint64(packet[16:24])
	return expected, received, received <= expected
}

type wdttUplinkPath struct {
	id           int
	adaptive     bool
	send         chan []byte
	done         <-chan struct{}
	mu           sync.Mutex
	next         uint64
	expected     uint64
	received     uint64
	baseExp      uint64
	baseRecv     uint64
	muted        bool
	checkAt      time.Time
	probing      bool
	pendingSince time.Time
}

func (p *wdttUplinkPath) frame(payload []byte, kind byte) []byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.adaptive {
		return payload
	}
	if kind == wdttData && len(payload) <= 160 {
		return frameWDTT(nil, payload, wdttBypass, 0)
	}
	packet := frameWDTT(nil, payload, kind, p.next)
	if p.next == p.expected {
		p.pendingSince = time.Now()
	}
	p.next++
	return packet
}

func (p *wdttUplinkPath) noteAck(packet []byte) bool {
	expected, received, ok := parseWDTTAck(packet)
	if !ok {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if expected > p.next || expected < p.expected || received < p.received {
		return true
	}
	p.expected, p.received = expected, received
	if expected == p.next {
		p.pendingSince = time.Time{}
	} else if expected > 0 {
		p.pendingSince = time.Now()
	}
	if p.probing && expected >= p.next && received-p.baseRecv >= 24 {
		p.muted = false
		p.probing = false
		p.baseExp, p.baseRecv = expected, received
		log.Printf("proxy: [conn %d] WDTT uplink recovered", p.id)
		return true
	}
	total := expected - p.baseExp
	got := received - p.baseRecv
	if !p.muted && total >= 64 && got <= total && (total-got)*8 > total {
		p.muted = true
		p.checkAt = time.Now().Add(10 * time.Second)
		p.baseExp, p.baseRecv = expected, received
		log.Printf("proxy: [conn %d] WDTT uplink muted after delivery loss (%d/%d received)", p.id, got, total)
	} else if !p.muted && total >= 128 {
		p.baseExp, p.baseRecv = expected, received
	}
	return true
}

func (p *wdttUplinkPath) usable() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return !p.muted && !p.probing
}

func (p *wdttUplinkPath) beginProbe(now time.Time) ([][]byte, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.muted && !p.pendingSince.IsZero() && now.Sub(p.pendingSince) >= 5*time.Second {
		p.muted = true
		p.checkAt = now
		p.baseExp, p.baseRecv = p.expected, p.received
		log.Printf("proxy: [conn %d] WDTT uplink muted after acknowledgement timeout", p.id)
	}
	if !p.adaptive || !p.muted || p.probing || now.Before(p.checkAt) {
		return nil, false
	}
	p.probing = true
	p.baseExp, p.baseRecv = p.expected, p.received
	frames := make([][]byte, 32)
	payload := make([]byte, 1312)
	for i := range frames {
		frames[i] = frameWDTT(nil, payload, wdttProbe, p.next)
		p.next++
	}
	return frames, true
}

func (p *wdttUplinkPath) finishFailedProbe() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.probing {
		p.probing = false
		p.checkAt = time.Now().Add(10 * time.Second)
	}
}

type wdttUplinkDispatcher struct {
	ctx   context.Context
	input <-chan []byte
	wake  chan struct{}
	mu    sync.RWMutex
	paths map[int]*wdttUplinkPath
	next  int
}

func newWDTTUplinkDispatcher(ctx context.Context, input <-chan []byte) *wdttUplinkDispatcher {
	return &wdttUplinkDispatcher{ctx: ctx, input: input, wake: make(chan struct{}, 1), paths: make(map[int]*wdttUplinkPath)}
}

func (d *wdttUplinkDispatcher) register(path *wdttUplinkPath) {
	d.mu.Lock()
	d.paths[path.id] = path
	d.mu.Unlock()
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

func (d *wdttUplinkDispatcher) unregister(path *wdttUplinkPath) {
	d.mu.Lock()
	if d.paths[path.id] == path {
		delete(d.paths, path.id)
	}
	d.mu.Unlock()
	select {
	case d.wake <- struct{}{}:
	default:
	}
}

func (d *wdttUplinkDispatcher) choose() *wdttUplinkPath {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.paths) == 0 {
		return nil
	}
	ids := make([]int, 0, len(d.paths))
	for id := range d.paths {
		ids = append(ids, id)
	}
	for i := 0; i < len(ids); i++ {
		idx := (d.next + i) % len(ids)
		path := d.paths[ids[idx]]
		if path.usable() {
			d.next = (idx + 1) % len(ids)
			return path
		}
	}
	// Preserve service if every path is quarantined; the least recently
	// selected path becomes the last-resort carrier until receipts recover.
	path := d.paths[ids[d.next%len(ids)]]
	path.mu.Lock()
	path.muted, path.probing = false, false
	path.baseExp, path.baseRecv = path.expected, path.received
	path.pendingSince = time.Now()
	path.mu.Unlock()
	return path
}

func (d *wdttUplinkDispatcher) run() {
	for {
		select {
		case <-d.ctx.Done():
			return
		case packet := <-d.input:
			for {
				path := d.choose()
				if path == nil {
					select {
					case <-d.ctx.Done():
						return
					case <-d.wake:
						continue
					}
				}
				select {
				case path.send <- packet:
				case <-path.done:
					continue
				case <-d.ctx.Done():
					return
				}
				break
			}
		}
	}
}

func (p *wdttUplinkPath) runRecovery(ctx context.Context) {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			frames, ok := p.beginProbe(now)
			if !ok {
				continue
			}
			for _, frame := range frames {
				select {
				case p.send <- frame:
				case <-ctx.Done():
					return
				}
			}
			timer := time.NewTimer(time.Second)
			select {
			case <-timer.C:
				p.finishFailedProbe()
			case <-ctx.Done():
				timer.Stop()
				return
			}
		}
	}
}
