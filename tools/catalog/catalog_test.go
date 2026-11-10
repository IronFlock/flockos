package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const repoRoot = "../.."

// release writes a release's artifacts as the pipeline leaves them.
func release(t *testing.T, version, buildID string, ids ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, id := range ids {
		d := filepath.Join(dir, id)
		must(t, os.MkdirAll(d, 0o755))
		name := id + "-" + version
		must(t, os.WriteFile(filepath.Join(d, name+".img.gz"), []byte("image of "+name), 0o644))
		must(t, os.WriteFile(filepath.Join(d, name+".sizes"), []byte("raw_size=4564471808\nmin_disk_size=9934209024\n"), 0o644))
		must(t, os.WriteFile(filepath.Join(d, name+".modules.alias.gz"), []byte("hardware of "+name), 0o644))
		if !strings.HasSuffix(id, "-installer") {
			must(t, os.WriteFile(filepath.Join(d, name+".raucb"), []byte("bundle of "+name), 0o644))
		} else {
			// The stick carries its target's base image (customize.sh).
			base := strings.TrimSuffix(id, "-installer") + "-base"
			must(t, os.WriteFile(filepath.Join(d, name+".payloads"), []byte(base+"\n"), 0o644))
		}
		osr := "NAME=\"IronFlockOS\"\nID=flockos\nIMAGE_ID=" + id + "\nIMAGE_VERSION=" + version + "\nBUILD_ID=" + buildID + "\n"
		must(t, os.WriteFile(filepath.Join(d, name+".os-release"), []byte(osr), 0o644))
	}
	return dir
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func boardDefs(t *testing.T) []BoardDef {
	t.Helper()
	var defs []BoardDef
	must(t, readJSON(filepath.Join(repoRoot, "release", "boards.json"), &defs))
	return defs
}

func TestBuildRelease(t *testing.T) {
	dir := release(t, "1.0.0", "20261120T095512Z-g1a2b3c4", "flockos-amd64-efi-base", "flockos-amd64-efi-installer", "flockos-rpi-arm64-base")
	rel, err := buildRelease(dir, repoRoot, "1.0.0", "https://dl.example/flockos/1.0.0", "1.5.8")
	must(t, err)
	if rel.BuildID != "20261120T095512Z-g1a2b3c4" || rel.BuildTime != "2026-11-20T09:55:12Z" || rel.MinAgent != "1.5.8" {
		t.Fatalf("release %+v", rel)
	}
	base := rel.Images["flockos-amd64-efi-base"]
	if base.Target != "amd64-efi" || base.Variant != "base" || base.Kernel != "std" || base.Architecture != "amd64" {
		t.Fatalf("base %+v", base)
	}
	if base.Image.URL != "https://dl.example/flockos/1.0.0/flockos-amd64-efi-base-1.0.0.img.gz" || base.Image.Size != int64(len("image of flockos-amd64-efi-base-1.0.0")) {
		t.Fatalf("image %+v", base.Image)
	}
	if base.Bundle == nil || base.Bundle.Compatible != "flockos-amd64-efi-base" {
		t.Fatalf("bundle %+v", base.Bundle)
	}
	if base.Image.RawSize != 4564471808 || base.Image.MinDiskSize != 9934209024 {
		t.Fatalf("sizes %+v", base.Image)
	}
	data, err := json.Marshal(base.Image)
	must(t, err)
	if !bytes.Contains(data, []byte(`"raw_size":4564471808,"min_disk_size":9934209024`)) {
		t.Fatalf("the image's JSON: %s", data)
	}
	if a := base.ModulesAlias; a == nil || a.URL != "https://dl.example/flockos/1.0.0/flockos-amd64-efi-base-1.0.0.modules.alias.gz" ||
		a.Size != int64(len("hardware of flockos-amd64-efi-base-1.0.0")) || !sha256Re.MatchString(a.SHA256) {
		t.Fatalf("hardware list %+v", a)
	}
	data, err = json.Marshal(base)
	must(t, err)
	if !bytes.Contains(data, []byte(`"modules_alias":{"url":"https://dl.example/flockos/1.0.0/flockos-amd64-efi-base-1.0.0.modules.alias.gz"`)) {
		t.Fatalf("the image entry's JSON: %s", data)
	}
	if rel.Images["flockos-amd64-efi-installer"].ModulesAlias == nil {
		t.Fatal("the installer has a hardware list too")
	}
	inst := rel.Images["flockos-amd64-efi-installer"]
	if inst.Bundle != nil {
		t.Fatal("the installer has no bundle")
	}
	if len(inst.Payloads) != 1 || inst.Payloads[0] != "flockos-amd64-efi-base" || base.Payloads != nil {
		t.Fatalf("payloads: installer %v, base %v", inst.Payloads, base.Payloads)
	}
	if rel.Images["flockos-rpi-arm64-base"].Architecture != "arm64" {
		t.Fatal("rpi-arm64 is arm64")
	}
}

func TestBuildReleaseRefuses(t *testing.T) {
	cases := map[string]func(dir string){
		"two builds": func(dir string) {
			p := filepath.Join(dir, "flockos-rpi-arm64-base", "flockos-rpi-arm64-base-1.0.0.os-release")
			data, _ := os.ReadFile(p)
			_ = os.WriteFile(p, bytes.ReplaceAll(data, []byte("g1a2b3c4"), []byte("g9999999")), 0o644)
		},
		"a base without bundle": func(dir string) {
			_ = os.Remove(filepath.Join(dir, "flockos-amd64-efi-base", "flockos-amd64-efi-base-1.0.0.raucb"))
		},
		"an installer with a bundle": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-installer", "flockos-amd64-efi-installer-1.0.0.raucb"), []byte("x"), 0o644)
		},
		"another version's os-release": func(dir string) {
			p := filepath.Join(dir, "flockos-amd64-efi-base", "flockos-amd64-efi-base-1.0.0.os-release")
			data, _ := os.ReadFile(p)
			_ = os.WriteFile(p, bytes.ReplaceAll(data, []byte("IMAGE_VERSION=1.0.0"), []byte("IMAGE_VERSION=0.9.0")), 0o644)
		},
		"not an image directory": func(dir string) {
			_ = os.MkdirAll(filepath.Join(dir, "flockos-amd64-efi-weird"), 0o755)
		},
		"an installer without payloads": func(dir string) {
			_ = os.Remove(filepath.Join(dir, "flockos-amd64-efi-installer", "flockos-amd64-efi-installer-1.0.0.payloads"))
		},
		"a payload the release does not have": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-installer", "flockos-amd64-efi-installer-1.0.0.payloads"),
				[]byte("flockos-amd64-efi-base\nflockos-amd64-efi-nvidia\n"), 0o644)
		},
		"another target's payload": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-installer", "flockos-amd64-efi-installer-1.0.0.payloads"),
				[]byte("flockos-rpi-arm64-base\n"), 0o644)
		},
		"the installer as its own payload": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-installer", "flockos-amd64-efi-installer-1.0.0.payloads"),
				[]byte("flockos-amd64-efi-installer\n"), 0o644)
		},
		"an image without its sizes": func(dir string) {
			_ = os.Remove(filepath.Join(dir, "flockos-rpi-arm64-base", "flockos-rpi-arm64-base-1.0.0.sizes"))
		},
		"a disk smaller than the image": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-base", "flockos-amd64-efi-base-1.0.0.sizes"),
				[]byte("raw_size=4564471808\nmin_disk_size=4564471807\n"), 0o644)
		},
		"a size that is not in bytes": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-base", "flockos-amd64-efi-base-1.0.0.sizes"),
				[]byte("raw_size=4G\nmin_disk_size=9934209024\n"), 0o644)
		},
		"an image without its hardware list": func(dir string) {
			_ = os.Remove(filepath.Join(dir, "flockos-amd64-efi-installer", "flockos-amd64-efi-installer-1.0.0.modules.alias.gz"))
		},
		"a size missing": func(dir string) {
			_ = os.WriteFile(filepath.Join(dir, "flockos-amd64-efi-base", "flockos-amd64-efi-base-1.0.0.sizes"),
				[]byte("raw_size=4564471808\n"), 0o644)
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			dir := release(t, "1.0.0", "20261120T095512Z-g1a2b3c4", "flockos-amd64-efi-base", "flockos-amd64-efi-installer", "flockos-rpi-arm64-base")
			mutate(dir)
			if _, err := buildRelease(dir, repoRoot, "1.0.0", "https://dl.example/flockos/1.0.0", "1.5.8"); err == nil {
				t.Fatal("accepted")
			}
		})
	}
}

