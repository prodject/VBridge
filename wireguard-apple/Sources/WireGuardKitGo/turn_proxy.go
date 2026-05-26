package main

/*
#include <stdlib.h>

typedef void(*proxy_logger_fn_t)(void *context, int level, const char *msg);
typedef void(*proxy_captcha_fn_t)(void *context, const char *msg);

static inline void call_proxy_logger(proxy_logger_fn_t fn, void *ctx, int level, const char *msg) {
    if (fn != NULL) {
        fn(ctx, level, msg);
    }
}

static inline void call_proxy_captcha(proxy_captcha_fn_t fn, void *ctx, const char *msg) {
    if (fn != NULL) {
        fn(ctx, msg);
    }
}
*/
import "C" 

import (
    "bytes"
    "context"
    "crypto/tls"
    "encoding/json"
    "errors"
    "fmt"
    "io"
	"log"
	"net"
	"net/http"
	mathrand "math/rand"
	"sync"
    "sync/atomic"
    "time"
    "unsafe"
    "strings"

    "github.com/cbeuw/connutil"
    "github.com/google/uuid"
    "github.com/pion/dtls/v3"
    "github.com/pion/dtls/v3/pkg/crypto/selfsign"
    "github.com/pion/logging"
    "github.com/pion/turn/v5"
)

var proxyLoggerFunc C.proxy_logger_fn_t
var proxyLoggerCtx unsafe.Pointer
var proxyCaptchaFunc C.proxy_captcha_fn_t
var proxyCaptchaCtx unsafe.Pointer
var proxyCancel context.CancelFunc
var manualCaptchaOnly atomic.Bool
var proxyStateMu sync.Mutex
var proxyDone chan struct{}
var proxyStartFailed chan struct{}
var proxyRuntimeMu sync.Mutex
var proxyRuntime *proxyRuntimeState

const relayPacketBufferSize = 64 * 1024
const (
	// Pace worker launches to avoid bursty credential/ TURN allocation spikes.
	workerSpawnBaseDelay     = 350 * time.Millisecond
	workerSpawnDelayJitter   = 250 * time.Millisecond
	workerSpawnBatchSize     = 4
	workerSpawnBatchCooldown = 2 * time.Second
	quotaRetryCooldown       = 5 * time.Second
	workerReconnectBackoff   = 1500 * time.Millisecond
)

type proxyRuntimeState struct {
    ctx            context.Context
    peer           *net.UDPAddr
    params         *turnParams
    listenConnChan chan net.PacketConn
    connchan       chan net.PacketConn
    tick           <-chan time.Time
    wg             *sync.WaitGroup
    readyChan      chan struct{}
    targetWorkers  int32
    workerCount    atomic.Int32
    connectedWorkers atomic.Int32
    increaseAckMu  sync.Mutex
    increaseAck    chan error
}

//export ProxySetLogger
func ProxySetLogger(context unsafe.Pointer, loggerFn C.proxy_logger_fn_t) {
    proxyLoggerCtx = context
    proxyLoggerFunc = loggerFn
}

//export ProxySetCaptchaCallback
func ProxySetCaptchaCallback(context unsafe.Pointer, captchaFn C.proxy_captcha_fn_t) {
    proxyCaptchaCtx = context
    proxyCaptchaFunc = captchaFn
}

var proxyReady = make(chan struct{}, 1)

//export ProxyWaitReady
func ProxyWaitReady(timeoutMs C.int) C.int {
    proxyStateMu.Lock()
    done := proxyDone
    startFailed := proxyStartFailed
    proxyStateMu.Unlock()

    if done != nil {
        select {
        case <-done:
            return 0
        default:
        }
    }

    select {
    case <-done:
        return 0
    case <-startFailed:
        return 0
    case <-proxyReady:
        if done != nil {
            select {
            case <-done:
                return 0
            default:
            }
        }
        return 1
    case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
        return 0
    }
}

func signalProxyStartFailure() {
    proxyStateMu.Lock()
    failed := proxyStartFailed
    proxyStateMu.Unlock()

    if failed != nil {
        select {
        case failed <- struct{}{}:
        default:
        }
    }

    if proxyCancel != nil {
        proxyCancel()
    }
}

func spawnProxyWorkerPair(rt *proxyRuntimeState, signalReady bool) {
    if rt == nil || rt.wg == nil {
        return
    }

    var okchan chan<- struct{}
    if signalReady {
        okchan = rt.readyChan
    }

    rt.wg.Go(func() {
        oneDtlsConnectionLoop(rt.ctx, rt.peer, rt.listenConnChan, rt.connchan, okchan)
    })
    rt.wg.Go(func() {
        oneTurnConnectionLoop(rt.ctx, rt.params, rt.peer, rt.connchan, rt.tick)
    })
	rt.workerCount.Add(1)
}

