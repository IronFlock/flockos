// rauc-pki issues the certificates of the IronFlockOS RAUC PKI (ADR-0006,
// docs/signing.md) with keys that never leave Cloud KMS.
//
//	rauc-pki ca    -ca-key VERSION -cn NAME -years 20 -out CA.pem
//	rauc-pki issue -ca-key VERSION -ca-cert CA.pem -key VERSION -cn NAME -years 3 -out SIGNER.pem
//
// VERSION is a KMS crypto key version resource name
// (projects/…/locations/…/keyRings/…/cryptoKeys/…/cryptoKeyVersions/N).
// Authenticates as the Application Default Credentials. Used once for the
// CA and every three years for a signer; nothing is signed in CI with the CA.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "rauc-pki:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: rauc-pki ca|issue [flags]")
	}
	ctx := context.Background()
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	caKey := fs.String("ca-key", "", "KMS key version of the root CA")
	caCert := fs.String("ca-cert", "", "root CA certificate (issue)")
	key := fs.String("key", "", "KMS key version of the signer (issue)")
	cn := fs.String("cn", "", "common name of the new certificate")
	years := fs.Int("years", 0, "validity in years")
	out := fs.String("out", "", "PEM file to write")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if *caKey == "" || *cn == "" || *years <= 0 || *out == "" {
		return errors.New("-ca-key, -cn, -years and -out are required")
	}
	if _, err := os.Stat(*out); err == nil {
		return fmt.Errorf("%s exists: a certificate is never overwritten", *out)
	}
	api, err := newKMS(ctx)
	if err != nil {
		return err
	}
	ca, err := newKMSSigner(ctx, api, *caKey)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	var der []byte
	switch args[0] {
	case "ca":
		der, err = selfSign(*cn, *years, ca, now)
	case "issue":
		if *caCert == "" || *key == "" {
			return errors.New("issue needs -ca-cert and -key")
		}
		data, rerr := os.ReadFile(*caCert)
		if rerr != nil {
			return rerr
		}
		caDER, perr := readCertPEM(data)
		if perr != nil {
			return fmt.Errorf("%s: %w", *caCert, perr)
		}
		pub, kerr := api.publicKey(ctx, *key)
		if kerr != nil {
			return kerr
		}
		der, err = issue(*cn, *years, pub, caDER, ca, now)
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
	if err != nil {
		return err
	}
	if err := os.WriteFile(*out, pemCert(der), 0o644); err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "wrote %s (%s)\n", *out, *cn)
	return err
}