func catalogFor(t *testing.T, prev *Catalog, version, channel string, issued time.Time) Catalog {
	t.Helper()
	dir := release(t, version, "20261120T095512Z-g1a2b3c4", "flockos-amd64-efi-base", "flockos-amd64-efi-installer", "flockos-rpi-arm64-base")
	rel, err := buildRelease(dir, repoRoot, version, "https://dl.example/flockos/"+version, "1.5.8")
	must(t, err)
	c, err := merge(prev, version, channel, rel, boardDefs(t), issued)
	must(t, err)
	return c
}

func TestChannels(t *testing.T) {
	t0 := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)

	first := catalogFor(t, nil, "1.0.0", "test", t0)
	if first.Channels["test"] != "1.0.0" || first.Channels["production"] != "1.0.0" {
		t.Fatalf("the first release is production too: %v", first.Channels)
	}

	second := catalogFor(t, &first, "1.0.1", "test", t0.Add(time.Hour))
	if second.Channels["test"] != "1.0.1" || second.Channels["production"] != "1.0.0" {
		t.Fatalf("a release goes to test: %v", second.Channels)
	}
	if len(second.Releases) != 2 {
		t.Fatalf("both releases named: %v", keys(second.Releases))
	}
	for _, b := range second.Boards {
		for _, i := range b.LatestImages {
			if i.Version != "1.0.0" {
				t.Fatalf("FlockFlasher's boards show production, not %s", i.Version)
			}
		}
	}

	promoted := catalogFor(t, &second, "1.0.1", "production", t0.Add(2*time.Hour))
	if promoted.Channels["production"] != "1.0.1" || len(promoted.Releases) != 1 {
		t.Fatalf("promoted: %v, releases %v", promoted.Channels, keys(promoted.Releases))
	}

	if _, err := merge(&promoted, "1.0.2", "test", promoted.Releases["1.0.1"], boardDefs(t), t0.Add(2*time.Hour)); err == nil {
		t.Fatal("an issue time not after the previous one was accepted")
	}
	if _, err := merge(nil, "1.0", "test", first.Releases["1.0.0"], boardDefs(t), t0); err == nil {
		t.Fatal("a version that is not semantic was accepted")
	}
	if _, err := merge(nil, "1.0.0", "beta", first.Releases["1.0.0"], boardDefs(t), t0); err == nil {
		t.Fatal("an unknown channel was accepted")
	}
}

