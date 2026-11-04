package main

// Cloud KMS through its REST API, as the Application Default Credentials
// (gcloud auth application-default login). Only SHA-256 digests leave this
// process; CRC32C checks guard both directions, as KMS recommends. Adapted
// from IronFlock/workflows tools/sign-openpgp.

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
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

// The algorithm of every FlockOS RAUC key (docs/signing.md): RAUC signs
// SHA-256 digests, and a KMS key accepts only its own digest.
const keyAlgorithm = "RSA_SIGN_PKCS1_4096_SHA256"

type kmsAPI interface {
	asymmetricSign(ctx context.Context, name string, digest []byte) ([]byte, error)
	publicKey(ctx context.Context, name string) (*rsa.PublicKey, error)
}

var newKMS = func(ctx context.Context) (kmsAPI, error) {
	creds, err := google.FindDefaultCredentials(ctx, "https://www.googleapis.com/auth/cloudkms")
	if err != nil {
		return nil, fmt.Errorf("kms: no Google credentials (gcloud auth application-default login): %w", err)
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

func (k *kmsREST) asymmetricSign(ctx context.Context, name string, digest []byte) ([]byte, error) {
	var answer struct {
		Signature            string `json:"signature"`
		SignatureCrc32c      string `json:"signatureCrc32c"`
		VerifiedDigestCrc32c bool   `json:"verifiedDigestCrc32c"`
		Name                 string `json:"name"`
	}
	request := map[string]any{
		"digest":       map[string]string{"sha256": base64.StdEncoding.EncodeToString(digest)},
		"digestCrc32c": crc(digest),
	}
	if err := k.call(ctx, http.MethodPost, name+":asymmetricSign", request, &answer); err != nil {
		return nil, err
	}
	if !answer.VerifiedDigestCrc32c {
		return nil, errors.New("kms: the digest was damaged on the way to KMS")
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

func (k *kmsREST) publicKey(ctx context.Context, name string) (*rsa.PublicKey, error) {
	var answer struct {
		Pem       string `json:"pem"`
		Algorithm string `json:"algorithm"`
		PemCrc32c string `json:"pemCrc32c"`
	}
	if err := k.call(ctx, http.MethodGet, name+"/publicKey", nil, &answer); err != nil {
		return nil, err
	}
	if answer.Algorithm != keyAlgorithm {
		return nil, fmt.Errorf("kms: %s is %s, want %s", name, answer.Algorithm, keyAlgorithm)
	}
	if answer.PemCrc32c != "" && crc([]byte(answer.Pem)) != answer.PemCrc32c {
		return nil, errors.New("kms: the public key was damaged on the way")
	}
	return parsePublicKeyPEM([]byte(answer.Pem), name)
}

func parsePublicKeyPEM(data []byte, source string) (*rsa.PublicKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("%s: no PEM key", source)
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", source, err)
	}
	rsaKey, ok := key.(*rsa.PublicKey)
	if !ok || rsaKey.N.BitLen() < 4096 {
		return nil, fmt.Errorf("%s: not an RSA key of 4096 bits", source)
	}
	return rsaKey, nil
}

// kmsSigner is a crypto.Signer whose private key is a KMS key version.
type kmsSigner struct {
	ctx  context.Context
	api  kmsAPI
	name string
	pub  *rsa.PublicKey
}

func newKMSSigner(ctx context.Context, api kmsAPI, name string) (*kmsSigner, error) {
	pub, err := api.publicKey(ctx, name)
	if err != nil {
		return nil, err
	}
	return &kmsSigner{ctx: ctx, api: api, name: name, pub: pub}, nil
}

func (s *kmsSigner) Public() crypto.PublicKey { return s.pub }

func (s *kmsSigner) Sign(_ io.Reader, digest []byte, opts crypto.SignerOpts) ([]byte, error) {
	if opts.HashFunc() != crypto.SHA256 {
		return nil, fmt.Errorf("kms: %s signs SHA-256 digests only, not %v", s.name, opts.HashFunc())
	}
	if _, pss := opts.(*rsa.PSSOptions); pss {
		return nil, errors.New("kms: the key signs PKCS #1 v1.5, not PSS")
	}
	return s.api.asymmetricSign(s.ctx, s.name, digest)
}
