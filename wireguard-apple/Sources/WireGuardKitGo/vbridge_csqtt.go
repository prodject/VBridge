package main

// CSQTT protocol compatibility portions:
// SPDX-FileCopyrightText: 2026 amurcanov
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

// #include <stdint.h>
import "C"

import (
	"bytes"
	"context"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
	"golang.zx2c4.com/wireguard/tun"
)

const (
	csqttKeepaliveInterval    = 15 * time.Second
	csqttHandshakeTimeout     = 20 * time.Second
	csqttProvisionTimeout     = 15 * time.Second
	csqttDisconnectTimeout    = 5 * time.Second
	csqttWriteTimeout         = time.Second
	csqttSocketBufSize        = 625 * 1024
	csqttTunOffset            = 4
	csqttDefaultMTU           = 1280
	csqttDefaultLocalPort     = 9000
	csqttPaddingMax           = 24
	csqttPayloadTypeAudio     = 111
	csqttWrapKeyLen           = 32
	csqttHeaderLen            = 24
	csqttTagLen               = 16
	csqttMaxPacketSize        = 4096
	csqttKeepaliveByte        = 0xff
	csqttKeepaliveSize        = 16
	csqttWireProtocolRevision = "CSQTT-WIRE-3"
	csqttFlowFrameLen         = 24
	csqttMaxTrackedFlows      = 4096
	csqttMaxPendingPerFlow    = 96
	csqttMaxPendingTotal      = 4096
	csqttGapReleaseAfter      = 12 * time.Millisecond
)

var csqttProvisionAttempts = []time.Duration{
	1500 * time.Millisecond,
	3 * time.Second,
	6 * time.Second,
	csqttProvisionTimeout,
}

var (
	csqttFlowFrameMagic     = []byte{'C', 'Q', 'F', '1'}
	csqttPanelRestart       = []byte{0xff, 'C', 'S', 'Q', 'T', 'T', '_', 'P', 'A', 'N', 'E', 'L', '_', 'R', 'E', 'S', 'T', 'A', 'R', 'T', '_', 'V', '1', 0x00, 0x91, 0x7d, 0x03, 0xa8}
	csqttStreamRepairPrefix = []byte{0xff, 'C', 'S', 'Q', 'T', 'T', '_', 'S', 'T', 'R', 'E', 'A', 'M', '_', 'R', 'E', 'P', 'A', 'I', 'R', '_', 'V', '1'}
	csqttStreamAlivePrefix  = []byte{0xff, 'C', 'S', 'Q', 'T', 'T', '_', 'S', 'T', 'R', 'E', 'A', 'M', '_', 'A', 'L', 'I', 'V', 'E', '_', 'V', '1'}
)

type csqttFlowFrameHeader struct {
	senderID uint64
	flowID   uint64
	sequence uint32
}

type csqttFlowReassemblyKey struct {
	senderID uint64
	flowID   uint64
}

type csqttPendingFlowPacket struct {
	sequence uint32
	packet   []byte
}

type csqttFlowReassemblyState struct {
	expected   uint32
	gapStarted time.Time
	pending    []csqttPendingFlowPacket
}

type csqttProvision struct {
	Address   string `json:"address"`
	DNS       string `json:"dns"`
	MTU       int    `json:"mtu"`
	LocalPort int    `json:"local_port"`
}

type csqttStats struct {
	ActiveWorkers  int32 `json:"active_workers"`
	TotalBytesUp   int64 `json:"total_bytes_up"`
	TotalBytesDown int64 `json:"total_bytes_down"`
}

type csqttRuntime struct {
	ctx         context.Context
	cancel      context.CancelFunc
	peerAddr    *net.UDPAddr
	hashes      []string
	config      ProxyConfig
	localPort   string
	turnHost    string
	turnPort    string
	deviceID    string
	password    string
	workerCount int
	useMasking bool
	clientTag  string
	salt       string
	generation uint64

	dispatcher *csqttDispatcher
	tunDevice  tun.Device

	readyCh     chan struct{}
	readyOnce   sync.Once
	provisionCh chan struct{}
	provMu      sync.Mutex
	provision   *csqttProvision
	errMu       sync.Mutex
	fatalErr    error

	turnServerIP   atomic.Value
	activeWorkers  atomic.Int32
	totalBytesUp   atomic.Int64
	totalBytesDown atomic.Int64
	downlinkMu      sync.Mutex
	downlinkFlows   map[csqttFlowReassemblyKey]*csqttFlowReassemblyState
	pendingDownlink int

	workersMu sync.Mutex
	workers   []*csqttWorker
	getCreds  getCredsFunc
	resetCreds func()
}

type csqttWorker struct {
	id      int
	runtime *csqttRuntime
	sendCh  chan []byte
	writeMu sync.Mutex

}

func (w *csqttWorker) wireID() int {
	return w.id + 1
}

type csqttDispatcher struct {
	runtime   *csqttRuntime
	mu        sync.Mutex
	workers   []*csqttWorker
	next      int
	senderID  uint64
	sequences map[uint64]uint32
}

type csqttConnectedUDPConn struct{ *net.UDPConn }

func (c *csqttConnectedUDPConn) WriteTo(p []byte, _ net.Addr) (int, error) { return c.Write(p) }

type csqttRelayPacketConn struct {
	relay net.PacketConn
	peer  net.Addr
}

func (c *csqttRelayPacketConn) ReadFrom(p []byte) (int, net.Addr, error) { return c.relay.ReadFrom(p) }
func (c *csqttRelayPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) { return c.relay.WriteTo(p, c.peer) }
func (c *csqttRelayPacketConn) Close() error                              { return c.relay.Close() }
func (c *csqttRelayPacketConn) LocalAddr() net.Addr                       { return c.relay.LocalAddr() }
func (c *csqttRelayPacketConn) SetDeadline(t time.Time) error             { return c.relay.SetDeadline(t) }
func (c *csqttRelayPacketConn) SetReadDeadline(t time.Time) error         { return c.relay.SetReadDeadline(t) }
func (c *csqttRelayPacketConn) SetWriteDeadline(t time.Time) error        { return c.relay.SetWriteDeadline(t) }