func TestBoards(t *testing.T) {
	c := catalogFor(t, nil, "1.0.0", "test", time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC))
	models := map[string]Board{}
	for _, b := range c.Boards {
		models[b.Model] = b
	}
	pc := models["amd64-efi"]
	if len(pc.LatestImages) != 2 || pc.LatestImages[0].ImageID != "flockos-amd64-efi-base" || pc.LatestImages[1].Variant != "installer" {
		t.Fatalf("pc: %+v", pc.LatestImages)
	}
	if pc.LatestImages[1].Update != "" || pc.LatestImages[0].Update == "" {
		t.Fatal("update is the bundle, empty for the installer")
	}
	if p := pc.LatestImages[1].Payloads; len(p) != 1 || p[0] != "flockos-amd64-efi-base" || pc.LatestImages[0].Payloads != nil {
		t.Fatalf("the installer lists the images it carries: %+v", pc.LatestImages)
	}
	if _, ok := models["arm64-efi"]; ok {
		t.Fatal("a board without an image of the release is left out")
	}
	if models["raspberrypi4"].LatestImages[0].File != "flockos-rpi-arm64-base-1.0.0.img.gz" {
		t.Fatalf("pi: %+v", models["raspberrypi4"].LatestImages)
	}
}

func TestTheSchemaExampleValidates(t *testing.T) {
	var c Catalog
	must(t, readJSON(filepath.Join(repoRoot, "docs", "manifest.example.json"), &c))
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
}

func keys(m map[string]Release) []string {
	out := []string{}
	for k := range m {
		out = append(out, k)
	}
	return out
}

