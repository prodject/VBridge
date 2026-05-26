package main

import (
	"testing"
	"time"
)

func TestPoolCredsCreatesDistinctCredentialsBeforeReusing(t *testing.T) {
	var calls int

	getter, reset := poolCreds(func(link string) (*turnCred, error) {
		calls++
		return &turnCred{
			user: string(rune('a' + calls - 1)),
			pass: string(rune('A' + calls - 1)),
			addr: string(rune('0' + calls - 1)),
		}, nil
	}, 2)
	defer reset()

	cred1, err := getter("link")
	if err != nil {
		t.Fatalf("first getter call failed: %v", err)
	}
	cred2, err := getter("link")
	if err != nil {
		t.Fatalf("second getter call failed: %v", err)
	}
	cred3, err := getter("link")
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
