package main

// The payload of dl/flockos/manifest.json, schema 1 (docs/manifest.schema.json,
// ADR-0009), built from a release's artifacts and the previous catalog.

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Artifact struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Bundle struct {
	Artifact
	Compatible string `json:"compatible"`
}

// DiskImage is the raw disk image (.img.gz) and what a disk needs for it:
// RawSize, the image decompressed, and MinDiskSize, the smallest disk on
// which it becomes a working device (build/lib.sh min_disk_size: every
// partition of the layout, 1 GiB of /data). Both in bytes, from the build's
// <image-id>-<version>.sizes. Releases up to 0.14.0 have neither.
type DiskImage struct {
	Artifact
	RawSize     int64 `json:"raw_size,omitempty"`
	MinDiskSize int64 `json:"min_disk_size,omitempty"`
}

type Image struct {
	Target       string    `json:"target"`
	Variant      string    `json:"variant"`
	Kernel       string    `json:"kernel"`
	Architecture string    `json:"architecture"`
	Image        DiskImage `json:"image"`
	Bundle       *Bundle   `json:"bundle,omitempty"`
	// Payloads are the image ids an installer stick carries (installer.conf
	// payload= picks one). Only the installer has them; a release up to
	// 0.10.0 has none, and readers take that as the target's base image.
	Payloads []string `json:"payloads,omitempty"`
}

type Release struct {
	BuildID   string           `json:"build_id"`
	BuildTime string           `json:"buildtime"`
	MinAgent  string           `json:"min_agent"`
	Images    map[string]Image `json:"images"`
}

type ImageInfo struct {
	BuildTime string `json:"buildtime"`
	Download  string `json:"download"`
	File      string `json:"file"`
	OSName    string `json:"osname"`
	OSVariant string `json:"osvariant"`
	SHA256    string `json:"sha256"`
	Size      int64  `json:"size"`
	Update    string `json:"update"`
	Version   string `json:"version"`
	ImageID   string `json:"image_id"`
	Variant   string `json:"variant"`
	Kernel    string `json:"kernel"`
	// Payloads as Image.Payloads: the images FlockFlasher offers to put on
	// the installer stick.
	Payloads []string `json:"payloads,omitempty"`
}

type Board struct {
	Architecture string      `json:"architecture"`
	Board        string      `json:"board"`
	BoardName    string      `json:"boardname"`
	CPU          string      `json:"cpu"`
	Docs         string      `json:"docs"`
	Reflasher    bool        `json:"reflasher"`
	Model        string      `json:"model"`
	ModelName    string      `json:"modelname"`
	LatestImages []ImageInfo `json:"latestImages"`
}

type Catalog struct {
	Schema   int                `json:"schema"`
	IssuedAt string             `json:"issued_at"`
	Channels map[string]string  `json:"channels"`
	Releases map[string]Release `json:"releases"`
	Boards   []Board            `json:"boards"`
}

// BoardDef is one board of release/boards.json: FlockFlasher's fields and the
// images it lists, base first.
type BoardDef struct {
	Architecture string   `json:"architecture"`
	Board        string   `json:"board"`
	BoardName    string   `json:"boardname"`
	CPU          string   `json:"cpu"`
	Docs         string   `json:"docs"`
	Reflasher    bool     `json:"reflasher"`
	Model        string   `json:"model"`
	ModelName    string   `json:"modelname"`
	Images       []string `json:"images"`
}

var (
	versionRe = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$`)
	buildIDRe = regexp.MustCompile(`^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z-g[0-9a-f]{7,40}$`)
	imageIDRe = regexp.MustCompile(`^flockos-([a-z0-9]+(?:-[a-z0-9]+)*)-(base|nvidia|installer)(-rt)?$`)
	sha256Re  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// buildTime turns BUILD_ID into its RFC 3339 time.
func buildTime(buildID string) (string, error) {
	m := buildIDRe.FindStringSubmatch(buildID)
	if m == nil {
		return "", fmt.Errorf("BUILD_ID %q is not <YYYYMMDD>T<HHMMSS>Z-g<commit>", buildID)
	}
	return fmt.Sprintf("%s-%s-%sT%s:%s:%sZ", m[1], m[2], m[3], m[4], m[5], m[6]), nil
}

// osRelease reads KEY=value lines; quotes are removed.
func osRelease(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	fields := map[string]string{}
	s := bufio.NewScanner(f)
	for s.Scan() {
		key, value, ok := strings.Cut(strings.TrimSpace(s.Text()), "=")
		if ok && key != "" && !strings.HasPrefix(key, "#") {
			fields[key] = strings.Trim(value, `"'`)
		}
	}
	return fields, s.Err()
}

