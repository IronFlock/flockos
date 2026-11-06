# ADR-0010: FlockOS images for virtual devices on Compute Engine

Status: accepted, 2026-11-06.

## Context

The virtual-device-manager (`IronFlock/virtual-device-manager`) creates IronFlock's cloud
devices as Compute Engine VMs in `record-1283` (zone `europe-west1-b`): amd64 on E2, N1
and G2 machines, arm64 on C4A. Until now it boots images made by hand
(`ironflock-device-image-2501`, `ironflock-device-image-arm-2501`, and the family
`ironflock-device-image-gpu` from Ubuntu's accelerator image). It then logs in over SSH,
as an account Google's guest agent creates from a key in the instance metadata, and
runs device-init's `install.sh` and `ironflock-init` with the device's `.flock`.

FlockOS should run there too, for field tests first: a VM is the quickest device to get.
But FlockOS has no default user and no Google guest environment, and it enrolls from a
`.flock` on its FLOCKOS partition (master plan, sections 3.4 and 3.9). A VM has no
partition anyone could put a file on.

## Decisions

### 1. Every release makes Compute Engine images of the published images

`release.yml` job `vm-images` (`build/gce-image.sh`) makes three images per release:
`amd64-efi base`, `amd64-efi nvidia` and `arm64-efi base` (`GCE_IMAGES` in
`build/release.conf`). VMs need no real-time kernel, and arm64-efi has no nvidia variant.

- **The images.** Each is made from the published `.img.gz`, which must match the
  release's `SHA256SUMS`, byte for byte as `disk.raw`. There is no VM build.
- **Names.** An image is `flockos-<target>-<variant>-v<x-y-z>`, in the image family
  `flockos-<target>-<variant>`, stored in `eu`. The labels carry the version, target and
  variant; the description carries the source URL and its sha256.
- **Disk size.** The disk is the smallest the layout fits: both slots, the FLOCKOS
  partition and 1 GiB of `/data`. That is 10 GiB for base and 18 GiB for nvidia, so
  Compute Engine refuses a VM disk the first boot could not partition.
- **Guest features.** `UEFI_COMPATIBLE` and `GVNIC`, plus `VIRTIO_SCSI_MULTIQUEUE` on
  amd64.
- **Timing.** The job runs after `promote`, so a family never offers an unpublished
  release, and the tag waits for it. A re-run keeps an image made from the same file.
- **Identity.** It runs as `flockos-publisher`. Its custom role
  `flockosVmImagePublisher` creates and reads images named `flockos-*` and nothing else
  of Compute Engine (`tools/release-setup.sh`).

The families follow the newest release, which is the test channel's (ADR-0009). Nothing
is promoted to a production family yet.

### 2. One image for hardware and VMs

The release images boot on Compute Engine as they are:

- UEFI boots GRUB from the removable-media path.
- The serial consoles are Compute Engine's serial port 1: `ttyS0` on amd64, `ttyAMA0` on
  arm64.
- Debian's kernel has the `gve`, `virtio_scsi`, `virtio_net` and `nvme` drivers.
- NetworkManager takes the VM's DHCP lease.
- systemd-repart grows the layout into the larger disk, as on hardware.

FlockOS carries no Google guest environment. The guest agent would create sudo accounts
from metadata keys: a second way in beside the one account from the `.flock`.

### 3. The `.flock` through the instance metadata, removed once the VM has it

- The manager creates a FlockOS VM with its `.flock` as the instance attribute
  `flockos-flock`, and with `enable-guest-attributes=TRUE`.
- On the first boot of a slot, `flockos-gce-flock.service` runs before
  `flockos-enroll.service`. It runs only where the firmware says
  `Google Compute Engine` (SMBIOS `product_name`).
- It writes the attribute to the FLOCKOS partition as `compute-engine.flock`. Enrollment
  then takes it like a `.flock` put there by hand: it copies it to `/data` and shreds it.
- It then sets the guest attribute `flockos/flock` to `taken`. The manager waits for
  that and removes `flockos-flock` from the metadata again.
- No SSH login, no `install.sh`: the device-agent and the rest of the device come with
  the image.
- On other machines the unit is skipped at once. It waits for no network target, so an
  offline device still enrolls without delay.

### 4. The device chooses FlockOS; the product stays the hardware

A product is the VM's hardware, which billing charges, and names no OS. The only
exception is Windows, whose licence is in its price.

- **The choice.** A virtual device runs FlockOS when it is created with a FlockOS image
  id (`os_image_id`), the field the platform keeps for every device's FlockOS image. The
  manager boots the image family of that id.
- **Checks.** The id must have a VM image, and the image must fit the product's
  architecture. The manager refuses any other id before the device exists.
- **Rebuilds.** A device whose VM is gone comes back on the id stored on its row.
- **No id.** Without an id, a device boots the product's images, as before.
- **Disks.** The products' minimum disks (10 GB, 40 GB with a GPU) fit FlockOS (10 GiB,
  18 GiB for nvidia).

## Consequences

- **The device dialog.** Studio's dialog for virtual devices has to offer the FlockOS
  images with a VM image and send the chosen `os_image_id`. That field comes with the
  platform's FlockOS image work in backend, platform-db and Studio.
- **Exposure window.** Between the VM's creation and the guest attribute, every process
  on the VM could read the device's secret from the metadata server. No app runs before
  the enrollment, and the window is a boot's length.
- **Interrupted manager.** A manager that dies inside that window leaves the attribute
  behind, so does a VM made by hand without guest attributes. `gce-flock` says so on the
  serial console.
- **Old images stay.** The family serves the newest, and the VMs keep their disks. A
  clean-up of old images (it needs `compute.images.delete`) is for later.
- **No GCE test in CI.** CI tests the scripts (`test/unit/gce.bats`) and the dry run of
  `vm-images`. The first boot on Compute Engine is tested in the field.
- **Owner action.** `tools/release-setup.sh --yes` must have created the role before the
  first release with `vm-images`. Until then that job fails, and with it the tag; a
  re-run of the failed jobs after the setup finishes the release.

## Alternatives

- **SSH as on the Ubuntu images**, with Google's guest agent in FlockOS. This adds a
  daemon that creates sudo accounts from metadata, contrary to section 3.9 of the master
  plan, and an SSH dependency to provisioning.
- **cloud-init.** A large Python dependency for one file.
- **A second disk holding the `.flock`.** The manager would have to write a disk without
  a VM.
- **A VM variant of the build.** One more image to build and test, while the release
  images boot as they are.
