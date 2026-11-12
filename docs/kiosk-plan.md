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
| GRUB, up to 2 s | the splash's background colour and picture (WP-8.7; before it, black) | Esc: the boot menu, with the slots and "Firmware setup" |
| Kernel and boot | the splash: IronFlock's logo, or the picture the device was given, on its background colour, with its animation | Esc: the boot messages, and back to the splash |
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
| D7 | The start is polished from the firmware's picture to the UI: no text, no black in between, and nothing that appears, goes and comes back. The background colour can be set, and the splash can have a small animation. |
| D8 | O1: a console password per device, set in Studio later. The device-agent writes its hash to `/data/ironflockos/console-password` (root, 0600, one line, yescrypt `$y$` or SHA-512 `$6$`); the image makes it the password of the enrolled user, with its sudo rule, and of no other account. No file: the password stays locked. Root stays locked, SSH key-only. |
| D9 | GRUB's editor stays open in this release; that a keyboard at the boot menu, or a USB stick with Secure Boot off, gives root is documented. A GRUB password, a firmware password and disk encryption are later hardening. |

Proposed by this plan, to be confirmed with it:

| # | Proposal | Why |
|---|----------|-----|
| P1 | The first virtual terminal belongs to the screen: the splash, then the kiosk. Login prompts are on terminals 2 to 6. | One rule with and without a kiosk app, and no prompt that draws over the logo. |
| P2 | D4 goes through the image: the app puts a PNG into one folder, and the image checks it and installs it for the next boot. The app never writes to the IRONFLOCKOS partition. | The splash is drawn before Docker runs, from a partition that also holds `grubenv`. A full or damaged partition must not be an app's doing. |
| P3 | GRUB hides its menu and, with WP-8.7, shows the splash's background colour and picture itself. Until WP-8.7 it shows nothing, and the default background is black. | Debian's kernel clears the screen when its console takes it, one to two seconds before Plymouth draws: a picture from GRUB alone would appear, go and come back. On black nothing of that is seen. WP-8.7 keeps the console off the screen, and only then is GRUB's picture a gain. Debian's signed GRUB has the PNG decoder and the graphics terminal built in. |
| P6 | Animations are built into the theme and chosen by name; a device brings a picture and a colour, not frames. The first two: `none` and `fade` (the picture fades in and stays), `fade` being the default. | One picture and one colour can be checked; a set of frames cannot, and it would have to fit the partition. An animation that ends in a still picture lets the screen app take over without a visible step. |
| P4 | The kernel's `quiet` comes with the splash, also on the serial console. `boot=text` in `display.conf` turns both off for a device; the installer stick and the QEMU tests stay on text. The level is not lowered further (`loglevel=3`): errors stay on the serial console, and the kept splash is safe from them because its terminal is in graphics mode, which WP-8.1 tests. | The kernel has one log level for all consoles. The journal keeps every line. |
| P5 | The EFI targets first (`amd64-efi`, `arm64-efi`). The Raspberry Pi and Jetson follow in work packages of their own. | Their boot files and graphics drivers differ. |

Decided since:

| # | Question | Answer |
|---|----------|--------|
| O1 | What does a person log in with at the console? Today no account has a password: `ironflock enroll` creates the device's user with a locked password and a key for SSH. A login prompt alone lets nobody in. | D8 (Marko, 2026-11-12): a console password per device, applied to the enrolled user; the file is `/data/ironflockos/console-password`. |

## The contract between the image and a screen app

A screen app is the kiosk app or a builder's own GUI app. It runs with the privileged
access its project granted.

The image guarantees:

- After the boot the splash stays on the screen. Nothing of the image holds the graphics
  device. The first virtual terminal is the one in front, in graphics mode, and nothing
  runs on it: no login prompt, and no kernel or boot message is drawn over the splash.
- The app may take `/dev/dri`, `/dev/input`, `/run/udev` (read-only) and the first
  virtual terminal.
- udev's database in `/run/udev` names every input device as what it is (the
  `ID_INPUT*` properties): the image keeps systemd's `60-input-id.rules` and
  `60-evdev.rules` with the hardware database. An input library in a container ignores
  a device without them.
- A process that is not root can make a user namespace, as on Debian: a browser's
  sandbox needs it. AppArmor in the image does not take that away.
- The folder `/data/ironflockos/screen` is there at every boot before Docker starts, and
  belongs to root. The image looks at `splash.png` in it and at no other name.
