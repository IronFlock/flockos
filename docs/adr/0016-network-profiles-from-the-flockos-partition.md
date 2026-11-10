# ADR-0016: Network profiles come with the boot medium, in the FLOCKOS partition's network folder

Status: accepted, 2026-11-10.

## Context

A device reaches the platform over a wired network with DHCP without any setting, and
over the `.flock`'s Wi-Fi, which enrollment turns into a NetworkManager profile. A device
on a network without DHCP, or on another Wi-Fi network, needs a profile before its first
connection. The platform cannot send one: the device has to know its network from its
first boot.

`ironflock os install` of device-init turns a running Debian or Ubuntu machine into an
IronFlockOS device by writing the released image onto its disk at the end of a shutdown
(device-init, ADR-0008). Many such machines have a static address, some are on Wi-Fi. The
command reads the network of the running system and has to hand it to the new one. It
writes the image from memory, with the changes to the FLOCKOS partition patched in; the
image holds the FLOCKOS partition and slot A only. `/data`, where NetworkManager's
profiles live on a device (`/etc/NetworkManager/system-connections` is bound from
`/data/network/connections`), is made by systemd-repart on the first boot. The FLOCKOS
partition is the only place of the new system that exists before that boot and that
another system can write, and it is where the `.flock` and `proxy.conf` already come
from ([ADR-0014](0014-proxy-per-device-from-the-flockos-partition.md)). FlockFlasher and
`ironflock os flash` write the same partition.

The FLOCKOS partition is FAT. It has no owners and no modes of its own (it is mounted for
root only, `umask=0077`), and someone who holds the disk reads it in any computer. A
Wi-Fi profile holds the network's password.

## Decision

### 1. The place: `network/<name>.nmconnection` on the FLOCKOS partition

- A NetworkManager keyfile, as NetworkManager writes one, in the folder `network` at the
  root of the FLOCKOS partition (`/boot/efi/network/` on the device). Any number of them.
- `flockos-network-profiles.service` runs `/usr/lib/flockos/network-profiles` on every
  boot where one lies there, the first boot included: after `/data` is mounted and
  `flockos-data-layout` has made its folders, before NetworkManager starts. Each file
  accepted goes to `/data/network/connections/<name>.nmconnection`, mode 0600, owned by
  root (NetworkManager ignores a profile others can read), with LF line ends and
  without a byte order mark. Then it is overwritten (`shred`) and removed from the
  partition, and the folder `network` is removed when it is empty.
- The format is NetworkManager's own, not one of IronFlockOS: every kind of connection
  NetworkManager knows can come this way, and what writes it can make it with
  NetworkManager's own tools (`nmcli --offline connection add` prints a keyfile).
  IronFlockOS checks the form, not the meaning.

### 2. Which files are taken

A file `network/*.nmconnection` is taken when:

| Rule | Why |
|------|-----|
| The name is `<name>.nmconnection`, `<name>` 1 to 64 of `A-Z a-z 0-9 . _ -`, not beginning with `.` or `-`, the extension in lower case | the name becomes a file in `/data/network/connections`; NetworkManager ignores names that begin with a dot |
| A regular file, 1 byte to 64 KiB | a folder or a link is no profile; a keyfile is a few hundred bytes, certificates inline make it a few KiB |
| UTF-8 text without a NUL byte | GLib's key files, which NetworkManager reads profiles with, are UTF-8; a file a power loss left with zeros is no profile |
| A key file as GLib reads one: every line blank, a comment (`#`), a `[group]` or a `key=value` line, a key without `[` or `]`, the first line that is no blank line or comment a group | NetworkManager does not load a file GLib cannot parse |
| A `[connection]` group with `type=` of `a-z 0-9 -`; a `uuid=` there, if any, is a UUID | a file without them is most likely no profile; NetworkManager names a profile after its file and derives its uuid from its path when `id` and `uuid` are missing |

`<name>.nmconnection` files whose extension is in other letters, and other files in the
folder, are not looked at. `/usr/lib/flockos/network-profiles check FILE` tells whether a
file would be taken, and changes nothing.

### 3. A refused file is renamed, the rest are taken