// --- signing -----------------------------------------------------------------

func keyFile(t *testing.T) (string, string, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	must(t, err)
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	must(t, err)
	path := filepath.Join(t.TempDir(), "key.pem")
	must(t, os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600))
	return path, base64.StdEncoding.EncodeToString(pub), priv
}

func payloadFile(t *testing.T) string {
	t.Helper()
	c := catalogFor(t, nil, "1.0.0", "test", time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC))
	data, err := json.MarshalIndent(c, "", "  ")
	must(t, err)
	path := filepath.Join(t.TempDir(), "payload.json")
	must(t, os.WriteFile(path, data, 0o644))
	return path
}

func TestSignAndVerify(t *testing.T) {
	key, pub, _ := keyFile(t)
	payload := payloadFile(t)
	out := filepath.Join(t.TempDir(), "manifest.json")
	must(t, run([]string{"sign", "-payload", payload, "-key-file", key, "-pubkey", pub, "-o", out}, os.Stdout))

	var got bytes.Buffer
	must(t, run([]string{"verify", "-pubkey", pub, out}, &got))
	want, _ := os.ReadFile(payload)
	if strings.TrimSpace(got.String()) != strings.TrimSpace(string(want)) {
		t.Fatal("verify does not return the payload")
	}

	_, other, _ := keyFile(t)
	if err := run([]string{"verify", "-pubkey", other, out}, &got); err == nil {
		t.Fatal("another key verified it")
	}
	if err := run([]string{"sign", "-payload", payload, "-key-file", key, "-pubkey", other, "-o", out}, os.Stdout); err == nil {
		t.Fatal("signed with a key that is not -pubkey")
	}

	// A payload changed after signing.
	var env envelope
	data, _ := os.ReadFile(out)
	must(t, json.Unmarshal(data, &env))
	env.Payload = bytes.Replace(env.Payload, []byte(`"production": "1.0.0"`), []byte(`"production": "9.9.9"`), 1)
	tampered, _ := json.Marshal(env)
	if _, err := open(tampered, mustKey(t, pub)); err == nil {
		t.Fatal("a tampered payload verified")
	}
}

func TestSignRefusesAnInvalidCatalog(t *testing.T) {
	key, pub, _ := keyFile(t)
	path := filepath.Join(t.TempDir(), "payload.json")
	must(t, os.WriteFile(path, []byte(`{"schema": 1, "issued_at": "2026-11-20T10:00:00Z", "channels": {"production": "1.0.0"}, "releases": {}}`), 0o644))
	if err := run([]string{"sign", "-payload", path, "-key-file", key, "-pubkey", pub}, &bytes.Buffer{}); err == nil {
		t.Fatal("signed a catalog whose production release is missing")
	}
}

// The message is the device-agent's (updatesig.Subject.Message).
func TestMessage(t *testing.T) {
	got := string(message([]byte("{}")))
	want := "flockos-manifest:v1\nflockos/manifest.json\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
	if got != want {
		t.Fatalf("message %q", got)
	}
}

type fakeKMS struct {
	priv ed25519.PrivateKey
	pub  ed25519.PublicKey
	data []byte
}

func (f *fakeKMS) sign(_ context.Context, _ string, data []byte) ([]byte, error) {
	f.data = data
	return ed25519.Sign(f.priv, data), nil
}

func (f *fakeKMS) publicKey(context.Context, string) (ed25519.PublicKey, error) { return f.pub, nil }

func TestSignWithKMS(t *testing.T) {
	_, pub, priv := keyFile(t)
	fake := &fakeKMS{priv: priv, pub: priv.Public().(ed25519.PublicKey)}
	old := newKMS
	newKMS = func(context.Context) (kmsAPI, error) { return fake, nil }
	t.Cleanup(func() { newKMS = old })

	payload := payloadFile(t)
	var out bytes.Buffer
	must(t, run([]string{"sign", "-payload", payload, "-kms-key", "projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1", "-pubkey", pub}, &out))
	data, _ := os.ReadFile(payload)
	if !bytes.Equal(fake.data, message(data)) {
		t.Fatal("KMS was not given the message")
	}
	if _, err := open(out.Bytes(), mustKey(t, pub)); err != nil {
		t.Fatal(err)
	}

	_, other, _ := keyFile(t)
	if err := run([]string{"sign", "-payload", payload, "-kms-key", "k", "-pubkey", other}, &out); err == nil {
		t.Fatal("signed with a KMS key that is not -pubkey")
	}
}

