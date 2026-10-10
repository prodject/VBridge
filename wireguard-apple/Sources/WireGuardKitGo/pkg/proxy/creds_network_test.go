package proxy

import (
	"errors"
	"testing"
)

func TestTransientNetworkErrorAfterPathLoss(t *testing.T) {
	tests := []struct {
		message string
		want    bool
	}{
		{"read: can't assign requested address", true},
		{"write: can't assign requested address", true},
		{"dial tcp: can't assign requested address", false},
	}

	for _, tt := range tests {
		if got := isTransientNetworkError(errors.New(tt.message)); got != tt.want {
			t.Errorf("isTransientNetworkError(%q) = %v, want %v", tt.message, got, tt.want)
		}
	}
}
