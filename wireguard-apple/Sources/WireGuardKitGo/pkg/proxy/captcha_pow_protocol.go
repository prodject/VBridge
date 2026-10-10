package proxy

import (
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net/url"
	"regexp"
	"strconv"
)

// powEnvelope describes the exact answer shape requested by the captcha page.
// VK has used the same v2 prefix for both shapes, so the page body decides it.
type powEnvelope uint8

const (
	envelopeLegacy3 powEnvelope = iota
	envelopeTelemetry5
)

type powPageParams struct {
	Input      string
	Difficulty int
	Envelope   powEnvelope
	Prefix     string
	DebugInfo  string
	Lang       string
}

var (
	// The first three arguments are stable. Since 2026-09-30 VK appends a
	// fourth probe-list argument, which must not make the parser reject the call.
	rePowIIFEArgs = regexp.MustCompile(`\}\(\s*["']([A-Za-z0-9+/=_-]{8,})["']\s*,\s*(\d+)\s*,\s*["'][^"']*["']\s*(?:,|\)\s*\))`)
	rePowLegacyInput = regexp.MustCompile(`const\s+powInput\s*=\s*"([^"]+)"`)
	rePowLegacyDiff  = regexp.MustCompile(`startsWith\('0'\.repeat\((\d+)\)\)|const\s+difficulty\s*=\s*(\d+)`)
	rePowPrefix      = regexp.MustCompile(`captchaPowResult["'\]]{0,3}\s*=\s*["']([A-Za-z0-9._-]{0,8})["']\s*\+`)
	rePowTelemetry   = regexp.MustCompile(`["']tel_hash["']\s*:`)

	reVKGlobalStart = regexp.MustCompile(`window\.vk\s*=\s*\{`)
	reVKGlobalUUID  = regexp.MustCompile(`[A-Za-z_$][\w$]*\s*:\s*"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"`)
	reVKGlobalLang  = regexp.MustCompile(`\blang\s*:\s*(\d+)\b`)
)

const powPrefixV2 = "v2."

func parsePowPage(html string) (powPageParams, error) {
	p := powPageParams{Prefix: powPrefixV2, Envelope: envelopeLegacy3}
	prefixRead := false
	if m := rePowPrefix.FindStringSubmatch(html); len(m) >= 2 {
		p.Prefix = m[1]
		prefixRead = true
	}
	if p.Prefix != powPrefixV2 {
		return powPageParams{}, fmt.Errorf("captcha pow envelope prefix %q is unknown", p.Prefix)
	}
	if rePowTelemetry.MatchString(html) {
		p.Envelope = envelopeTelemetry5
		if !prefixRead {
			return powPageParams{}, errors.New("captcha pow envelope prefix is not readable on a telemetry-shaped page")
		}
	}
	p.DebugInfo, p.Lang = parseVKGlobal(html)

	if m := rePowIIFEArgs.FindStringSubmatch(html); len(m) >= 3 {
		d, err := strconv.Atoi(m[2])
		if err != nil || d <= 0 || d > 8 {
			return powPageParams{}, fmt.Errorf("captcha pow difficulty %q out of range", m[2])
		}
		p.Input, p.Difficulty = m[1], d
		return p, nil
	}
	if m := rePowLegacyInput.FindStringSubmatch(html); len(m) >= 2 {
		p.Input, p.Difficulty = m[1], 2
		if dm := rePowLegacyDiff.FindStringSubmatch(html); len(dm) >= 2 {
			raw := dm[1]
			if raw == "" && len(dm) >= 3 {
				raw = dm[2]
			}
			if d, err := strconv.Atoi(raw); err == nil && d > 0 && d <= 8 {
				p.Difficulty = d
			}
		}
		return p, nil
	}
	return powPageParams{}, errors.New("captcha pow parameters not found in HTML")
}

func vkGlobalBlock(html string) string {
	m := reVKGlobalStart.FindStringIndex(html)
	if m == nil {
		return ""
	}
	start, depth := m[1]-1, 0
	var inString byte
	for i := start; i < len(html); i++ {
		c := html[i]
		if inString != 0 {
			if c == '\\' {
				i++
			} else if c == inString {
				inString = 0
			}
			continue
		}
		switch c {
		case '"', '\'':
			inString = c
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return html[start : i+1]
			}
		}
	}
	return ""
}

func parseVKGlobal(html string) (debugInfo, lang string) {
	block := vkGlobalBlock(html)
	if block == "" {
		return "", ""
	}
	if matches := reVKGlobalUUID.FindAllStringSubmatch(block, -1); len(matches) > 0 {
		debugInfo = matches[0][1]
		if len(matches) > 1 {
			log.Printf("pow: window.vk carries %d UUID values; using the first as debug_info", len(matches))
		}
	}
	if m := reVKGlobalLang.FindStringSubmatch(block); len(m) >= 2 {
		lang = m[1]
	}
	return debugInfo, lang
}

func buildPowResult(p powPageParams, hexHash string, nonce int, durationMs int64) string {
	var payload string
	if p.Envelope == envelopeTelemetry5 {
		payload = fmt.Sprintf(`{"hash":"%s","nonce":%d,"duration_ms":%d,"telemetry":{},"tel_hash":""}`, hexHash, nonce, durationMs)
	} else {
		payload = fmt.Sprintf(`{"hash":"%s","nonce":%d,"duration_ms":%d}`, hexHash, nonce, durationMs)
	}
	return p.Prefix + base64.StdEncoding.EncodeToString([]byte(payload))
}

func initSessionBody(sessionToken, domain, lang string) string {
	if lang == "" {
		lang = "0"
	}
	return fmt.Sprintf("session_token=%s&domain=%s&lang=%s",
		url.QueryEscape(sessionToken), url.QueryEscape(domain), url.QueryEscape(lang)) + accessTokenSuffix
}

// initSessionSettings adapts the BFF response to the legacy slider solver's
// response.captcha_settings format. settings_key is the value VK expects.
func initSessionSettings(resp map[string]interface{}) (map[string]interface{}, string) {
	obj, ok := resp["response"].(map[string]interface{})
	if !ok {
		return nil, ""
	}
	showType, _ := obj["show_captcha_type"].(string)
	var settings []interface{}
	if content, ok := obj["content_settings"].([]interface{}); ok {
		for _, raw := range content {
			item, ok := raw.(map[string]interface{})
			if !ok {
				continue
			}
			converted := map[string]interface{}{"type": item["type"]}
			if key, _ := item["settings_key"].(string); key != "" {
				converted["settings"] = key
			} else {
				converted["settings"] = item["settings"]
			}
			settings = append(settings, converted)
		}
	}
	data := map[string]interface{}{"show_captcha_type": showType}
	if settings != nil {
		data["captcha_settings"] = settings
	}
	return map[string]interface{}{"response": data}, showType
}
