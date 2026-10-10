package proxy

import "testing"

func TestConnStartDelay(t *testing.T) {
	if got := connStartDelay(0); got != 0 {
		t.Fatalf("bootstrap delay = %s, want 0", got)
	}
	for i := 0; i < 1000; i++ {
		delay := connStartDelay(i + 1)
		if delay < 0 || delay >= connStartStagger {
			t.Fatalf("connection delay = %s, want [0, %s)", delay, connStartStagger)
		}
	}
}