func TestBuildOnThePublishedCatalog(t *testing.T) {
	key, pub, _ := keyFile(t)
	t0 := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	oldNow := now
	t.Cleanup(func() { now = oldNow })

	dir := release(t, "1.0.0", "20261120T095512Z-g1a2b3c4", "flockos-amd64-efi-base")
	tmp := t.TempDir()
	payload, manifest := filepath.Join(tmp, "p1.json"), filepath.Join(tmp, "m1.json")
	args := func(extra ...string) []string {
		return append([]string{"build", "-dir", dir, "-repo", repoRoot, "-url", "https://dl.example/flockos/1.0.0",
			"-min-agent", "1.5.8", "-boards", filepath.Join(repoRoot, "release", "boards.json")}, extra...)
	}
	now = func() time.Time { return t0 }
	must(t, run(args("-version", "1.0.0", "-o", payload), os.Stdout))
	must(t, run([]string{"sign", "-payload", payload, "-key-file", key, "-pubkey", pub, "-o", manifest}, os.Stdout))

	dir2 := release(t, "1.0.1", "20261130T141003Z-g5d6e7f8", "flockos-amd64-efi-base")
	now = func() time.Time { return t0.Add(time.Hour) }
	var out bytes.Buffer
	must(t, run([]string{"build", "-dir", dir2, "-repo", repoRoot, "-version", "1.0.1", "-url", "https://dl.example/flockos/1.0.1",
		"-min-agent", "1.5.8", "-boards", filepath.Join(repoRoot, "release", "boards.json"), "-previous", manifest, "-pubkey", pub}, &out))
	var c Catalog
	must(t, json.Unmarshal(out.Bytes(), &c))
	if c.Channels["production"] != "1.0.0" || c.Channels["test"] != "1.0.1" {
		t.Fatalf("channels %v", c.Channels)
	}

	_, other, _ := keyFile(t)
	if err := run([]string{"build", "-dir", dir2, "-repo", repoRoot, "-version", "1.0.1", "-url", "https://dl.example/flockos/1.0.1",
		"-min-agent", "1.5.8", "-boards", filepath.Join(repoRoot, "release", "boards.json"), "-previous", manifest, "-pubkey", other}, &out); err == nil {
		t.Fatal("built on a previous catalog that does not verify")
	}
}

func mustKey(t *testing.T, text string) ed25519.PublicKey {
	t.Helper()
	k, err := parsePublicKey(text)
	must(t, err)
	return k
}

func TestMoveAPublishedReleaseToProduction(t *testing.T) {
	key, pub, _ := keyFile(t)
	t0 := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	first := catalogFor(t, nil, "1.0.0", "test", t0)
	second := catalogFor(t, &first, "1.0.1", "test", t0.Add(time.Hour))
	tmp := t.TempDir()
	payload, manifest := filepath.Join(tmp, "p.json"), filepath.Join(tmp, "m.json")
	data, err := json.MarshalIndent(second, "", "  ")
	must(t, err)
	must(t, os.WriteFile(payload, data, 0o644))
	must(t, run([]string{"sign", "-payload", payload, "-key-file", key, "-pubkey", pub, "-o", manifest}, os.Stdout))

	oldNow := now
	t.Cleanup(func() { now = oldNow })
	now = func() time.Time { return t0.Add(2 * time.Hour) }
	boards := filepath.Join(repoRoot, "release", "boards.json")
	var out bytes.Buffer
	must(t, run([]string{"build", "-version", "1.0.1", "-channel", "production", "-boards", boards, "-previous", manifest, "-pubkey", pub}, &out))
	var c Catalog
	must(t, json.Unmarshal(out.Bytes(), &c))
	if c.Channels["production"] != "1.0.1" || c.Channels["test"] != "1.0.1" || len(c.Releases) != 1 {
		t.Fatalf("channels %v, releases %v", c.Channels, keys(c.Releases))
	}
	if c.Releases["1.0.1"].BuildID != second.Releases["1.0.1"].BuildID {
		t.Fatal("the release moved changed")
	}
	if c.Boards[0].LatestImages[0].Version != "1.0.1" {
		t.Fatal("FlockFlasher's boards do not show the new production release")
	}

	if err := run([]string{"build", "-version", "9.9.9", "-channel", "production", "-boards", boards, "-previous", manifest, "-pubkey", pub}, &out); err == nil {
		t.Fatal("moved a release the catalog does not have")
	}
	if err := run([]string{"build", "-version", "1.0.1", "-channel", "production", "-boards", boards}, &out); err == nil {
		t.Fatal("built without -dir and without -previous")
	}
}

