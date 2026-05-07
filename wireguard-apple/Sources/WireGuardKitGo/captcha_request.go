package main

import (
	"fmt"
	neturl "net/url"
	"regexp"
	"strings"
)

func normalizeCaptchaAttempt(attempt string) string {
	trimmed := strings.TrimSpace(attempt)
	if trimmed == "" || trimmed == "0" {
		return "1"
	}
	return trimmed
}

func buildAnonymousTokenPayload(link string, name string, accessToken string, captchaSid string, captchaKey string, successToken string, captchaTs string, captchaAttempt string) string {
	values := neturl.Values{}
	values.Set("vk_join_link", "https://vk.com/call/join/"+link)
	values.Set("name", name)
	values.Set("access_token", accessToken)

	if captchaSid != "" {
		values.Set("captcha_sid", captchaSid)
	}
	if captchaKey != "" || successToken != "" {
		values.Set("captcha_key", captchaKey)
	}
	if captchaTs != "" {
		values.Set("captcha_ts", captchaTs)
	}
	if captchaAttempt != "" {
		values.Set("captcha_attempt", normalizeCaptchaAttempt(captchaAttempt))
	}
	if successToken != "" {
		values.Set("is_sound_captcha", "0")
		values.Set("success_token", successToken)
	}

	return values.Encode()
}

func normalizeCaptchaUserAgent(userAgent string) string {
	trimmed := strings.TrimSpace(userAgent)
	if trimmed == "" {
		return "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
	}

	chromeVersionRe := regexp.MustCompile(`Chrome/\d+(\.\d+)*`)
	if chromeVersionRe.MatchString(trimmed) {
		return chromeVersionRe.ReplaceAllString(trimmed, "Chrome/120.0.0.0")
	}
	return trimmed
}

func buildCaptchaClientHints(userAgent string) (secChUa string, platform string, mobile string) {
	ua := normalizeCaptchaUserAgent(userAgent)
	major := "120"
	if match := regexp.MustCompile(`Chrome/(\d+)`).FindStringSubmatch(ua); len(match) >= 2 {
		major = match[1]
	}

	lowerUA := strings.ToLower(ua)
	platform = "Windows"
	mobile = "?0"
	brand := "Google Chrome"

	switch {
	case strings.Contains(lowerUA, "android"):
		platform = "Android"
		mobile = "?1"
	case strings.Contains(lowerUA, "iphone") || strings.Contains(lowerUA, "ipad"):
		platform = "iOS"
		mobile = "?1"
	case strings.Contains(lowerUA, "linux"):
		platform = "Linux"
	case strings.Contains(lowerUA, "mac os x") || strings.Contains(lowerUA, "macintosh"):
		platform = "macOS"
	}

	if strings.Contains(lowerUA, "edg/") {
		brand = "Microsoft Edge"
	}
	if strings.Contains(lowerUA, "wv)") || strings.Contains(lowerUA, "android webview") {
		brand = "Android WebView"
	}

	secChUa = fmt.Sprintf(`"Chromium";v="%s", "Not-A.Brand";v="24", "%s";v="%s"`, major, brand, major)
	return secChUa, platform, mobile
}

func applyCaptchaApiHeaders(headers interface{ Set(string, string) }, userAgent string) {
	normalizedUA := normalizeCaptchaUserAgent(userAgent)
	secChUa, secChPlatform, secChMobile := buildCaptchaClientHints(normalizedUA)
	headers.Set("User-Agent", normalizedUA)
	headers.Set("Accept", "*/*")
	headers.Set("Accept-Language", "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7")
	headers.Set("Origin", "https://id.vk.ru")
	headers.Set("Referer", "https://id.vk.ru/")
	headers.Set("sec-ch-ua-platform", fmt.Sprintf(`"%s"`, secChPlatform))
	headers.Set("sec-ch-ua", secChUa)
	headers.Set("sec-ch-ua-mobile", secChMobile)
	headers.Set("Sec-Fetch-Site", "same-site")
	headers.Set("Sec-Fetch-Mode", "cors")
	headers.Set("Sec-Fetch-Dest", "empty")
	headers.Set("DNT", "1")
	headers.Set("Priority", "u=1, i")
	headers.Set("Cache-Control", "no-cache")
	headers.Set("Pragma", "no-cache")
}

func applyCaptchaDocumentHeaders(headers interface{ Set(string, string) }, userAgent string) {
	normalizedUA := normalizeCaptchaUserAgent(userAgent)
	secChUa, secChPlatform, secChMobile := buildCaptchaClientHints(normalizedUA)
	headers.Set("User-Agent", normalizedUA)
	headers.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	headers.Set("Accept-Language", "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7")
	headers.Set("sec-ch-ua-platform", fmt.Sprintf(`"%s"`, secChPlatform))
	headers.Set("sec-ch-ua", secChUa)
	headers.Set("sec-ch-ua-mobile", secChMobile)
	headers.Set("Sec-Fetch-Site", "none")
	headers.Set("Sec-Fetch-Mode", "navigate")
	headers.Set("Sec-Fetch-Dest", "document")
	headers.Set("DNT", "1")
	headers.Set("Cache-Control", "no-cache")
	headers.Set("Pragma", "no-cache")
}
