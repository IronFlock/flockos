package main

// The two certificate profiles of the FlockOS RAUC PKI (ADR-0006,
// docs/signing.md): a root CA that only issues signer certificates, and a
// bundle signer that RAUC accepts with `check-purpose=codesign`.

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1" //nolint:gosec // subject key identifier, RFC 5280 method 1, not a signature
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"time"
)

const organization = "IronFlock"

func serial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
}

func keyID(pub *rsa.PublicKey) []byte {
	sum := sha1.Sum(x509.MarshalPKCS1PublicKey(pub)) //nolint:gosec // see import
	return sum[:]
}

// caTemplate: CA:TRUE with path length 0, certificate and CRL signing only.
func caTemplate(cn string, pub *rsa.PublicKey, now time.Time, years int) (*x509.Certificate, error) {
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	return &x509.Certificate{
		SerialNumber:          sn,
		Subject:               pkix.Name{Organization: []string{organization}, CommonName: cn},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(years, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		SubjectKeyId:          keyID(pub),
		SignatureAlgorithm:    x509.SHA256WithRSA,
	}, nil
}

// signerTemplate: an end-entity certificate for code signing (RAUC's
// codesign purpose), digital signature only.
func signerTemplate(cn string, pub *rsa.PublicKey, now time.Time, years int) (*x509.Certificate, error) {
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	return &x509.Certificate{
		SerialNumber:          sn,
		Subject:               pkix.Name{Organization: []string{organization}, CommonName: cn},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(years, 0, 0),
		BasicConstraintsValid: true,
		IsCA:                  false,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning},
		SubjectKeyId:          keyID(pub),
		SignatureAlgorithm:    x509.SHA256WithRSA,
	}, nil
}

// selfSign makes the root CA certificate with the CA key.
func selfSign(cn string, years int, key crypto.Signer, now time.Time) ([]byte, error) {
	pub, ok := key.Public().(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("the CA key is not RSA")
	}
	tmpl, err := caTemplate(cn, pub, now, years)
	if err != nil {
		return nil, err
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, key)
	if err != nil {
		return nil, err
	}
	return verifyIssued(der, der, false)
}

// issue makes a signer certificate for subjectKey, signed by the CA.
func issue(cn string, years int, subjectKey *rsa.PublicKey, caCertDER []byte, caKey crypto.Signer, now time.Time) ([]byte, error) {
	ca, err := x509.ParseCertificate(caCertDER)
	if err != nil {
		return nil, fmt.Errorf("CA certificate: %w", err)
	}
	caPub, ok := ca.PublicKey.(*rsa.PublicKey)
	if !ok || !caPub.Equal(caKey.Public()) {
		return nil, errors.New("the CA key is not the key of the CA certificate")
	}
	if subjectKey.Equal(caPub) {
		return nil, errors.New("the signer key must not be the CA key")
	}
	tmpl, err := signerTemplate(cn, subjectKey, now, years)
	if err != nil {
		return nil, err
	}
	if tmpl.NotAfter.After(ca.NotAfter) {
		tmpl.NotAfter = ca.NotAfter
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, subjectKey, caKey)
	if err != nil {
		return nil, err
	}
	return verifyIssued(der, caCertDER, true)
}

// verifyIssued checks the new certificate against its issuer the way a
// device does (chain to the CA, code signing for a signer) and returns it.
func verifyIssued(der, caDER []byte, codeSigning bool) ([]byte, error) {
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	usage := []x509.ExtKeyUsage{x509.ExtKeyUsageAny}
	if codeSigning {
		usage = []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning}
	}
	if _, err := cert.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: usage, CurrentTime: cert.NotBefore.Add(2 * time.Hour)}); err != nil {
		return nil, fmt.Errorf("the new certificate does not verify: %w", err)
	}
	return der, nil
}

func pemCert(der []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func readCertPEM(data []byte) ([]byte, error) {
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("no PEM certificate")
	}
	return block.Bytes, nil
}