type csqttObfsPacketConn struct {
	base net.PacketConn
	peer net.Addr
	aead cipher.AEAD
	ssrc uint32

	startedAt          time.Time
	initialSeq         uint16
	initialTS          uint32
	initialAbsSendTime uint32
	transportSeq       uint16

	txMu  sync.Mutex
	txBuf []byte
	rxMu  sync.Mutex
	rxBuf []byte
}

func newCSQTTRuntime(config ProxyConfig) (*csqttRuntime, error) {
	hashes := ParseHashes(config.VKLink)
	if len(hashes) == 0 {
		return nil, errors.New("csqtt: no VK call hashes configured")
	}
	peerAddr, err := net.ResolveUDPAddr("udp", config.PeerAddr)
	if err != nil {
		return nil, fmt.Errorf("csqtt: resolve peer: %w", err)
	}
	localPort := strconv.Itoa(csqttDefaultLocalPort)
	if _, port, splitErr := net.SplitHostPort(strings.TrimSpace(config.ListenAddr)); splitErr == nil && port != "" {
		localPort = port
	}
	deviceID := strings.TrimSpace(config.DeviceID)
	if deviceID == "" {
		deviceID = uuid.NewString()
	}
	workerCount := config.NumConns
	if workerCount <= 0 {
		workerCount = 1
	}
	workerCount += max(config.CSQTTExtraThreads, 0)
	if workerCount > 126 {
		return nil, fmt.Errorf("csqtt: worker count %d exceeds protocol maximum 126", workerCount)
	}
	identityPoolSize := ceilDiv(workerCount, 12)
	if identityPoolSize < 1 {
		identityPoolSize = 1
	}
	useMasking := true
	if config.CSQTTUseMasking != nil {
		useMasking = *config.CSQTTUseMasking
	}
	clientTag := strings.TrimSpace(config.CSQTTClientTag)
	if clientTag == "" {
		clientTag = "vbridge"
	}
	salt := strings.TrimSpace(config.CSQTTClientTag)
	if salt == "" {
		salt = deviceID
	}
	ctx, cancel := context.WithCancel(context.Background())
	runtime := &csqttRuntime{
		ctx:         ctx,
		cancel:      cancel,
		peerAddr:    peerAddr,
		hashes:      hashes,
		config:      config,
		localPort:   localPort,
		turnHost:    config.TurnServer,
		turnPort:    config.TurnPort,
		deviceID:    deviceID,
		password:    strings.TrimSpace(config.CSQTTPassword),
		workerCount: workerCount,
		useMasking:  useMasking,
		clientTag:   clientTag,
		salt:        salt,
		generation:  uint64(time.Now().UnixMilli()),
		readyCh:     make(chan struct{}),
		provisionCh: make(chan struct{}),
	}
	runtime.getCreds, runtime.resetCreds = poolCreds(func(ctx context.Context, hash string) (*turnCred, error) {
		return getVKTurnCredWithFallback(ctx, hash)
	}, identityPoolSize)
	runtime.downlinkFlows = make(map[csqttFlowReassemblyKey]*csqttFlowReassemblyState)
	runtime.dispatcher = &csqttDispatcher{
		runtime:   runtime,
		senderID:  csqttRandomSenderID(),
		sequences: make(map[uint64]uint32),
	}
	log.Printf("csqtt: TURN identity strategy: %d workers, %d cached identities", workerCount, identityPoolSize)
	return runtime, nil
}

func (r *csqttRuntime) Start() {
	for index := 0; index < r.workerCount; index++ {
		worker := &csqttWorker{
			id:      index,
			runtime: r,
			sendCh:  make(chan []byte, 128),
		}
		r.dispatcher.register(worker)
		r.workersMu.Lock()
		r.workers = append(r.workers, worker)
		r.workersMu.Unlock()
		go worker.run()
	}
}

func (r *csqttRuntime) Stop() {
	r.cancel()
	if r.tunDevice != nil {
		_ = r.tunDevice.Close()
	}
}

func (r *csqttRuntime) WaitBootstrap(timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-r.readyCh:
		return nil
	case <-timer.C:
		if err := r.fatalError(); err != nil {
			return err
		}
		return fmt.Errorf("bootstrap timeout after %s", timeout)
	case <-r.ctx.Done():
		if err := r.fatalError(); err != nil {
			return err
		}
		return context.Canceled
	}
}

func (r *csqttRuntime) WaitProvision(timeout time.Duration) (*csqttProvision, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-r.provisionCh:
		r.provMu.Lock()
		defer r.provMu.Unlock()
		if r.provision == nil {
			return nil, errors.New("csqtt: provision missing")
		}
		provision := *r.provision
		return &provision, nil
	case <-timer.C:
		if err := r.fatalError(); err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("csqtt: provision timeout after %s", timeout)
	case <-r.ctx.Done():
		if err := r.fatalError(); err != nil {
			return nil, err
		}
		return nil, context.Canceled
	}
}

func (r *csqttRuntime) AttachTUN(tunFd int32) error {
	if r.tunDevice != nil {
		return nil
	}
	dupFd, err := dupFD(int(tunFd))
	if err != nil {
		return fmt.Errorf("csqtt: dup tun fd: %w", err)
	}
	tunFile := os.NewFile(uintptr(dupFd), "/dev/tun")
	device, err := tun.CreateTUNFromFile(tunFile, 0)
	if err != nil {
		_ = tunFile.Close()
		return fmt.Errorf("csqtt: create tun from fd: %w", err)
	}
	r.tunDevice = device
	go r.runTUNReader(device)
	return nil
}

