package main

import "testing"

func TestPoolCredsCreatesDistinctCredentialsBeforeReusing(t *testing.T) {
	var calls int

	getter, reset := poolCreds(func(link string) (string, string, string, error) {
		calls++
		return string(rune('a' + calls - 1)), string(rune('A' + calls - 1)), string(rune('0' + calls - 1)), nil
	}, 2)
	defer reset()

	u1, p1, a1, err := getter("link")
	if err != nil {
		t.Fatalf("first getter call failed: %v", err)
	}
	u2, p2, a2, err := getter("link")
	if err != nil {
		t.Fatalf("second getter call failed: %v", err)
	}
	u3, p3, a3, err := getter("link")
	if err != nil {
		t.Fatalf("third getter call failed: %v", err)
	}

	if calls != 2 {
		t.Fatalf("expected exactly 2 credential fetches, got %d", calls)
	}
	if u1 == u2 || p1 == p2 || a1 == a2 {
		t.Fatalf("expected first two credentials to be distinct, got (%q,%q,%q) and (%q,%q,%q)", u1, p1, a1, u2, p2, a2)
	}
	if u3 != u1 || p3 != p1 || a3 != a1 {
		t.Fatalf("expected third credential to reuse the first entry, got (%q,%q,%q) and (%q,%q,%q)", u1, p1, a1, u3, p3, a3)
	}
}

