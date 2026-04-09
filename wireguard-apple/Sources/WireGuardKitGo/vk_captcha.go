package main

import (
    "context"
    "crypto/rand"
    "crypto/sha256"
    "crypto/tls"
    "encoding/base64"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "io"
    "log"
    mathrand "math/rand"
    "net"
    "net/http"
    "net/http/cookiejar"
    "net/url"
    "regexp"
    "strconv"
    "strings"
    "time"
)

type VkCaptchaError struct {
    ErrorCode               int
    ErrorMsg                string
    CaptchaSid              string
    CaptchaImg              string
    RedirectUri             string
    IsSoundCaptchaAvailable bool
    SessionToken            string
    CaptchaTs               string
    CaptchaAttempt          string
}

func randomHex(n int) string {
    bytes := make([]byte, n)
    if _, err := rand.Read(bytes); err != nil {
        for i := range bytes {
            bytes[i] = byte(mathrand.Intn(256))
        }
    }
    return hex.EncodeToString(bytes)
}

func newCaptchaClient() *http.Client {
    jar, _ := cookiejar.New(nil)
    return &http.Client{
        Timeout: 20 * time.Second,
        Jar:     jar,
        Transport: &http.Transport{
            DialContext: (&net.Dialer{
                Timeout:   30 * time.Second,
                KeepAlive: 30 * time.Second,
            }).DialContext,
            TLSClientConfig: &tls.Config{
                InsecureSkipVerify: false,
            },
        },
    }
}

func ParseVkCaptchaError(errData map[string]interface{}) *VkCaptchaError {
    codeFloat, _ := errData["error_code"].(float64)
    code := int(codeFloat)

    redirectUri, _ := errData["redirect_uri"].(string)
    captchaSid, _ := errData["captcha_sid"].(string)
    captchaImg, _ := errData["captcha_img"].(string)
    errorMsg, _ := errData["error_msg"].(string)

    var sessionToken string
    if redirectUri != "" {
        if parsed, err := url.Parse(redirectUri); err == nil {
            sessionToken = parsed.Query().Get("session_token")
        }
    }

    isSound, _ := errData["is_sound_captcha_available"].(bool)

    var captchaTs string
    if tsFloat, ok := errData["captcha_ts"].(float64); ok {
        captchaTs = fmt.Sprintf("%.0f", tsFloat)
    } else if tsStr, ok := errData["captcha_ts"].(string); ok {
        captchaTs = tsStr
    }

    var captchaAttempt string
    if attFloat, ok := errData["captcha_attempt"].(float64); ok {
        captchaAttempt = fmt.Sprintf("%.0f", attFloat)
    } else if attStr, ok := errData["captcha_attempt"].(string); ok {
        captchaAttempt = attStr
    }

    return &VkCaptchaError{
        ErrorCode:               code,
        ErrorMsg:                errorMsg,
        CaptchaSid:              captchaSid,
        CaptchaImg:              captchaImg,
        RedirectUri:             redirectUri,
        IsSoundCaptchaAvailable: isSound,
        SessionToken:            sessionToken,
        CaptchaTs:               captchaTs,
        CaptchaAttempt:          captchaAttempt,
    }
}

func (e *VkCaptchaError) IsCaptchaError() bool {
    return e.ErrorCode == 14 && e.RedirectUri != "" && e.SessionToken != ""
}

func solveVkCaptcha(ctx context.Context, captchaErr *VkCaptchaError) (string, error) {
    time.Sleep(time.Duration(1500+mathrand.Intn(1000)) * time.Millisecond)

    log.Printf("[Captcha] Solving Not Robot Captcha...")

    sessionToken := captchaErr.SessionToken
    if sessionToken == "" {
        return "", fmt.Errorf("no session_token in redirect_uri")
    }

    profile := getRandomProfile()
    client := newCaptchaClient()

    powInput, difficulty, htmlSettings, err := fetchPowInput(ctx, client, profile, captchaErr.RedirectUri)
    if err != nil {
        return "", fmt.Errorf("failed to fetch PoW input: %w", err)
    }

    log.Printf("[Captcha] PoW input: %s, difficulty: %d, htmlSettings=%v", powInput, difficulty, htmlSettings != nil)

    hash := solvePoW(powInput, difficulty)
    log.Printf("[Captcha] PoW solved: hash=%s", hash)

    successToken, err := callCaptchaNotRobot(ctx, client, profile, sessionToken, hash, htmlSettings)
    if err != nil {
        return "", fmt.Errorf("captchaNotRobot API failed: %w", err)
    }

    log.Printf("[Captcha] Success! Got success_token")
    return successToken, nil
}

