// catalog builds, signs and checks dl/flockos/manifest.json, the FlockOS
// release catalog the device-agent and FlockFlasher read (ADR-0009,
// docs/manifest.schema.json, docs/release.md).
//
//	catalog build  -dir OUT -repo . -version V -channel test|production -url BASE
//	               -min-agent V -boards release/boards.json [-previous manifest.json -pubkey KEY] -o payload.json
//	catalog sign   -payload payload.json (-kms-key VERSION | -key-file key.pem) -pubkey KEY -o manifest.json
//	catalog verify -pubkey KEY manifest.json
//
// KEY is the catalog key as the agent lists it (base64 of the raw Ed25519
// key) or a PEM public key file (pki/flockos-catalog.pub). VERSION is a KMS
// key version resource name. -key-file is for dry runs with a throwaway key.
package main

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "catalog:", err)
		os.Exit(1)
	}
}

// now is the issue time; tests replace it.
var now = time.Now

func run(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: catalog build|sign|verify [flags]")
	}
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	dir := fs.String("dir", "", "release artifacts, one directory per image (build)")
	repo := fs.String("repo", ".", "the flockos checkout, for targets/*/target.conf (build)")
	version := fs.String("version", "", "the FlockOS version (build)")
	channel := fs.String("channel", "test", "the channel that gets the release: test or production (build)")
	url := fs.String("url", "", "the download base of the release's files (build)")
	minAgent := fs.String("min-agent", "", "the oldest device-agent that may install the release (build)")
	boards := fs.String("boards", "", "FlockFlasher's boards, release/boards.json (build)")
	previous := fs.String("previous", "", "the published catalog to build on, verified with -pubkey (build)")
	payload := fs.String("payload", "", "the catalog payload (sign)")
	kmsKey := fs.String("kms-key", "", "the KMS key version that signs (sign)")
	keyFile := fs.String("key-file", "", "a PEM Ed25519 key that signs (sign, dry runs)")
	pubkey := fs.String("pubkey", "", "the catalog key: base64 raw Ed25519 or a PEM public key file")
	out := fs.String("o", "", "output file (default stdout)")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	write := func(data []byte) error {
		if *out == "" {
			_, err := stdout.Write(append(data, '\n'))
			return err
		}
		return os.WriteFile(*out, append(data, '\n'), 0o644) //nolint:gosec // G306: a public catalog
	}
	key := func() (ed25519.PublicKey, error) {
		if *pubkey == "" {
			return nil, errors.New("-pubkey is required")
		}
		text := *pubkey
		if data, err := os.ReadFile(*pubkey); err == nil {
			text = string(data)
		}
		return parsePublicKey(text)
	}

	switch args[0] {
	case "build":
		if *dir == "" || *version == "" || *url == "" || *minAgent == "" || *boards == "" {
			return errors.New("build needs -dir, -version, -url, -min-agent and -boards")
		}
		rel, err := buildRelease(*dir, *repo, *version, *url, *minAgent)
		if err != nil {
			return err
		}
		var defs []BoardDef
		if err := readJSON(*boards, &defs); err != nil {
			return fmt.Errorf("%s: %w", *boards, err)
		}
		var prev *Catalog
		if *previous != "" {
			pub, err := key()
			if err != nil {
				return err
			}
			data, err := os.ReadFile(*previous)
			if err != nil {
				return err
			}
			p, err := open(data, pub)
			if err != nil {
				return fmt.Errorf("the previous catalog %s: %w", *previous, err)
			}
			prev = &Catalog{}
			if err := json.Unmarshal(p, prev); err != nil {
				return fmt.Errorf("the previous catalog: %w", err)
			}
		}
		c, err := merge(prev, *version, *channel, rel, defs, now())
		if err != nil {
			return err
		}
		data, err := json.MarshalIndent(c, "", "  ")
		if err != nil {
			return err
		}
		return write(data)

	case "sign":
		if *payload == "" || (*kmsKey == "") == (*keyFile == "") {
			return errors.New("sign needs -payload and one of -kms-key and -key-file")
		}
		pub, err := key()
		if err != nil {
			return err
		}
		data, err := os.ReadFile(*payload)
		if err != nil {
			return err
		}
		var c Catalog
		if err := json.Unmarshal(data, &c); err != nil {
			return fmt.Errorf("%s: %w", *payload, err)
		}
		if err := c.Validate(); err != nil {
			return fmt.Errorf("%s: %w", *payload, err)
		}
		var sig []byte
		if *kmsKey != "" {
			ctx := context.Background()
			api, err := newKMS(ctx)
			if err != nil {
				return err
			}
			kmsPub, err := api.publicKey(ctx, *kmsKey)
			if err != nil {
				return err
			}
			if !kmsPub.Equal(pub) {
				return fmt.Errorf("%s is not the catalog key -pubkey names", *kmsKey)
			}
			if sig, err = api.sign(ctx, *kmsKey, message(data)); err != nil {
				return err
			}
		} else {
			pem, err := os.ReadFile(*keyFile)
			if err != nil {
				return err
			}
			priv, err := parsePrivateKey(pem)
			if err != nil {
				return fmt.Errorf("%s: %w", *keyFile, err)
			}
			if !priv.Public().(ed25519.PublicKey).Equal(pub) {
				return fmt.Errorf("%s is not the key -pubkey names", *keyFile)
			}
			sig = ed25519.Sign(priv, message(data))
		}
		env, err := seal(data, sig, pub)
		if err != nil {
			return err
		}
		return write(env)

	case "verify":
		if fs.NArg() != 1 {
			return errors.New("verify needs one manifest.json")
		}
		pub, err := key()
		if err != nil {
			return err
		}
		data, err := os.ReadFile(fs.Arg(0))
		if err != nil {
			return err
		}
		p, err := open(data, pub)
		if err != nil {
			return err
		}
		var c Catalog
		if err := json.Unmarshal(p, &c); err != nil {
			return err
		}
		if err := c.Validate(); err != nil {
			return err
		}
		return write(p)
	}
	return fmt.Errorf("unknown command %q", args[0])
}