func sleepWithContext(ctx context.Context, delay time.Duration) bool {
	if delay <= 0 {
		return true
	}

	timer := time.NewTimer(delay)
	defer func() {
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
	}()

	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func workerSpawnDelay(spawned int) time.Duration {
	delay := workerSpawnBaseDelay + time.Duration(mathrand.Int63n(int64(workerSpawnDelayJitter/time.Millisecond+1)))*time.Millisecond
	if spawned > 0 && spawned%workerSpawnBatchSize == 0 {
		delay += workerSpawnBatchCooldown
	}
	return delay
}

func ceilDiv(value, divisor int) int {
	if divisor <= 0 {
		return value
	}
	return (value + divisor - 1) / divisor
}

func setProxyRuntime(rt *proxyRuntimeState) {
    proxyRuntimeMu.Lock()
    proxyRuntime = rt
    proxyRuntimeMu.Unlock()
}

func getProxyRuntime() *proxyRuntimeState {
    proxyRuntimeMu.Lock()
    defer proxyRuntimeMu.Unlock()
    return proxyRuntime
}

func (rt *proxyRuntimeState) setIncreaseAck(ch chan error) {
    rt.increaseAckMu.Lock()
    rt.increaseAck = ch
    rt.increaseAckMu.Unlock()
}

func (rt *proxyRuntimeState) deliverIncreaseAck(err error) {
    rt.increaseAckMu.Lock()
    ch := rt.increaseAck
    rt.increaseAck = nil
    rt.increaseAckMu.Unlock()

    if ch == nil {
        return
    }

    select {
    case ch <- err:
    default:
    }
}

func isAllocationQuotaError(err error) bool {
    if err == nil {
        return false
    }
    msg := strings.ToLower(err.Error())
    return strings.Contains(msg, "error 486") || strings.Contains(msg, "allocation quota reached")
}

type ProxyLogger int

func (l ProxyLogger) Write(p []byte) (n int, err error) {
    if proxyLoggerFunc == nil {
        return len(p), nil
    }

    cleanMsg := bytes.TrimRight(p, "\n")
    cMsg := C.CString(string(cleanMsg))
    defer C.free(unsafe.Pointer(cMsg))

    C.call_proxy_logger(proxyLoggerFunc, proxyLoggerCtx, C.int(l), cMsg)

    return len(p), nil
}

func notifyCaptchaRequired(mode string, captchaURL string, directURL string, message string) {
    if proxyCaptchaFunc == nil {
        return
    }

    payload, err := json.Marshal(map[string]string{
        "id":         uuid.NewString(),
        "mode":       mode,
        "url":        captchaURL,
        "direct_url": directURL,
        "message":    message,
    })
    if err != nil {
        log.Printf("[Captcha] Failed to encode manual fallback payload: %v", err)
        return
    }

    cMsg := C.CString(string(payload))
    defer C.free(unsafe.Pointer(cMsg))

    C.call_proxy_captcha(proxyCaptchaFunc, proxyCaptchaCtx, cMsg)
}

func init() {
    log.SetFlags(0)
    log.SetOutput(ProxyLogger(0))
}

type getCredsFunc func(string) (*turnCred, error)

type VKCredentials struct {
	ClientID     string
	ClientSecret string
}

var vkCredentialsList = []VKCredentials{
	{ClientID: "6287487", ClientSecret: "QbYic1K3lEV5kTGiqlq2"},
	{ClientID: "7879029", ClientSecret: "aR5NKGmm03GYrCiNKsaw"},
	{ClientID: "52461373", ClientSecret: "o557NLIkAErNhakXrQ7A"},
	{ClientID: "52649896", ClientSecret: "WStp4ihWG4l3nmXZgIbC"},
	{ClientID: "51781872", ClientSecret: "IjjCNl4L4Tf5QZEXIHKK"},
}

var (
	cachedSuccessToken string
	cachedTokenUsages  int32
	cacheMutex         sync.Mutex
)

func popCachedToken() string {
	cacheMutex.Lock()
	defer cacheMutex.Unlock()
	if cachedTokenUsages > 0 && cachedSuccessToken != "" {
		cachedTokenUsages--
		return cachedSuccessToken
	}
	return ""
}

func pushCachedToken(token string, usages int32) {
	if token == "" || usages <= 0 {
		return
	}
	cacheMutex.Lock()
	cachedSuccessToken = token
	cachedTokenUsages = usages
	cacheMutex.Unlock()
}

func invalidateCachedToken() {
	cacheMutex.Lock()
	cachedSuccessToken = ""
	cachedTokenUsages = 0
	cacheMutex.Unlock()
}

func applyBrowserProfile(req *http.Request, profile Profile) {
	req.Header.Set("User-Agent", profile.UserAgent)
	req.Header.Set("sec-ch-ua", profile.SecChUa)
	req.Header.Set("sec-ch-ua-mobile", profile.SecChUaMobile)
	req.Header.Set("sec-ch-ua-platform", profile.SecChUaPlatform)
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("DNT", "1")
}

func vkDelayRandom(minMs, maxMs int) {
	ms := minMs
	if maxMs > minMs {
		ms = minMs + mathrand.Intn(maxMs-minMs+1)
	}
	time.Sleep(time.Duration(ms) * time.Millisecond)
}

func getCreds(link string) (resCred *turnCred, resErr error) {
    profile := getRandomProfile()
    name := generateName()

    log.Printf("Connecting - Name: %s | UA: %s", name, profile.UserAgent)

	doRequest := func(data string, url string) (resp map[string]interface{}, err error) {

		client := &http.Client{
			Timeout: 20 * time.Second,
			Transport: &http.Transport{
				MaxIdleConns:        100,
				MaxIdleConnsPerHost: 100,
				IdleConnTimeout:     90 * time.Second,
			},
		}
		defer client.CloseIdleConnections()
		req, err := http.NewRequest("POST", url, bytes.NewBuffer([]byte(data)))
		if err != nil {
			return nil, err
		}

		applyBrowserProfile(req, profile)
		req.Header.Add("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Add("Accept", "*/*")
		req.Header.Add("Origin", "https://vk.ru")
		req.Header.Add("Referer", "https://vk.ru/")
		req.Header.Add("Sec-Fetch-Site", "same-site")
		req.Header.Add("Sec-Fetch-Mode", "cors")
		req.Header.Add("Sec-Fetch-Dest", "empty")
		req.Header.Add("Priority", "u=1, i")

		httpResp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer func() {
			if closeErr := httpResp.Body.Close(); closeErr != nil {
				log.Printf("close response body: %s", closeErr)
			}
		}()

		body, err := io.ReadAll(httpResp.Body)
		if err != nil {
			return nil, err
		}

		err = json.Unmarshal(body, &resp)
		if err != nil {
			return nil, err
		}

		return resp, nil
	}

	var resp map[string]interface{}
	var err error
	    defer func() {
	        if r := recover(); r != nil {
	            log.Printf("get TURN creds error (bad JSON?): %v\n\n", resp)
	            resErr = fmt.Errorf("panic in getCreds: %v", r)
	        }
    }()

	data := "client_id=6287487&token_type=messages&client_secret=QbYic1K3lEV5kTGiqlq2&version=1&app_id=6287487"
	url := "https://login.vk.ru/?act=get_anonym_token"

    var token1 string
    var token2 string
    const maxCaptchaAttempts = 3
    const previewURL = "https://api.vk.ru/method/calls.getCallPreview?v=5.275&client_id=%s"
    const anonymousURL = "https://api.vk.ru/method/calls.getAnonymousToken?v=5.275&client_id=%s"

    for _, creds := range vkCredentialsList {
        data = fmt.Sprintf("client_id=%s&token_type=messages&client_secret=%s&version=1&app_id=%s", creds.ClientID, creds.ClientSecret, creds.ClientID)
        url = "https://login.vk.ru/?act=get_anonym_token"

        resp, err = doRequest(data, url)
        if err != nil {
            log.Printf("[VK Auth] client_id=%s token1 failed: %v", creds.ClientID, err)
            continue
        }

        tokenData, ok := resp["data"].(map[string]interface{})
        if !ok {
            log.Printf("[VK Auth] client_id=%s invalid token1 response: %v", creds.ClientID, resp)
            continue
        }

        token1, ok = tokenData["access_token"].(string)
        if !ok || token1 == "" {
            log.Printf("[VK Auth] client_id=%s missing access_token", creds.ClientID)
            continue
        }

        vkDelayRandom(100, 150)

        previewData := fmt.Sprintf("vk_join_link=https://vk.com/call/join/%s&fields=photo_200&access_token=%s", link, token1)
        _, err = doRequest(previewData, fmt.Sprintf(previewURL, creds.ClientID))
        if err != nil {
            log.Printf("[VK Auth] Warning: getCallPreview failed for client_id=%s: %v", creds.ClientID, err)
        }

        vkDelayRandom(200, 400)

        data = buildAnonymousTokenPayload(link, name, token1, "", "", "", "", "")
        reqURL := fmt.Sprintf(anonymousURL, creds.ClientID)

        token2 = ""
        preferManualCaptcha := false
        usedCachedToken := false
        for attempt := 0; attempt <= maxCaptchaAttempts; attempt++ {
            usedCachedToken = false
            resp, err = doRequest(data, reqURL)
            if err != nil {
                log.Printf("[VK Auth] client_id=%s request failed: %v", creds.ClientID, err)
                break
            }

            if errObj, hasErr := resp["error"].(map[string]interface{}); hasErr {
                errCode, _ := errObj["error_code"].(float64)
                if errCode == 14 {
                    if attempt == maxCaptchaAttempts {
                        err = fmt.Errorf("captcha failed after %d attempts", maxCaptchaAttempts)
                        break
                    }

                    captchaErr := ParseVkCaptchaError(errObj)
                    if captchaErr.IsCaptchaError() {
                        log.Printf("[Captcha] Attempt %d/%d: solving...", attempt+1, maxCaptchaAttempts)

                        if manualCaptchaOnly.Load() || preferManualCaptcha {
                            if captchaErr.RedirectUri != "" {
                                if preferManualCaptcha && !manualCaptchaOnly.Load() {
                                    log.Printf("[Captcha] Auto solver failed on previous challenge; retrying with fresh manual proxy flow...")
                                } else {
                                    log.Printf("[Captcha] Manual captcha mode enabled; using proxy flow...")
                                }
                                successToken, solveErr := solveCaptchaViaProxy(captchaErr.RedirectUri)
                                if solveErr != nil {
                                    err = fmt.Errorf("manual captcha proxy solve error: %v", solveErr)
                                    break
                                }
                                pushCachedToken(successToken, 4)

                                if captchaErr.CaptchaAttempt == "0" || captchaErr.CaptchaAttempt == "" {
                                    captchaErr.CaptchaAttempt = "1"
                                }

                                data = buildAnonymousTokenPayload(
                                    link,
                                    name,
                                    token1,
                                    captchaErr.CaptchaSid,
                                    "",
                                    successToken,
                                    captchaErr.CaptchaTs,
                                    captchaErr.CaptchaAttempt,
                                )
                                preferManualCaptcha = false
                                continue
                            }

                            if captchaErr.CaptchaImg != "" {
                                if preferManualCaptcha && !manualCaptchaOnly.Load() {
                                    log.Printf("[Captcha] Auto solver failed on previous challenge; retrying with fresh manual image flow...")
                                } else {
                                    log.Printf("[Captcha] Manual captcha mode enabled; using image flow...")
                                }
                                captchaKey, solveErr := solveCaptchaViaHTTP(captchaErr.CaptchaImg)
                                if solveErr != nil {
                                    err = fmt.Errorf("manual captcha image solve error: %v", solveErr)
                                    break
                                }

                                data = buildAnonymousTokenPayload(
                                    link,
                                    name,
                                    token1,
                                    captchaErr.CaptchaSid,
                                    captchaKey,
                                    "",
                                    captchaErr.CaptchaTs,
                                    captchaErr.CaptchaAttempt,
                                )
                                preferManualCaptcha = false
                                continue
                            }

                            err = fmt.Errorf("manual captcha mode: no redirect_uri or captcha_img")
                            break
                        } else {
                            successToken := popCachedToken()
                            usedCachedToken = successToken != ""
                            if usedCachedToken {
                                log.Printf("[Captcha] Reusing cached success_token for a fresh VK group")
                            } else {
                                solveToken, solveErr := solveVkCaptcha(context.Background(), captchaErr)
                                if solveErr != nil {
                                    var retryErr *captchaManualRetryRequiredError
                                    if errors.As(solveErr, &retryErr) {
                                        preferManualCaptcha = true
                                        log.Printf("[Captcha] Automatic solver degraded the current challenge; requesting a fresh challenge for manual solve...")
                                        continue
                                    }
                                    err = fmt.Errorf("captcha solve error: %v", solveErr)
                                    break
                                }
                                successToken = solveToken
                                pushCachedToken(successToken, 4)
                            }

                            if captchaErr.CaptchaAttempt == "0" || captchaErr.CaptchaAttempt == "" {
                                captchaErr.CaptchaAttempt = "1"
                            }

                            data = buildAnonymousTokenPayload(
                                link,
                                name,
                                token1,
                                captchaErr.CaptchaSid,
                                "",
                                successToken,
                                captchaErr.CaptchaTs,
                                captchaErr.CaptchaAttempt,
                            )
                            if usedCachedToken {
                                preferManualCaptcha = false
                            }
                            continue
                        }
                    }
                }
                if errCode == 14 && usedCachedToken {
                    log.Printf("[Captcha] Cached success_token was rejected by VK; invalidating cache")
                    invalidateCachedToken()
                }
                err = fmt.Errorf("VK API error: %v", errObj)
                break
            }

            token2, _ = resp["response"].(map[string]interface{})["token"].(string)
            if token2 != "" {
                err = nil
                break
            }
            err = fmt.Errorf("missing token in response: %v", resp)
            break
        }

        if err == nil && token2 != "" {
            break
        }
    }

    if token2 == "" {
        return nil, fmt.Errorf("all VK credentials failed: %w", err)
    }

	data = fmt.Sprintf("%s%s%s", "session_data=%7B%22version%22%3A2%2C%22device_id%22%3A%22", uuid.New(), "%22%2C%22client_version%22%3A1.1%2C%22client_type%22%3A%22SDK_JS%22%7D&method=auth.anonymLogin&format=JSON&application_key=CGMMEJLGDIHBABABA")
	url = "https://calls.okcdn.ru/fb.do"

	resp, err = doRequest(data, url)
	if err != nil {
		return nil, fmt.Errorf("request error:%s", err)
	}

	token3 := resp["session_key"].(string)

	data = fmt.Sprintf("joinLink=%s&isVideo=false&protocolVersion=5&anonymToken=%s&method=vchat.joinConversationByLink&format=JSON&application_key=CGMMEJLGDIHBABABA&session_key=%s", link, token2, token3)
	url = "https://calls.okcdn.ru/fb.do"

	resp, err = doRequest(data, url)
	if err != nil {
		return nil, fmt.Errorf("request error:%s", err)
	}

	turnServer, ok := resp["turn_server"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing turn_server in response")
	}

	user, _ := turnServer["username"].(string)
	pass, _ := turnServer["credential"].(string)
	rawURLs, _ := turnServer["urls"].([]interface{})
	if user == "" || pass == "" || len(rawURLs) == 0 {
		return nil, fmt.Errorf("invalid turn_server payload")
	}

	var address string
	for _, rawURL := range rawURLs {
		turn, ok := rawURL.(string)
		if !ok || turn == "" {
			continue
		}
		clean := strings.Split(turn, "?")[0]
		address = strings.TrimPrefix(strings.TrimPrefix(clean, "turn:"), "turns:")
		if address != "" {
			break
		}
	}
	if address == "" {
		return nil, fmt.Errorf("no usable TURN URL in response")
	}

	lifetimeSeconds := 0
	if value, ok := turnServer["lifetime"].(float64); ok && value > 0 {
		lifetimeSeconds = int(value)
	} else if value, ok := turnServer["ttl"].(float64); ok && value > 0 {
		lifetimeSeconds = int(value)
	}

	return &turnCred{
		user:       user,
		pass:       pass,
		addr:       address,
		lifetime:   time.Duration(lifetimeSeconds) * time.Second,
		fetchedAt:  time.Now(),
	}, nil
}

func dtlsFunc(ctx context.Context, conn net.PacketConn, peer *net.UDPAddr) (net.Conn, error) {
    certificate, err := selfsign.GenerateSelfSigned()
    if err != nil {
        return nil, err
    }
    config := &dtls.Config{
        Certificates:          []tls.Certificate{certificate},
        InsecureSkipVerify:    true,
        ExtendedMasterSecret:  dtls.RequireExtendedMasterSecret,
        CipherSuites:          []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
        ConnectionIDGenerator: dtls.OnlySendCIDGenerator(),
    }
    ctx1, cancel := context.WithTimeout(ctx, 30*time.Second)
    defer cancel()
    dtlsConn, err := dtls.Client(conn, peer, config)
    if err != nil {
        return nil, err
    }

    if err := dtlsConn.HandshakeContext(ctx1); err != nil {
        if closeErr := dtlsConn.Close(); closeErr != nil {
            log.Printf("Failed to close DTLS connection after handshake error: %s", closeErr)
        }
        return nil, err
    }
    return dtlsConn, nil
}

const (
    dtlsHandshakeMaxAttempts = 3
    dtlsHandshakeBaseDelay   = 250 * time.Millisecond
    dtlsHandshakeMaxDelay    = 2 * time.Second
)

func dtlsRetryDelay(attempt int) time.Duration {
    if attempt < 1 {
        attempt = 1
    }

    delay := dtlsHandshakeBaseDelay << (attempt - 1)
    if delay > dtlsHandshakeMaxDelay {
        return dtlsHandshakeMaxDelay
    }
    return delay
}

func isTransientDTLSError(err error) bool {
    if err == nil {
        return false
    }

    if errors.Is(err, context.DeadlineExceeded) {
        return true
    }

    var netErr net.Error
    if errors.As(err, &netErr) && netErr.Timeout() {
        return true
    }

    return strings.Contains(strings.ToLower(err.Error()), "context deadline exceeded")
}

func oneDtlsConnection(ctx context.Context, peer *net.UDPAddr, listenConn net.PacketConn, connchan chan<- net.PacketConn, okchan chan<- struct{}, c1 chan<- error) {
	var err error = nil
	defer func() { c1 <- err }()
	dtlsctx, dtlscancel := context.WithCancel(ctx)
	defer dtlscancel()
	var conn1, conn2 net.PacketConn
	var dtlsConn net.Conn
	var err1 error
	var activeAttemptDone chan struct{}
	for attempt := 1; attempt <= dtlsHandshakeMaxAttempts; attempt++ {
		if dtlsctx.Err() != nil {
			err = dtlsctx.Err()
			return
		}

		conn1, conn2 = connutil.AsyncPacketPipe()
		attemptDone := make(chan struct{})
		go func(conn net.PacketConn, done <-chan struct{}) {
			select {
			case <-dtlsctx.Done():
				return
			case <-done:
				return
			case connchan <- conn:
			}
		}(conn2, attemptDone)

		dtlsConn, err1 = dtlsFunc(dtlsctx, conn1, peer)
		if err1 == nil {
			activeAttemptDone = attemptDone
			break
		}

		close(attemptDone)
		if closeErr := conn1.Close(); closeErr != nil {
			log.Printf("Failed to close DTLS retry pipe: %s", closeErr)
		}
		if closeErr := conn2.Close(); closeErr != nil {
			log.Printf("Failed to close DTLS retry pipe: %s", closeErr)
		}

		if !isTransientDTLSError(err1) || attempt == dtlsHandshakeMaxAttempts || dtlsctx.Err() != nil {
			err = fmt.Errorf("failed to connect DTLS after %d attempts: %w", attempt, err1)
			return
		}

		delay := dtlsRetryDelay(attempt)
		log.Printf("DTLS connect attempt %d/%d failed: %v; retrying in %s", attempt, dtlsHandshakeMaxAttempts, err1, delay)

		timer := time.NewTimer(delay)
		select {
		case <-dtlsctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			err = dtlsctx.Err()
			return
		case <-timer.C:
		}
	}
	if activeAttemptDone != nil {
		defer close(activeAttemptDone)
	}
	defer func() {
		if closeErr := dtlsConn.Close(); closeErr != nil {
			err = fmt.Errorf("failed to close DTLS connection: %s", closeErr)
			return
		}
		log.Printf("Closed DTLS connection\n")
	}()
	log.Printf("Established DTLS connection!\n")
    if rt := getProxyRuntime(); rt != nil {
        connectedWorkers := rt.connectedWorkers.Add(1)
        log.Printf("[Proxy] Connected workers %d/%d", connectedWorkers, rt.targetWorkers)
        defer func() {
            remainingWorkers := rt.connectedWorkers.Add(-1)
            if remainingWorkers < 0 {
                rt.connectedWorkers.Store(0)
                remainingWorkers = 0
            }
            log.Printf("[Proxy] Connected workers %d/%d", remainingWorkers, rt.targetWorkers)
        }()
    }
	select {
	case proxyReady <- struct{}{}:
	default:
	}
	go func() {
		for {
			select {
			case <-dtlsctx.Done():
				return
			case okchan <- struct{}{}:
			}
		}
	}()

	wg := sync.WaitGroup{}
    wg.Add(2)
    context.AfterFunc(dtlsctx, func() {
        listenConn.SetDeadline(time.Now())
        dtlsConn.SetDeadline(time.Now())
    })
    var addr atomic.Value
    go func() {
        defer wg.Done()
        defer dtlscancel()
        buf := make([]byte, relayPacketBufferSize)
        for {
            select {
            case <-dtlsctx.Done():
                return
            default:
            }
            n, addr1, err1 := listenConn.ReadFrom(buf)
            if err1 != nil {
                log.Printf("Failed: %s", err1)
                return
            }

            addr.Store(addr1)

            _, err1 = dtlsConn.Write(buf[:n])
            if err1 != nil {
                log.Printf("Failed: %s", err1)
                return
            }
        }
    }()

    go func() {
        defer wg.Done()
        defer dtlscancel()
        buf := make([]byte, relayPacketBufferSize)
        for {
            select {
            case <-dtlsctx.Done():
                return
            default:
            }
            n, err1 := dtlsConn.Read(buf)
            if err1 != nil {
                log.Printf("Failed: %s", err1)
                return
            }
            addr1, ok := addr.Load().(net.Addr)
            if !ok {
                log.Printf("Failed: no listener ip")
                return
            }

            _, err1 = listenConn.WriteTo(buf[:n], addr1)
            if err1 != nil {
                log.Printf("Failed: %s", err1)
                return
            }
        }
    }()

    wg.Wait()
    listenConn.SetDeadline(time.Time{})
    dtlsConn.SetDeadline(time.Time{})
}

type connectedUDPConn struct {
	*net.UDPConn
}

func (c *connectedUDPConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return c.Write(p)
}

type turnParams struct {
    host     string
    port     string
    link     string
    udp      bool
    getCreds getCredsFunc
    resetCreds func()
}

func oneTurnConnection(ctx context.Context, turnParams *turnParams, peer *net.UDPAddr, conn2 net.PacketConn, c chan<- error) {
	var err error = nil
	defer func() { c <- err }()
	cred, err1 := turnParams.getCreds(turnParams.link)
	if err1 != nil {
		err = fmt.Errorf("failed to get TURN credentials: %s", err1)
		return
	}
	user := cred.user
	pass := cred.pass
	url := cred.addr
	urlhost, urlport, err1 := net.SplitHostPort(url)
	if err1 != nil {
		err = fmt.Errorf("failed to parse TURN server address: %s", err1)
		return
	}
	if turnParams.host != "" {
		urlhost = turnParams.host
	}
	if turnParams.port != "" {
		urlport = turnParams.port
	}
	var turnServerAddr string
	turnServerAddr = net.JoinHostPort(urlhost, urlport)
	turnServerUdpAddr, err1 := net.ResolveUDPAddr("udp", turnServerAddr)
	if err1 != nil {
		err = fmt.Errorf("failed to resolve TURN server address: %s", err1)
		return
	}
	turnServerAddr = turnServerUdpAddr.String()
	fmt.Println(turnServerUdpAddr.IP)
	// Dial TURN Server
	var cfg *turn.ClientConfig
	var turnConn net.PacketConn
	var d net.Dialer
	ctx1, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if turnParams.udp {
		conn, err2 := net.DialUDP("udp", nil, turnServerUdpAddr) // nolint: noctx
		if err2 != nil {
			err = fmt.Errorf("failed to connect to TURN server: %s", err2)
			return
		}
		defer func() {
			if err1 = conn.Close(); err1 != nil {
				err = fmt.Errorf("failed to close TURN server connection: %s", err1)
				return
			}
		}()
		turnConn = &connectedUDPConn{conn}
	} else {
		conn, err2 := d.DialContext(ctx1, "tcp", turnServerAddr) // nolint: noctx
		if err2 != nil {
			err = fmt.Errorf("failed to connect to TURN server: %s", err2)
			return
		}
		defer func() {
			if err1 = conn.Close(); err1 != nil {
				err = fmt.Errorf("failed to close TURN server connection: %s", err1)
				return
			}
		}()
		turnConn = turn.NewSTUNConn(conn)
	}
	var addrFamily turn.RequestedAddressFamily
	if peer.IP.To4() != nil {
		addrFamily = turn.RequestedAddressFamilyIPv4
	} else {
		addrFamily = turn.RequestedAddressFamilyIPv6
	}
	// Start a new TURN Client and wrap our net.Conn in a STUNConn
	// This allows us to simulate datagram based communication over a net.Conn
	cfg = &turn.ClientConfig{
		STUNServerAddr:         turnServerAddr,
		TURNServerAddr:         turnServerAddr,
		Conn:                   turnConn,
		Username:               user,
		Password:               pass,
		RequestedAddressFamily: addrFamily,
		LoggerFactory:          logging.NewDefaultLoggerFactory(),
	}

	client, err1 := turn.NewClient(cfg)
	if err1 != nil {
		err = fmt.Errorf("failed to create TURN client: %s", err1)
		return
	}
	defer client.Close()

	// Start listening on the conn provided.
	err1 = client.Listen()
	if err1 != nil {
		err = fmt.Errorf("failed to listen: %s", err1)
		return
	}

	// Allocate a relay socket on the TURN server. On success, it
	// will return a net.PacketConn which represents the remote
	// socket.
	relayConn, err1 := client.Allocate()
	if err1 != nil {
		if rt := getProxyRuntime(); rt != nil {
			rt.deliverIncreaseAck(err1)
		}
		if turnParams.resetCreds != nil && isAllocationQuotaError(err1) {
			turnParams.resetCreds()
		}
		err = fmt.Errorf("failed to allocate: %s", err1)
		return
	}
	if rt := getProxyRuntime(); rt != nil {
		rt.deliverIncreaseAck(nil)
	}
	defer func() {
		if err1 := relayConn.Close(); err1 != nil {
			err = fmt.Errorf("failed to close TURN allocated connection: %s", err1)
		}
	}()

	// The relayConn's local address is actually the transport
	// address assigned on the TURN server.
	log.Printf("relayed-address=%s", relayConn.LocalAddr().String())

	wg := sync.WaitGroup{}
	wg.Add(2)
	turnctx, turncancel := context.WithCancel(ctx)
	context.AfterFunc(turnctx, func() {
		if err := relayConn.SetDeadline(time.Now()); err != nil {
			log.Printf("Failed to set relay deadline: %s", err)
		}
		if err := conn2.SetDeadline(time.Now()); err != nil {
			log.Printf("Failed to set upstream deadline: %s", err)
		}
	})
	if rotateAfter := credentialRotateAfter(cred); rotateAfter > 0 {
		timer := time.NewTimer(rotateAfter)
		go func() {
			defer timer.Stop()
			select {
			case <-turnctx.Done():
			case <-timer.C:
				log.Printf("[TURN] Credential lifetime window reached; rotating worker before TURN credentials expire")
				turncancel()
			}
		}()
	}
	var addr atomic.Value
	// Start read-loop on conn2 (output of DTLS)
	go func() {
		defer wg.Done()
		defer turncancel()
		buf := make([]byte, relayPacketBufferSize)
		for {
			select {
			case <-turnctx.Done():
				return
			default:
			}
			n, addr1, err1 := conn2.ReadFrom(buf)
			if err1 != nil {
				log.Printf("Failed: %s", err1)
				return
			}

			addr.Store(addr1) // store peer

			_, err1 = relayConn.WriteTo(buf[:n], peer)
			if err1 != nil {
				log.Printf("Failed: %s", err1)
				return
			}
		}
	}()

	// Start read-loop on relayConn
	go func() {
		defer wg.Done()
		defer turncancel()
		buf := make([]byte, relayPacketBufferSize)
		for {
			select {
			case <-turnctx.Done():
				return
			default:
			}
			n, _, err1 := relayConn.ReadFrom(buf)
			if err1 != nil {
				log.Printf("Failed: %s", err1)
				return
			}
			addr1, ok := addr.Load().(net.Addr)
			if !ok {
				log.Printf("Failed: no listener ip")
				return
			}

			_, err1 = conn2.WriteTo(buf[:n], addr1)
			if err1 != nil {
				log.Printf("Failed: %s", err1)
				return
			}
		}
	}()

	wg.Wait()
	if err := relayConn.SetDeadline(time.Time{}); err != nil {
		log.Printf("Failed to clear relay deadline: %s", err)
	}
	if err := conn2.SetDeadline(time.Time{}); err != nil {
		log.Printf("Failed to clear upstream deadline: %s", err)
	}
}

func oneDtlsConnectionLoop(ctx context.Context, peer *net.UDPAddr, listenConnChan <-chan net.PacketConn, connchan chan<- net.PacketConn, okchan chan<- struct{}) {
	for {
		select {
		case <-ctx.Done():
			return
		case listenConn := <-listenConnChan:
			c := make(chan error)
			go oneDtlsConnection(ctx, peer, listenConn, connchan, okchan, c)
			if err := <-c; err != nil {
				log.Printf("%s", err)
				if okchan != nil {
					signalProxyStartFailure()
					return
				}
			}
		}
	}
}

func oneTurnConnectionLoop(ctx context.Context, turnParams *turnParams, peer *net.UDPAddr, connchan <-chan net.PacketConn, t <-chan time.Time) {
	for {
		select {
		case <-ctx.Done():
			return
		case conn2 := <-connchan:
			select {
			case <-ctx.Done():
				return
			case <-t:
			}

			c := make(chan error)
			go oneTurnConnection(ctx, turnParams, peer, conn2, c)
			if err := <-c; err != nil {
				if ctx.Err() != nil {
					return
				}
				log.Printf("%s; reconnecting in %s", err, workerReconnectBackoff)
			} else {
				if ctx.Err() != nil {
					return
				}
				log.Printf("TURN worker stopped; reconnecting in %s", workerReconnectBackoff)
			}

			timer := time.NewTimer(workerReconnectBackoff)
			select {
			case <-ctx.Done():
				if !timer.Stop() {
					<-timer.C
				}
				return
			case <-timer.C:
			}
		}
	}
}

type turnCred struct {
	user, pass, addr string
	lifetime         time.Duration
	fetchedAt        time.Time
}

func poolCreds(f getCredsFunc, poolSize int) (getCredsFunc, func()) {
	var mu sync.Mutex
	var cached []*turnCred
	var next int
	var cTime time.Time

	if poolSize < 1 {
		poolSize = 1
	}

	reset := func() {
		mu.Lock()
		cached = nil
		next = 0
		cTime = time.Time{}
		mu.Unlock()
	}

	getter := func(link string) (*turnCred, error) {
		mu.Lock()
		defer mu.Unlock()

		if shouldRefreshCachedCreds(cached) || (!cTime.IsZero() && time.Since(cTime) > 10*time.Minute) {
			cached = nil
			next = 0
			cTime = time.Time{}
		}

		if len(cached) < poolSize {
			cred, err := f(link)
			if err != nil {
				return nil, err
			}

			cached = append(cached, cred)
			if cTime.IsZero() {
				cTime = time.Now()
			}
			log.Printf("Successfully registered User Identity %d/%d", len(cached), poolSize)
			return cloneTurnCred(cred), nil
		}

		cred := cached[next]
		next = (next + 1) % len(cached)
		return cloneTurnCred(cred), nil
	}

	return getter, reset
}

func cloneTurnCred(cred *turnCred) *turnCred {
	if cred == nil {
		return nil
	}
	cloned := *cred
	return &cloned
}

func credentialRotateAfter(cred *turnCred) time.Duration {
	if cred == nil || cred.lifetime <= 0 {
		return 0
	}

	lead := 2 * time.Minute
	switch {
	case cred.lifetime <= 30*time.Second:
		lead = 5 * time.Second
	case cred.lifetime <= 2*time.Minute:
		lead = cred.lifetime / 4
	case cred.lifetime <= 10*time.Minute:
		lead = time.Minute
	}

	rotateAfter := cred.lifetime - lead
	if rotateAfter <= 0 {
		rotateAfter = cred.lifetime / 2
	}
	if rotateAfter <= 0 {
		return 0
	}
	return rotateAfter
}

func shouldRefreshCachedCreds(cached []*turnCred) bool {
	if len(cached) == 0 {
		return false
	}

	now := time.Now()
	for _, cred := range cached {
		if cred == nil || cred.lifetime <= 0 || cred.fetchedAt.IsZero() {
			continue
		}
		if now.Sub(cred.fetchedAt) >= credentialRotateAfter(cred) {
			return true
		}
	}

	return false
}

//export ProxyIncreaseThreads
func ProxyIncreaseThreads(cDelta C.int) C.int {
    delta := int(cDelta)
    if delta < 1 {
        return 0
    }

    rt := getProxyRuntime()
    if rt == nil {
        return 0
    }

    const (
        increaseAckTimeout      = 10 * time.Second
        quotaRetryAckTimeout    = 120 * time.Second
    )

	successCount := 0
	for i := 0; i < delta; i++ {
		if i > 0 {
			if !sleepWithContext(rt.ctx, workerSpawnDelay(int(rt.workerCount.Load()))) {
				return C.int(successCount)
			}
		}

		ackCh := make(chan error, 1)
		rt.setIncreaseAck(ackCh)
		spawnProxyWorkerPair(rt, false)

        select {
        case err := <-ackCh:
			if err != nil {
				if isAllocationQuotaError(err) {
					log.Printf("[Proxy] Increase rejected: TURN allocation quota reached, cooling down and refreshing credentials")
					if !sleepWithContext(rt.ctx, quotaRetryCooldown) {
						return C.int(successCount)
					}
					if rt.params != nil && rt.params.resetCreds != nil {
						rt.params.resetCreds()
					}

                    retryAckCh := make(chan error, 1)
                    rt.setIncreaseAck(retryAckCh)
                    spawnProxyWorkerPair(rt, false)

                    select {
                    case retryErr := <-retryAckCh:
                        if retryErr != nil {
                            if isAllocationQuotaError(retryErr) {
                                log.Printf("[Proxy] Retry also rejected: TURN allocation quota reached")
                            } else {
                                log.Printf("[Proxy] Retry rejected: %v", retryErr)
                            }
                            return C.int(successCount)
                        }
                        successCount++
                        continue
                    case <-time.After(quotaRetryAckTimeout):
                        log.Printf("[Proxy] Retry timed out while waiting for TURN allocation confirmation")
                        return C.int(successCount)
                    case <-rt.ctx.Done():
                        return C.int(successCount)
                    }
                } else {
                    log.Printf("[Proxy] Increase rejected: %v", err)
                }
                return C.int(successCount)
            }
            successCount++
        case <-time.After(increaseAckTimeout):
            log.Printf("[Proxy] Increase timed out while waiting for TURN allocation confirmation")
            return C.int(successCount)
        case <-rt.ctx.Done():
            return C.int(successCount)
        }
    }
    return C.int(successCount)
}

//export StartProxy
func StartProxy(cLink *C.char, cPeerAddr *C.char, cLocalAddr *C.char, cN C.int, cCredsGroupSize C.int, cManualCaptcha C.int, cTurnHost *C.char, cTurnPort *C.char, cUseUdp C.int) {
    select { case <-proxyReady: default: }
    proxyStateMu.Lock()
    proxyDone = make(chan struct{})
    proxyStartFailed = make(chan struct{}, 1)
    proxyStateMu.Unlock()

    link := C.GoString(cLink)
    peerAddrStr := C.GoString(cPeerAddr)
    localAddrStr := C.GoString(cLocalAddr)
    turnHost := C.GoString(cTurnHost)
    turnPort := C.GoString(cTurnPort)

	host := turnHost
	port := turnPort
	if port == "" {
		port = "19302"
	}
	n := int(cN)
	if n < 1 {
		n = 10
	}
	credsGroupSize := int(cCredsGroupSize)
	if credsGroupSize < 1 {
		credsGroupSize = 12
	}
	identityPoolSize := ceilDiv(n, credsGroupSize)
	if identityPoolSize < 1 {
		identityPoolSize = 1
	}
	udp := cUseUdp != 0
	manualCaptchaOnly.Store(cManualCaptcha != 0)
	if manualCaptchaOnly.Load() {
		log.Printf("Manual captcha mode is enabled (auto-solver disabled)")
	}
	log.Printf("TURN identity strategy: %d workers, %d workers per identity, %d cached identities", n, credsGroupSize, identityPoolSize)
	if host != "" || turnPort != "" || !udp {
		log.Printf("TURN override active: host=%q port=%q udp=%v", host, port, udp)
	}

    ctx, cancel := context.WithCancel(context.Background())
    proxyCancel = cancel
    defer cancel()

	peer, err := net.ResolveUDPAddr("udp", peerAddrStr)
	if err != nil {
		log.Printf("Resolve UDP error: %v", err)
		signalProxyStartFailure()
		return
	}

    parts := strings.Split(link, "join/")
    link = parts[len(parts)-1]
    if idx := strings.IndexAny(link, "/?#"); idx != -1 {
        link = link[:idx]
    }

    pooledCreds, resetCreds := poolCreds(getCreds, identityPoolSize)
    params := &turnParams{
        host:       host,
        port:       port,
        link:       link,
        udp:        udp,
        getCreds:   pooledCreds,
        resetCreds: resetCreds,
    }

    listenConnChan := make(chan net.PacketConn)
    connchan := make(chan net.PacketConn)
    okchan := make(chan struct{})
    t := time.Tick(200 * time.Millisecond)
    wg1 := sync.WaitGroup{}

	    rt := &proxyRuntimeState{
	        ctx:            ctx,
	        peer:           peer,
	        params:         params,
	        listenConnChan: listenConnChan,
	        connchan:       connchan,
	        tick:           t,
	        wg:             &wg1,
	        readyChan:      okchan,
            targetWorkers:  int32(n),
	    }
    setProxyRuntime(rt)
    defer setProxyRuntime(nil)

	listenConn, err := net.ListenPacket("udp", localAddrStr)
	if err != nil {
		log.Printf("Failed to listen: %s", err)
		signalProxyStartFailure()
		return
	}

    context.AfterFunc(ctx, func() {
        if closeErr := listenConn.Close(); closeErr != nil {
            log.Printf("Failed to close local connection: %s", closeErr)
        }
    })

    go func() {
        for {
            select {
            case <-ctx.Done():
                return
            case listenConnChan <- listenConn:
            }
        }
    }()

	spawnProxyWorkerPair(rt, true)

	select {
	case <-okchan:
	case <-ctx.Done():
		return
	}

    for i := 0; i < n-1; i++ {
        if !sleepWithContext(ctx, workerSpawnDelay(int(rt.workerCount.Load()))) {
            return
        }
        spawnProxyWorkerPair(rt, false)
    }

    log.Printf("Proxy started on %s", localAddrStr)
    wg1.Wait()
}

//export StopProxy
func StopProxy() {
    proxyStateMu.Lock()
    done := proxyDone
    proxyDone = nil
    proxyStartFailed = nil
    proxyStateMu.Unlock()

    setProxyRuntime(nil)

    if done != nil {
        close(done)
    }
    if proxyCancel != nil {
        proxyCancel()
        proxyCancel = nil
        log.Println("Proxy gracefully stopped")
    }
}
