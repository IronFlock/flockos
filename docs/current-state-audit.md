# Current-state audit (2026-11-04)

Evidence for the [master plan](master-plan.md). Read-only review of this repository and
of the sibling repositories `device-init`, `device-agent`, `flasher`, `workflows` and the
private `IronFlock/flockos`. Paths are relative to the repository root unless shown
otherwise. "Likely" marks an inference that was not confirmed by running a build.

## 1. Repository

- `RecordEvolution/ReswarmOS`, public, default branch `master`, 757 commits, no GitHub
  workflows, no rulesets. `.github/` holds only `copilot-instructions.md`.
- Last commit 82b9a03 (2026-10-17) removed `reswarmify/` (now `IronFlock/device-init`)
  and the `reagent`/`reswarm*` units and scripts **from `reswarmify/archive`** only. The
  same units and scripts still exist under `buildroot/rootfs/` and
  `cubic/project/rootfs-overlay/`.
- Branding: "reswarm" has about 300 occurrences in 62 files, "IronFlock" 48 in 15,
  "FlockOS" none (apart from docs for a dev VM).
- No firmware update mechanism of any kind exists (no fwupd, no `rpi-eeprom` handling, no
  Jetson capsule flow; only runtime blobs inside the rootfs). No real-time kernel option
  exists in either tree.
- Secrets in the public tree: `cubic/README.md` line 141 contains a plaintext VM password
  (`sudo su ironflock` with the password printed); root password hashes in
  `cubic/config/autoinstall/{efi,bios}.yaml` (two different hashes); Buildroot
  `BR2_TARGET_GENERIC_ROOT_PASSWD="reswarm"`; default user `revenent`/`reverb` in
  `buildroot/boot/device.ini`.

## 2. `buildroot/` (Raspberry Pi images)

### Pipeline

| Step | What happens | Problems |
|------|--------------|----------|
| `make setup` | generates a self-signed RAUC cert/key per `output-build/` (365 days), copies the cert into `rootfs/etc/rauc/cert.pem`, writes `rootfs/etc/os-release` with a timestamp taken at setup time, builds `reswarmos-builder:latest` (`ubuntu:22.04`, unpinned apt, `yq` from `latest`, amd64 only) | `.dockerignore` misses `output-build/`, so the whole build output enters the Docker context |
| `make build` | `docker run -it` → `build-it.sh`: downloads Buildroot zip `9757e7d99e` (2021.11+1190 commits, early 2022), patches `.config`, copies `packages/`, genimage.cfg and post-build.sh, `make -j4` | needs a TTY; top-level `-j4` unsupported without per-package dirs; `ccache` dir inside the throwaway container |
| `make release` | `gsutil` round-trip of `supportedBoardsImages.json`, `supported-boards.py`, upload image + bundle to `gs://reswarmos/<board>/`, `gsutil setmeta -r` on the whole bucket | host needs `rauc`, `gsutil`, `python3-yaml` |

Buildroot header in every RPi/x86 config: `# Buildroot 2021.11-1190-g9757e7d99e Configuration`.
Toolchain GCC 10.3.0 glibc; kernels 5.10; U-Boot 2022.01/2022.04; `BR2_TARGET_UBOOT_NEEDS_PYTHON2=y`.

### Boards

| `config/<board>/<model>` | State |
|---|---|
| `raspberrypi/raspberrypi0w` | armv6 32-bit, consistent |
| `raspberrypi/raspberrypi3` | 32-bit; `config-full` has `BR2_cortex_a72=y` with `BR2_GCC_TARGET_CPU="cortex-a53"` (copied from Pi 4); `linux-config-full` is an x86 config |
| `raspberrypi/raspberrypi4` | 32-bit; **current `setup.yaml` target** (`config-full`, version 0.5.7) |
| `raspberrypi/raspberrypi2` | genimage.cfg only |
| `nvidia/jetson-nano` | 51-line fragment without header for a third-party Buildroot fork, L4T r32.4.2, kernel 4.9, Linaro GCC 7.3.1; **cannot build** |
| `nvidia/jetson-agx-xavier` | Dockerfile/makefile for a Go cross-build that reads `~/.git-credentials`; no OS config |
| `nvidia/reswarmify-nvidia.sh` | the Jetson path actually used: runs on NVIDIA's Ubuntu, installs `docker.io`, downloads the legacy agent |
| `x86_64/pc` | missing `genimage.cfg`, `post-image-efi.sh`, `grub.cfg`; no agent; no shadow; single GRUB entry, no A/B; **cannot build** |

