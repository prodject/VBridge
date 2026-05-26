package main

import (
	"context"
	"testing"
	"time"
)

func TestPoolCredsCreatesDistinctCredentialsBeforeReusing(t *testing.T) {
	var calls int

	getter, reset := poolCreds(func(_ context.Context, hash string) (*turnCred, error) {
		calls++
		return &turnCred{
			user: string(rune('a' + calls - 1)),
			pass: string(rune('A' + calls - 1)),
			addr: hash + string(rune('0'+calls-1)),
		}, nil
	}, 2)
	defer reset()

	ctx := context.Background()
	cred1, err := getter(ctx, "link-")
	if err != nil {
		t.Fatalf("first getter call failed: %v", err)
	}
	cred2, err := getter(ctx, "link-")
	if err != nil {
		t.Fatalf("second getter call failed: %v", err)
	}
	cred3, err := getter(ctx, "link-")
	if err != nil {
		t.Fatalf("third getter call failed: %v", err)
	}

	if calls != 2 {
		t.Fatalf("expected exactly 2 credential fetches, got %d", calls)
	}
	if cred1.user == cred2.user || cred1.pass == cred2.pass || cred1.addr == cred2.addr {
		t.Fatalf("expected first two credentials to be distinct, got (%q,%q,%q) and (%q,%q,%q)", cred1.user, cred1.pass, cred1.addr, cred2.user, cred2.pass, cred2.addr)
	}
	if cred3.user != cred1.user || cred3.pass != cred1.pass || cred3.addr != cred1.addr {
		t.Fatalf("expected third credential to reuse the first entry, got (%q,%q,%q) and (%q,%q,%q)", cred1.user, cred1.pass, cred1.addr, cred3.user, cred3.pass, cred3.addr)
	}
}

func TestShouldRefreshCachedCredsWhenRotationWindowReached(t *testing.T) {
	cred := &turnCred{
		user:      "u",
		pass:      "p",
		addr:      "a",
		lifetime:  10 * time.Minute,
		fetchedAt: time.Now().Add(-9 * time.Minute),
	}

	if !shouldRefreshCachedCreds([]*turnCred{cred}) {
		t.Fatal("expected cached credentials to refresh inside the rotation window")
	}
}

func TestParseHashesExtractsJoinHashes(t *testing.T) {
	got := ParseHashes("https://vk.com/call/join/abc123?foo=1, def456 , https://vk.com/call/join/ghi789/bar")
	want := []string{"abc123", "def456", "ghi789"}

	if len(got) != len(want) {
		t.Fatalf("unexpected hash count: got=%v want=%v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("unexpected hashes: got=%v want=%v", got, want)
		}
	}
}

func TestFallbackHashSkipsCurrentHash(t *testing.T) {
	tp := &turnParams{hashes: []string{"first", "second", "third"}}
	if got := tp.fallbackHash("second"); got != "first" {
		t.Fatalf("unexpected fallback hash: %q", got)
	}
}

func TestSelectTurnAddressCyclesThroughURLs(t *testing.T) {
	tp := &turnParams{}
	cred := &turnCred{turnURLs: []string{"a:1", "b:2"}}

	if got := tp.selectTurnAddress(cred); got != "a:1" {
		t.Fatalf("unexpected first turn URL: %q", got)
	}
	if got := tp.selectTurnAddress(cred); got != "b:2" {
		t.Fatalf("unexpected second turn URL: %q", got)
	}
}
