package proxy

import "testing"

func TestFatalCallError(t *testing.T) {
	tests := []struct {
		name    string
		code    float64
		message string
		fatal   bool
	}{
		{name: "call not found", code: 951, message: "Call not found", fatal: true},
		{name: "invalid join link", code: 954, message: "Invalid join link", fatal: true},
		{name: "legacy call error", code: 9008, message: "Join link is not valid", fatal: true},
		{name: "captcha", code: 14, message: "Captcha needed", fatal: false},
		{name: "rate limit", code: 6, message: "Too many requests", fatal: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := map[string]interface{}{
				"error": map[string]interface{}{
					"error_code": test.code,
					"error_msg":  test.message,
				},
			}
			got := fatalCallError(response)
			if test.fatal {
				if got == nil {
					t.Fatal("fatalCallError returned nil")
				}
				if got.Code != int(test.code) || got.Message != test.message {
					t.Fatalf("unexpected error: %#v", got)
				}
			} else if got != nil {
				t.Fatalf("unexpected fatal error: %#v", got)
			}
		})
	}
}