Base `config` for Pi 3/4 selects firmware variants that do not match `genimage.cfg`
(`start_x.elf`/`start4x.elf` expected); only `config-full` matches.

### Boot and A/B (RPi)

- MBR: p1 `boot.vfat` 32 MiB label `ReswarmOS`; p2 `rootfsA`; p3 `rootfsB` (8 MiB
  placeholder); p4 `appfs` (8 MiB placeholder). `repart.service` grows p2/p3/p4 on
  first boot (about 18%/18%/rest) with `/dev/mmcblk0` hard-coded.
- Firmware → `kernel=u-boot.bin` → `boot.scr.uimg` (`config/raspberrypi/<model>/uboot.sh`):
  `BOOT_ORDER "rootfsA rootfsB"`, `BOOT_<slot>_LEFT 3`, loads `uImage` + DTB from the
  shared FAT, `root=/dev/mmcblk0p2|p3 rauc.slot=...`, `saveenv` to `/boot/uboot.env`
  (16 KiB file shipped as all zeros). RAUC `bootloader=uboot` edits it via `fw_setenv`.
- Kernel, DTBs, overlays and `boot.scr` live on the single FAT partition; the RAUC
  bundle contains only `rootfs.ext4`. **Kernel updates are impossible over RAUC.**
- `raucmarkgood.service` runs `rauc status mark-good` on every boot with `rauc.slot=` on
  the command line; no health check.
- U-Boot patches (`boot/uboot/rpi{3,4}.patch`) make U-Boot silent and uninterruptible.

### RAUC

`rootfs/etc/rauc/system.conf`: `compatible=ReswarmOS` (rewritten at build to
`ReswarmOS-<variant>-<model>`), `bootloader=uboot`, `statusfile=/boot/central-status.raucs`,
`bundle-formats=plain verity`, keyring `/etc/rauc/cert.pem`, slots `/dev/mmcblk0p2`
(`rootfsA`) and `/dev/mmcblk0p3` (`rootfsB`).

- Commit 279a545 (2025-11-24) changed `update/manifest.raucm` from `version=` to
  `version=0.5.7`; the Makefile's `sed "s/^version=/version=$(VSN)/"` now yields
  `version=0.5.70.5.7` (reproduced with the same sed).
- Device keyring cert in the tree: valid 2025-02-02 to **2026-02-02 (expired)**.
  `update/certs/cert.pem`: valid 2021-10-29 to **2022-10-29 (expired)**, with
  `key.pem` next to it (gitignored, on disk). Different keys; bundles from
  `update/generate-bundle.sh` would not verify on devices built from this tree.
- `update/Dockerfile` copies `certs/` (including the private key) into an image layer.
- `reswarmos-update-get.service` and `-install.service` use `$(...)` and globs in
  `ExecStart`, which systemd does not expand, split on `:` a file written with `,`, and
  have empty `[Install]` sections: **the in-image OTA path never worked**.

### Rootfs overlay and provisioning

- Flow: `repart` → `reswarm.sh` (newest `/boot/*.reswarm`; `.flock` files are **not**
  recognised) → writes `/boot/device.ini`, `/root/key.pem`, `/root/id.pub` →
  `rehost`/`reuser`/`rewifi`/`redocker` → `reagent` + `reagent-manager` (a 30 s
  `ps | grep` loop managing `Reagent-active/latest/previous` symlinks).
- `reswarm.sh`, `reuser-setup.sh`, `rewifi.sh` **echo the user password, device secret
  and WiFi password to the journal**.
- `motd.sh` calls `http://ipinfo.io` three times on every login.
- NetworkManager dispatcher calls `/usr/sbin/restart-agent.sh`, which does not exist
  (the script is `restart-reagent.sh`).
- `sshd_config` has no `Include` line, so `sshd_config.d/root.conf` is inert; `sftp`
  subsystem path is Buildroot's.
- `sysctl.conf` lines start with `sysctl `, likely invalid.
- `build-agent.sh` downloads `dl/re-agent/linux/<arch>/<ver>/reagent` with no checksum
  and has no aarch64 mapping.
- `packages/shadow` (4.9) would clash with upstream Buildroot's own `shadow` package;
  `packages/reagent` has a `Config.in` and no `.mk`.

## 3. `cubic/` (x86 installer ISO)

- Source: `ubuntu-20.04.3-live-server-amd64.iso` from `old-releases.ubuntu.com`
  (Focal; standard support ended 2025-05). `versions.json` `source` field is unused.
