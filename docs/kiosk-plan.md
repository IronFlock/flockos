# The screen: boot splash, the usual keys and the kiosk app

Plan, proposed 2026-11-12. Owner: Marko Petzold. It works out section 3 of
[ADR-0020](adr/0020-a-machine-panel-pc-on-the-stock-image.md) and cuts
the work into work packages in the form of [implementation-plan.md](implementation-plan.md).

A device with a screen shows a logo while it boots and the UI of an IronFlock app once it
runs, and a person at the device still reaches the firmware setup, the boot messages and a
login prompt with the keys they know. The image brings the splash and the keys. The
browser that shows the UI is an app that IronFlock provides, not a part of the image.

## What a person at the device sees

| Phase | On the screen | Keys |
|-------|---------------|------|
| Firmware | the firmware's own picture | the firmware's setup key, as the PC's maker set it |
| GRUB, up to 2 s | nothing | Esc: the boot menu, with the slots and "Firmware setup" |
| Kernel and boot | the splash: IronFlock's logo, or the image the device was given | Esc: the boot messages, and back to the splash |
| Running, no kiosk app | the splash stays | Ctrl+Alt+F2 to F6: a login prompt; Ctrl+Alt+F1: back |
| Running, kiosk app | the UI of the app the kiosk is pointed at | the same keys, and the kiosk's own key to IronFlock Studio |
| Shutdown and restart | the splash | |

## Decisions

Decided by Marko on 2026-11-12:

| # | Decision |
|---|----------|
| D1 | The splash is the default of the image, and the default picture is IronFlock's logo. |
| D2 | The usual keys work: into the firmware setup and into a normal Unix shell. |
| D3 | The kiosk is an app that IronFlock provides. It is built in its own repository (WP-8.5). |
| D4 | The kiosk app can give the device its splash picture and change it. |
| D5 | The kiosk app has no content of its own. It shows the UI of another app, and which one is a setting of the kiosk app. |
| D6 | The kiosk app has a key that opens IronFlock Studio, at its login when nobody is signed in. |

Proposed by this plan, to be confirmed with it:

| # | Proposal | Why |
|---|----------|-----|
| P1 | The first virtual terminal belongs to the screen: the splash, then the kiosk. Login prompts are on terminals 2 to 6. | One rule with and without a kiosk app, and no prompt that draws over the logo. |
| P2 | D4 goes through the image: the app puts a PNG into one folder, and the image checks it and installs it for the next boot. The app never writes to the IRONFLOCKOS partition. | The splash is drawn before Docker runs, from a partition that also holds `grubenv`. A full or damaged partition must not be an app's doing. |
| P3 | GRUB shows no picture and hides its menu. | Its two seconds are not worth GRUB's image decoders in the boot path. |
| P4 | The kernel's `quiet` comes with the splash, also on the serial console. `boot=text` in `display.conf` turns both off for a device; the installer stick and the QEMU tests stay on text. | The kernel has one log level for all consoles. The journal keeps every line. |
| P5 | The EFI targets first (`amd64-efi`, `arm64-efi`). The Raspberry Pi and Jetson follow in work packages of their own. | Their boot files and graphics drivers differ. |

Open, Marko's to decide:

| # | Question | Recommendation |
|---|----------|----------------|
| O1 | What does a person log in with at the console? Today no account has a password: `ironflock enroll` creates the device's user with a locked password and a key for SSH. A login prompt alone lets nobody in. | A console password as a device setting, off until someone sets it: its hash in `/data/ironflockos/console-login.conf`, applied to the device's user on every boot of a slot. SSH stays key-only. No default password, and no shell without a login. |

## The contract between the image and a screen app

A screen app is the kiosk app or a builder's own GUI app. It runs with the privileged
access its project granted.

The image guarantees:

- After the boot the splash stays on the screen. Nothing of the image holds the graphics
  device, and no login prompt runs on the first virtual terminal.