func artifact(path, url string) (Artifact, error) {
	f, err := os.Open(path)
	if err != nil {
		return Artifact{}, err
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return Artifact{}, err
	}
	return Artifact{URL: url, SHA256: hex.EncodeToString(h.Sum(nil)), Size: n}, nil
}

// targetArch reads ARCH from targets/<target>/target.conf.
func targetArch(repo, target string) (string, error) {
	fields, err := osRelease(filepath.Join(repo, "targets", target, "target.conf"))
	if err != nil {
		return "", err
	}
	if fields["ARCH"] == "" {
		return "", fmt.Errorf("targets/%s/target.conf has no ARCH", target)
	}
	return fields["ARCH"], nil
}

// buildRelease reads one release from dir: one directory per image as the
// release pipeline leaves them (flockos-<id>/ with <id>-<version>.img.gz, its
// raw size and minimum disk size in <id>-<version>.sizes, the .raucb but for
// the installer, <id>-<version>.os-release, and for the installer
// <id>-<version>.payloads, the image ids it carries one per line).
// Files are published below baseURL.
func buildRelease(dir, repo, version, baseURL, minAgent string) (Release, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return Release{}, err
	}
	rel := Release{MinAgent: minAgent, Images: map[string]Image{}}
	for _, e := range entries {
		id := e.Name()
		if !e.IsDir() || !strings.HasPrefix(id, "flockos-") {
			continue
		}
		m := imageIDRe.FindStringSubmatch(id)
		if m == nil {
			return Release{}, fmt.Errorf("%s is not an image directory (flockos-<target>-<variant>[-rt])", id)
		}
		target, variant, kernel := m[1], m[2], "std"
		if m[3] != "" {
			kernel = "rt"
		}
		name := id + "-" + version
		osr, err := osRelease(filepath.Join(dir, id, name+".os-release"))
		if err != nil {
			return Release{}, err
		}
		if osr["IMAGE_ID"] != id || osr["IMAGE_VERSION"] != version {
			return Release{}, fmt.Errorf("%s: os-release says %s %s", id, osr["IMAGE_ID"], osr["IMAGE_VERSION"])
		}
		bt, err := buildTime(osr["BUILD_ID"])
		if err != nil {
			return Release{}, fmt.Errorf("%s: %w", id, err)
		}
		switch {
		case rel.BuildID == "":
			rel.BuildID, rel.BuildTime = osr["BUILD_ID"], bt
		case rel.BuildID != osr["BUILD_ID"]:
			return Release{}, fmt.Errorf("%s has BUILD_ID %s, another image %s: not one build", id, osr["BUILD_ID"], rel.BuildID)
		}
		arch, err := targetArch(repo, target)
		if err != nil {
			return Release{}, err
		}
		img := Image{Target: target, Variant: variant, Kernel: kernel, Architecture: arch}
		img.Image.Artifact, err = artifact(filepath.Join(dir, id, name+".img.gz"), baseURL+"/"+name+".img.gz")
		if err != nil {
			return Release{}, err
		}
		img.Image.RawSize, img.Image.MinDiskSize, err = diskSizes(filepath.Join(dir, id, name+".sizes"))
		if err != nil {
			return Release{}, fmt.Errorf("%s: %w", id, err)
		}
		bundlePath := filepath.Join(dir, id, name+".raucb")
		switch _, err := os.Stat(bundlePath); {
		case err == nil && variant == "installer":
			return Release{}, fmt.Errorf("%s has a bundle; the installer has none", id)
		case err == nil:
			a, err := artifact(bundlePath, baseURL+"/"+name+".raucb")
			if err != nil {
				return Release{}, err
			}
			img.Bundle = &Bundle{Artifact: a, Compatible: id}
		case variant != "installer":
			return Release{}, fmt.Errorf("%s has no bundle (%s)", id, filepath.Base(bundlePath))
		}
		if variant == "installer" {
			img.Payloads, err = payloads(filepath.Join(dir, id, name+".payloads"))
			if err != nil {
				return Release{}, fmt.Errorf("%s: %w", id, err)
			}
		}
		rel.Images[id] = img
	}
	if len(rel.Images) == 0 {
		return Release{}, fmt.Errorf("no image directories in %s", dir)
	}
	for id, img := range rel.Images {
		if err := checkPayloads(id, img, rel.Images); err != nil {
			return Release{}, err
		}
	}
	return rel, nil
}

