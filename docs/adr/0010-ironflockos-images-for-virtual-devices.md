# ADR-0010: IronFlockOS images for virtual devices on Compute Engine

Status: accepted, 2026-11-06.

## Context

The virtual-device-manager (`IronFlock/virtual-device-manager`) creates IronFlock's cloud
devices as Compute Engine VMs in `record-1283` (zone `europe-west1-b`): amd64 on E2, N1
and G2 machines, arm64 on C4A. Until now it boots images made by hand
(`ironflock-device-image-2501`, `ironflock-device-image-arm-2501`, and the family
`ironflock-device-image-gpu` from Ubuntu's accelerator image). It then logs in over SSH,
as an account Google's guest agent creates from a key in the instance metadata, and
runs device-init's `install.sh` and `ironflock-init` with the device's `.flock`.

IronFlockOS should run there too, for field tests first: a VM is the quickest device to get.
But IronFlockOS has no default user and no Google guest environment, and it enrolls from a
`.flock` on its IRONFLOCKOS partition (master plan, sections 3.4 and 3.9). A VM has no
partition anyone could put a file on.

## Decisions

### 1. Every release makes Compute Engine images of the published images

`release.yml` job `vm-images` (`build/gce-image.sh`) makes three images per release:
`amd64-efi base`, `amd64-efi nvidia` and `arm64-efi base` (`GCE_IMAGES` in
`build/release.conf`). VMs need no real-time kernel, and arm64-efi has no nvidia variant.

- **The images.** Each is made from the published `.img.gz`, which must match the
  release's `SHA256SUMS`, byte for byte as `disk.raw`. There is no VM build.
- **Names.** An image is `ironflockos-<target>-<variant>-v<x-y-z>`, in the image family
  `ironflockos-<target>-<variant>`, stored in `eu`. The labels carry the version, target and
  variant; the description carries the source URL and its sha256.
- **Disk size.** The disk is the smallest the layout fits: both slots, the IRONFLOCKOS
  partition and 1 GiB of `/data`. That is 10 GiB for base and 18 GiB for nvidia, so
  Compute Engine refuses a VM disk the first boot could not partition.
- **Guest features.** `UEFI_COMPATIBLE` and `GVNIC`, plus `VIRTIO_SCSI_MULTIQUEUE` on
  amd64.
- **Timing.** The job runs after `promote`, so a family never offers an unpublished
  release, and the tag waits for it. A re-run keeps an image made from the same file.
- **Identity.** It runs as `ironflockos-publisher`. Its custom role
  `ironflockosVmImagePublisher` creates and reads images named `ironflockos-*` and nothing else
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

IronFlockOS carries no Google guest environment. The guest agent would create sudo accounts
from metadata keys: a second way in beside the one account from the `.flock`.

### 3. The `.flock` through the instance metadata, removed once the VM has it

- The manager creates an IronFlockOS VM with its `.flock` as the instance attribute
  `ironflockos-flock`, and with `enable-guest-attributes=TRUE`.
- On the first boot of a slot, `ironflockos-gce-flock.service` runs before
  `ironflockos-enroll.service`. It runs only where the firmware says
  `Google Compute Engine` (SMBIOS `product_name`).
- It writes the attribute to the IRONFLOCKOS partition as `compute-engine.flock`. Enrollment
  then takes it like a `.flock` put there by hand: it copies it to `/data` and shreds it.
- It then sets the guest attribute `ironflockos/flock` to `taken`. The manager waits for
  that and removes `ironflockos-flock` from the metadata again.
- No SSH login, no `install.sh`: the device-agent and the rest of the device come with
  the image.
- On other machines the unit is skipped at once. It waits for no network target, so an
  offline device still enrolls without delay.

### 4. Every Linux VM runs IronFlockOS; the image follows the hardware

The manager's Ubuntu and Debian images are deprecated (2026-11-06) and no longer
offered. Every virtual device that is not Windows runs IronFlockOS.

- **The image.** The product's hardware decides it: `ironflockos-arm64-efi-base` on arm64,
  `ironflockos-amd64-efi-nvidia` with a GPU, `ironflockos-amd64-efi-base` otherwise. No arm64
  image has the NVIDIA driver, so an arm64 product with a GPU is refused before the
  device exists.
- **No OS in products.** A product is the VM's hardware, which billing charges. Only
  Windows is a product of its own, as its licence is in the price.
- **The device row.** The manager records the image as the device's `os_image_id`, the
  field the platform keeps for every device's IronFlockOS image. Studio's dialog for
  virtual devices needs no OS choice.
- **Rebuilds.** A device whose VM is gone comes back on IronFlockOS, the image derived from
  its product again. This holds for devices made on the old images too.
- **Disks.** The products' minimum disks (10 GB, 40 GB with a GPU) fit IronFlockOS (10 GiB,
  18 GiB for nvidia).

## Consequences

- **Old devices.** Devices made on the old images keep running them until their VM is
  rebuilt. device-init's end-to-end targets `vdm-amd64` and `vdm-arm64` still boot those
  images, so they stay in `record-1283` until device-init moves on.
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

- **SSH as on the Ubuntu images**, with Google's guest agent in IronFlockOS. This adds a
  daemon that creates sudo accounts from metadata, contrary to section 3.9 of the master
  plan, and an SSH dependency to provisioning.
- **cloud-init.** A large Python dependency for one file.
- **A second disk holding the `.flock`.** The manager would have to write a disk without
  a VM.
- **A VM variant of the build.** One more image to build and test, while the release
  images boot as they are.