- The app may take `/dev/dri`, `/dev/input`, `/run/udev` (read-only) and the first
  virtual terminal.
- A PNG at `/data/ironflockos/screen/splash.png` becomes the splash of the next boot and
  of every boot after it, across updates. Removing the file brings IronFlock's logo
  back. A factory reset removes it.
- The image takes a PNG of at most 4 MiB and 3840x2160 pixels with the chunks `IHDR`,
  `PLTE`, `tRNS`, `IDAT` and `IEND`, and shows it centred on black. It refuses anything
  else, says so in the journal, and keeps the splash it had.

The app guarantees:

- It leaves the switch to the other virtual terminals working (Ctrl+Alt+F1 to F6), and
  draws again when the first one comes back.
- It writes `splash.png` only as a PNG it has decoded and encoded itself, in one
  rename, and writes nothing else outside its own data.
- It needs nothing else from the image. A need that turns up is a change to this plan.

## Work packages

### WP-8.1 The splash by default on the EFI targets (3 days)

- Scope: Plymouth in `profiles/base/packages` and in the initramfs; a theme
  `ironflockos` with the logo of `docs/assets` on black and a spinner; `quiet splash
  plymouth.ignore-serial-consoles vt.global_cursor_default=0` on the kernel command line
  of `grub.cfg` (Plymouth draws nothing while a serial console is named, unless told to
  ignore it); GRUB's menu hidden; no `getty@tty1` while the splash is on; Plymouth quits
  with the splash kept; the splash at shutdown; `/etc/ironflockos/display.conf` (on
  `/data`) with `boot=splash|text`, carried in `grubenv` so it holds on both slots; the
  installer variant and the QEMU tests on text. The QEMU harness gets a display device
  and reads the screen through QMP.
- Deliverables: the above; `docs/build.md`, "The screen"; the sizes of the initramfs and
  the slot before and after.
- Acceptance: in QEMU the screen shows the logo in the initramfs, at the end of the
  boot and 30 seconds later, and no text at any of the three; with `boot=text` the
  screen and the serial console are as in 0.16.0; a device installed with 0.16.0 and
  updated boots as before, on text, as its `grub.cfg` is the old one (Known limits); the
  slot stays below the fill warning.

### WP-8.2 The usual keys (2 days, after O1)

- Scope: Esc during the boot shows the boot messages; Ctrl+Alt+F2 to F6 give a login
  prompt and Ctrl+Alt+F1 leads back; Esc in GRUB's two seconds shows the menu, with an
  entry "Firmware setup" (`fwsetup`, which also serves the `-rt` images, whose kernel
  turns the EFI runtime services off); the console login as O1 is decided.
- Acceptance: in QEMU, with keys sent through QMP: the menu and its firmware entry, the
  messages, the prompt on the second terminal and the way back; a login as O1 says; the
  firmware's own setup key on the first machine (WP-8.6).

### WP-8.3 What the image has to say appears on the splash (1.5 days)

- Scope: the lines that today go to the console for a person at the device (no
  `.flock` found, `/data` missing, the apps' data not kept, a network profile refused,
  the factory reset, NVIDIA with Secure Boot on) also go to Plymouth as a message; the
  theme shows one message below the logo; Plymouth quits after `ironflockos-enroll`, so
  the last message stays on the kept splash.
- Acceptance: in QEMU a device without a `.flock` shows the logo and the sentence that
  it is not enrolled; with `boot=text` the console lines are unchanged.

### WP-8.4 The device's own splash picture (2.5 days)

- Scope: `ironflockos-splash` with a path unit on `/data/ironflockos/screen`: it checks
  `splash.png` as the contract says, packs it as the theme's logo into a cpio archive and
  renames that into place as `splash.cpio` next to `grubenv`; `grub.cfg` loads the
  archive after the slot's `initrd.img` when the file is there, so the picture is in
  place before Plymouth starts and no initramfs is built on a device; the same picture
  for the shutdown splash; removal of the file; the factory reset (ADR-0015) removes the
  archive with the old owner's data.
