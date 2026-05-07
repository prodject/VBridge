package main

import (
	neturl "net/url"
	"testing"
)

func TestBuildAnonymousTokenPayloadEscapesSuccessTokenAndKeepsCaptchaState(t *testing.T) {
	payload := buildAnonymousTokenPayload(
		"abc123",
		"John Doe",
		"token-1",
		"sid-42",
		"",
		"tok+/=value",
		"1712345678",
		"",
	)

	values, err := neturl.ParseQuery(payload)
	if err != nil {
		t.Fatalf("ParseQuery: %v", err)
	}

	if got := values.Get("success_token"); got != "tok+/=value" {
		t.Fatalf("success_token mismatch: %q", got)
	}
	if got := values.Get("captcha_attempt"); got != "1" {
		t.Fatalf("captcha_attempt mismatch: %q", got)
	}
	if got := values.Get("captcha_ts"); got != "1712345678" {
		t.Fatalf("captcha_ts mismatch: %q", got)
	}
	if got := values.Get("captcha_sid"); got != "sid-42" {
		t.Fatalf("captcha_sid mismatch: %q", got)
	}
	if got := values.Get("name"); got != "John Doe" {
		t.Fatalf("name mismatch: %q", got)
	}
	if got := values.Get("vk_join_link"); got != "https://vk.com/call/join/abc123" {
		t.Fatalf("vk_join_link mismatch: %q", got)
	}
}

func TestBuildAnonymousTokenPayloadIncludesImageCaptchaState(t *testing.T) {
	payload := buildAnonymousTokenPayload(
		"abc123",
		"Jane Doe",
		"token-2",
		"sid-99",
		"image-key",
		"",
		"1710000000",
		"3",
	)

	values, err := neturl.ParseQuery(payload)
	if err != nil {
		t.Fatalf("ParseQuery: %v", err)
	}

	if got := values.Get("captcha_key"); got != "image-key" {
		t.Fatalf("captcha_key mismatch: %q", got)
	}
	if got := values.Get("captcha_ts"); got != "1710000000" {
		t.Fatalf("captcha_ts mismatch: %q", got)
	}
	if got := values.Get("captcha_attempt"); got != "3" {
		t.Fatalf("captcha_attempt mismatch: %q", got)
	}
}

func TestVkCaptchaErrorClassificationAllowsImageOnlyChallenges(t *testing.T) {
	imageOnly := &VkCaptchaError{
		ErrorCode:   14,
		CaptchaSid:  "sid-1",
		CaptchaImg:  "https://example.com/captcha.jpg",
		RedirectUri: "",
	}
	if !imageOnly.IsCaptchaError() {
		t.Fatal("expected image-only captcha to be classified as captcha")
	}

	redirectOnly := &VkCaptchaError{
		ErrorCode:   14,
		RedirectUri: "https://id.vk.ru/captcha?session_token=abc",
		SessionToken: "abc",
	}
	if !redirectOnly.IsCaptchaError() {
		t.Fatal("expected redirect captcha to be classified as captcha")
	}
}
