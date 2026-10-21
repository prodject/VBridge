package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const wdttServerVersion = "simple-1"

type adminResponse struct {
	OK             bool                  `json:"ok"`
	Message        string                `json:"message,omitempty"`
	BackupStatus   *serverBackupStatus   `json:"backup_status,omitempty"`
	Backup         *serverBackupSummary  `json:"backup,omitempty"`
	BackupDocument *serverBackupDocument `json:"backup_document,omitempty"`
}

type simpleBackupRequest struct {
	MainPassword string   `json:"main_password"`
	Args         []string `json:"args"`
}

func clientDeviceIDSet(loaded *Database) map[string]struct{} {
	ids := make(map[string]struct{})
	for id := range loaded.Devices {
		if id != "" && id != "multi" {
			ids[id] = struct{}{}
		}
	}
	for _, access := range loaded.Passwords {
		if access == nil {
			continue
		}
		if access.DeviceID != "" && access.DeviceID != "multi" {
			ids[access.DeviceID] = struct{}{}
		}
		for _, id := range access.DeviceIDs {
			if id != "" && id != "multi" {
				ids[id] = struct{}{}
			}
		}
	}
	return ids
}

func executeSimpleBackupRequest(configDir string, request simpleBackupRequest) (adminResponse, error) {
	dbMutex.Lock()
	if db == nil || strings.TrimSpace(request.MainPassword) == "" ||
		subtle.ConstantTimeCompare([]byte(request.MainPassword), []byte(db.MainPassword)) != 1 {
		dbMutex.Unlock()
		return adminResponse{}, errors.New("main administrator password does not match")
	}
	var snapshot *Database
	var err error
	if len(request.Args) > 0 && (request.Args[0] == "backup-create" || request.Args[0] == "backup-configure") {
		snapshot, err = cloneDatabaseForBackup(db)
	}
	dbMutex.Unlock()
	if err != nil {
		return adminResponse{}, err
	}
	if len(request.Args) == 0 {
		return adminResponse{}, errors.New("missing backup command")
	}
	serverBackupRequestMu.Lock()
	defer serverBackupRequestMu.Unlock()
	args := request.Args[1:]
	switch request.Args[0] {
	case "backup-status", "backup-list":
		status, err := serverBackupStatusFor(configDir)
		return adminResponse{OK: err == nil, BackupStatus: status}, err
	case "backup-configure":
		return adminBackupConfigure(configDir, snapshot, args)
	case "backup-create":
		return adminBackupCreate(configDir, snapshot, args)
	case "backup-verify":
		return adminBackupVerify(configDir, args)
	case "backup-export":
		return adminBackupExport(configDir, args)
	case "backup-delete":
		return adminBackupDelete(configDir, args)
	default:
		return adminResponse{}, errors.New("unsupported Simple backup command")
	}
}

func startSimpleBackupAdmin(ctx context.Context, configDir, socketPath string) error {
	if err := ensurePrivateDirectory(filepath.Dir(socketPath)); err != nil {
		return err
	}
	if info, err := os.Lstat(socketPath); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("unsafe Simple backup socket path")
		}
		if err := os.Remove(socketPath); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(socketPath, 0600); err != nil {
		_ = listener.Close()
		return err
	}
	go func() { <-ctx.Done(); _ = listener.Close() }()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(time.Minute))
				var request simpleBackupRequest
				response := adminResponse{}
				decoder := json.NewDecoder(io.LimitReader(conn, 64<<10))
				if err := decoder.Decode(&request); err != nil {
					response.Message = "invalid backup request"
				} else {
					var err error
					response, err = executeSimpleBackupRequest(configDir, request)
					if err != nil {
						response = adminResponse{Message: fmt.Sprint(err)}
					}
				}
				_ = json.NewEncoder(conn).Encode(response)
			}(conn)
		}
	}()
	return nil
}
