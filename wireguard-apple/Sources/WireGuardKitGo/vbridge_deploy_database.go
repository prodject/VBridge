package main

import (
	"crypto/rand"
	_ "embed"
	"encoding/json"
	"fmt"
	"time"

	"golang.org/x/crypto/ssh"
)

//go:embed wdtt_database_migration.py
var wdttDatabaseMigration string

func prepareWDTTDatabase(client *ssh.Client, req deployRequest) (string, error) {
	payload, err := json.Marshal(map[string]string{
		"target":        req.DeployKind,
		"main_password": req.MainPassword,
		"admin_id":      req.AdminID,
		"bot_token":     req.BotToken,
	})
	if err != nil {
		return "", err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	path := fmt.Sprintf("/tmp/vbridge-wdtt-migration-%x.json", nonce)
	// sudo consumes stdin for authentication, so use a private temporary file
	// for the migration payload and remove it on both success and failure.
	if _, err := runSSHCommandWithInput(client, "umask 077; set -C; cat > "+shellQuoteDeploy(path), payload, 20*time.Second); err != nil {
		_, _ = runSSHCommand(client, "rm -f -- "+shellQuoteDeploy(path), 20*time.Second)
		return "", err
	}
	command := "trap " + shellQuoteDeploy("rm -f -- "+shellQuoteDeploy(path)) + " EXIT; " +
		"python3 -c " + shellQuoteDeploy(wdttDatabaseMigration) + " < " + shellQuoteDeploy(path)
	defer func() { _, _ = runSSHCommand(client, "rm -f -- "+shellQuoteDeploy(path), 20*time.Second) }()
	return runSSHCommand(client, rootDeployCommand(command, req.Password), 2*time.Minute)
}
