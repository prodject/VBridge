package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	mathrand "math/rand"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
)

var vkSemaphore = make(chan struct{}, 2)

type vkBotProfile struct {
	Profile       Profile
	Name          string
	BrowserFP     string
	DeviceJSON    string
	CursorJSON    string
	Accelerometer string
	Gyroscope     string
	Motion        string
	Taps          string
	Downlink      string
	DebugInfo     string
}

func getVKTurnCredWithFallback(ctx context.Context, hash string) (*turnCred, error) {
	cred, err := getUniqueVKCreds(ctx, hash, 5)
	if err == nil {
		return cred, nil
	}

	rt := getProxyRuntime()
	if rt == nil || rt.params == nil {
		return nil, err
	}

	fallback := rt.params.fallbackHash(hash)
	if fallback == "" {
		return nil, err
	}

	log.Printf("[VK Auth] Primary hash failed, trying fallback hash")
	return getUniqueVKCreds(ctx, fallback, 3)
}

func getUniqueVKCreds(ctx context.Context, hash string, maxRetries int) (*turnCred, error) {
	if maxRetries < 1 {
		maxRetries = 1
	}

	var lastErr error
	for attempt := 0; attempt < maxRetries; attempt++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case vkSemaphore <- struct{}{}:
		}

		cred, err := getVKCredsOnce(ctx, hash)
		<-vkSemaphore

		if err == nil {
			return cred, nil
		}

		lastErr = err
		errLower := strings.ToLower(err.Error())
		if strings.Contains(errLower, "9000") || strings.Contains(errLower, "call not found") {
			return nil, fmt.Errorf("hash appears dead: %w", err)
		}

		backoff := time.Duration(1<<minInt(attempt, 5))*time.Second + time.Duration(mathrand.Intn(800))*time.Millisecond
		if strings.Contains(errLower, "flood") {
			backoff = time.Duration(minInt((attempt+1)*5, 60)) * time.Second
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(backoff):
		}
	}

	return nil, fmt.Errorf("exhausted %d VK credential attempts: %w", maxRetries, lastErr)
}