- Cubic 2024.02 on an Ubuntu 23.10 host; `project/amd64/cubic.conf` hard-codes
  `/home/ruben/git/ReswarmOS`; the Makefile hard-codes `$HOME/git/ReswarmOS` in about
  24 lines and `/home/ruben/Desktop/VM`.
- Of ten steps, four are GUI-only (project wizard, chroot terminal paste of
  `scripts/setup-rootfs.sh`, kernel/package pages, ISO generation). Cubic has no
  headless mode. `scripts/apply-changes.sh` (a non-Cubic path) calls three scripts
  without their `.sh` suffix and does not exist as written.
- `scripts/setup-rootfs.sh`: apt-installs `rauc rauc-service` which **Focal does not
  have** (with `set -e` the script should stop), adds the dead `impish` repository
  (404), then installs Debian `rauc_1.5.1` with `dpkg --force-all`. Docker unpinned.
- `config/autoinstall/efi.yaml`: GPT with ESP 512 MiB, `/` 5 GiB, slot B 5 GiB,
  `/home` 2 GiB, shared `/boot` 512 MiB, `/apps` rest; no `identity:`; root unlocked
  with a hard-coded hash. `bios.yaml`: no slot B, no `/boot` grub fix-up; **likely
  unbootable**.
- `etc/grub.d/40_custom` (RAUC GRUB script) line 25 reads `TRY= rootfsB_TRY` (missing
  `$`): fallback to slot B cannot work. Both slots share one `/vmlinuz` on `/boot`.
- `etc/rauc/system.conf`: `compatible=ReswarmOS` (never rewritten for x86),
  `bootloader=grub`, devices `/dev/xxx2`/`/dev/xxx3` patched at install by
  `update-device-names.sh` using kernel names (breaks for `mmcblk2p2`).
- No x86 RAUC bundle has ever been produced: `ipc/ReswarmOS-installer-0.0.7-efi.raucb`
  returns 404; the published `ipc/ReswarmOS-installer-0.0.7-efi.iso.gz` was last
  modified **2022-06-28**. The 2024 Cubic rework was never published.
- Overlay vs `buildroot/rootfs`: 22 files identical, 15 differ (mostly shebang,
  device paths, cert), the rest unique to one side. Same password-logging scripts.
- `update-os-config.sh` (writes os-release buildtime) is never called; the committed
  os-release says `v0.0.7-7bc5a8a-20220628T112125`, so the OTA buildtime comparison
  is frozen.

## 4. Published catalog (live)

- `https://instance-registry.ironflock.com/dl/reswarmos/supportedBoardsImages.json`
  (= `gs://reswarmos/supportedBoardsImages.json`) lists IPC `installer` 0.0.7
  (2022-06-28), RPi 3/4 `image` 0.5.x and RPi 0W `heavy` 0.5.3; the private flockos
  repo also published `raspberrypi3-64`/`raspberrypizero2w-64` 0.5.15 into it.
- `https://storage.googleapis.com/reswarmos/supportedBoards.json` is a board list
  without images (ipc/efi, jetson nano/agx, rpi 3/4/0w) with `docs.record-evolution.de`
  links.

## 5. `IronFlock/flockos` (private, abandoned)

- In-tree fork of Buildroot `2024.08-rc1`, branch `newb`, last real work 2025-03-29.
- `flockOS/raspberrypi/{raspberrypi3-64 (0.5.15 "working"), raspberrypizero2w-64 (wip),
  raspberrypi4-64 (stale)}`; `BR2_INIT_SYSTEMD`, Docker, NetworkManager, RAUC, U-Boot;
  FAT label `FlockOS`; 4 partitions boot/rootfsA/rootfsB/appfs; paths hard-coded to
  `/home/ironflock/git/buildroot`; built on GCE VM `flockos-builder-standard`; no CI.
- RAUC bundler broken: copies the overlay directory instead of `rootfs.ext4`, mangles
  the manifest, `compatible=ReswarmOS` vs system `ReswarmOS-image-<model>`; `release.sh`
  never uploads a `.raucb`.
- **`flockOS/build_scripts/update/certs/key.pem` was committed** (aef6d695, 2025-02-26)
  and pushed to `origin/newb`. Its certificate matches the keyring cert in
  `cubic/project/rootfs-overlay/etc/rauc/cert.pem` (SHA-256 `2F:60:B1:2C:…:27:ED:EA`,
  expired 2022-10-29). Treat the key as compromised; never reuse.
