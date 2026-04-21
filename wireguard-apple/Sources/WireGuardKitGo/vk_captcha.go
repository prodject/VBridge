package main

import (
    "context"
    "crypto/md5"
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
    "sort"
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

type captchaSettingsResponse struct {
    ShowCaptchaType string
    SettingsByType  map[string]string
}

type captchaBootstrap struct {
    PowInput   string
    Difficulty int
    Settings   *captchaSettingsResponse
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

    powInput, difficulty, initialSettings, err := fetchPowInput(ctx, client, profile, captchaErr.RedirectUri)
    if err != nil {
        return "", fmt.Errorf("failed to fetch PoW input: %w", err)
    }

    log.Printf("[Captcha] PoW input: %s, difficulty: %d, htmlSettings=%v", powInput, difficulty, initialSettings != nil)

    hash := solvePoW(powInput, difficulty)
    log.Printf("[Captcha] PoW solved: hash=%s", hash)

    successToken, err := callCaptchaNotRobot(ctx, client, profile, sessionToken, hash, initialSettings)
    if err != nil {
        log.Printf("[Captcha] Automatic solver failed: %v", err)

        if captchaErr.RedirectUri != "" {
            log.Printf("[Captcha] Falling back to manual proxy solver...")
            if token, manualErr := solveCaptchaViaProxy(ctx, captchaErr.RedirectUri); manualErr == nil && token != "" {
                return token, nil
            } else if manualErr != nil {
                log.Printf("[Captcha] Manual proxy solver failed: %v", manualErr)
            }
        }

        if captchaErr.CaptchaImg != "" {
            log.Printf("[Captcha] Falling back to manual image solver...")
            if token, manualErr := solveCaptchaViaHTTP(ctx, captchaErr.CaptchaImg); manualErr == nil && token != "" {
                return token, nil
            } else if manualErr != nil {
                log.Printf("[Captcha] Manual image solver failed: %v", manualErr)
            }
        }

        return "", fmt.Errorf("captchaNotRobot API failed: %w", err)
    }

    log.Printf("[Captcha] Success! Got success_token")
    return successToken, nil
}

func fetchPowInput(ctx context.Context, client *http.Client, profile Profile, redirectUri string) (string, int, *captchaSettingsResponse, error) {
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
    bootstrap, err := parseCaptchaBootstrapHTML(html)
    if err != nil {
        return "", 0, nil, err
    }
    if bootstrap.Settings != nil {
        log.Printf("[Captcha] Parsed window.init htmlSettings")
    }

    return powInput, difficulty, bootstrap.Settings, nil
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

func callCaptchaNotRobot(ctx context.Context, client *http.Client, profile Profile, sessionToken, hash string, initialSettings *captchaSettingsResponse) (string, error) {
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
    settingsRespRaw, err := vkReq("captchaNotRobot.settings", baseParams)
    if err != nil {
        return "", fmt.Errorf("settings failed: %w", err)
    }
    settingsResp, err := parseCaptchaSettingsResponse(settingsRespRaw)
    if err != nil {
        return "", fmt.Errorf("parse settings failed: %w", err)
    }
    settingsResp = mergeCaptchaSettings(settingsResp, initialSettings)
    time.Sleep(time.Duration(100+mathrand.Intn(100)) * time.Millisecond)

    // Step 2: componentDone
    log.Printf("[Captcha] Step 2/4: componentDone")

    browserFp := generateBrowserFp(profile)

    componentDoneData := baseParams + fmt.Sprintf("&browser_fp=%s&device=%s",
        browserFp, url.QueryEscape(buildCaptchaDeviceJSON(profile)))

    _, err = vkReq("captchaNotRobot.componentDone", componentDoneData)
    if err != nil {
        return "", fmt.Errorf("componentDone failed: %w", err)
    }
    time.Sleep(time.Duration(1500+mathrand.Intn(1000)) * time.Millisecond)

    // Step 3: checkbox check
    log.Printf("[Captcha] Step 3/4: check (checkbox)")

    cursorJSON := generateFakeCursor()
    answer := base64.StdEncoding.EncodeToString([]byte("{}"))
    debugInfoBytes := md5.Sum([]byte(profile.UserAgent + strconv.FormatInt(time.Now().UnixNano(), 10)))
    debugInfo := hex.EncodeToString(debugInfoBytes[:])
    connectionRtt := "[50,50,50,50,50,50,50,50,50,50]"
    connectionDownlink := "[9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5,9.5]"

    checkData := baseParams + fmt.Sprintf(
        "&accelerometer=%s&gyroscope=%s&motion=%s&cursor=%s&taps=%s&connectionRtt=%s&connectionDownlink=%s"+
            "&browser_fp=%s&hash=%s&answer=%s&debug_info=%s",
        url.QueryEscape("[]"),
        url.QueryEscape("[]"),
        url.QueryEscape("[]"),
        url.QueryEscape(cursorJSON),
        url.QueryEscape("[]"),
        url.QueryEscape(connectionRtt),
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

    sliderSettings, hasSlider := settingsResp.SettingsByType[sliderCaptchaType]
    log.Printf(
        "[Captcha] Slider settings found=%v, show_type=%q, available_types=%s",
        hasSlider,
        settingsResp.ShowCaptchaType,
        describeCaptchaTypes(settingsResp.SettingsByType),
    )

    sliderToken, sliderErr := solveSliderCaptcha(vkReq, baseParams, browserFp, hash, sliderSettings)
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

func generateBrowserFp(profile Profile) string {
    data := profile.UserAgent + profile.SecChUa + "1920x1080x24" + strconv.FormatInt(time.Now().UnixNano(), 10)
    sum := md5.Sum([]byte(data))
    return hex.EncodeToString(sum[:])
}

func generateFakeCursor() string {
    startX := 600 + mathrand.Intn(400)
    startY := 300 + mathrand.Intn(200)
    startTime := time.Now().UnixMilli() - int64(mathrand.Intn(2000)+1000)
    points := make([]string, 0, 15+mathrand.Intn(10))
    for i := 0; i < 15+mathrand.Intn(10); i++ {
        startX += mathrand.Intn(15) - 5
        startY += mathrand.Intn(15) + 2
        startTime += int64(mathrand.Intn(40) + 10)
        points = append(points, fmt.Sprintf(`{"x":%d,"y":%d,"t":%d}`, startX, startY, startTime))
    }
    return "[" + strings.Join(points, ",") + "]"
}

func parseCaptchaSettingsResponse(resp map[string]interface{}) (*captchaSettingsResponse, error) {
    respObj, ok := resp["response"].(map[string]interface{})
    if !ok {
        return nil, fmt.Errorf("invalid settings response: %v", resp)
    }

    settings := &captchaSettingsResponse{
        SettingsByType: make(map[string]string),
    }
    settings.ShowCaptchaType, _ = respObj["show_captcha_type"].(string)

    rawSettings, ok := expandCaptchaSettings(respObj["captcha_settings"])
    if !ok {
        return settings, nil
    }

    for _, rawItem := range rawSettings {
        item, ok := rawItem.(map[string]interface{})
        if !ok {
            continue
        }

        captchaType, _ := item["type"].(string)
        if captchaType == "" {
            continue
        }

        normalized, err := normalizeCaptchaSettings(item["settings"])
        if err != nil {
            return nil, fmt.Errorf("invalid captcha_settings for %s: %w", captchaType, err)
        }

        settings.SettingsByType[captchaType] = normalized
    }

    return settings, nil
}

func parseCaptchaBootstrapHTML(html string) (*captchaBootstrap, error) {
    powInputRe := regexp.MustCompile(`const\s+powInput\s*=\s*"([^"]+)"`)
    powInputMatch := powInputRe.FindStringSubmatch(html)
    if len(powInputMatch) < 2 {
        return nil, fmt.Errorf("powInput not found in captcha HTML")
    }

    difficulty := 2
    for _, expr := range []*regexp.Regexp{
        regexp.MustCompile(`startsWith\('0'\.repeat\((\d+)\)\)`),
        regexp.MustCompile(`const\s+difficulty\s*=\s*(\d+)`),
    } {
        if match := expr.FindStringSubmatch(html); len(match) >= 2 {
            if parsed, err := strconv.Atoi(match[1]); err == nil {
                difficulty = parsed
                break
            }
        }
    }

    settings, err := parseCaptchaSettingsFromHTML(html)
    if err != nil {
        return nil, err
    }

    return &captchaBootstrap{
        PowInput:   powInputMatch[1],
        Difficulty: difficulty,
        Settings:   settings,
    }, nil
}

func parseCaptchaSettingsFromHTML(html string) (*captchaSettingsResponse, error) {
    initRe := regexp.MustCompile(`(?s)window\.init\s*=\s*(\{.*?})\s*;\s*window\.lang`)
    initMatch := initRe.FindStringSubmatch(html)
    if len(initMatch) < 2 {
        return &captchaSettingsResponse{SettingsByType: make(map[string]string)}, nil
    }

    var initPayload struct {
        Data struct {
            ShowCaptchaType string      `json:"show_captcha_type"`
            CaptchaSettings interface{} `json:"captcha_settings"`
        } `json:"data"`
    }
    if err := json.Unmarshal([]byte(initMatch[1]), &initPayload); err != nil {
        return nil, fmt.Errorf("parse window.init captcha data: %w", err)
    }

    return parseCaptchaSettingsResponse(map[string]interface{}{
        "response": map[string]interface{}{
            "show_captcha_type": initPayload.Data.ShowCaptchaType,
            "captcha_settings":  initPayload.Data.CaptchaSettings,
        },
    })
}

func mergeCaptchaSettings(primary *captchaSettingsResponse, fallback *captchaSettingsResponse) *captchaSettingsResponse {
    if primary == nil {
        return cloneCaptchaSettings(fallback)
    }
    if primary.SettingsByType == nil {
        primary.SettingsByType = make(map[string]string)
    }
    if fallback == nil {
        return primary
    }
    if primary.ShowCaptchaType == "" {
        primary.ShowCaptchaType = fallback.ShowCaptchaType
    }
    for captchaType, settings := range fallback.SettingsByType {
        if _, exists := primary.SettingsByType[captchaType]; !exists {
            primary.SettingsByType[captchaType] = settings
        }
    }
    return primary
}

func cloneCaptchaSettings(src *captchaSettingsResponse) *captchaSettingsResponse {
    if src == nil {
        return nil
    }

    cloned := &captchaSettingsResponse{
        ShowCaptchaType: src.ShowCaptchaType,
        SettingsByType:  make(map[string]string, len(src.SettingsByType)),
    }
    for captchaType, settings := range src.SettingsByType {
        cloned.SettingsByType[captchaType] = settings
    }
    return cloned
}

func expandCaptchaSettings(raw interface{}) ([]interface{}, bool) {
    switch value := raw.(type) {
    case nil:
        return nil, false
    case []interface{}:
        return value, true
    case map[string]interface{}:
        items := make([]interface{}, 0, len(value))
        for captchaType, settings := range value {
            items = append(items, map[string]interface{}{
                "type":     captchaType,
                "settings": settings,
            })
        }
        return items, true
    case string:
        trimmed := strings.TrimSpace(value)
        if trimmed == "" {
            return nil, false
        }

        var items []interface{}
        if err := json.Unmarshal([]byte(trimmed), &items); err == nil {
            return items, true
        }

        var mapping map[string]interface{}
        if err := json.Unmarshal([]byte(trimmed), &mapping); err == nil {
            return expandCaptchaSettings(mapping)
        }
    }

    return nil, false
}

func normalizeCaptchaSettings(raw interface{}) (string, error) {
    switch value := raw.(type) {
    case nil:
        return "", nil
    case string:
        return value, nil
    default:
        data, err := json.Marshal(value)
        if err != nil {
            return "", err
        }
        return string(data), nil
    }
}

func describeCaptchaTypes(settingsByType map[string]string) string {
    if len(settingsByType) == 0 {
        return "[]"
    }

    types := make([]string, 0, len(settingsByType))
    for captchaType := range settingsByType {
        types = append(types, captchaType)
    }
    sort.Strings(types)
    return "[" + strings.Join(types, ",") + "]"
}
