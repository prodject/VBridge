package proxy

import (
	"encoding/json"
	"testing"
)

func TestEffectiveCredCacheModeDefaultsToAnon(t *testing.T) {
	if got := effectiveCredCacheMode(""); got != credCacheModeAnon {
		t.Fatalf("effectiveCredCacheMode(\"\") = %q, want %q", got, credCacheModeAnon)
	}
}

func TestLegacyCredCacheDecodesAsAnon(t *testing.T) {
	var cache credCacheFile
	if err := json.Unmarshal([]byte(`{"version":2,"saved_at":1,"creds":[]}`), &cache); err != nil {
		t.Fatalf("decode legacy cache: %v", err)
	}
	if got := effectiveCredCacheMode(cache.Mode); got != credCacheModeAnon {
		t.Fatalf("legacy cache mode = %q, want %q", got, credCacheModeAnon)
	}
}

func TestExplicitCredCacheModeIsPreserved(t *testing.T) {
	const mode = "cookie"
	if got := effectiveCredCacheMode(mode); got != mode {
		t.Fatalf("effectiveCredCacheMode(%q) = %q", mode, got)
	}
}
