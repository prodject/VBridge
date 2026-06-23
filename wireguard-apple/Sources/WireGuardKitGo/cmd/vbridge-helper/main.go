package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/amnezia-vpn/amneziawg-apple/pkg/proxy"
	"github.com/amnezia-vpn/amneziawg-apple/pkg/turnbind"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

const (
	listenAddress = "127.0.0.1:41737"
	stateDir      = "/Library/Application Support/VBridge"
	routeStatePath = stateDir + "/active-route.json"
	logPath       = "/Users/Shared/VBridge/vpn_tunnel.log"
)

type tunnelStartConfiguration struct {
	VKLink          string      `json:"vkLink"`
	PeerAddr        string      `json:"peerAddr"`
	ListenAddr       string      `json:"listenAddr"`
	NValue          int         `json:"nValue"`
	CredsGroupSize  int         `json:"credsGroupSize"`
	WgQuickConfig   string      `json:"wgQuickConfig"`
	TurnHost        string      `json:"turnHost"`
	TurnPort        string      `json:"turnPort"`
	UseUDP          bool        `json:"useUdp"`
	TransportMode   string      `json:"transportMode"`
	WrapKeyHex      string      `json:"wrapKeyHex"`
	WDTTPassword    string      `json:"wdttPassword"`
	WDTTClientKey   string      `json:"wdttClientKey"`
	WDTTServerKey   string      `json:"wdttServerKey"`
	SeededTURN      *seededTURN `json:"seededTURN"`
}

