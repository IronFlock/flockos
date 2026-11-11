package main

// The device-agent's signed envelope (device-agent src/updatesig): one JSON
// file {"payload": "<base64>", "signature": "<base64 of the 64-byte Ed25519
// signature>"}, the signature over
//
//	ironflockos-manifest:v1
//	ironflockos/manifest.json
//	<sha256 hex of the payload>
//
// joined by "\n", no trailing newline (ADR-0009). The agent reads at most
// 64 KiB of it.

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"strings"
)

const (
	signContext = "ironflockos-manifest:v1"
	signSubject = "ironflockos/manifest.json"
	maxEnvelope = 64 << 10
)

type envelope struct {
	Payload   []byte `json:"payload"`
	Signature string `json:"signature"`
}

// message is what the signature covers.
func message(payload []byte) []byte {
	sum := sha256.Sum256(payload)
	return []byte(signContext + "\n" + signSubject + "\n" + hex.EncodeToString(sum[:]))
}

// seal makes the envelope and checks that it opens with pub.
func seal(payload, signature []byte, pub ed25519.PublicKey) ([]byte, error) {
	if len(signature) != ed25519.SignatureSize {
		return nil, fmt.Errorf("a signature of %d bytes, not %d", len(signature), ed25519.SignatureSize)
	}
	data, err := json.MarshalIndent(envelope{Payload: payload, Signature: base64.StdEncoding.EncodeToString(signature)}, "", "  ")
	if err != nil {
		return nil, err
	}
	if len(data) > maxEnvelope {
		return nil, fmt.Errorf("the envelope is %d bytes; the device-agent reads %d", len(data), maxEnvelope)
	}
	if _, err := open(data, pub); err != nil {
		return nil, fmt.Errorf("the sealed catalog does not open: %w", err)
	}
	return data, nil
}

// open verifies an envelope against pub and returns its payload.
func open(data []byte, pub ed25519.PublicKey) ([]byte, error) {
	if len(data) > maxEnvelope {
		return nil, fmt.Errorf("envelope of %d bytes", len(data))
	}
	var e envelope
	if err := json.Unmarshal(data, &e); err != nil {
		return nil, fmt.Errorf("not an envelope: %w", err)
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(e.Signature))
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, errors.New("the signature is not base64 of 64 bytes")
	}
	if !ed25519.Verify(pub, message(e.Payload), sig) {
		return nil, errors.New("the signature does not verify")
	}
	return e.Payload, nil
}

// parsePublicKey reads a key as the agent lists it (standard base64 of the
// raw 32 bytes) or as a PEM public key (Cloud KMS, pki/ironflockos-catalog.pub).
func parsePublicKey(text string) (ed25519.PublicKey, error) {
	text = strings.TrimSpace(text)
	if block, _ := pem.Decode([]byte(text)); block != nil {
		key, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			return nil, err
		}
		pub, ok := key.(ed25519.PublicKey)
		if !ok {
			return nil, errors.New("not an Ed25519 public key")
		}
		return pub, nil
	}
	if i := strings.Index(text, "#"); i >= 0 {
		text = strings.TrimSpace(text[:i])
	}
	raw, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(raw) != ed25519.PublicKeySize {
		return nil, errors.New("not base64 of a 32-byte Ed25519 key, nor a PEM public key")
	}
	return ed25519.PublicKey(raw), nil
}

// parsePrivateKey reads a PKCS #8 PEM Ed25519 key (dry runs only).
func parsePrivateKey(data []byte) (ed25519.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("no PEM key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	priv, ok := key.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("not an Ed25519 private key")
	}
	return priv, nil
}