func fetchPowInput(ctx context.Context, client *http.Client, profile Profile, redirectUri string) (string, int, map[string]interface{}, error) {
    req, err := http.NewRequestWithContext(ctx, "GET", redirectUri, nil)
    if err != nil {
        return "", 0, nil, err
    }

    req.Header.Set("User-Agent", profile.UserAgent)
    req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8")
    req.Header.Set("Accept-Language", "en-US,en;q=0.9")
    req.Header.Set("sec-ch-ua", profile.SecChUa)
    req.Header.Set("sec-ch-ua-mobile", profile.SecChUaMobile)
    req.Header.Set("sec-ch-ua-platform", profile.SecChUaPlatform)
    req.Header.Set("Sec-Fetch-Site", "none")
    req.Header.Set("Sec-Fetch-Mode", "navigate")
    req.Header.Set("Sec-Fetch-Dest", "document")
    req.Header.Set("Sec-GPC", "1")
    req.Header.Set("DNT", "1")

    resp, err := client.Do(req)
    if err != nil {
        return "", 0, nil, err
    }
    defer resp.Body.Close()

    body, err := io.ReadAll(resp.Body)
    if err != nil {
        return "", 0, nil, err
    }

    html := string(body)

    // Parse PoW input
    powInputRe := regexp.MustCompile(`const\s+powInput\s*=\s*"([^"]+)"`)
    powInputMatch := powInputRe.FindStringSubmatch(html)
    if len(powInputMatch) < 2 {
        return "", 0, nil, fmt.Errorf("powInput not found in captcha HTML")
    }
    powInput := powInputMatch[1]

    // Parse difficulty
    diffRe := regexp.MustCompile(`startsWith\('0'\.repeat\((\d+)\)\)`)
    diffMatch := diffRe.FindStringSubmatch(html)
    difficulty := 2
    if len(diffMatch) >= 2 {
        if d, err := strconv.Atoi(diffMatch[1]); err == nil {
            difficulty = d
        }
    }

    // Parse window.init for slider captcha settings
    var htmlSettings map[string]interface{}
    initRe := regexp.MustCompile(`(?s)window\.init\s*=\s*(\{.*?\})\s*;\s*window\.lang`)
    if initMatch := initRe.FindStringSubmatch(html); len(initMatch) >= 2 {
        var initPayload map[string]interface{}
        if err := json.Unmarshal([]byte(initMatch[1]), &initPayload); err == nil {
            if data, ok := initPayload["data"].(map[string]interface{}); ok {
                htmlSettings = map[string]interface{}{"response": data}
                log.Printf("[Captcha] Parsed window.init htmlSettings")
            }
        }
    }

    return powInput, difficulty, htmlSettings, nil
}

func solvePoW(powInput string, difficulty int) string {
    target := strings.Repeat("0", difficulty)

    for nonce := 1; nonce <= 10000000; nonce++ {
        data := powInput + strconv.Itoa(nonce)
        hash := sha256.Sum256([]byte(data))
        hexHash := hex.EncodeToString(hash[:])

        if strings.HasPrefix(hexHash, target) {
            return hexHash
        }
    }
    return ""
}

