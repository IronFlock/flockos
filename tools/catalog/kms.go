package main

// Cloud KMS through its REST API, as the Application Default Credentials (the
// release run's workload identity). An Ed25519 key signs the message itself,
// not a digest; CRC32C checks guard both directions, as KMS recommends.
// After tools/rauc-pki/kms.go.

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"strconv"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const signAlgorithm = "EC_SIGN_ED25519"

type kmsAPI interface {
	sign(ctx context.Context, name string, data []byte) ([]byte, error)
	publicKey(ctx context.Context, name string) (ed25519.PublicKey, error)
}

var newKMS = func(ctx context.Context) (kmsAPI, error) {
	creds, err := google.FindDefaultCredentials(ctx, "https://www.googleapis.com/auth/cloudkms")
	if err != nil {
		return nil, fmt.Errorf("kms: no Google credentials: %w", err)
	}
	return &kmsREST{client: oauth2.NewClient(ctx, creds.TokenSource), endpoint: "https://cloudkms.googleapis.com/v1/"}, nil
}

type kmsREST struct {
	client   *http.Client
	endpoint string
}

var crc32c = crc32.MakeTable(crc32.Castagnoli)

func crc(data []byte) string { return strconv.FormatUint(uint64(crc32.Checksum(data, crc32c)), 10) }

func (k *kmsREST) call(ctx context.Context, method, path string, body, into any) error {
	var in io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		in = bytes.NewReader(data)
	}
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, k.endpoint+path, in)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return fmt.Errorf("kms: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("kms: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("kms: %s %s: %s: %s", method, path, resp.Status, bytes.TrimSpace(data))
	}
	return json.Unmarshal(data, into)
}

func (k *kmsREST) sign(ctx context.Context, name string, data []byte) ([]byte, error) {
	var answer struct {
		Signature          string `json:"signature"`
		SignatureCrc32c    string `json:"signatureCrc32c"`
		VerifiedDataCrc32c bool   `json:"verifiedDataCrc32c"`
		Name               string `json:"name"`
	}
	request := map[string]any{
		"data":       base64.StdEncoding.EncodeToString(data),
		"dataCrc32c": crc(data),
	}
	if err := k.call(ctx, http.MethodPost, name+":asymmetricSign", request, &answer); err != nil {
		return nil, err
	}
	if !answer.VerifiedDataCrc32c {
		return nil, errors.New("kms: the message was damaged on the way to KMS")
	}
	if answer.Name != name {
		return nil, fmt.Errorf("kms: signed with %q, not %q", answer.Name, name)
	}
	sig, err := base64.StdEncoding.DecodeString(answer.Signature)
	if err != nil {
		return nil, fmt.Errorf("kms: the signature is not base64: %w", err)
	}
	if crc(sig) != answer.SignatureCrc32c {
		return nil, errors.New("kms: the signature was damaged on the way back")
	}
	return sig, nil
}

func (k *kmsREST) publicKey(ctx context.Context, name string) (ed25519.PublicKey, error) {
	var answer struct {
		Pem       string `json:"pem"`
		Algorithm string `json:"algorithm"`
		PemCrc32c string `json:"pemCrc32c"`
	}
	if err := k.call(ctx, http.MethodGet, name+"/publicKey", nil, &answer); err != nil {
		return nil, err
	}
	if answer.Algorithm != signAlgorithm {
		return nil, fmt.Errorf("kms: %s is %s, want %s", name, answer.Algorithm, signAlgorithm)
	}
	if answer.PemCrc32c != "" && crc([]byte(answer.Pem)) != answer.PemCrc32c {
		return nil, errors.New("kms: the public key was damaged on the way")
	}
	return parsePublicKey(answer.Pem)
}