func (r *csqttRuntime) runTUNReader(device tun.Device) {
	batchSize := device.BatchSize()
	if batchSize < 1 {
		batchSize = 1
	}
	buffers := make([][]byte, batchSize)
	sizes := make([]int, batchSize)
	for index := range buffers {
		buffers[index] = make([]byte, csqttMaxPacketSize)
	}
	for {
		count, err := device.Read(buffers, sizes, csqttTunOffset)
		if err != nil {
			if r.ctx.Err() == nil {
				log.Printf("csqtt: tun read failed: %v", err)
			}
			return
		}
		for index := 0; index < count; index++ {
			size := sizes[index]
			if size <= 0 {
				continue
			}
			packet := make([]byte, size)
			copy(packet, buffers[index][csqttTunOffset:csqttTunOffset+size])
			r.totalBytesUp.Add(int64(size))
			r.dispatcher.dispatch(packet)
		}
	}
}

func (r *csqttRuntime) writeTUNPacket(packet []byte) {
	if r.tunDevice == nil || len(packet) == 0 {
		return
	}
	buffer := make([]byte, csqttTunOffset+len(packet))
	copy(buffer[csqttTunOffset:], packet)
	if _, err := r.tunDevice.Write([][]byte{buffer}, csqttTunOffset); err != nil {
		log.Printf("csqtt: tun write failed: %v", err)
		return
	}
	r.totalBytesDown.Add(int64(len(packet)))
}

func (r *csqttRuntime) signalReady() {
	r.readyOnce.Do(func() {
		close(r.readyCh)
	})
}

func (r *csqttRuntime) setProvision(provision *csqttProvision) {
	r.provMu.Lock()
	defer r.provMu.Unlock()
	if r.provision != nil {
		return
	}
	if provision.MTU <= 0 {
		provision.MTU = csqttDefaultMTU
	}
	r.provision = provision
	close(r.provisionCh)
}

func (r *csqttRuntime) setFatalError(err error) {
	if err == nil {
		return
	}
	r.errMu.Lock()
	defer r.errMu.Unlock()
	if r.fatalErr != nil {
		return
	}
	r.fatalErr = err
	r.cancel()
}

func (r *csqttRuntime) fatalError() error {
	r.errMu.Lock()
	defer r.errMu.Unlock()
	return r.fatalErr
}

func (r *csqttRuntime) TURNServerIP() string {
	if value, ok := r.turnServerIP.Load().(string); ok {
		return value
	}
	return ""
}

func (r *csqttRuntime) Stats() csqttStats {
	return csqttStats{
		ActiveWorkers:  r.activeWorkers.Load(),
		TotalBytesUp:   r.totalBytesUp.Load(),
		TotalBytesDown: r.totalBytesDown.Load(),
	}
}

func (d *csqttDispatcher) register(worker *csqttWorker) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.workers = append(d.workers, worker)
}

func (d *csqttDispatcher) unregister(worker *csqttWorker) {
	d.mu.Lock()
	defer d.mu.Unlock()
	nextWorkers := d.workers[:0]
	for _, current := range d.workers {
		if current != worker {
			nextWorkers = append(nextWorkers, current)
		}
	}
	d.workers = nextWorkers
	if d.next >= len(d.workers) {
		d.next = 0
	}
}

func (d *csqttDispatcher) dispatch(packet []byte) {
	d.mu.Lock()
	packet = d.framePacket(packet)
	workers := append([]*csqttWorker(nil), d.workers...)
	start := d.next
	if len(workers) > 0 {
		d.next = (d.next + 1) % len(workers)
	}
	d.mu.Unlock()
	if len(workers) == 0 {
		return
	}
	for offset := 0; offset < len(workers); offset++ {
		worker := workers[(start+offset)%len(workers)]
		select {
		case worker.sendCh <- packet:
			return
		default:
		}
	}
}

func (d *csqttDispatcher) framePacket(packet []byte) []byte {
	flowID, ok := csqttTCPFlowID(packet)
	if !ok {
		return packet
	}
	if len(d.sequences) == csqttMaxTrackedFlows {
		if _, exists := d.sequences[flowID]; !exists {
			d.sequences = make(map[uint64]uint32)
			d.senderID = csqttMix64(d.senderID + 0x9e3779b97f4a7c15)
			if d.senderID == 0 {
				d.senderID = 1
			}
		}
	}
	sequence := d.sequences[flowID]
	d.sequences[flowID] = sequence + 1
	framed := make([]byte, csqttFlowFrameLen+len(packet))
	copy(framed[:4], csqttFlowFrameMagic)
	binary.BigEndian.PutUint64(framed[4:12], d.senderID)
	binary.BigEndian.PutUint64(framed[12:20], flowID)
	binary.BigEndian.PutUint32(framed[20:24], sequence)
	copy(framed[csqttFlowFrameLen:], packet)
	return framed
}

func (w *csqttWorker) run() {
	defer w.runtime.dispatcher.unregister(w)
	hash := w.runtime.hashes[w.id%len(w.runtime.hashes)]
	backoff := time.Second
	for w.runtime.ctx.Err() == nil {
		if err := w.runSingleSession(hash); err != nil {
			log.Printf("csqtt: worker %d ended: %v", w.id, err)
			lowered := strings.ToLower(err.Error())
			if strings.Contains(lowered, "fatal_auth") ||
				strings.Contains(lowered, "fatal_protocol") ||
				strings.Contains(lowered, "fatal_config") ||
				strings.Contains(lowered, "wrong password") ||
				strings.Contains(lowered, "device mismatch") {
				w.runtime.setFatalError(err)
				return
			}
		}
		select {
		case <-time.After(backoff):
		case <-w.runtime.ctx.Done():
			return
		}
		if backoff < 8*time.Second {
			backoff *= 2
		}
	}
}