func callCaptchaNotRobot(ctx context.Context, client *http.Client, profile Profile, sessionToken, hash string, htmlSettings map[string]interface{}) (string, error) {
    vkReq := func(method string, postData string) (map[string]interface{}, error) {
        requestURL := "https://api.vk.ru/method/" + method + "?v=5.131"

        req, err := http.NewRequestWithContext(ctx, "POST", requestURL, strings.NewReader(postData))
        if err != nil {
            return nil, err
        }

        req.Header.Set("User-Agent", profile.UserAgent)
        req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
        req.Header.Set("Accept", "*/*")
        req.Header.Set("Accept-Language", "en-US,en;q=0.9")
        req.Header.Set("Origin", "https://id.vk.ru")
        req.Header.Set("Referer", "https://id.vk.ru/")
        req.Header.Set("sec-ch-ua", profile.SecChUa)
        req.Header.Set("sec-ch-ua-mobile", profile.SecChUaMobile)
        req.Header.Set("sec-ch-ua-platform", profile.SecChUaPlatform)
        req.Header.Set("Sec-Fetch-Site", "same-site")
        req.Header.Set("Sec-Fetch-Mode", "cors")
        req.Header.Set("Sec-Fetch-Dest", "empty")
        req.Header.Set("Sec-GPC", "1")
        req.Header.Set("DNT", "1")
        req.Header.Set("Priority", "u=1, i")

        httpResp, err := client.Do(req)
        if err != nil {
            return nil, err
        }
        defer httpResp.Body.Close()

        body, err := io.ReadAll(httpResp.Body)
        if err != nil {
            return nil, err
        }

        var resp map[string]interface{}
        if err := json.Unmarshal(body, &resp); err != nil {
            return nil, err
        }

        return resp, nil
    }

    domain := "vk.com"
    baseParams := fmt.Sprintf("session_token=%s&domain=%s&adFp=&access_token=",
        url.QueryEscape(sessionToken), url.QueryEscape(domain))

    // Step 1: settings
    log.Printf("[Captcha] Step 1/4: settings")
    settingsResp, err := vkReq("captchaNotRobot.settings", baseParams)
    if err != nil {
        return "", fmt.Errorf("settings failed: %w", err)
    }
    time.Sleep(time.Duration(100+mathrand.Intn(100)) * time.Millisecond)

    // Step 2: componentDone
    log.Printf("[Captcha] Step 2/4: componentDone")

    browserFp := fmt.Sprintf("%016x%016x", mathrand.Int63(), mathrand.Int63())

    resolutions := [][]int{{1920, 1080}, {1366, 768}, {1440, 900}, {1536, 864}, {2560, 1440}}
    res := resolutions[mathrand.Intn(len(resolutions))]
    screenW, screenH := res[0], res[1]

    cores := []int{4, 8, 12, 16}[mathrand.Intn(4)]
    ram := []int{4, 8, 16, 32}[mathrand.Intn(4)]

    baseDownlink := 8.0 + mathrand.Float64()*4.0
    downlinkStr := fmt.Sprintf("%.1f", baseDownlink)

    deviceMap := map[string]interface{}{
        "screenWidth":             screenW,
        "screenHeight":            screenH,
        "screenAvailWidth":        screenW,
        "screenAvailHeight":       screenH - 40,
        "innerWidth":              screenW - mathrand.Intn(100),
        "innerHeight":             screenH - 100 - mathrand.Intn(50),
        "devicePixelRatio":        []float64{1, 1.25, 1.5, 2}[mathrand.Intn(4)],
        "language":                "en-US",
        "languages":               []string{"en-US", "en"},
        "webdriver":               false,
        "hardwareConcurrency":     cores,
        "deviceMemory":            ram,
        "connectionEffectiveType": "4g",
        "connectionRtt":           []int{50, 100, 150}[mathrand.Intn(3)],
        "connectionDownlink":      baseDownlink,
        "notificationsPermission": "denied",
    }
    deviceBytes, _ := json.Marshal(deviceMap)

    componentDoneData := baseParams + fmt.Sprintf("&browser_fp=%s&device=%s",
        browserFp, url.QueryEscape(string(deviceBytes)))

    _, err = vkReq("captchaNotRobot.componentDone", componentDoneData)
    if err != nil {
        return "", fmt.Errorf("componentDone failed: %w", err)
    }
    time.Sleep(time.Duration(1500+mathrand.Intn(1000)) * time.Millisecond)

    // Step 3: checkbox check
    log.Printf("[Captcha] Step 3/4: check (checkbox)")

    type Point struct {
        X int   `json:"x"`
        Y int   `json:"y"`
        T int64 `json:"t"`
    }
    var cursor []Point
    startX, startY := screenW/2+mathrand.Intn(200)-100, screenH/2+mathrand.Intn(200)-100
    startTime := time.Now().Add(-300 * time.Millisecond).UnixMilli()

    pointsCount := 4 + mathrand.Intn(5)
    for i := 0; i < pointsCount; i++ {
        cursor = append(cursor, Point{
            X: startX,
            Y: startY,
            T: startTime + int64(i*20+mathrand.Intn(10)),
        })
        startX += mathrand.Intn(30) - 15
        startY += mathrand.Intn(30) - 15
    }
    cursorBytes, _ := json.Marshal(cursor)

    connectionDownlink := "[" + downlinkStr + "," + downlinkStr + "," + downlinkStr + "," + downlinkStr + "," + downlinkStr + "," + downlinkStr + "," + downlinkStr + "]"

    answer := base64.StdEncoding.EncodeToString([]byte("{}"))
    debugInfo := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    checkData := baseParams + fmt.Sprintf(
        "&accelerometer=%s&gyroscope=%s&motion=%s&cursor=%s&taps=%s&connectionRtt=%s&connectionDownlink=%s"+
            "&browser_fp=%s&hash=%s&answer=%s&debug_info=%s",
        url.QueryEscape("[]"),
        url.QueryEscape("[]"),
        url.QueryEscape("[]"),
        url.QueryEscape(string(cursorBytes)),
        url.QueryEscape("[]"),
        url.QueryEscape("[]"),
        url.QueryEscape(connectionDownlink),
        browserFp,
        hash,
        answer,
        debugInfo,
    )

    checkResp, err := vkReq("captchaNotRobot.check", checkData)
    if err != nil {
        return "", fmt.Errorf("check failed: %w", err)
    }

    respObj, ok := checkResp["response"].(map[string]interface{})
    if !ok {
        return "", fmt.Errorf("invalid check response: %v", checkResp)
    }

    status, _ := respObj["status"].(string)
    log.Printf("[Captcha] checkbox status: %s", status)

    if status == "OK" {
        successToken, ok := respObj["success_token"].(string)
        if ok && successToken != "" {
            log.Printf("[Captcha] Step 4/4: endSession")
            _, _ = vkReq("captchaNotRobot.endSession", baseParams)
            return successToken, nil
        }
    }

    // Checkbox failed — try slider captcha
    log.Printf("[Captcha] Checkbox failed, trying slider captcha...")

    // Use htmlSettings from the HTML page if available, otherwise use API settings
    mergedSettings := settingsResp
    if htmlSettings != nil {
        mergedSettings = htmlSettings
    }

    sliderToken, sliderErr := solveSliderCaptcha(vkReq, baseParams, browserFp, hash, mergedSettings)
    if sliderErr != nil {
        return "", fmt.Errorf("slider captcha also failed: %w", sliderErr)
    }

    log.Printf("[Captcha] Slider solved! endSession...")
    _, _ = vkReq("captchaNotRobot.endSession", baseParams)
    return sliderToken, nil
}

func buildCaptchaDeviceJSON(profile Profile) string {
    return fmt.Sprintf(
        `{"screenWidth":1920,"screenHeight":1080,"screenAvailWidth":1920,"screenAvailHeight":1040,"innerWidth":1920,"innerHeight":969,"devicePixelRatio":1,"language":"en-US","languages":["en-US"],"webdriver":false,"hardwareConcurrency":8,"deviceMemory":8,"connectionEffectiveType":"4g","notificationsPermission":"default","userAgent":"%s","platform":"Win32"}`,
        profile.UserAgent,
    )
}
