package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestStableAdminDatabase(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is required for the stable server's SSH database adapter")
	}
	for _, action := range []string{"list", "create", "unbind", "delete", "cleanup-orphans", "cleanup-expired"} {
		t.Run(action, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "passwords.json")
			fixture := `{"main_password":"owner","passwords":{
				"client":{"marker":"WDTT client","device_id":"multi","device_ids":["a","b"],"max_devices":2},
				"expired":{"device_id":"old","device_ids":["old"],"expires_at":1}
			},"devices":{"a":{},"b":{},"old":{},"orphan":{}}}`
			if err := os.WriteFile(path, []byte(fixture), 0600); err != nil {
				t.Fatal(err)
			}
			payload, _ := json.Marshal(map[string]any{
				"action": action, "mainPassword": "owner", "clientPassword": "client",
			})
			if action == "create" {
				payload, _ = json.Marshal(map[string]any{
					"action": action, "mainPassword": "owner", "clientPassword": "new-client",
				})
			}
			script := strings.Replace(wdttStableAdminScript, `CONFIG_DIR = "/etc/wdtt"`, "CONFIG_DIR = "+strconv.Quote(dir), 1)
			output, err := exec.Command(python, "-c", script, base64.StdEncoding.EncodeToString(payload)).CombinedOutput()
			if err != nil {
				t.Fatalf("adapter failed: %v\n%s", err, output)
			}
			var response serverAdminResponse
			if err := json.Unmarshal(output, &response); err != nil || !response.OK {
				t.Fatalf("invalid adapter response: %s (%v)", output, err)
			}
			if action == "list" {
				if response.State == nil || len(response.State.Passwords) != 2 {
					t.Fatalf("missing clients: %s", output)
				}
				for _, row := range response.State.Passwords {
					if row.Password == "client" && (row.Label != "WDTT client" || row.Status != "active") {
						t.Fatalf("WDTT fields were lost: %+v", row)
					}
				}
			}
			var db struct {
				Passwords map[string]struct {
					DeviceID  string   `json:"device_id"`
					DeviceIDs []string `json:"device_ids"`
				} `json:"passwords"`
				Devices map[string]json.RawMessage `json:"devices"`
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(data, &db); err != nil {
				t.Fatal(err)
			}
			switch action {
			case "create":
				if _, exists := db.Passwords["new-client"]; !exists {
					t.Fatal("new client was not persisted")
				}
			case "unbind", "delete":
				for _, id := range []string{"a", "b"} {
					if _, exists := db.Devices[id]; exists {
						t.Fatalf("bound device %s survived %s", id, action)
					}
				}
				if row, exists := db.Passwords["client"]; exists && (action == "delete" || row.DeviceID != "" || len(row.DeviceIDs) != 0) {
					t.Fatalf("client bindings survived %s", action)
				}
			case "cleanup-orphans":
				if len(db.Devices) != 3 {
					t.Fatalf("cleanup removed bound devices or kept the orphan: %s", data)
				}
			case "cleanup-expired":
				if _, exists := db.Devices["old"]; exists || len(db.Passwords["expired"].DeviceIDs) != 0 {
					t.Fatal("expired client remains bound")
				}
			}
		})
	}
}