// diskSizes reads an image's .sizes file (build/lib.sh write_sizes):
// raw_size= and min_disk_size=, in bytes.
func diskSizes(path string) (raw, minDisk int64, err error) {
	fields, err := osRelease(path)
	if err != nil {
		return 0, 0, err
	}
	for _, f := range []struct {
		key  string
		into *int64
	}{{"raw_size", &raw}, {"min_disk_size", &minDisk}} {
		n, err := strconv.ParseInt(fields[f.key], 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, fmt.Errorf("%s: %s is not a size in bytes: %q", filepath.Base(path), f.key, fields[f.key])
		}
		*f.into = n
	}
	if minDisk < raw {
		return 0, 0, fmt.Errorf("%s: min_disk_size %d is less than raw_size %d", filepath.Base(path), minDisk, raw)
	}
	return raw, minDisk, nil
}

// payloads reads an installer's .payloads file: image ids, one per line.
func payloads(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	ids := strings.Fields(string(data))
	if len(ids) == 0 {
		return nil, fmt.Errorf("%s lists no image", filepath.Base(path))
	}
	return ids, nil
}

// checkPayloads holds an image's payloads to the images of its release: only
// an installer has them, each is an updatable image of the installer's target
// in the same release, and none twice.
func checkPayloads(id string, img Image, images map[string]Image) error {
	if img.Variant != "installer" {
		if len(img.Payloads) > 0 {
			return fmt.Errorf("%s: only the installer has payloads", id)
		}
		return nil
	}
	seen := map[string]bool{}
	for _, p := range img.Payloads {
		pi, ok := images[p]
		switch {
		case seen[p]:
			return fmt.Errorf("%s: payload %s twice", id, p)
		case !ok:
			return fmt.Errorf("%s: payload %s is not an image of the release", id, p)
		case pi.Target != img.Target || pi.Variant == "installer" || pi.Bundle == nil:
			return fmt.Errorf("%s: payload %s is not an updatable image of %s", id, p, img.Target)
		}
		seen[p] = true
	}
	return nil
}

// merge puts release under version into the previous catalog (nil for the
// first) on channel: the channel names it, a catalog without production gets
// it as production too, releases no channel names go, and the boards show
// production.
func merge(prev *Catalog, version, channel string, rel Release, boards []BoardDef, issued time.Time) (Catalog, error) {
	if !versionRe.MatchString(version) {
		return Catalog{}, fmt.Errorf("version %q is not a semantic version", version)
	}
	if channel != "production" && channel != "test" {
		return Catalog{}, fmt.Errorf("channel %q: production or test", channel)
	}
	c := Catalog{Schema: 1, Channels: map[string]string{}, Releases: map[string]Release{}}
	if prev != nil {
		if prev.Schema != 1 {
			return Catalog{}, fmt.Errorf("the previous catalog is schema %d", prev.Schema)
		}
		prevIssued, err := time.Parse(time.RFC3339, prev.IssuedAt)
		if err == nil && !issued.After(prevIssued) {
			return Catalog{}, fmt.Errorf("issued_at %s is not after the previous catalog's %s", issued.Format(time.RFC3339), prev.IssuedAt)
		}
		for k, v := range prev.Channels {
			c.Channels[k] = v
		}
		for k, v := range prev.Releases {
			c.Releases[k] = v
		}
	}
	c.IssuedAt = issued.UTC().Format(time.RFC3339)
	c.Channels[channel] = version
	if c.Channels["production"] == "" {
		c.Channels["production"] = version
	}
	c.Releases[version] = rel
	named := map[string]bool{}
	for _, v := range c.Channels {
		named[v] = true
	}
	for v := range c.Releases {
		if !named[v] {
			delete(c.Releases, v)
		}
	}
	prodVersion := c.Channels["production"]
	prod := c.Releases[prodVersion]
	c.Boards = []Board{}
	for _, b := range boards {
		board := Board{Architecture: b.Architecture, Board: b.Board, BoardName: b.BoardName, CPU: b.CPU, Docs: b.Docs,
			Reflasher: b.Reflasher, Model: b.Model, ModelName: b.ModelName, LatestImages: []ImageInfo{}}
		for _, id := range b.Images {
			img, ok := prod.Images[id]
			if !ok {
				continue
			}
			update := ""
			if img.Bundle != nil {
				update = img.Bundle.URL
			}
			board.LatestImages = append(board.LatestImages, ImageInfo{
				BuildTime: prod.BuildTime, Download: img.Image.URL, File: lastSegment(img.Image.URL), OSName: "IronFlockOS",
				OSVariant: "image", SHA256: img.Image.SHA256, Size: img.Image.Size, Update: update,
				Version: prodVersion, ImageID: id, Variant: img.Variant, Kernel: img.Kernel, Payloads: img.Payloads,
			})
		}
		if len(board.LatestImages) > 0 {
			c.Boards = append(c.Boards, board)
		}
	}
	return c, c.Validate()
}

