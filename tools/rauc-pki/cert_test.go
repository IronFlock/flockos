package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var now = time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)

func newKey(t *testing.T, bits int) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestCAProfile(t *testing.T) {
	der, err := selfSign("IronFlockOS root CA", 20, newKey(t, 2048), now)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	if !c.IsCA || c.MaxPathLen != 0 || !c.MaxPathLenZero {
		t.Errorf("CA constraints: IsCA=%v MaxPathLen=%d zero=%v", c.IsCA, c.MaxPathLen, c.MaxPathLenZero)
	}
	if c.KeyUsage != x509.KeyUsageCertSign|x509.KeyUsageCRLSign || len(c.ExtKeyUsage) != 0 {
		t.Errorf("CA usage: %v %v", c.KeyUsage, c.ExtKeyUsage)
	}
	if c.SignatureAlgorithm != x509.SHA256WithRSA {
		t.Errorf("signature algorithm %v", c.SignatureAlgorithm)
	}
	if got := c.NotAfter.Year(); got != 2046 {
		t.Errorf("CA expires %d, want 2046", got)
	}
	if c.Subject.CommonName != "IronFlockOS root CA" || c.Subject.Organization[0] != "IronFlock" {
		t.Errorf("subject %v", c.Subject)
	}
}

func TestSignerChainsToTheCAForCodeSigningOnly(t *testing.T) {
	caKey, signerKey := newKey(t, 2048), newKey(t, 2048)
	caDER, err := selfSign("IronFlockOS root CA", 20, caKey, now)
	if err != nil {
		t.Fatal(err)
	}
	der, err := issue("IronFlockOS bundle signer 2026", 3, &signerKey.PublicKey, caDER, caKey, now)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	ca, _ := x509.ParseCertificate(caDER)
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	if _, err := c.Verify(x509.VerifyOptions{Roots: roots, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning}}); err != nil {
		t.Fatalf("code signing: %v", err)
	}
	if _, err := c.Verify(x509.VerifyOptions{Roots: roots, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err == nil {
		t.Error("the signer must not be valid for TLS")
	}
	if c.IsCA || c.KeyUsage != x509.KeyUsageDigitalSignature {
		t.Errorf("signer: IsCA=%v usage=%v", c.IsCA, c.KeyUsage)
	}
	if string(c.AuthorityKeyId) != string(ca.SubjectKeyId) {
		t.Error("the signer does not name the CA's key")
	}
	if got := c.NotAfter.Year(); got != 2029 {
		t.Errorf("signer expires %d, want 2029", got)
	}
}

func TestSignerNeverOutlivesTheCA(t *testing.T) {
	caKey, signerKey := newKey(t, 2048), newKey(t, 2048)
	caDER, _ := selfSign("short CA", 1, caKey, now)
	der, err := issue("signer", 3, &signerKey.PublicKey, caDER, caKey, now)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	ca, _ := x509.ParseCertificate(caDER)
	if !c.NotAfter.Equal(ca.NotAfter) {
		t.Errorf("signer until %v, CA until %v", c.NotAfter, ca.NotAfter)
	}
}

func TestIssueRefusesAMismatchedCAKeyAndTheCAKeyAsSigner(t *testing.T) {
	caKey, other := newKey(t, 2048), newKey(t, 2048)
	caDER, _ := selfSign("IronFlockOS root CA", 20, caKey, now)
	if _, err := issue("x", 3, &other.PublicKey, caDER, other, now); err == nil || !strings.Contains(err.Error(), "not the key of the CA") {
		t.Errorf("mismatched CA key: %v", err)
	}
	if _, err := issue("x", 3, &caKey.PublicKey, caDER, caKey, now); err == nil || !strings.Contains(err.Error(), "must not be the CA key") {
		t.Errorf("CA key as signer: %v", err)
	}
}

// fakeKMS serves the two KMS calls rauc-pki makes with a local key.
func fakeKMS(t *testing.T, key *rsa.PrivateKey, name string, damage bool) *httptest.Server {
	t.Helper()
	pubDER, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
	pubPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}))
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/v1/")
		switch {
		case r.Method == http.MethodGet && path == name+"/publicKey":
			_ = json.NewEncoder(w).Encode(map[string]string{"pem": pubPEM, "algorithm": keyAlgorithm, "pemCrc32c": crc([]byte(pubPEM))})
		case r.Method == http.MethodPost && path == name+":asymmetricSign":
			var req struct {
				Digest struct{ Sha256 string } `json:"digest"`
				Crc    string                  `json:"digestCrc32c"`
			}
			_ = json.NewDecoder(r.Body).Decode(&req)
			digest, _ := base64.StdEncoding.DecodeString(req.Digest.Sha256)
			sig, err := rsa.SignPKCS1v15(nil, key, crypto.SHA256, digest)
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			sigCrc := crc(sig)
			if damage {
				sigCrc = "1"
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"signature": base64.StdEncoding.EncodeToString(sig), "signatureCrc32c": sigCrc,
				"verifiedDigestCrc32c": req.Crc == crc(digest), "name": name,
			})
		default:
			http.NotFound(w, r)
		}
	}))
}

func TestCAThroughTheKMSRESTClient(t *testing.T) {
	key := newKey(t, 4096)
	name := "projects/p/locations/l/keyRings/ironflockos-rauc-ca/cryptoKeys/root/cryptoKeyVersions/1"
	srv := fakeKMS(t, key, name, false)
	defer srv.Close()
	api := &kmsREST{client: srv.Client(), endpoint: srv.URL + "/v1/"}
	signer, err := newKMSSigner(context.Background(), api, name)
	if err != nil {
		t.Fatal(err)
	}
	der, err := selfSign("IronFlockOS root CA", 20, signer, now)
	if err != nil {
		t.Fatal(err)
	}
	c, _ := x509.ParseCertificate(der)
	if !c.PublicKey.(*rsa.PublicKey).Equal(&key.PublicKey) {
		t.Error("the certificate carries another key")
	}
}

func TestKMSClientRejectsADamagedSignature(t *testing.T) {
	key := newKey(t, 4096)
	name := "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1"
	srv := fakeKMS(t, key, name, true)
	defer srv.Close()
	api := &kmsREST{client: srv.Client(), endpoint: srv.URL + "/v1/"}
	sum := sha256.Sum256([]byte("x"))
	if _, err := api.asymmetricSign(context.Background(), name, sum[:]); err == nil || !strings.Contains(err.Error(), "damaged") {
		t.Errorf("damaged signature accepted: %v", err)
	}
}

func TestKMSSignerSignsSHA256PKCS1Only(t *testing.T) {
	s := &kmsSigner{name: "k", pub: &newKey(t, 2048).PublicKey}
	if _, err := s.Sign(nil, make([]byte, 48), crypto.SHA384); err == nil {
		t.Error("SHA-384 accepted")
	}
	if _, err := s.Sign(nil, make([]byte, 32), &rsa.PSSOptions{Hash: crypto.SHA256}); err == nil {
		t.Error("PSS accepted")
	}
}

func TestRunNeverOverwritesACertificate(t *testing.T) {
	out := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(out, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := run([]string{"ca", "-ca-key", "k", "-cn", "c", "-years", "1", "-out", out}, os.Stdout)
	if err == nil || !strings.Contains(err.Error(), "never overwritten") {
		t.Errorf("overwrite: %v", err)
	}
}