- `flock.sh` echoes the device secret and WiFi password to the log.

## 6. `IronFlock/device-init` (v1.4.8)

- Entry: `curl -fsSL https://instance-registry.ironflock.com/dl/device-init/install.sh | sudo bash -s -- -c device.flock`.
  `install.sh` verifies OpenPGP signatures (bootstrap key in Cloud KMS
  `ironflock-release/device-init-bootstrap`), maps `x86_64→amd64`, `aarch64→arm64`,
  `armv7l→armv7`, `armv6l→armv6`, and runs the signed `ironflock-init` binary.
- `ironflock-init` (Go): requires root; parses `.flock` (`name`, `swarm_owner_name`,
  `wlanssid`, `password`, `device_key`, `secret`, `authentication.key`, `update_url`,
  `device_endpoint_url`); detects layout (Current `/opt/ironflock/device-agent` +
  `installed.json`, Legacy `/opt/reagent`, Migrating, Migrated, None); cleans legacy
  leftovers; package manager by **first word of `/etc/issue`** (Debian/Ubuntu/Raspbian/
  Linux Mint → apt; Arch, CentOS/Fedora, SUSE partially); installs `jq ca-certificates
  curl gnupg lsb-release net-tools iproute2 dnsutils network-manager openssh-server`;
  Docker via `get.docker.com` if the socket does not answer; agent version from the
  signed `device-agent/manifest-v2.json` (`channels.production`); downloads
  `device-agent/linux/<arch>/<ver>/device-agent` + `.sha256` + Ed25519 `.sig`;
  writes `/etc/docker/daemon.json` (data-root `/opt/ironflock/device-agent/docker-apps`,
  buildkit, json-file 10m×3, `nvidia` runtime when `/usr/bin/nvidia-container-runtime`
  exists); SSH user (locked password, authorized key, sudoers NOPASSWD); WiFi
  nmconnection; NM `wifi.scan-rand-mac-address=no`; NM and dbus restart drop-ins; motd;
  `--disable-suspend`; proxy drop-in; then `device-agent service install -config …
  -agentDir /opt/ironflock/device-agent -start` (the agent writes its own unit).
- Does not set the hostname. Supported: "Debian or Ubuntu-based OS (x86_64, arm64,
  armv5/v6/v7) with systemd"; staged agent arches `amd64 arm64`.
- Downloads: `gs://ironflock-downloads/device-init/` behind `dl/device-init/`.
- CI: `ci.yml` (go-gate, workflows-lint, release-intent on `cli/release/version.txt`,
  release dry run, `ci-ok`), `release.yml` (verify → build + SBOM → KMS sign → stage →
  e2e on VMs ~1.5 h → promote → tag), `security.yml` (`languages: go`, blocking
  `fail-on`). Rulesets: squash-only main with `ci-ok` + `security / report`; tags by
  the release App.

## 7. `IronFlock/flasher` (FlockFlasher v2.2.4)

- Electron 43, `etcher-sdk` 10.2, Node 22. Accepts local `.flock .reswarm .iso .img`.
- Catalog: `https://instance-registry.ironflock.com/dl/reswarmos/supportedBoardsImages.json`,
  shape `{boards: SupportedBoard[], latestUpdate}`; `SupportedBoard{architecture, board,
  boardname, cpu, docs, reflasher, latestImages[], model, modelname}`;
  `ImageInfo{buildtime, download, file, osname, osvariant, sha256, size, update, version}`
  where `sha256`/`size` describe the `.gz`. **Only `latestImages[0]` is used.**
  Catalog downloads must end in `.gz`. The catalog itself is not signed.
- `osvariant === 'image'`: flash, mount every partition, copy `<name>.flock` (and
  `.reswarm` for compatibility) to **the first mountpoint**; no label check; Windows
  mount step is a no-op.
- Any other `osvariant`: extract ISO, write `boot/<name>.flock`, repack with xorriso
  assuming `/isolinux/isolinux.bin` and `/boot/grub/efi.img` (Ubuntu ≤ 20.04 layout).
- CI/release follow the harness; Windows installer unsigned; macOS not released.

## 8. `IronFlock/device-agent` (v1.5.4)

- `src/system/rauc.go`: D-Bus `de.pengutronix.rauc.Installer.InstallBundle(path,
  {ignore-compatible:false})`, waits for `Completed`, polls `Progress`/`LastError`.
  `GetSlotStatus`, `GetPrimary`, `Mark` constants exist but are unused.