- A PNG at `/data/ironflockos/screen/splash.png` becomes the splash of the next boot and
  of every boot after it, across updates. Removing the file brings IronFlock's logo
  back. A factory reset removes it.
- The image takes a PNG of at most 4 MiB and 3840x2160 pixels with the chunks `IHDR`,
  `PLTE`, `tRNS`, `IDAT` and `IEND`. It refuses anything else, says so in the journal,
  and keeps the splash it had.
- `/data/ironflockos/screen/splash.conf`, next to the picture or alone, sets
  `background=#RRGGBB` (default `#000000`) and `animation=none|fade` (default `fade`).
  It is taken and checked as the picture is; an unknown key or value is refused and the
  splash stays as it was.
- The picture is drawn centred, at its own size in pixels, on the background colour, and
  nothing else is on the screen but a message below it when the image has one to give
  (WP-8.3). It is never made larger; one larger than the screen is made smaller to fit.
  When the boot ends, the animation has ended in the still picture.
  The default picture is one file, `docs/assets/ironflock-splash.png` (WP-8.1 adds it:
  `ironflock-white.svg` at 320x320 pixels, transparent around the logo). An app that
  wants the hand-over from the splash to be invisible draws that file by the same rule.
- Docker is 20.10 or later, and no rule of the image stands between a container and a
  port that another app publishes on the device. Docker's own rules between its networks
  apply; a firewall setting of the device-agent (ADR-0020) has to keep that way open.

The app guarantees:

- It leaves the switch to the other virtual terminals working (Ctrl+Alt+F1 to F6), and
  draws again when the first one comes back.
- It writes `splash.png` only as a PNG it has decoded and encoded itself: under another
  name in the same folder first, then synced and renamed onto `splash.png`. It writes
  nothing else outside its own data.
- It needs nothing else from the image. A need that turns up is a change to this plan.

## Work packages

### WP-8.1 The splash by default on the EFI targets (3 days)

- Scope: Plymouth in `profiles/base/packages` and in the initramfs; a theme
  `ironflockos` that draws the default picture by the contract's rule, with the
  animations `none` and `fade` and no spinner, so that an app's first frame can look the
  same as the splash's last; `quiet splash
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
  boot and 30 seconds later, and no text at any of the three; after the boot the first
  virtual terminal is in front, an error written to the kernel's log leaves the screen
  as it is, every input device has its `ID_INPUT*` properties, and a user that is not
  root makes a user namespace; with `boot=text` the
  screen and the serial console are as in 0.16.0; a device installed with 0.16.0 and
  updated boots as before, on text, as its `grub.cfg` is the old one (Known limits); the
  slot stays below the fill warning.