func (w *csqttWorker) runSingleSession(hash string) error {
	ctx := w.runtime.ctx
	cred, err := w.runtime.getCreds(ctx, hash)
	if err != nil {
		return fmt.Errorf("get turn creds: %w", err)
	}
	turnAddr, turnHost, err := w.selectTURNAddress(cred)
	if err != nil {
		return err
	}
	w.runtime.turnServerIP.Store(turnHost)

	resolvedTURN, err := net.ResolveUDPAddr("udp", turnAddr)
	if err != nil {
		return fmt.Errorf("resolve turn address: %w", err)
	}
	udpConn, err := net.DialUDP("udp", nil, resolvedTURN)
	if err != nil {
		return fmt.Errorf("dial turn udp: %w", err)
	}
	defer udpConn.Close()
	_ = udpConn.SetReadBuffer(csqttSocketBufSize)
	_ = udpConn.SetWriteBuffer(csqttSocketBufSize)

	addrFamily := turn.RequestedAddressFamilyIPv4
	if w.runtime.peerAddr.IP.To4() == nil {
		addrFamily = turn.RequestedAddressFamilyIPv6
	}
	turnClient, err := turn.NewClient(&turn.ClientConfig{
		STUNServerAddr:         turnAddr,
		TURNServerAddr:         turnAddr,
		Conn:                   &csqttConnectedUDPConn{udpConn},
		Username:               cred.user,
		Password:               cred.pass,
		RequestedAddressFamily: addrFamily,
		LoggerFactory:          logging.NewDefaultLoggerFactory(),
	})
	if err != nil {
		return fmt.Errorf("turn client: %w", err)
	}
	defer turnClient.Close()
	if err := turnClient.Listen(); err != nil {
		return fmt.Errorf("turn listen: %w", err)
	}
	relay, err := turnClient.Allocate()
	if err != nil {
		return fmt.Errorf("turn allocate: %w", err)
	}
	defer relay.Close()

	go w.bindingLoop(ctx, turnClient)

	packetConn := net.PacketConn(&csqttRelayPacketConn{
		relay: relay,
		peer:  w.runtime.peerAddr,
	})
	if w.runtime.useMasking {
		obfsConn, err := newCSQTTObfsPacketConn(packetConn, w.runtime.peerAddr, w.runtime.password)
		if err != nil {
			return fmt.Errorf("obfs transport: %w", err)
		}
		defer obfsConn.Close()
		packetConn = obfsConn
	}

	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		return fmt.Errorf("generate dtls cert: %w", err)
	}
	dtlsConn, err := dtls.Client(packetConn, w.runtime.peerAddr, &dtls.Config{
		Certificates:          []tls.Certificate{cert},
		InsecureSkipVerify:    true,
		ExtendedMasterSecret:  dtls.RequireExtendedMasterSecret,
		CipherSuites:          []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
		ConnectionIDGenerator: dtls.OnlySendCIDGenerator(),
	})
	if err != nil {
		return fmt.Errorf("dtls client: %w", err)
	}
	defer dtlsConn.Close()
	defer w.sendDisconnect(dtlsConn)

	handshakeCtx, handshakeCancel := context.WithTimeout(ctx, csqttHandshakeTimeout)
	defer handshakeCancel()
	if err := dtlsConn.HandshakeContext(handshakeCtx); err != nil {
		return fmt.Errorf("dtls handshake: %w", err)
	}

	w.runtime.activeWorkers.Add(1)
	defer w.runtime.activeWorkers.Add(-1)
	w.runtime.signalReady()

	provision, err := w.requestProvision(dtlsConn)
	if err != nil {
		return err
	}
	if provision != nil {
		w.runtime.setProvision(provision)
	}

	go w.keepaliveLoop(ctx, dtlsConn)
	return w.proxyPackets(ctx, dtlsConn)
}

func (w *csqttWorker) selectTURNAddress(cred *turnCred) (string, string, error) {
	if cred == nil {
		return "", "", errors.New("empty turn credentials")
	}
	addresses := cred.turnURLs
	if len(addresses) == 0 && cred.addr != "" {
		addresses = []string{cred.addr}
	}
	if len(addresses) == 0 {
		return "", "", errors.New("no TURN URLs in credentials")
	}
	selected := addresses[w.id%len(addresses)]
	host, port, err := net.SplitHostPort(selected)
	if err != nil {
		return "", "", fmt.Errorf("split turn url %q: %w", selected, err)
	}
	if strings.TrimSpace(w.runtime.turnHost) != "" {
		host = strings.TrimSpace(w.runtime.turnHost)
	}
	if strings.TrimSpace(w.runtime.turnPort) != "" {
		port = strings.TrimSpace(w.runtime.turnPort)
	}
	return net.JoinHostPort(host, port), host, nil
}

func (w *csqttWorker) bindingLoop(ctx context.Context, client *turn.Client) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			client.SendBindingRequest()
		}
	}
}