func getVKCredsOnce(ctx context.Context, hash string) (*turnCred, error) {
	profile := generateVKBotProfile(hash)
	log.Printf("[VK Auth] Connecting - Name: %s | UA: %s", profile.Name, profile.Profile.UserAgent)

	doRequest := func(data string, requestURL string) (map[string]interface{}, error) {
		client := &http.Client{
			Timeout: 20 * time.Second,
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				DialContext:           (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
				ForceAttemptHTTP2:     true,
				MaxIdleConns:          100,
				MaxIdleConnsPerHost:   100,
				IdleConnTimeout:       90 * time.Second,
				TLSHandshakeTimeout:   15 * time.Second,
				ExpectContinueTimeout: time.Second,
			},
		}
		defer client.CloseIdleConnections()

		req, err := http.NewRequestWithContext(ctx, "POST", requestURL, bytes.NewBufferString(data))
		if err != nil {
			return nil, err
		}

		applyBrowserProfile(req, profile.Profile)
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("Accept", "*/*")
		req.Header.Set("Origin", "https://vk.ru")
		req.Header.Set("Referer", "https://vk.ru/")
		req.Header.Set("Sec-Fetch-Site", "same-site")
		req.Header.Set("Sec-Fetch-Mode", "cors")
		req.Header.Set("Sec-Fetch-Dest", "empty")
		req.Header.Set("Priority", "u=1, i")
		req.Header.Set("X-Request-Id", profile.BrowserFP[:16])
		req.Header.Set("X-Device-Fingerprint", profile.BrowserFP)

		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()

		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}

		var parsed map[string]interface{}
		if err := json.Unmarshal(body, &parsed); err != nil {
			return nil, fmt.Errorf("decode JSON: %w | body=%s", err, string(body))
		}
		return parsed, nil
	}

	var token1 string
	var token2 string
	var lastErr error

	const maxCaptchaAttempts = 4
	const previewURL = "https://api.vk.ru/method/calls.getCallPreview?v=5.275&client_id=%s"
	const anonymousURL = "https://api.vk.ru/method/calls.getAnonymousToken?v=5.275&client_id=%s"

	for _, creds := range vkCredentialsList {
		reqBody := fmt.Sprintf("client_id=%s&token_type=messages&client_secret=%s&version=1&app_id=%s", creds.ClientID, creds.ClientSecret, creds.ClientID)
		resp, err := doRequest(reqBody, "https://login.vk.ru/?act=get_anonym_token")
		if err != nil {
			lastErr = err
			log.Printf("[VK Auth] client_id=%s token1 failed: %v", creds.ClientID, err)
			continue
		}

		tokenData, ok := resp["data"].(map[string]interface{})
		if !ok {
			lastErr = fmt.Errorf("invalid token1 response: %v", resp)
			continue
		}

		token1, ok = tokenData["access_token"].(string)
		if !ok || token1 == "" {
			lastErr = fmt.Errorf("missing token1 access_token")
			continue
		}

		vkDelayRandom(100, 180)

		previewData := fmt.Sprintf("vk_join_link=https://vk.com/call/join/%s&fields=photo_200&access_token=%s", hash, token1)
		if _, err := doRequest(previewData, fmt.Sprintf(previewURL, creds.ClientID)); err != nil {
			log.Printf("[VK Auth] getCallPreview warning for client_id=%s: %v", creds.ClientID, err)
		}

		vkDelayRandom(200, 450)

		reqBody = buildAnonymousTokenPayload(hash, profile.Name, token1, "", "", "", "", "")
		requestURL := fmt.Sprintf(anonymousURL, creds.ClientID)
		token2 = ""
		preferManualCaptcha := false

		for attempt := 0; attempt < maxCaptchaAttempts; attempt++ {
			resp, err = doRequest(reqBody, requestURL)
			if err != nil {
				lastErr = err
				break
			}

			if errObj, hasErr := resp["error"].(map[string]interface{}); hasErr {
				captchaErr := ParseVkCaptchaError(errObj)
				if captchaErr != nil && captchaErr.IsCaptchaError() {
					if attempt == maxCaptchaAttempts-1 {
						lastErr = fmt.Errorf("captcha failed after %d attempts", maxCaptchaAttempts)
						break
					}

					if cached := popCachedToken(); cached != "" && !preferManualCaptcha {
						reqBody = buildAnonymousTokenPayload(
							hash,
							profile.Name,
							token1,
							captchaErr.CaptchaSid,
							"",
							cached,
							captchaErr.CaptchaTs,
							captchaErr.CaptchaAttempt,
						)
						continue
					}

					if manualCaptchaOnly.Load() || preferManualCaptcha {
						if captchaErr.RedirectUri != "" {
							successToken, solveErr := solveCaptchaViaProxy(captchaErr.RedirectUri)
							if solveErr != nil {
								lastErr = fmt.Errorf("manual captcha proxy solve error: %w", solveErr)
								break
							}
							pushCachedToken(successToken, 4)
							reqBody = buildAnonymousTokenPayload(
								hash,
								profile.Name,
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
							captchaKey, solveErr := solveCaptchaViaHTTP(captchaErr.CaptchaImg)
							if solveErr != nil {
								lastErr = fmt.Errorf("manual captcha image solve error: %w", solveErr)
								break
							}
							reqBody = buildAnonymousTokenPayload(
								hash,
								profile.Name,
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

						lastErr = fmt.Errorf("manual captcha mode: no redirect_uri or captcha_img")
						break
					}

					successToken, solveErr := solveVkCaptcha(ctx, captchaErr)
					if solveErr != nil {
						var retryErr *captchaManualRetryRequiredError
						if strings.Contains(strings.ToLower(solveErr.Error()), "success_token") {
							invalidateCachedToken()
						}
						if errors.As(solveErr, &retryErr) {
							preferManualCaptcha = true
							continue
						}
						lastErr = fmt.Errorf("captcha solve error: %w", solveErr)
						break
					}

					pushCachedToken(successToken, 4)
					reqBody = buildAnonymousTokenPayload(
						hash,
						profile.Name,
						token1,
						captchaErr.CaptchaSid,
						"",
						successToken,
						captchaErr.CaptchaTs,
						captchaErr.CaptchaAttempt,
					)
					continue
				}

				lastErr = fmt.Errorf("VK API error: %v", errObj)
				break
			}

			responseObj, ok := resp["response"].(map[string]interface{})
			if !ok {
				lastErr = fmt.Errorf("missing response object: %v", resp)
				break
			}

			token2, _ = responseObj["token"].(string)
			if token2 == "" {
				lastErr = fmt.Errorf("missing token in response: %v", resp)
				break
			}
			lastErr = nil
			break
		}

		if lastErr == nil && token2 != "" {
			break
		}
	}

	if token2 == "" {
		if lastErr == nil {
			lastErr = fmt.Errorf("all VK credentials failed")
		}
		return nil, lastErr
	}

	authData := fmt.Sprintf("session_data=%7B%22version%22%3A2%2C%22device_id%22%3A%22%s%22%2C%22client_version%22%3A1.1%2C%22client_type%22%3A%22SDK_JS%22%7D&method=auth.anonymLogin&format=JSON&application_key=CGMMEJLGDIHBABABA", newDeviceID())
	authResp, err := doRequest(authData, "https://calls.okcdn.ru/fb.do")
	if err != nil {
		return nil, fmt.Errorf("auth.anonymLogin error: %w", err)
	}

	sessionKey, _ := authResp["session_key"].(string)
	if sessionKey == "" {
		return nil, fmt.Errorf("missing session_key in auth response: %v", authResp)
	}

	joinData := fmt.Sprintf("joinLink=%s&isVideo=false&protocolVersion=5&anonymToken=%s&method=vchat.joinConversationByLink&format=JSON&application_key=CGMMEJLGDIHBABABA&session_key=%s", hash, token2, sessionKey)
	joinResp, err := doRequest(joinData, "https://calls.okcdn.ru/fb.do")
	if err != nil {
		return nil, fmt.Errorf("joinConversationByLink error: %w", err)
	}

	return parseTurnCred(joinResp)
}

func parseTurnCred(resp map[string]interface{}) (*turnCred, error) {
	turnServer, ok := resp["turn_server"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("missing turn_server in response: %v", resp)
	}

	user, _ := turnServer["username"].(string)
	pass, _ := turnServer["credential"].(string)
	if user == "" || pass == "" {
		return nil, fmt.Errorf("missing TURN username or credential")
	}

	rawURLs := collectTurnURLs(turnServer["urls"])
	if len(rawURLs) == 0 {
		if singleURL, _ := turnServer["url"].(string); singleURL != "" {
			rawURLs = []string{singleURL}
		}
	}
	if len(rawURLs) == 0 {
		return nil, fmt.Errorf("missing TURN urls")
	}

	cleanURLs := make([]string, 0, len(rawURLs))
	for _, value := range rawURLs {
		cleaned := normalizeTurnAddress(value)
		if cleaned != "" {
			cleanURLs = append(cleanURLs, cleaned)
		}
	}
	if len(cleanURLs) == 0 {
		return nil, fmt.Errorf("TURN urls are malformed: %v", rawURLs)
	}

	lifetime := extractLifetime(turnServer)
	return &turnCred{
		user:      user,
		pass:      pass,
		addr:      cleanURLs[0],
		turnURLs:  cleanURLs,
		lifetime:  lifetime,
		fetchedAt: time.Now(),
	}, nil
}

func collectTurnURLs(value interface{}) []string {
	switch typed := value.(type) {
	case []interface{}:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if s, ok := item.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	case []string:
		return append([]string(nil), typed...)
	default:
		return nil
	}
}

func normalizeTurnAddress(raw string) string {
	clean := strings.TrimSpace(raw)
	if clean == "" {
		return ""
	}
	if idx := strings.Index(clean, "?"); idx != -1 {
		clean = clean[:idx]
	}
	clean = strings.TrimPrefix(clean, "turn:")
	clean = strings.TrimPrefix(clean, "turns:")
	return clean
}

func extractLifetime(turnServer map[string]interface{}) time.Duration {
	for _, key := range []string{"ttl", "lifetime", "expires_in"} {
		switch value := turnServer[key].(type) {
		case float64:
			if value > 0 {
				return time.Duration(value) * time.Second
			}
		case int:
			if value > 0 {
				return time.Duration(value) * time.Second
			}
		case string:
			if value == "" {
				continue
			}
			if parsed, err := time.ParseDuration(value); err == nil {
				return parsed
			}
		}
	}
	return 10 * time.Minute
}

func generateVKBotProfile(seed string) vkBotProfile {
	baseProfile := getRandomProfile()
	name := generateName()

	hash := sha256.Sum256([]byte(seed + "|" + baseProfile.UserAgent))
	src := mathrand.NewSource(int64(binary.BigEndian.Uint64(hash[:8])))
	rng := mathrand.New(src)

	screenWidths := []int{360, 393, 412, 430, 720, 1080}
	screenWidth := screenWidths[rng.Intn(len(screenWidths))]
	screenHeight := int(float64(screenWidth) * (1.8 + rng.Float64()*0.7))
	availHeight := screenHeight - (60 + rng.Intn(120))
	innerHeight := availHeight - rng.Intn(48)
	hardwareConcurrency := []int{4, 6, 8}[rng.Intn(3)]
	deviceMemory := []int{4, 6, 8, 12}[rng.Intn(4)]
	downlink := fmt.Sprintf(`["%.1f","%.1f","%.1f"]`, 8+rng.Float64()*4, 10+rng.Float64()*6, 12+rng.Float64()*8)
	browserFP := fmt.Sprintf("%016x%016x%016x", rng.Uint64(), rng.Uint64(), rng.Uint64())

	taps := make([]string, 0, 2+rng.Intn(3))
	baseTime := 400 + rng.Intn(900)
	for i := 0; i < cap(taps); i++ {
		baseTime += 250 + rng.Intn(1200)
		taps = append(taps, fmt.Sprintf(`{"x":%.1f,"y":%.1f,"duration":%d,"time":%d}`, 40+rng.Float64()*240, 120+rng.Float64()*480, 40+rng.Intn(140), baseTime))
	}

	accel := fmt.Sprintf(`[{"x":%.3f,"y":%.3f,"z":%.3f}]`, -0.3+rng.Float64()*0.6, 4+rng.Float64()*2, 8+rng.Float64()*1.2)
	gyro := fmt.Sprintf(`[{"alpha":%.2f,"beta":%.2f,"gamma":%.2f}]`, rng.Float64()*0.3, rng.Float64()*0.3, rng.Float64()*0.3)
	motion := fmt.Sprintf(`[{"accelerationIncludingGravity":{"x":%.3f,"y":%.3f,"z":%.3f}}]`, -0.2+rng.Float64()*0.4, 4+rng.Float64()*2, 8+rng.Float64()*1.2)
	deviceJSON := fmt.Sprintf(
		`{"screenWidth":%d,"screenHeight":%d,"screenAvailWidth":%d,"screenAvailHeight":%d,"innerWidth":%d,"innerHeight":%d,"devicePixelRatio":%.2f,"language":"ru-RU","languages":["ru-RU","en-US"],"webdriver":false,"hardwareConcurrency":%d,"deviceMemory":%d,"connectionEffectiveType":"4g","notificationsPermission":"default"}`,
		screenWidth,
		screenHeight,
		screenWidth,
		availHeight,
		screenWidth,
		innerHeight,
		2.0+rng.Float64()*1.5,
		hardwareConcurrency,
		deviceMemory,
	)
	debugInfoHash := sha256.Sum256([]byte(seed + "|debug"))

	return vkBotProfile{
		Profile:       baseProfile,
		Name:          name,
		BrowserFP:     browserFP,
		DeviceJSON:    deviceJSON,
		CursorJSON:    "[]",
		Accelerometer: accel,
		Gyroscope:     gyro,
		Motion:        motion,
		Taps:          "[" + strings.Join(taps, ",") + "]",
		Downlink:      downlink,
		DebugInfo:     hex.EncodeToString(debugInfoHash[:]),
	}
}

func newDeviceID() string {
	return uuid.NewString()
}

func minInt(a int, b int) int {
	if a < b {
		return a
	}
	return b
}