- Acceptance: in QEMU a test picture is on the screen at the next boot and after an
  update; a file that is no PNG, one that is too large and one with other chunks are
  refused and the earlier splash stays; an archive of random bytes on the partition
  does not stop the boot, which then shows IronFlock's logo; after a factory reset the
  logo is IronFlock's.

### WP-8.5 The kiosk app (own repository, estimate from its own plan)

- Scope: an IronFlock app with a full-screen browser in a container. It shows the UI of
  the app it is pointed at and nothing of its own beyond a waiting page (D5); it opens
  IronFlock Studio on a key and leads back (D6); it takes a splash picture and hands it
  to the image (D4); it keeps to the contract above.
- Acceptance: on an IronFlockOS device in QEMU with a graphics device: the logo, then
  the configured UI without a text frame in between; the Studio key and the way back;
  the terminal switch; a new splash picture at the next boot; the UI again after the
  browser was killed; all of it without a route to the platform.

### WP-8.6 Acceptance on the first machine (1 day, after WP-8.1 to WP-8.5)

- Scope: on the machine of ADR-0020, once it runs IronFlockOS: the time from power-on
  to the logo and to the UI (today about 35 seconds to the graphical session), touch,
  the picture on Intel graphics, the keys with a keyboard plugged in, the firmware's
  setup key, a changed splash picture, the screen across an OS update.
- Acceptance: the figures and results in `docs/targets/amd64-efi.md`.

## Status board

| WP | Title | Repo | Days | Depends on | Status |
|----|-------|------|------|------------|--------|
| 8.1 | The splash by default on the EFI targets | ironflockos | 3 | | open |
| 8.2 | The usual keys | ironflockos | 2 | 8.1, O1 | blocked (O1) |
| 8.3 | Messages on the splash | ironflockos | 1.5 | 8.1 | open |
| 8.4 | The device's own splash picture | ironflockos | 2.5 | 8.1 | open |
| 8.5 | The kiosk app | its own | own plan | the contract | open |
| 8.6 | Acceptance on the first machine | ironflockos, hardware | 1 | 8.1 to 8.5 | open |

WP-8.5 needs only the contract, so it starts at once and is tested against the image as
WP-8.1 and WP-8.4 arrive.

## What changes for every device

- Every newly installed device with a screen shows the logo where it showed boot text
  and a login prompt. The prompt moves to the second virtual terminal.
- The serial console is quieter by default (P4). Virtual devices and the tests that read
  it keep text through `display.conf` or the kernel command line.
- The image and its initramfs grow by Plymouth and the kernel's graphics drivers.
  WP-8.1 records by how much.
- The master plan's non-goal stays: no display server and no GUI toolkit in the image.

## Known limits

- `grub.cfg` is on the IRONFLOCKOS partition, which an update does not write. The kernel
  parameters of the splash, the hidden menu, the firmware entry and the device's own
  picture therefore come with a new installation. A device installed earlier keeps the
  text boot after an update. No device is in the field yet (`docs/build.md`); changing
  `grub.cfg` on installed devices would be a work package of its own.
- Without a kiosk app, the first virtual terminal does not get the logo back after a
  visit to another terminal: nothing is left that draws it. A screen app draws again.
- The first boot of a device shows IronFlock's logo. Its own picture comes with the
  boot after the kiosk app has handed it over.
- Whoever stands at the device with a keyboard reaches GRUB's menu and a login prompt,
  as on any PC. That is today's state too; Secure Boot here is no tamper protection
  (ADR-0011).

## Not in this plan

- The splash on the Raspberry Pi and on Jetson (P5).
- A setting in Studio for the splash picture or the kiosk's target; both are settings of
  the kiosk app at first.
- A display server in the image, and a GRUB that shows a picture.
