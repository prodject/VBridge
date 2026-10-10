package main

import (
	"reflect"
	"testing"
)

func TestServerBackupAdminArgs(t *testing.T) {
	enabled := true
	tests := []struct {
		request serverAdminRequest
		want    []string
	}{
		{serverAdminRequest{Action: "backup-status"}, []string{"backup-status"}},
		{serverAdminRequest{Action: "backup-create"}, []string{"backup-create", "--reason", "manual"}},
		{serverAdminRequest{Action: "backup-verify", BackupID: "20261010T120000Z-abcdef123456"}, []string{"backup-verify", "--id", "20261010T120000Z-abcdef123456"}},
		{serverAdminRequest{Action: "backup-export", BackupID: "20261010T120000Z-abcdef123456"}, []string{"backup-export", "--id", "20261010T120000Z-abcdef123456"}},
		{serverAdminRequest{Action: "backup-delete", BackupID: "20261010T120000Z-abcdef123456"}, []string{"backup-delete", "--id", "20261010T120000Z-abcdef123456", "--confirm", "УДАЛИТЬ"}},
		{serverAdminRequest{Action: "backup-configure", BackupEnabled: &enabled, BackupInterval: 24, BackupKeep: 14}, []string{"backup-configure", "--enabled", "true", "--interval-hours", "24", "--retention", "14"}},
	}

	for _, tt := range tests {
		got, err := tt.request.adminArgs()
		if err != nil {
			t.Fatalf("adminArgs(%q): %v", tt.request.Action, err)
		}
		if !reflect.DeepEqual(got, tt.want) {
			t.Errorf("adminArgs(%q) = %#v, want %#v", tt.request.Action, got, tt.want)
		}
	}
}