func (w *csqttWorker) requestProvision(conn net.Conn) (*csqttProvision, error) {
	request := fmt.Sprintf("GETCONF:%s|%s|%s|%d|%s|%d|%d|%s",
		w.runtime.localPort,
		w.runtime.deviceID,
		w.runtime.password,
		w.runtime.generation,
		w.runtime.salt,
		w.wireID(),
		w.runtime.workerCount,
		csqttWireProtocolRevision,
	)
	buffer := make([]byte, csqttMaxPacketSize)
	defer conn.SetReadDeadline(time.Time{})
	for attempt, timeout := range csqttProvisionAttempts {
		if err := w.writePacket(conn, []byte(request)); err != nil {
			return nil, fmt.Errorf("send getconf: %w", err)
		}
		deadline := time.Now().Add(timeout)
		for {
			_ = conn.SetReadDeadline(deadline)
			count, err := conn.Read(buffer)
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					break
				}
				return nil, fmt.Errorf("read provision: %w", err)
			}
			payload := buffer[:count]
			if !isCSQTTControlPacket(payload) {
				continue
			}
			text := strings.TrimSpace(string(payload))
			if strings.HasPrefix(text, "TUNCONF:") {
				return parseCSQTTProvision(payload)
			}
			if strings.HasPrefix(text, "DENIED:") {
				return nil, csqttDeniedError(text)
			}
			if text == "NOCONF" {
				return nil, errors.New("fatal_config: CSQTT server has no tunnel address available")
			}
		}
		if attempt == len(csqttProvisionAttempts)-1 {
			break
		}
		log.Printf("csqtt: worker %d GETCONF timeout, retry %d/%d", w.id, attempt+1, len(csqttProvisionAttempts))
	}
	return nil, fmt.Errorf("csqtt: provision timeout after %d attempts", len(csqttProvisionAttempts))
}

func (w *csqttWorker) sendDisconnect(conn net.Conn) {
	if w.runtime.ctx.Err() == nil {
		return
	}
	request := fmt.Sprintf("DISCONNECT:%s|%s", w.runtime.deviceID, w.runtime.salt)
	_ = w.writePacketWithTimeout(conn, []byte(request), csqttDisconnectTimeout)
}

func (w *csqttWorker) writePacket(conn net.Conn, payload []byte) error {
	return w.writePacketWithTimeout(conn, payload, csqttWriteTimeout)
}

func (w *csqttWorker) writePacketWithTimeout(conn net.Conn, payload []byte, timeout time.Duration) error {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()

	if err := conn.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set write deadline: %w", err)
	}
	defer conn.SetWriteDeadline(time.Time{})

	written, err := conn.Write(payload)
	if err != nil {
		return err
	}
	if written != len(payload) {
		return io.ErrShortWrite
	}
	return nil
}

func (w *csqttWorker) keepaliveLoop(ctx context.Context, conn net.Conn) {
	ticker := time.NewTicker(csqttKeepaliveInterval)
	defer ticker.Stop()
	ping := bytes.Repeat([]byte{csqttKeepaliveByte}, csqttKeepaliveSize)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := w.writePacket(conn, ping); err != nil {
				_ = conn.Close()
				return
			}
		}
	}
}

func (w *csqttWorker) proxyPackets(ctx context.Context, conn net.Conn) error {
	readBuffer := make([]byte, csqttMaxPacketSize)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		select {
		case packet, ok := <-w.sendCh:
			if ok {
				if err := w.writePacket(conn, packet); err != nil {
					return fmt.Errorf("dtls write: %w", err)
				}
			}
		default:
		}
		_ = conn.SetReadDeadline(time.Now().Add(time.Second))
		count, err := conn.Read(readBuffer)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return fmt.Errorf("dtls read: %w", err)
		}
		payload := append([]byte(nil), readBuffer[:count]...)
		if bytes.Equal(payload, csqttPanelRestart) {
			return errors.New("csqtt: server requested reconnect after panel restart")
		}
		if isCSQTTControlPacket(payload) {
			if strings.HasPrefix(string(payload), "TUNCONF:") {
				if provision, parseErr := parseCSQTTProvision(payload); parseErr == nil {
					w.runtime.setProvision(provision)
				}
			}
			continue
		}
		if isCSQTTKeepalivePacket(payload) {
			continue
		}
		for _, packet := range w.runtime.acceptDownlinkPacket(payload) {
			w.runtime.writeTUNPacket(packet)
		}
	}
}

func parseCSQTTProvision(payload []byte) (*csqttProvision, error) {
	text := strings.TrimSpace(string(payload))
	value := strings.TrimPrefix(text, "TUNCONF:")
	parts := strings.Split(value, ":")
	if len(parts) < 3 {
		return nil, fmt.Errorf("invalid TUNCONF payload: %q", text)
	}
	localPort, _ := strconv.Atoi(parts[2])
	return &csqttProvision{
		Address:   strings.TrimSpace(parts[0]) + "/32",
		DNS:       strings.TrimSpace(parts[1]),
		MTU:       csqttDefaultMTU,
		LocalPort: localPort,
	}, nil
}

func csqttDeniedError(response string) error {
	reason := strings.TrimSpace(strings.TrimPrefix(response, "DENIED:"))
	switch reason {
	case "wrong_password":
		return errors.New("fatal_auth: CSQTT password is incorrect")
	case "expired":
		return errors.New("fatal_auth: CSQTT password has expired")
	case "device_mismatch":
		return errors.New("fatal_auth: CSQTT password is bound to another device")
	case "protocol_mismatch", "invalid_worker_count":
		return fmt.Errorf("fatal_protocol: CSQTT client/server protocol mismatch (%s)", reason)
	default:
		return fmt.Errorf("fatal_auth: CSQTT access denied (%s)", reason)
	}
}

func decodeCSQTTFlowFrame(packet []byte) (csqttFlowFrameHeader, []byte, bool) {
	if len(packet) < csqttFlowFrameLen || !bytes.Equal(packet[:4], csqttFlowFrameMagic) {
		return csqttFlowFrameHeader{}, packet, false
	}
	header := csqttFlowFrameHeader{
		senderID: binary.BigEndian.Uint64(packet[4:12]),
		flowID:   binary.BigEndian.Uint64(packet[12:20]),
		sequence: binary.BigEndian.Uint32(packet[20:24]),
	}
	return header, packet[csqttFlowFrameLen:], true
}