A file that breaks a rule is renamed to `<name>.nmconnection.refused` (replacing an older
one of that name). Its reason goes to the journal and to the console, as a device without
its network is reached there; the other files are taken all the same, and the unit fails,
so `systemctl --failed` shows it. Nothing of the device's profiles changes for it.

Renaming, not leaving the file: a file left in place would be refused at every boot, and
a later release that accepted it would apply an old profile by surprise and could take the
device off its network. Renaming, not removing: the person who wrote it finds it with the
medium in another computer. A refused Wi-Fi profile keeps its password on the partition
until someone removes it, as a refused `proxy.conf` does.

### 4. A profile replaces the device's of the same name and the same uuid

The new profile replaces the device's file of the same name, and every other profile on
`/data/network/connections` whose `[connection]` holds the same `uuid` (compared without
regard to case): NetworkManager keeps one profile per uuid, and the one that came last is
the one meant. Profiles of other names and uuids stay. Several files in one boot are taken
in the order of their names.

Enrollment writes the `.flock`'s Wi-Fi as `ironflock-wifi.nmconnection` after
NetworkManager has started, so a profile of that name from the partition is replaced at the
same boot when the `.flock` has a Wi-Fi network.

### 5. A power loss takes the profile again

The profile is written under `.flockos-profile-<name>.part` in the same folder, renamed to
its name, and synced to `/data` before anything leaves the partition. A power loss before
the rename leaves a part file, which the next run removes; after it, the file is still on
the partition, and the next boot takes it again, with the same result.

### 6. The secret on FAT

A Wi-Fi profile and a profile with an 802.1X or VPN secret lie on the partition from the
moment they are written until the boot that takes them: readable by anyone who holds the
medium, as a `.flock` and a `proxy.conf` with a password are. The device overwrites the
file before it removes it. On FAT, and on flash memory with its own wear levelling, that
does not make sure the old content is gone from the medium
([ADR-0015](0015-factory-reset-requested-on-the-flockos-partition.md), section 4); until
its blocks are written again, someone who reads the raw medium may find the password.

### 7. The order with the other units of the FLOCKOS partition

| Unit | When | With the profiles |
|------|------|-------------------|
| `flockos-factory-reset` | before `/data` is mounted | before; see section 8 |
| `flockos-data-layout` | after `/data` is mounted | before: it makes `/data/network/connections` with mode 0700 |
| `flockos-network-profiles` | before NetworkManager | |
| `flockos-proxy` | before containerd, Docker, the agent and chrony | independent |
| NetworkManager | | reads the profiles at its start |
| `flockos-gce-flock`, `flockos-enroll` | after NetworkManager | after: enroll writes the `.flock`'s Wi-Fi |

### 8. A factory reset

While a factory reset is pending or has begun (`factory-reset.conf` or
`factory-reset.keep` on the partition), the profiles there are for the device after it
and wait, as the `.flock` and `proxy.conf` do (ADR-0015). The reset runs before `/data` is
mounted and leaves them on the partition. At the first boot after it they are taken into
the new `/data`:

- **keep-network=yes**: the device's profiles were kept, and the waiting ones are taken
  into them, replacing kept ones of the same name or uuid.
- **keep-network=no**: the device's profiles are gone, and the waiting ones are all the
  device has, besides the `.flock`'s Wi-Fi.

A refused request is renamed before this unit runs; the profiles are then taken as
without one. A reset that failed before it began keeps the request, and the profiles wait
on.

### 9. The contract for the caller

`ironflock os install` (and later `ironflock os flash` and FlockFlasher) write profiles
by these rules:

- **Support.** A system takes the profiles when it has
  `/usr/lib/flockos/network-profiles`: every release after 0.14.0. IronFlockOS 0.14.0
  and older ignore the folder and leave it on the partition, so a machine that needs a
  profile needs a newer image.
