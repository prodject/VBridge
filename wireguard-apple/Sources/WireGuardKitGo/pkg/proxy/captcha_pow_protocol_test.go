package proxy

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestParsePowPageAcceptsProbeListFourthArgument(t *testing.T) {
	html := `<script>window['captchaPowResult']='v2.'+encode({'hash':h,'nonce':n,'duration_ms':0,'telemetry':{},'tel_hash':''});}("fnZQN7lKKXvo37tH",2,"pow_timeout",["nav_tamper","plugins"]));</script>`
	p, err := parsePowPage(html)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if p.Input != "fnZQN7lKKXvo37tH" || p.Difficulty != 2 || p.Envelope != envelopeTelemetry5 {
		t.Fatalf("unexpected params: %+v", p)
	}
}

func TestParsePowPageKeepsLegacyFormat(t *testing.T) {
	p, err := parsePowPage(`const powInput = "legacyInput123"; const difficulty = 3;`)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if p.Input != "legacyInput123" || p.Difficulty != 3 || p.Envelope != envelopeLegacy3 {
		t.Fatalf("unexpected params: %+v", p)
	}
}

func TestBuildPowResultUsesPageEnvelope(t *testing.T) {
	result := buildPowResult(powPageParams{Prefix: powPrefixV2, Envelope: envelopeTelemetry5}, "00ab", 7, 11)
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(result, powPrefixV2))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	want := `{"hash":"00ab","nonce":7,"duration_ms":11,"telemetry":{},"tel_hash":""}`
	if string(raw) != want {
		t.Fatalf("payload = %q, want %q", raw, want)
	}
}

func TestInitSessionBodyAndSliderSettings(t *testing.T) {
	if got := initSessionBody("T0K", "vk.com", "3"); got != "session_token=T0K&domain=vk.com&lang=3&access_token=" {
		t.Fatalf("body = %q", got)
	}
	settings, showType := initSessionSettings(map[string]interface{}{"response": map[string]interface{}{
		"show_captcha_type": "slider",
		"content_settings": []interface{}{map[string]interface{}{
			"type": "slider", "settings": "old", "settings_key": "current",
		}},
	}})
	if showType != "slider" || extractSliderSettings(settings) != "current" {
		t.Fatalf("show=%q settings=%q", showType, extractSliderSettings(settings))
	}
}