func (r *csqttRuntime) acceptDownlinkPacket(packet []byte) [][]byte {
	header, payload, framed := decodeCSQTTFlowFrame(packet)
	if !framed {
		return [][]byte{packet}
	}

	r.downlinkMu.Lock()
	defer r.downlinkMu.Unlock()
	key := csqttFlowReassemblyKey{senderID: header.senderID, flowID: header.flowID}
	if len(r.downlinkFlows) == csqttMaxTrackedFlows {
		if _, exists := r.downlinkFlows[key]; !exists {
			r.downlinkFlows = make(map[csqttFlowReassemblyKey]*csqttFlowReassemblyState)
			r.pendingDownlink = 0
		}
	}
	state := r.downlinkFlows[key]
	if state == nil {
		state = &csqttFlowReassemblyState{}
		r.downlinkFlows[key] = state
	}
	ready := make([][]byte, 0, 2)
	r.releaseExpiredDownlink(state, time.Now(), &ready)
	if header.sequence == state.expected {
		ready = append(ready, append([]byte(nil), payload...))
		state.expected++
		state.gapStarted = time.Time{}
		r.drainContiguousDownlink(state, &ready)
		return ready
	}
	if !csqttSequenceForward(header.sequence, state.expected) {
		return ready
	}
	for _, pending := range state.pending {
		if pending.sequence == header.sequence {
			return ready
		}
	}
	if len(state.pending) == csqttMaxPendingPerFlow {
		r.releaseLowestDownlink(state, time.Now(), &ready)
	}
	if r.pendingDownlink == csqttMaxPendingTotal {
		if len(state.pending) == 0 {
			ready = append(ready, append([]byte(nil), payload...))
			state.expected = header.sequence + 1
			state.gapStarted = time.Time{}
			return ready
		}
		r.releaseLowestDownlink(state, time.Now(), &ready)
	}
	state.pending = append(state.pending, csqttPendingFlowPacket{
		sequence: header.sequence,
		packet:   append([]byte(nil), payload...),
	})
	r.pendingDownlink++
	if state.gapStarted.IsZero() {
		state.gapStarted = time.Now()
	}
	r.releaseExpiredDownlink(state, time.Now(), &ready)
	return ready
}

func (r *csqttRuntime) releaseExpiredDownlink(state *csqttFlowReassemblyState, now time.Time, ready *[][]byte) {
	if !state.gapStarted.IsZero() && now.Sub(state.gapStarted) >= csqttGapReleaseAfter {
		r.releaseLowestDownlink(state, now, ready)
	}
}

func (r *csqttRuntime) releaseLowestDownlink(state *csqttFlowReassemblyState, now time.Time, ready *[][]byte) {
	lowestIndex := -1
	var lowestDistance uint32
	for index, pending := range state.pending {
		if !csqttSequenceForward(pending.sequence, state.expected) {
			continue
		}
		distance := pending.sequence - state.expected
		if lowestIndex == -1 || distance < lowestDistance {
			lowestIndex = index
			lowestDistance = distance
		}
	}
	if lowestIndex == -1 {
		state.gapStarted = time.Time{}
		return
	}
	pending := state.pending[lowestIndex]
	state.pending[lowestIndex] = state.pending[len(state.pending)-1]
	state.pending = state.pending[:len(state.pending)-1]
	r.pendingDownlink--
	state.expected = pending.sequence + 1
	*ready = append(*ready, pending.packet)
	state.gapStarted = time.Time{}
	r.drainContiguousDownlink(state, ready)
	if len(state.pending) > 0 {
		state.gapStarted = now
	}
}

func (r *csqttRuntime) drainContiguousDownlink(state *csqttFlowReassemblyState, ready *[][]byte) {
	for {
		index := -1
		for candidate, pending := range state.pending {
			if pending.sequence == state.expected {
				index = candidate
				break
			}
		}
		if index == -1 {
			return
		}
		pending := state.pending[index]
		state.pending[index] = state.pending[len(state.pending)-1]
		state.pending = state.pending[:len(state.pending)-1]
		r.pendingDownlink--
		state.expected++
		*ready = append(*ready, pending.packet)
	}
}

func csqttSequenceForward(sequence, expected uint32) bool {
	return sequence != expected && sequence-expected < 1<<31
}

func csqttTCPFlowID(packet []byte) (uint64, bool) {
	if len(packet) == 0 {
		return 0, false
	}
	var headerLen int
	var protocol byte
	var source, destination []byte
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 {
			return 0, false
		}
		headerLen = int(packet[0]&0x0f) * 4
		if headerLen < 20 || len(packet) < headerLen+20 {
			return 0, false
		}
		protocol = packet[9]
		source, destination = packet[12:16], packet[16:20]
	case 6:
		if len(packet) < 60 {
			return 0, false
		}
		headerLen = 40
		protocol = packet[6]
		source, destination = packet[8:24], packet[24:40]
	default:
		return 0, false
	}
	if protocol != 6 {
		return 0, false
	}
	tcp := packet[headerLen:]
	dataOffset := int(tcp[12]>>4) * 4
	if dataOffset < 20 || len(tcp) < dataOffset {
		return 0, false
	}
	if len(tcp) == dataOffset && tcp[13]&0x03 == 0 {
		return 0, false
	}
	hash := uint64(0xcbf29ce484222325)
	csqttHashBytes(&hash, []byte{protocol})
	csqttHashBytes(&hash, source)
	csqttHashBytes(&hash, destination)
	csqttHashBytes(&hash, tcp[:4])
	return csqttMix64(hash), true
}

func csqttHashBytes(hash *uint64, value []byte) {
	for _, current := range value {
		*hash ^= uint64(current)
		*hash *= 0x100000001b3
	}
}

func csqttMix64(value uint64) uint64 {
	value ^= value >> 30
	value *= 0xbf58476d1ce4e5b9
	value ^= value >> 27
	value *= 0x94d049bb133111eb
	return value ^ (value >> 31)
}