- **The place.** The folder `network` at the root of the FLOCKOS partition (the partition
  named `FLOCKOS`, the first of the EFI images; FAT32; `/boot/efi` on a running device;
  on Jetson NVIDIA's ESP). One file per profile, `network/<name>.nmconnection`.
- **The name.** `<name>` is 1 to 64 characters of `A-Z a-z 0-9 . _ -`, the first neither
  `.` nor `-`; the extension `.nmconnection` in lower case. Not `ironflock-wifi`, which
  enrollment writes. A name the device already has replaces that profile.
- **The content.** A NetworkManager keyfile, UTF-8, at most 64 KiB, no NUL byte, LF line
  ends (CRLF and a byte order mark are accepted). Every line blank, `#` comment, `[group]`
  or `key=value`; the first group before the first key. A `[connection]` group with
  `type=` (`ethernet`, `wifi`, ...) and a `uuid=` of a new random UUID, which makes the
  profile replace any of the device's with that uuid. A key of the
  `[ethernet]` or `[wifi]` group `mac-address=` binds the profile to the card, as
  interface names may differ between the old system and IronFlockOS. Mode and owner on
  the partition do not matter; the device makes the file 0600 and root's.
- **Writing it.** On a mounted partition: under a name that does not end in
  `.nmconnection` (for example `network/.<name>.part`), then renamed, so a power loss
  never leaves a half profile with the right name. Into an image before its first boot,
  as `os install` patches it, the file is complete before the system starts anyway.
- **The result.** At the next boot the file is gone from the partition and the profile is
  in `/etc/NetworkManager/system-connections/<name>.nmconnection`, the line
  `took <name>.nmconnection (<type>) from the FLOCKOS partition` in
  `journalctl -u flockos-network-profiles`. A refused file is
  `network/<name>.nmconnection.refused`, with
  `network-profiles: refused <name>.nmconnection: <reason>; renamed to ...` in the journal
  and on the console, and the unit has failed. While a factory reset is pending or has
  begun, the files stay where they are.
- **`check`.** `/usr/lib/flockos/network-profiles check FILE` on a device: exit 0 and no
  output when FILE (by its name and content) would be taken; exit 1 and one line
  `network-profiles: <reason>` on stderr when not, without the file's name; exit 2 for
  wrong arguments. The reasons: `the name is not <name>.nmconnection with 1 to 64 of A-Z
  a-z 0-9 . _ -`, `it is not a file`, `it is empty`, `it is larger than 64 KiB`, `it holds
  a NUL byte`, `it is not UTF-8 text`, `line <n> is not a [group] line`, `line <n> is not
  a key=value line`, `line <n>: a key=value line before the first [group]`, `line <n>:
  not a key name`, `it has no type= in a [connection] group`, `type= is not a
  NetworkManager connection type`, `uuid= is not a UUID`.

What else `os install` reads from a release, each image's raw size, its smallest disk and
its hardware list (`image.raw_size`, `image.min_disk_size`, `modules_alias`), is in
[release.md](../release.md#what-ironflock-os-install-reads).

## Consequences

- `os install` gives a machine with a static address or a Wi-Fi network its network on
  the first boot, and FlockFlasher can do the same for any device.
- A profile on the partition also changes the network of a running device at its next
  boot: with the medium in another computer, a device that lost its network can be given a
  new one.
- A wrong profile takes a device off its network as surely as a right one puts it on.
  IronFlockOS checks the form, not whether the address or password is right; the caller
  checks what it can (ADR-0008 of device-init: the address, the gateway, the card).
- The partition carries a Wi-Fi password until the first boot, as it carries the `.flock`.
- NetworkManager's whole format is open, also kinds of connection `os install` refuses
  (VLANs, bonds, 802.1X): a person or a later tool can use them.
- IronFlockOS 0.14.0 and older ignore the folder.

## Alternatives

- **Settings of IronFlockOS's own** (`network.conf` with `address=`, `gateway=`, `ssid=`),
  turned into a profile on the device: a second format to define, parse and extend for
  every kind of connection, which the caller would turn into anyway from what it reads.
  Rejected.
- **The network in the `.flock`**: it holds a Wi-Fi network already, but the `.flock` is
  made by the platform for every OS, before anyone knows the machine's address; a static
  address belongs to the machine, not the device's identity. It also cannot carry a
  profile a person writes. Kept for the `.flock`'s Wi-Fi only.
- **NetworkManager reading the FLOCKOS partition** (a second keyfile path): the secrets
  would stay on FAT for good, NetworkManager would write there when a profile changes, and
  a profile could not outlive a reflash of the partition's content. Rejected.
- **Leaving a refused file in place, or removing it**: see section 3.