// A release up to 0.10.0 (v0.10.0 is published so) has installers without
// payloads; built on, it stays valid, and readers take the target's base.
func TestAnInstallerWithoutPayloadsStaysValid(t *testing.T) {
	t0 := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	old := catalogFor(t, nil, "1.0.0", "test", t0)
	inst := old.Releases["1.0.0"].Images["flockos-amd64-efi-installer"]
	inst.Payloads = nil
	old.Releases["1.0.0"].Images["flockos-amd64-efi-installer"] = inst
	must(t, old.Validate())
	next := catalogFor(t, &old, "1.0.1", "test", t0.Add(time.Hour))
	if next.Releases["1.0.0"].Images["flockos-amd64-efi-installer"].Payloads != nil {
		t.Fatal("the old release changed")
	}
	data, err := json.Marshal(next.Releases["1.0.0"].Images["flockos-amd64-efi-installer"])
	must(t, err)
	if bytes.Contains(data, []byte("payloads")) {
		t.Fatalf("an installer without payloads gains the key: %s", data)
	}
}

// A release up to 0.14.0 has no raw_size, min_disk_size and modules_alias;
// built on, it stays valid and does not gain them. One of the two sizes
// alone, a disk smaller than the image, or a hardware list of another name,
// is invalid.
func TestAReleaseWithoutSizesStaysValid(t *testing.T) {
	t0 := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	old := catalogFor(t, nil, "1.0.0", "test", t0)
	for id, img := range old.Releases["1.0.0"].Images {
		img.Image.RawSize, img.Image.MinDiskSize, img.ModulesAlias = 0, 0, nil
		old.Releases["1.0.0"].Images[id] = img
	}
	must(t, old.Validate())
	next := catalogFor(t, &old, "1.0.1", "test", t0.Add(time.Hour))
	data, err := json.Marshal(next.Releases["1.0.0"])
	must(t, err)
	if bytes.Contains(data, []byte("raw_size")) || bytes.Contains(data, []byte("min_disk_size")) || bytes.Contains(data, []byte("modules_alias")) {
		t.Fatalf("an old release gains the sizes or a hardware list: %s", data)
	}
	if next.Releases["1.0.1"].Images["flockos-amd64-efi-base"].Image.MinDiskSize == 0 {
		t.Fatal("the new release has no min_disk_size")
	}

	for name, sizes := range map[string][2]int64{
		"raw_size alone":      {4564471808, 0},
		"min_disk_size alone": {0, 9934209024},
		"a smaller disk":      {4564471808, 4564471807},
	} {
		c := catalogFor(t, nil, "1.0.0", "test", t0)
		img := c.Releases["1.0.0"].Images["flockos-amd64-efi-base"]
		img.Image.RawSize, img.Image.MinDiskSize = sizes[0], sizes[1]
		c.Releases["1.0.0"].Images["flockos-amd64-efi-base"] = img
		if err := c.Validate(); err == nil {
			t.Fatalf("%s: valid", name)
		}
	}
	c := catalogFor(t, nil, "1.0.0", "test", t0)
	img := c.Releases["1.0.0"].Images["flockos-amd64-efi-base"]
	other := *img.ModulesAlias
	other.URL = strings.Replace(other.URL, "flockos-amd64-efi-base-1.0.0", "flockos-amd64-efi-nvidia-1.0.0", 1)
	img.ModulesAlias = &other
	c.Releases["1.0.0"].Images["flockos-amd64-efi-base"] = img
	if err := c.Validate(); err == nil {
		t.Fatal("another image's hardware list: valid")
	}
}