func lastSegment(url string) string { return url[strings.LastIndex(url, "/")+1:] }

// Validate checks what the readers rely on (docs/manifest.schema.json and the
// invariants test/unit/manifest.bats holds the example to).
func (c Catalog) Validate() error {
	var errs []error
	if c.Schema != 1 {
		errs = append(errs, fmt.Errorf("schema %d", c.Schema))
	}
	if _, err := time.Parse(time.RFC3339, c.IssuedAt); err != nil {
		errs = append(errs, fmt.Errorf("issued_at: %w", err))
	}
	if c.Channels["production"] == "" {
		errs = append(errs, errors.New("no production channel"))
	}
	named := map[string]bool{}
	for ch, v := range c.Channels {
		if ch != "production" && ch != "test" {
			errs = append(errs, fmt.Errorf("unknown channel %q", ch))
		}
		if _, ok := c.Releases[v]; !ok {
			errs = append(errs, fmt.Errorf("channel %s names %s, which is not listed", ch, v))
		}
		named[v] = true
	}
	for v, r := range c.Releases {
		if !named[v] {
			errs = append(errs, fmt.Errorf("release %s is named by no channel", v))
		}
		if !versionRe.MatchString(v) {
			errs = append(errs, fmt.Errorf("release %q is not a semantic version", v))
		}
		if _, err := buildTime(r.BuildID); err != nil {
			errs = append(errs, err)
		}
		for id, img := range r.Images {
			if !imageIDRe.MatchString(id) {
				errs = append(errs, fmt.Errorf("%s: not an image id", id))
			}
			for _, a := range []*Artifact{&img.Image.Artifact, bundleArtifact(img.Bundle)} {
				if a == nil {
					continue
				}
				if !strings.HasPrefix(a.URL, "https://") || !sha256Re.MatchString(a.SHA256) || a.Size <= 0 {
					errs = append(errs, fmt.Errorf("%s %s: url, sha256 or size", v, id))
				}
			}
			if !strings.HasSuffix(img.Image.URL, "/"+id+"-"+v+".img.gz") {
				errs = append(errs, fmt.Errorf("%s %s: the image is not %s-%s.img.gz", v, id, id, v))
			}
			// Both or neither (releases up to 0.14.0); the disk holds the image.
			if d := img.Image; (d.RawSize != 0 || d.MinDiskSize != 0) && (d.RawSize <= 0 || d.MinDiskSize < d.RawSize) {
				errs = append(errs, fmt.Errorf("%s %s: raw_size %d and min_disk_size %d", v, id, d.RawSize, d.MinDiskSize))
			}
			if (img.Variant == "installer") == (img.Bundle != nil) {
				errs = append(errs, fmt.Errorf("%s %s: the installer and only the installer has no bundle", v, id))
			}
			if img.Bundle != nil && (img.Bundle.Compatible != id || !strings.HasSuffix(img.Bundle.URL, "/"+id+"-"+v+".raucb")) {
				errs = append(errs, fmt.Errorf("%s %s: the bundle is not %s-%s.raucb, compatible %s", v, id, id, v, id))
			}
			if err := checkPayloads(id, img, r.Images); err != nil {
				errs = append(errs, fmt.Errorf("%s %w", v, err))
			}
		}
	}
	for _, b := range c.Boards {
		if len(b.LatestImages) == 0 || b.LatestImages[0].Variant != "base" {
			errs = append(errs, fmt.Errorf("board %s: its first image is not base", b.Model))
		}
	}
	return errors.Join(errs...)
}

func bundleArtifact(b *Bundle) *Artifact {
	if b == nil {
		return nil
	}
	return &b.Artifact
}

func readJSON(path string, into any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, into)
}