type seededTURN struct {
	Address  string `json:"address"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type activeTunnel struct {
	device       *device.Device
	proxy        *proxy.Proxy
	interfaceName string
	turnServerIP string
	defaultGateway string
	routesApplied bool
}

type routeState struct {
	InterfaceName  string `json:"interfaceName"`
	TurnServerIP   string `json:"turnServerIP"`
	DefaultGateway string `json:"defaultGateway"`
}

type helperServer struct {
	mu     sync.Mutex
	active *activeTunnel
}

func main() {
	setupLogging()
	log.Printf("vbridge-helper starting on %s", listenAddress)
	cleanupPersistedRoutes()
	cleanupStaleUtunDefaultRoutes()

	server := &helperServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/tunnel/start", server.handleStart)
	mux.HandleFunc("/v1/tunnel/stop", server.handleStop)
	mux.HandleFunc("/v1/tunnel/status", server.handleStatus)

	httpServer := &http.Server{
		Addr:              listenAddress,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("vbridge-helper stopped: %v", err)
	}
}

func setupLogging() {
	_ = os.MkdirAll(filepath.Dir(logPath), 0o755)
	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Printf("open helper log failed: %v", err)
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, file))
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
}

func (s *helperServer) handleStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isLoopbackRemote(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	var cfg tunnelStartConfiguration
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		http.Error(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if s.active != nil {
		s.stopLocked()
	}

	tunnel, err := startTunnel(r.Context(), cfg)
	if err != nil {
		log.Printf("start failed: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.active = tunnel

	writeJSON(w, map[string]string{
		"status":       "started",
		"interface":    tunnel.interfaceName,
		"turnServerIP": tunnel.turnServerIP,
	})
}

func (s *helperServer) handleStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !isLoopbackRemote(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopLocked()
	writeJSON(w, map[string]string{"status": "stopped"})
}

func (s *helperServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	if !isLoopbackRemote(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active == nil {
		writeJSON(w, map[string]string{"status": "stopped"})
		return
	}
	writeJSON(w, map[string]string{
		"status":       "started",
		"interface":    s.active.interfaceName,
		"turnServerIP": s.active.turnServerIP,
	})
}

func (s *helperServer) stopLocked() {
	if s.active == nil {
		return
	}
	t := s.active
	s.active = nil

	log.Printf("stopping tunnel interface=%s turn=%s", t.interfaceName, t.turnServerIP)
	cleanupRoutes(t.interfaceName, t.turnServerIP)
	if t.proxy != nil {
		t.proxy.StopWithTimeout(2 * time.Second)
	}
	if t.device != nil {
		t.device.Close()
	}
	clearRouteState()
}

func startTunnel(ctx context.Context, cfg tunnelStartConfiguration) (*activeTunnel, error) {
	if cfg.TransportMode != "wdtt" {
		return nil, fmt.Errorf("macOS helper currently supports WDTT mode only; got %q", cfg.TransportMode)
	}
	if cfg.PeerAddr == "" {
		return nil, errors.New("peerAddr is empty")
	}
	if cfg.WDTTPassword == "" {
		return nil, errors.New("wdttPassword is empty")
	}

	defaultGateway, err := currentDefaultGateway()
	if err != nil {
		return nil, fmt.Errorf("read default gateway: %w", err)
	}

	p, err := newProxy(cfg)
	if err != nil {
		return nil, err
	}
	var tunDevice tun.Device
	var dev *device.Device
	var interfaceName string
	var turnServerIP string
	routesApplied := false
	startSucceeded := false
	defer func() {
		if startSucceeded {
			return
		}
		if routesApplied || interfaceName != "" || turnServerIP != "" {
			cleanupRoutes(interfaceName, turnServerIP)
			clearRouteState()
		}
		if dev != nil {
			dev.Close()
		} else if tunDevice != nil {
			tunDevice.Close()
		}
		p.StopWithTimeout(2 * time.Second)
	}()

	errCh := make(chan error, 1)
	go func() {
		errCh <- p.Start()
	}()

	if err := waitBootstrap(ctx, p, errCh, 120*time.Second); err != nil {
		return nil, err
	}

	turnServerIP = p.TURNServerIP()
	if turnServerIP == "" {
		return nil, errors.New("TURN server IP is empty after bootstrap")
	}

	provision, err := p.WaitWrapAProvision(30 * time.Second)
	if err != nil {
		return nil, fmt.Errorf("wait WDTT provision: %w", err)
	}

	mtu := provision.MTU
	if mtu <= 0 {
		mtu = 1280
	}
	tunDevice, err = tun.CreateTUN("utun", mtu)
	if err != nil {
		return nil, fmt.Errorf("create utun: %w", err)
	}

	interfaceName, err = tunDevice.Name()
	if err != nil {
		return nil, fmt.Errorf("read utun name: %w", err)
	}

	if err := configureInterface(interfaceName, provision.Address, mtu); err != nil {
		return nil, err
	}

	bind := turnbind.NewTURNBind(p)
	logger := device.NewLogger(device.LogLevelVerbose, "(vbridge-helper/wireguard) ")
	dev = device.NewDevice(tunDevice, bind, logger)
	tunDevice = nil
	if err := dev.IpcSet(provision.UAPIConfig()); err != nil {
		return nil, fmt.Errorf("wireguard ipc set: %w", err)
	}
	if err := dev.Up(); err != nil {
		return nil, fmt.Errorf("wireguard up: %w", err)
	}
	if err := applyRoutes(interfaceName, turnServerIP, defaultGateway); err != nil {
		return nil, err
	}
	routesApplied = true
	writeRouteState(interfaceName, turnServerIP, defaultGateway)

	if provision.DNS != "" {
		log.Printf("DNS requested by server: %s (not applied globally by helper yet)", provision.DNS)
	}

	log.Printf("tunnel started interface=%s address=%s dns=%s mtu=%d turn=%s gateway=%s", interfaceName, provision.Address, provision.DNS, mtu, turnServerIP, defaultGateway)
	startSucceeded = true
	return &activeTunnel{
		device:         dev,
		proxy:          p,
		interfaceName:  interfaceName,
		turnServerIP:   turnServerIP,
		defaultGateway: defaultGateway,
		routesApplied:  routesApplied,
	}, nil
}

func newProxy(cfg tunnelStartConfiguration) (*proxy.Proxy, error) {
	deviceID, err := persistedDeviceID()
	if err != nil {
		return nil, err
	}

	var seeded *proxy.TURNCreds
	if cfg.SeededTURN != nil && cfg.SeededTURN.Address != "" {
		seeded = &proxy.TURNCreds{
			Address:  cfg.SeededTURN.Address,
			Username: cfg.SeededTURN.Username,
			Password: cfg.SeededTURN.Password,
		}
	}

	numConns := cfg.NValue
	if numConns <= 0 {
		numConns = 1
	}

	return proxy.NewProxy(proxy.Config{
		PeerAddr:         cfg.PeerAddr,
		TurnServer:       cfg.TurnHost,
		TurnPort:         cfg.TurnPort,
		VKLink:           cfg.VKLink,
		UseDTLS:          false,
		UseUDP:           cfg.UseUDP,
		UseWrap:          false,
		UseSrtp:          false,
		UseWrapA:         true,
		WrapAPassword:    cfg.WDTTPassword,
		DeviceID:         deviceID,
		NumConns:         numConns,
		CredPoolCooldown: 120 * time.Second,
		SeededTURN:       seeded,
		CredCachePath:    filepath.Join(stateDir, "creds-pool.json"),
	}), nil
}

func waitBootstrap(ctx context.Context, p *proxy.Proxy, errCh <-chan error, timeout time.Duration) error {
	done := make(chan error, 1)
	go func() {
		done <- p.WaitBootstrap(timeout)
	}()

	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("bootstrap: %w", err)
		}
		return nil
	case err := <-errCh:
		if err != nil {
			return fmt.Errorf("proxy start: %w", err)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func configureInterface(interfaceName, address string, mtu int) error {
	ip, prefix, err := splitCIDR(address)
	if err != nil {
		return err
	}
	netmask := prefixToNetmask(prefix)

	if err := runCommand("ifconfig", interfaceName, "inet", ip, ip, "netmask", netmask, "mtu", strconv.Itoa(mtu), "up"); err != nil {
		return fmt.Errorf("configure %s: %w", interfaceName, err)
	}
	return nil
}

func applyRoutes(interfaceName, turnServerIP, defaultGateway string) error {
	if defaultGateway != "" && turnServerIP != "" {
		if err := runCommand("route", "add", "-host", turnServerIP, defaultGateway); err != nil {
			return fmt.Errorf("add TURN host route: %w", err)
		}
	}
	if err := runCommand("route", "add", "default", "-interface", interfaceName); err != nil {
		cleanupRoutes(interfaceName, turnServerIP)
		return fmt.Errorf("add default tunnel route: %w", err)
	}
	return nil
}

func cleanupRoutes(interfaceName, turnServerIP string) {
	if turnServerIP != "" {
		runCommand("route", "delete", "-host", turnServerIP)
	}
	if interfaceName != "" {
		runCommand("route", "delete", "default", "-interface", interfaceName)
	}
}

func writeRouteState(interfaceName, turnServerIP, defaultGateway string) {
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		log.Printf("write route state mkdir failed: %v", err)
		return
	}
	data, err := json.Marshal(routeState{
		InterfaceName:  interfaceName,
		TurnServerIP:   turnServerIP,
		DefaultGateway: defaultGateway,
	})
	if err != nil {
		log.Printf("write route state marshal failed: %v", err)
		return
	}
	if err := os.WriteFile(routeStatePath, data, 0o644); err != nil {
		log.Printf("write route state failed: %v", err)
	}
}

func cleanupPersistedRoutes() {
	data, err := os.ReadFile(routeStatePath)
	if err != nil {
		return
	}
	var state routeState
	if err := json.Unmarshal(data, &state); err != nil {
		log.Printf("route state invalid, removing: %v", err)
		clearRouteState()
		return
	}
	log.Printf("cleaning persisted route state interface=%s turn=%s", state.InterfaceName, state.TurnServerIP)
	cleanupRoutes(state.InterfaceName, state.TurnServerIP)
	clearRouteState()
}

func clearRouteState() {
	if err := os.Remove(routeStatePath); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("remove route state failed: %v", err)
	}
}

func cleanupStaleUtunDefaultRoutes() {
	for i := 0; i < 32; i++ {
		runCommand("route", "delete", "default", "-interface", fmt.Sprintf("utun%d", i))
	}
}

func currentDefaultGateway() (string, error) {
	out, err := exec.Command("route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "gateway:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "gateway:")), nil
		}
	}
	return "", errors.New("gateway not found in route output")
}

func splitCIDR(address string) (string, int, error) {
	ip, ipNet, err := net.ParseCIDR(address)
	if err != nil {
		parsed := net.ParseIP(address)
		if parsed == nil {
			return "", 0, fmt.Errorf("invalid tunnel address %q", address)
		}
		return parsed.String(), 32, nil
	}
	ones, _ := ipNet.Mask.Size()
	return ip.String(), ones, nil
}

func prefixToNetmask(prefix int) string {
	if prefix < 0 {
		prefix = 0
	}
	if prefix > 32 {
		prefix = 32
	}
	var mask uint32
	for i := 0; i < prefix; i++ {
		mask |= 1 << (31 - i)
	}
	return fmt.Sprintf("%d.%d.%d.%d", byte(mask>>24), byte(mask>>16), byte(mask>>8), byte(mask))
}

func persistedDeviceID() (string, error) {
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return "", fmt.Errorf("create state dir: %w", err)
	}
	path := filepath.Join(stateDir, "wdtt-device-id")
	if data, err := os.ReadFile(path); err == nil {
		value := strings.TrimSpace(string(data))
		if value != "" {
			return value, nil
		}
	}

	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", fmt.Errorf("generate device id: %w", err)
	}
	value := hex.EncodeToString(random[:])
	if err := os.WriteFile(path, []byte(value+"\n"), 0o644); err != nil {
		return "", fmt.Errorf("write device id: %w", err)
	}
	return value, nil
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	if len(output) > 0 {
		log.Printf("%s %s: %s", name, strings.Join(args, " "), strings.TrimSpace(string(output)))
	}
	return nil
}

func isLoopbackRemote(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}