func csqttRandomSenderID() uint64 {
	var seed [8]byte
	if _, err := rand.Read(seed[:]); err == nil {
		if value := binary.BigEndian.Uint64(seed[:]); value != 0 {
			return value
		}
	}
	value := csqttMix64(uint64(time.Now().UnixNano()))
	if value == 0 {
		return 1
	}
	return value
}

func isCSQTTControlPacket(payload []byte) bool {
	text := string(payload)
	return strings.HasPrefix(text, "TUNCONF:") ||
		strings.HasPrefix(text, "DENIED:") ||
		bytes.HasPrefix(payload, csqttStreamRepairPrefix) ||
		bytes.HasPrefix(payload, csqttStreamAlivePrefix) ||
		text == "NOCONF" ||
		text == "READY_OK" ||
		text == "OK:disconnected"
}

func isCSQTTKeepalivePacket(payload []byte) bool {
	if len(payload) != csqttKeepaliveSize {
		return false
	}
	for _, value := range payload {
		if value != csqttKeepaliveByte {
			return false
		}
	}
	return true
}

func deriveCSQTTWrapKey(password string) ([]byte, error) {
	if strings.TrimSpace(password) == "" {
		return nil, errors.New("csqtt: empty password")
	}
	key := make([]byte, csqttWrapKeyLen)
	reader := hkdf.New(sha256.New, []byte(password), []byte("CSQTT-WRAP-v1"), []byte("rtp-obfs/chacha20poly1305"))
	if _, err := io.ReadFull(reader, key); err != nil {
		return nil, fmt.Errorf("csqtt: derive wrap key: %w", err)
	}
	return key, nil
}

func newCSQTTObfsPacketConn(base net.PacketConn, peer net.Addr, password string) (*csqttObfsPacketConn, error) {
	key, err := deriveCSQTTWrapKey(password)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, fmt.Errorf("csqtt: aead init: %w", err)
	}
	var seed [16]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return nil, fmt.Errorf("csqtt: random seed: %w", err)
	}
	return &csqttObfsPacketConn{
		base:               base,
		peer:               peer,
		aead:               aead,
		ssrc:               uint32(seed[0])<<24 | uint32(seed[1])<<16 | uint32(seed[2])<<8 | uint32(seed[3]),
		startedAt:          time.Now(),
		initialSeq:         uint16(seed[4])<<8 | uint16(seed[5]),
		initialTS:          uint32(seed[6])<<24 | uint32(seed[7])<<16 | uint32(seed[8])<<8 | uint32(seed[9]),
		initialAbsSendTime: uint32(seed[10])<<16 | uint32(seed[11])<<8 | uint32(seed[12]),
		transportSeq:       uint16(seed[13])<<8 | uint16(seed[14]),
		txBuf:              make([]byte, csqttMaxPacketSize),
		rxBuf:              make([]byte, csqttMaxPacketSize),
	}, nil
}

func (c *csqttObfsPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	c.rxMu.Lock()
	defer c.rxMu.Unlock()
	count, addr, err := c.base.ReadFrom(c.rxBuf)
	if err != nil {
		return 0, addr, err
	}
	if count < csqttHeaderLen+csqttTagLen+1 {
		return 0, addr, errors.New("csqtt: short RTP packet")
	}
	wire := c.rxBuf[:count]
	if wire[0]>>6 != 2 || (wire[1]&0x7f) != csqttPayloadTypeAudio {
		return 0, addr, errors.New("csqtt: unsupported RTP packet")
	}
	paddingTotal := int(wire[len(wire)-1])
	if paddingTotal <= 0 || paddingTotal > len(wire)-csqttHeaderLen-csqttTagLen {
		return 0, addr, errors.New("csqtt: invalid RTP padding")
	}
	payloadEnd := len(wire) - paddingTotal
	tagStart := payloadEnd - csqttTagLen
	if tagStart <= csqttHeaderLen {
		return 0, addr, errors.New("csqtt: invalid payload bounds")
	}
	sequence := uint16(wire[2])<<8 | uint16(wire[3])
	timestamp := uint32(wire[4])<<24 | uint32(wire[5])<<16 | uint32(wire[6])<<8 | uint32(wire[7])
	ssrc := uint32(wire[8])<<24 | uint32(wire[9])<<16 | uint32(wire[10])<<8 | uint32(wire[11])
	var nonce [12]byte
	csqttBuildNonce(&nonce, ssrc, sequence, timestamp)
	plain, err := c.aead.Open(nil, nonce[:], wire[csqttHeaderLen:tagStart], wire[:csqttHeaderLen])
	if err != nil {
		return 0, addr, fmt.Errorf("csqtt: obfs auth failed: %w", err)
	}
	if len(plain) > len(p) {
		return 0, addr, io.ErrShortBuffer
	}
	copy(p, plain)
	return len(plain), addr, nil
}