- As built (branch `splash`, `docs/build.md` "The screen"): the setting is `boot=` in
  `/etc/ironflockos/display.conf`, written into `grubenv` as `IRONFLOCKOS_BOOT=text` by
  `ironflockos-display`; `ironflockos.boot=text` in `IRONFLOCKOS_CMDLINE` is the tests'
  way. One parameter more than this plan named: `plymouth.force-frame-buffer-on-boot`.
  Plymouth draws into the kernel's framebuffer device instead of taking the graphics
  device: the kernel removes a framebuffer when the program that made it ends, so a
  splash drawn through the graphics device would turn black when Plymouth quits, and
  the framebuffer device keeps it. The packages are the EFI targets' (`plymouth`,
  `plymouth-label`, `fontconfig`), not `profiles/base`'s, which the Raspberry Pi and
  Jetson share (P5). The sizes of the initramfs and the slot are in the CI log of the
  first build (`initramfs:` in the build log, `sizes:` in the QEMU test's).

### WP-8.2 The usual keys (2 days, after O1)

- Scope: Esc during the boot shows the boot messages; Ctrl+Alt+F2 to F6 give a login
  prompt and Ctrl+Alt+F1 leads back; Esc in GRUB's two seconds shows the menu, with an
  entry "Firmware setup" (`fwsetup`, which also serves the `-rt` images, whose kernel
  turns the EFI runtime services off); the console login as O1 is decided.
- Acceptance: in QEMU, with keys sent through QMP: the menu and its firmware entry, the
  messages, the prompt on the second terminal and the way back; a login as O1 says; the
  firmware's own setup key on the first machine (WP-8.6).
- As built (branch `splash`): the menu has "Start with messages" too (one boot on
  text, the setting untouched). The enrolled user is the one in `ironflock`'s record
  `/opt/ironflock/device-init/installed.json`: `ironflock status --json` does not name
  it. The QEMU test sends Esc to a Plymouth started by hand on the running system (the
  boot's own Plymouth is gone before the test's shell can time a key), switches to tty2
  and back, and logs in there with a console password. The menu and its "Firmware
  setup" are checked in the rendered `grub.cfg` only: a key sent during GRUB's two
  seconds would have to miss the firmware's own Esc, which the test cannot tell apart.
  They are WP-8.6's on the machine.

### WP-8.3 What the image has to say appears on the splash (1.5 days)

- Scope: the lines that today go to the console for a person at the device (no
  `.flock` found, `/data` missing, the apps' data not kept, a network profile refused,
  the factory reset, NVIDIA with Secure Boot on) also go to Plymouth as a message; the
  theme shows one message below the logo; Plymouth quits after `ironflockos-enroll`, so
  the last message stays on the kept splash.
- Acceptance: in QEMU a device without a `.flock` shows the logo and the sentence that
  it is not enrolled; with `boot=text` the console lines are unchanged.

### WP-8.4 The device's own splash picture (2.5 days)

- Scope: `ironflockos-data-layout` makes `/data/ironflockos/screen` at every boot,
  before Docker; `ironflockos-splash` with a path unit on `splash.png` in it, which
  other names in the folder do not start: it checks `splash.png` and `splash.conf` as
  the contract says, packs the picture and the theme's settings into a cpio archive and
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
- As built (branch `splash`): `ironflockos-splash.path` watches `splash.png` and
  `splash.conf`; while one is missing systemd watches the folder instead, and a run
  that another name started reads the two names and changes nothing. A refusal makes
  the unit fail, as a refused network profile does. The archive holds the picture and
  the theme's script with the settings in its first lines; the shutdown splash gets
  the same files through a copy of the theme in `/run`, mounted over the theme's
  folder. The QEMU test reads the picture on the screen at the boot after it was
  given; after the update it checks the archive, not the screen (one boot with the
  splash fewer).

### WP-8.7 No black between the firmware's picture and the splash (3 days, and the machine)

- Scope: GRUB in graphics mode at the panel's resolution, kept for the kernel
  (`gfxpayload=keep`); GRUB fills the screen with the splash's background colour and
  draws its picture, both written next to `grubenv` by `ironflockos-splash` (the
  default ones by the build); the kernel's console stays off the screen until Plymouth
  has drawn the same picture, and the virtual terminals 2 to 6 get their text back
  after the boot, so the keys of WP-8.2 keep working; with `boot=text` all of it is off.
- Risk: whether the picture survives the moment the graphics driver takes the screen
  from the firmware's framebuffer depends on the driver. Intel's keeps it; QEMU's
  graphics devices do not show what Intel's does. The last word is the machine's.
- Acceptance: in QEMU, GRUB's screen and Plymouth's first frame are the same picture,
  and the keys of WP-8.2 work; on the first machine, a recording of the screen from
  power-on to the UI shows the firmware's picture, then the splash without a black
  frame, a text line or a picture that goes and comes back.

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
| 8.1 | The splash by default on the EFI targets | ironflockos | 3 | | built on `splash`, proof in CI |
| 8.2 | The usual keys | ironflockos | 2 | 8.1, O1 | built on `splash`, proof in CI |
| 8.3 | Messages on the splash | ironflockos | 1.5 | 8.1 | open |
| 8.4 | The device's own splash picture | ironflockos | 2.5 | 8.1 | built on `splash`, proof in CI |
| 8.5 | The kiosk app | its own | own plan | the contract | open |
| 8.7 | No black between the firmware's picture and the splash | ironflockos, hardware | 3 | 8.1, 8.2, 8.4 | open |
| 8.6 | Acceptance on the first machine | ironflockos, hardware | 1 | 8.1 to 8.5, 8.7 | open |

WP-8.5 needs only the contract, so it starts at once and is tested against the image as
WP-8.1 and WP-8.4 arrive.

Marko decided on 2026-11-12 that WP-8.1, WP-8.2, WP-8.3, WP-8.4 and WP-8.7 go into the
next IronFlockOS release.

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
- The first picture a person sees is the firmware's, for as long as the firmware takes
  (nine seconds on the first machine). IronFlockOS cannot change it; the PC's maker sets
  it, to the same logo or to black.
- Until WP-8.7 the screen is black between the firmware's picture and the splash, for
  GRUB's two seconds and the kernel's first one or two. A background colour other than
  black shows that gap; black hides it.
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
- A display server in the image.
- Animations a device brings as frames of its own (P6).