- `src/system/system.go`: expects `/etc/reswarmos-update` (`version,buildtime,url`) and
  `/etc/os-release-latest.json` written by the OS poller (deleted from this repo);
  downloads to `/tmp/<file>` without hash check; `InstallOSUpdate` logs failures and
  **returns nil**; no automatic reboot.
- RPCs: `get_os_release`, `download_os_update`, `install_os_update` (privilege
  `MAINTAIN`); `perform_os_update` defined without handler. `/etc/os-release` `VERSION`
  must be `v<ver>-g<sha>-<buildtime>` (three dash-separated parts).
- Layout detection: `/opt/reagent/flock-mode` or `/opt/reagent/ironflock/services` →
  `legacy-image`.
- Self-update: Ed25519 detached `.sig` (`updatesig`), KMS `ironflock-release/agent-update`
  (+ OpenBao transit), tree `gs://ironflock-downloads/device-agent/`.
- CI: go-gate, integration, coverage, windows-unit; release with SBOM + `actions/attest`,
  Authenticode via jsign/KMS, multi-arch images, `promote` signs manifest; `security.yml`.

## 9. `IronFlock/workflows` (harness, callers use `@v1`, latest `v1.4.0`)

- Reusable: `go-gate.yml`, `node-gate.yml`, `python-gate.yml` (jobs `lint`, `unit`,
  `build`, each a `just` recipe), `security.yml` (gitleaks, govulncheck/osv-scanner,
  semgrep with IronFlock rules, trivy config + licence, SBOM, optional Dockerfile image
  scan, `report` applying `fail-on`, VEX/trivyignore/gitleaks exceptions),
  `workflows-lint.yml` (actionlint, zizmor with `IronFlock/*: ref-pin`, `*: hash-pin`,
  pinact), `release-intent.yml`, `release-image.yml` (BuildKit `--sbom --provenance`,
  keyless WIF push), `release-tag.yml` (release App), `selftest.yml`.
- README: "Gates for Node, Python and chart/shell repositories follow the same pattern
  and are added when the first repository of that kind adopts the harness." No shell
  gate exists yet. `security.yml` has `languages: none` and scans Dockerfiles, not a
  built rootfs.
- `tools.lock` pins gitleaks 8.30.1, trivy 0.76.0, osv-scanner 2.7.0, actionlint 1.7.12,
  zizmor 1.31.1, pinact 5.0.0, shellcheck 0.11.0, just 1.59.0, and others by sha256.
- Versioning: version file + `just release-patch|minor|major` (fetches `scripts/pr.sh@v1`)
  opens the PR `release <name> v<x>` with auto squash-merge; `release-intent` enforces
  the pairing; `release.sh mode` returns release/released/dry-run/tag.
- Org `.github`: `SECURITY.md`, PR template with a security checklist. `CODEOWNERS` only
  in `workflows` (`* @markope`). No dependabot, scorecard, cosign or CodeQL analysis
  anywhere (the CodeQL action uploads SARIF only).

## 10. External facts checked on 2026-11-04

- Debian 13 (trixie) ships `rauc` 1.13-3; bookworm 1.8-2; sid 1.15.2. Upstream RAUC
  latest is 1.15.2 (April 2026).
- RAUC supports `--cert`/`--key` as PKCS#11 URIs with `RAUC_PKCS11_MODULE`; Google's
  `libkmsp11` exposes Cloud KMS keys through PKCS#11 (`KMS_PKCS11_CONFIG`).
- Raspberry Pi A/B via firmware `tryboot`/`autoboot.txt` has a working RAUC `custom`
  backend precedent (Bootlin, Pi 5) and comparable designs in Eclipse Oniro SysOTA and
  Ubuntu 25.10's piboot A/B.
- Jetson Linux r36.x supports rootfs A/B (`ROOTFS_AB=1`, `nvbootctrl -t rootfs`); UEFI
  retries the other slot after three failed boots; the retry counter decrements on warm
  reboots only.
- GitHub `ubuntu-24.04-arm` runners are free on public repositories (4 vCPU, 16 GB);
  private repositories get 2 vCPU runners that bill minutes.
- NVIDIA publishes a CUDA apt repository for `debian13` (drivers incl. open kernel
  modules); `nvidia-container-toolkit` comes from NVIDIA's distro-independent
  `libnvidia-container` deb repository. Debian's own `non-free` driver is 550.x.
- `mmdebstrap --mode=unshare` builds cross-architecture roots unprivileged with
  `qemu-user-static` and is bit-for-bit reproducible with `SOURCE_DATE_EPOCH`.