func (c *csqttObfsPacketConn) WriteTo(payload []byte, _ net.Addr) (int, error) {
	if len(payload) == 0 {
		return 0, errors.New("csqtt: empty payload")
	}
	c.txMu.Lock()
	defer c.txMu.Unlock()

	sequence := c.initialSeq
	c.initialSeq++
	elapsed := time.Since(c.startedAt)
	timestamp := c.initialTS + uint32(elapsed.Milliseconds())*48
	transportSeq := c.transportSeq
	c.transportSeq++
	absoluteSendTime := (c.initialAbsSendTime + uint32(elapsed.Nanoseconds()/3814)) & 0x00ff_ffff

	paddingRandom := 0
	if csqttPaddingMax > 0 {
		var rnd [1]byte
		if _, err := rand.Read(rnd[:]); err != nil {
			return 0, err
		}
		paddingRandom = int(rnd[0]) % csqttPaddingMax
	}
	paddingTotal := paddingRandom + 1
	wireLen := csqttHeaderLen + len(payload) + csqttTagLen + paddingTotal
	if wireLen > len(c.txBuf) {
		return 0, io.ErrShortBuffer
	}
	wire := c.txBuf[:wireLen]
	for index := range wire {
		wire[index] = 0
	}
	wire[0] = 0xb0
	wire[1] = csqttPayloadTypeAudio
	wire[2] = byte(sequence >> 8)
	wire[3] = byte(sequence)
	wire[4] = byte(timestamp >> 24)
	wire[5] = byte(timestamp >> 16)
	wire[6] = byte(timestamp >> 8)
	wire[7] = byte(timestamp)
	wire[8] = byte(c.ssrc >> 24)
	wire[9] = byte(c.ssrc >> 16)
	wire[10] = byte(c.ssrc >> 8)
	wire[11] = byte(c.ssrc)
	wire[12] = 0xbe
	wire[13] = 0xde
	wire[14] = 0x00
	wire[15] = 0x02
	wire[16] = 0x32
	wire[17] = byte(absoluteSendTime >> 16)
	wire[18] = byte(absoluteSendTime >> 8)
	wire[19] = byte(absoluteSendTime)
	wire[20] = 0x51
	wire[21] = byte(transportSeq >> 8)
	wire[22] = byte(transportSeq)
	var nonce [12]byte
	csqttBuildNonce(&nonce, c.ssrc, sequence, timestamp)
	sealed := c.aead.Seal(wire[csqttHeaderLen:csqttHeaderLen], nonce[:], payload, wire[:csqttHeaderLen])
	copy(wire[csqttHeaderLen:], sealed)
	paddingStart := csqttHeaderLen + len(payload) + csqttTagLen
	if paddingRandom > 0 {
		if _, err := rand.Read(wire[paddingStart : paddingStart+paddingRandom]); err != nil {
			return 0, err
		}
	}
	wire[wireLen-1] = byte(paddingTotal)
	if _, err := c.base.WriteTo(wire, c.peer); err != nil {
		return 0, err
	}
	return len(payload), nil
}

func (c *csqttObfsPacketConn) Close() error                       { return c.base.Close() }
func (c *csqttObfsPacketConn) LocalAddr() net.Addr                { return c.base.LocalAddr() }
func (c *csqttObfsPacketConn) SetDeadline(t time.Time) error      { return c.base.SetDeadline(t) }
func (c *csqttObfsPacketConn) SetReadDeadline(t time.Time) error  { return c.base.SetReadDeadline(t) }
func (c *csqttObfsPacketConn) SetWriteDeadline(t time.Time) error { return c.base.SetWriteDeadline(t) }

func csqttBuildNonce(dst *[12]byte, ssrc uint32, seq uint16, timestamp uint32) {
	dst[0] = byte(ssrc >> 24)
	dst[1] = byte(ssrc >> 16)
	dst[2] = byte(ssrc >> 8)
	dst[3] = byte(ssrc)
	dst[4] = byte(seq >> 8)
	dst[5] = byte(seq)
	dst[6] = 0
	dst[7] = 0
	dst[8] = byte(timestamp >> 24)
	dst[9] = byte(timestamp >> 16)
	dst[10] = byte(timestamp >> 8)
	dst[11] = byte(timestamp)
}

//export VBridgeWGWaitCSQTTProvision
func VBridgeWGWaitCSQTTProvision(tunnelHandle C.int32_t, timeoutMs C.int32_t) *C.char {
	id := int32(tunnelHandle)
	tunnelsMu.Lock()
	entry, ok := tunnels[id]
	tunnelsMu.Unlock()
	if !ok || entry.csqtt == nil {
		log.Printf("VBridgeWGWaitCSQTTProvision: tunnel %d missing csqtt entry", id)
		return C.CString("")
	}
	timeout := time.Duration(int64(timeoutMs)) * time.Millisecond
	startedAt := time.Now()
	log.Printf("VBridgeWGWaitCSQTTProvision: tunnel %d wait start timeout=%s", id, timeout)
	provision, err := entry.csqtt.WaitProvision(timeout)
	if err != nil {
		log.Printf("VBridgeWGWaitCSQTTProvision: tunnel %d failed after %s: %v", id, time.Since(startedAt).Round(10*time.Millisecond), err)
		return C.CString("")
	}
	data, err := json.Marshal(provision)
	if err != nil {
		log.Printf("VBridgeWGWaitCSQTTProvision: tunnel %d marshal: %v", id, err)
		return C.CString("")
	}
	log.Printf("VBridgeWGWaitCSQTTProvision: tunnel %d ready after %s address=%s mtu=%d", id, time.Since(startedAt).Round(10*time.Millisecond), provision.Address, provision.MTU)
	return C.CString(string(data))
}

//export VBridgeWGAttachCSQTT
func VBridgeWGAttachCSQTT(tunnelHandle C.int32_t, tunFd C.int32_t) C.int32_t {
	id := int32(tunnelHandle)
	tunnelsMu.Lock()
	entry, ok := tunnels[id]
	tunnelsMu.Unlock()
	if !ok || entry.csqtt == nil {
		log.Printf("VBridgeWGAttachCSQTT: tunnel %d missing csqtt entry", id)
		return -1
	}
	log.Printf("VBridgeWGAttachCSQTT: tunnel %d attach start tunFd=%d", id, int32(tunFd))
	if err := entry.csqtt.AttachTUN(int32(tunFd)); err != nil {
		log.Printf("VBridgeWGAttachCSQTT: tunnel %d: %v", id, err)
		return -2
	}
	log.Printf("VBridgeWGAttachCSQTT: tunnel %d TUN attached", id)
	return 1
}
