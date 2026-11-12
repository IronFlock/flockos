#!/usr/bin/env python3
"""Boot a built IronFlockOS image in QEMU and test it (docs/testing.md).

  run.py --target amd64-efi --variant base [--out out] [--work DIR]
         [--docker-image-tar FILE] [--secure-boot] [--keep]

The image under test is the artefact from `just build`, unchanged except for
one value in the IRONFLOCKOS partition's grubenv of the test copy:
IRONFLOCKOS_CMDLINE asks systemd for a root debug shell, which this script drives:
on the second serial port on amd64 (ttyS1), on a virtio console on arm64
(hvc0; QEMU's virt machine has one UART). grubenv lives on the IRONFLOCKOS
partition, so the shell is there on both slots, before and after an update.

With --secure-boot the firmware has Microsoft's keys enrolled and Secure
Boot on, as on a PC from the factory (ADR-0011): the image's shim, GRUB and
kernel have to pass its checks, and the kernel runs locked down.

Sequence (WP-1.3, WP-1.4, WP-1.7): first boot (boot chain and Secure Boot
state, partitions grown, /data layout, identity, SSH policy, RAUC slot A good,
Docker, fwupd, enrolled through `ironflock enroll`); ironflock in the image
(WP-5.1 of the CLI's plan: /usr/bin/ironflock, `ironflock status`, its refusals, a .flock that
is not accepted); `ironflock os` on the device as written (WP-5.2, WP-5.3:
`os rollback` refuses, `os update` refuses a catalog of the test's own, which
IronFlock did not sign); enrolled, the device changes hands with `sudo ironflock
agent configure -c` run by its owner over SSH, and back; for nvidia
the driver, its modules and the container runtime without a GPU; reboot
(state persists, a proxy.conf and a static network profile on the IRONFLOCKOS
partition are taken); the splash (docs/build.md, "The screen"; every other
boot is on text, ironflockos.boot=text, as the checks read the serial
console): Plymouth from the initramfs, the screen read through QMP's
screendump through the boot and after, a damaged splash.cpio, then the
device's own picture with its refusals; update into slot B with the bundle of the same build
(while RAUC installs, `os update` and `os rollback` refuse; installed, `os
rollback` refuses the update that waits for its restart);
under KVM, `ironflock os rollback` back to slot A and forward to slot B;
factory reset (ADR-0015): the device in slot B, with a running container,
resets, keeps its network settings and RAUC's state, enrolls with a new
.flock, and slot A is cleared too;
fallback: an update into slot A that is never marked good falls back to B,
and `os rollback` refuses that slot;
a kernel crash without a connection: the device restarts by itself on a slot
that has proven itself, and the crash is on record on /data.

What ironflock reads and prints along the way (RAUC's status, grubenv, the
`ironflock os` commands as text and JSON) is kept in <work>/captured/, for
the CLI's fixtures.

Needs: qemu-system-<arch>, OVMF/AAVMF firmware (for --secure-boot the
builds with Microsoft's keys: Debian's and Ubuntu's ovmf, qemu-efi-aarch64),
mtools (mcopy), OpenSSL 3 (Ed25519 keys and signatures). Standard library
only; run with `python3 -I`.
"""

import argparse
import base64
import gzip
import hashlib
import http.server
import json
import os
import re
import select
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The guest device of the debug shell per architecture (see the docstring).
# systemd starts a getty on a virtio console by itself; on the test's hvc0 it
# would take the terminal from the shell.
DEBUG_SHELL = {"amd64": "ttyS1", "arm64": "hvc0"}
HOST_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(os.uname().machine)


def debug_cmdline(arch, splash=False):
    """The test's kernel parameters. The tests read the boot on the serial
    console, so they boot on text (ironflockos.boot=text, docs/build.md "The
    screen"); the splash step boots with the splash (splash=True)."""
    tty = DEBUG_SHELL[arch]
    extra = f" systemd.mask=serial-getty@{tty}.service" if tty.startswith("hvc") else ""
    text = "" if splash else " ironflockos.boot=text"
    return f"systemd.debug_shell={tty}{extra}{text}"


def pick_accel(arch):
    """KVM on Linux, Hypervisor.framework on an arm64 Mac, else emulation."""
    if arch == HOST_ARCH and os.access("/dev/kvm", os.R_OK | os.W_OK):
        return "kvm"
    if arch == HOST_ARCH == "arm64" and sys.platform == "darwin":
        return "hvf"
    return "tcg"


FIRMWARE = {
    "amd64": [
        ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
        ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
        ("/usr/share/ovmf/OVMF.fd", None),
        ("/opt/homebrew/share/qemu/edk2-x86_64-code.fd", "/opt/homebrew/share/qemu/edk2-i386-vars.fd"),
    ],
    "arm64": [
        ("/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"),
        ("/opt/homebrew/share/qemu/edk2-aarch64-code.fd", "/opt/homebrew/share/qemu/edk2-arm-vars.fd"),
    ],
}
# Firmware with Secure Boot on and Microsoft's keys enrolled (the variable
# store's "ms" build), as PCs ship. On amd64 the code is the SMM build, which
# keeps the variables from the guest and needs q35 with SMM.
SECURE_BOOT_FIRMWARE = {
    "amd64": [("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd", "/usr/share/OVMF/OVMF_VARS_4M.ms.fd")],
    "arm64": [("/usr/share/AAVMF/AAVMF_CODE.ms.fd", "/usr/share/AAVMF/AAVMF_VARS.ms.fd")],
}


class TestFailure(Exception):
    pass


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_conf(path):
    conf = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            conf[key] = value.strip().strip('"').strip("'")
    return conf


# --- grubenv -----------------------------------------------------------------

GRUBENV_HEADER = "# GRUB Environment Block\n"


def grubenv_parse(data):
    text = data.decode("utf-8", "replace")
    if not text.startswith(GRUBENV_HEADER):
        raise TestFailure("grubenv has no GRUB header")
    env = {}
    for line in text[len(GRUBENV_HEADER):].split("\n"):
        if line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key] = value
    return env


def grubenv_render(env):
    body = GRUBENV_HEADER + "".join(f"{k}={v}\n" for k, v in env.items())
    if len(body) > 1024:
        raise TestFailure("grubenv would exceed 1024 bytes")
    return (body + "#" * (1024 - len(body))).encode()


def esp_offset(disk):
    """Byte offset of partition 1 (GPT), read from the partition table."""
    with open(disk, "rb") as fh:
        fh.seek(512)
        header = fh.read(92)
        if header[:8] != b"EFI PART":
            raise TestFailure("the disk has no GPT")
        entries_lba = int.from_bytes(header[72:80], "little")
        fh.seek(entries_lba * 512)
        entry = fh.read(128)
        first_lba = int.from_bytes(entry[32:40], "little")
        return first_lba * 512


# --- the screen ----------------------------------------------------------------
# The VM has a graphics device; QEMU's QMP command screendump reads what it
# shows (with -display none too). A frame is compared with the splash it
# should show: the picture centred at its own size on the background colour
# (docs/kiosk-plan.md, the contract), faded in by some amount.


def png_chunk(kind, data):
    return len(data).to_bytes(4, "big") + kind + data + zlib.crc32(kind + data).to_bytes(4, "big")


def png_encode(width, height, rgb, chunks=()):
    """An 8-bit RGB PNG of rgb (width * height * 3 bytes); chunks: extra
    (type, data) pairs before the image data."""
    rows = b"".join(b"\0" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", width.to_bytes(4, "big") + height.to_bytes(4, "big") + b"\x08\x02\0\0\0")
    for kind, data in chunks:
        out += png_chunk(kind, data)
    return out + png_chunk(b"IDAT", zlib.compress(rows, 9)) + png_chunk(b"IEND", b"")


def png_decode(data):
    """(width, height, RGBA bytes) of an 8-bit, not interlaced RGB or RGBA
    PNG: the default picture and the test's."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise TestFailure("not a PNG")
    pos, idat, width = 8, b"", 0
    while pos < len(data):
        n = int.from_bytes(data[pos:pos + 4], "big")
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            width, height = int.from_bytes(body[0:4], "big"), int.from_bytes(body[4:8], "big")
            depth, ctype, interlace = body[8], body[9], body[12]
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise TestFailure(f"png_decode: colour type {ctype}, {depth} bits, interlace {interlace}")
        elif kind == b"IDAT":
            idat += body
    bpp = 3 if ctype == 2 else 4
    raw, stride = zlib.decompress(idat), width * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(height):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        if bpp == 4:
            out += line
        else:
            for i in range(0, stride, 3):
                out += line[i:i + 3] + b"\xff"
    return width, height, bytes(out)


class Splash:
    """What the screen should show: picture (PNG bytes) centred on bg (r, g,
    b). match(frame) says whether a frame is that splash, faded in by alpha
    (0: the background alone, 1: the whole picture), with nothing else on it."""

    def __init__(self, picture, bg):
        self.w, self.h, rgba = png_decode(picture)
        self.bg = bg
        # The pixels of the picture that differ from the background, as their
        # difference; the others must be the background.
        self.ink, self.clear = [], []
        for i in range(self.w * self.h):
            r, g, b, a = rgba[4 * i:4 * i + 4]
            d = tuple((c - k) * a / 255 for c, k in zip((r, g, b), bg))
            if max(abs(x) for x in d) > 24:
                self.ink.append((i % self.w, i // self.w, d))
            elif a == 0:
                self.clear.append((i % self.w, i // self.w))
        self.clear = self.clear[::7]

    def match(self, frame):
        """(True, alpha, why) for the splash, (False, alpha or None, why) for
        anything else."""
        width, height, px = frame
        if width < self.w or height < self.h:
            return False, None, f"a screen of {width}x{height}"
        bg = px[0:3]
        if max(abs(a - b) for a, b in zip(bg, self.bg)) > 1:
            return False, None, f"the corner is #{bg.hex()}, not the background"
        x0, y0 = (width - self.w) // 2, (height - self.h) // 2
        row = bg * width
        # Outside the picture (and a pixel around it) only the background.
        for y in range(height):
            line = px[y * width * 3:(y + 1) * width * 3]
            if y < y0 - 1 or y > y0 + self.h:
                if line != row:
                    return False, None, f"something besides the background in row {y}"
            elif line[:(x0 - 1) * 3] != row[:(x0 - 1) * 3] or line[(x0 + self.w + 1) * 3:] != row[(x0 + self.w + 1) * 3:]:
                return False, None, f"something besides the background beside the picture, row {y}"
        # Where the contract puts it; a pixel off is looked for only when it
        # is not there.
        best = self._fit(px, width, x0, y0, bg)
        if not self._good(best):
            for dx, dy in ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)):
                fit = self._fit(px, width, x0 + dx, y0 + dy, bg)
                if fit[1] < best[1]:
                    best = fit
        alpha, err, off, clear_off = best
        if not self._good(best):
            return False, alpha, f"not the picture (alpha {alpha:.2f}, error {err:.1f}, {off:.1%} off, {clear_off:.1%} not clear)"
        return True, alpha, f"the splash, alpha {alpha:.2f}"

    def match_message(self, frame):
        """(True, why) when the frame is the whole splash with a line of text
        in the band below the picture (WP-8.3), and nothing else."""
        width, height, px = frame
        top = (height - self.h) // 2 + self.h + 8
        bottom = min(height, top + 120)
        bg_row = bytes(self.bg) * width
        band = px[top * width * 3:bottom * width * 3]
        if band == bg_row * (bottom - top):
            return False, "no text below the picture"
        cleared = px[:top * width * 3] + bg_row * (bottom - top) + px[bottom * width * 3:]
        ok, alpha, why = self.match((width, height, cleared))
        if not ok or alpha < 0.97:
            return False, f"besides the text below the picture: {why}"
        return True, "the splash with a message below the picture"

    @staticmethod
    def _good(fit):
        _, err, off, clear_off = fit
        return err <= 6 and off <= 0.01 and clear_off <= 0.01

    def _fit(self, px, width, x0, y0, bg):
        obs = []
        for x, y, d in self.ink:
            p = 3 * ((y0 + y) * width + x0 + x)
            obs.append((tuple(px[p + c] - bg[c] for c in range(3)), d))
        num = sum(o[c] * d[c] for o, d in obs for c in range(3))
        den = sum(d[c] * d[c] for _, d in obs for c in range(3)) or 1
        alpha = max(0.0, min(1.0, num / den))
        errs = [max(abs(o[c] - alpha * d[c]) for c in range(3)) for o, d in obs]
        err = sum(errs) / max(1, len(errs))
        off = sum(1 for e in errs if e > 40) / max(1, len(errs))
        clear_off = sum(1 for x, y in self.clear
                        if max(abs(px[3 * ((y0 + y) * width + x0 + x) + c] - bg[c]) for c in range(3)) > 8)
        return alpha, err, off, clear_off / max(1, len(self.clear))


class QMP:
    """QEMU's machine protocol on a unix socket: screendump."""

    def __init__(self, path):
        deadline = time.time() + 30
        while True:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                self.sock.connect(path)
                break
            except (ConnectionRefusedError, FileNotFoundError):
                self.sock.close()
                if time.time() > deadline:
                    raise TestFailure("QEMU's QMP socket does not answer") from None
                time.sleep(0.2)
        self.sock.settimeout(60)
        self.file = self.sock.makefile("rwb")
        self.lock = threading.Lock()
        self._read()
        self.command("qmp_capabilities")

    def _read(self):
        line = self.file.readline()
        if not line:
            raise TestFailure("QEMU closed the QMP socket")
        return json.loads(line)

    def command(self, name, **arguments):
        with self.lock:
            self.file.write(json.dumps({"execute": name, "arguments": arguments}).encode() + b"\r\n")
            self.file.flush()
            while True:
                msg = self._read()
                if "return" in msg:
                    return msg["return"]
                if "error" in msg:
                    raise TestFailure(f"QMP {name}: {msg['error'].get('desc')}")

    def screen(self, path):
        """(width, height, RGB bytes) of what the screen shows, by screendump
        (PPM), or None when there is no picture yet."""
        try:
            self.command("screendump", filename=path)
        except TestFailure:
            return None
        with open(path, "rb") as fh:
            data = fh.read()
        os.remove(path)
        # One whitespace byte after the maximum value, then the pixels, whose
        # first bytes may well be whitespace themselves (0x20 is a colour).
        m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+255\s", data)
        if not m:
            raise TestFailure("screendump wrote no PPM")
        width, height = int(m.group(1)), int(m.group(2))
        return width, height, data[m.end():m.end() + width * height * 3]

    def close(self):
        self.sock.close()


def save_screen(frame, path):
    """A frame as a PNG, for CI's artifact."""
    width, height, px = frame
    with open(path, "wb") as fh:
        fh.write(png_encode(width, height, px))


class ScreenWatch:
    """screendump about once a second in a thread, each frame matched against
    a splash: what the screen showed through a reboot."""

    # A frame's kind: the splash (with how far the picture has faded in), an
    # empty screen of another colour than the background (a graphics driver
    # taking the screen over), or anything else.
    SPLASH, BLANK, OTHER = "splash", "blank", "other"

    def __init__(self, qmp, splash, workdir, name):
        self.qmp, self.splash, self.workdir, self.name = qmp, splash, workdir, name
        self.frames = []
        self.saved = 0
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        tmp = os.path.join(self.workdir, f"screendump-{self.name}.ppm")
        last = None
        while not self.stop_flag.is_set():
            t = time.time()
            try:
                frame = self.qmp.screen(tmp)
            except (TestFailure, OSError, ValueError, IndexError):
                frame = None
            if frame is None:
                self.frames.append((t, None, None, "no picture"))
            else:
                ok, alpha, why = self.splash.match(frame)
                kind = self.SPLASH if ok else self.OTHER
                if not ok and frame[2] == frame[2][:3] * (frame[0] * frame[1]):
                    kind, why = self.BLANK, f"an empty screen #{frame[2][:3].hex()}"
                self.frames.append((t, kind, alpha, why))
                # Each new kind of picture is saved, for CI's artifact.
                key = (kind, round(alpha or 0, 1), why.split(" ")[:3] if kind == self.OTHER else None)
                if key != last and self.saved < 40:
                    self.saved += 1
                    save_screen(frame, os.path.join(self.workdir, f"screen-{self.name}-{len(self.frames):03d}-{kind}.png"))
                last = key
            self.stop_flag.wait(max(0.0, 1.0 - (time.time() - t)))

    def stop(self):
        self.stop_flag.set()
        self.thread.join(30)

    def timeline(self, t0):
        return "\n".join(f"  {t - t0:6.1f}s  {why}" for t, _, _, why in self.frames)

    def _after(self, frames, start, t0, t_shell):
        """The checks from frame start to the end: nothing but the splash and
        empty screens; from the shell's first answer (the root filesystem's
        system runs) only the splash, never fading back, whole at the end.
        Returns the frames before that answer without the whole picture after
        it first showed: empty screens and dips while a graphics driver takes
        the screen over, which QEMU's drivers show and the machine's need
        not."""
        for f in frames[start:]:
            if f[1] == self.OTHER:
                raise TestFailure(f"something besides the splash at {f[0] - t0:.1f}s, after it showed:\n"
                                  f"{self.timeline(t0)}")
            if f[0] >= t_shell and f[1] != self.SPLASH:
                raise TestFailure(f"no splash at {f[0] - t0:.1f}s, after the root filesystem's system answered "
                                  f"({t_shell - t0:.1f}s):\n{self.timeline(t0)}")
        top, gaps = 0.0, 0
        for t, kind, alpha, _ in frames[start:]:
            alpha = alpha if kind == self.SPLASH else 0.0
            if top >= 0.5 and alpha < top - 0.15:
                if t >= t_shell:
                    raise TestFailure(f"the picture faded back at {t - t0:.1f}s, after it showed:\n{self.timeline(t0)}")
                # A dip before the answer: the picture is to come back.
                gaps += 1
                continue
            top = max(top, alpha)
        if frames[-1][1] != self.SPLASH or frames[-1][2] < 0.97:
            raise TestFailure(f"the picture is not whole at the end:\n{self.timeline(t0)}")
        return gaps

    def check(self, t0, t_kernel, t_shell):
        """The picture shows after the kernel started; from the first frame
        after anything else before it (the system before the restart, the
        firmware's picture, which may stay until a graphics driver takes the
        screen) to the end, the splash and nothing else (and empty screens
        before the root filesystem's system answered); from that answer on,
        the splash only, never fading back once the picture showed (nothing
        that appears, goes and comes back), whole at the end. Returns the
        number of dips before the answer (see _after)."""
        frames = [f for f in self.frames if f[1] is not None]
        if not frames:
            raise TestFailure("no picture from the screen")
        shown = next((i for i, f in enumerate(frames) if f[0] >= t_kernel and f[1] == self.SPLASH and f[2] >= 0.5), None)
        if shown is None:
            raise TestFailure(f"the picture never showed after the kernel started:\n{self.timeline(t0)}")
        start = max((i for i in range(shown) if frames[i][1] == self.OTHER), default=-1) + 1
        if frames[start][0] > t_shell:
            raise TestFailure(f"something besides the splash on the screen after the root filesystem was "
                              f"there ({t_shell - t0:.1f}s):\n{self.timeline(t0)}")
        return self._after(frames, start, t0, t_shell)

    def check_grub(self, t0, t_kernel, t_shell):
        """WP-8.7: after the firmware's last picture, and before the kernel
        started, the whole splash is on the screen (GRUB drew it); from there
        to the end the checks of _after. Returns the dips it counted."""
        frames = [f for f in self.frames if f[1] is not None]
        firmware = max((i for i, f in enumerate(frames) if f[1] == self.OTHER and f[0] < t_kernel), default=-1)
        first = next((i for i in range(firmware + 1, len(frames))
                      if frames[i][1] == self.SPLASH and frames[i][2] >= 0.97 and frames[i][0] < t_kernel), None)
        if first is None:
            raise TestFailure(f"GRUB did not draw the splash before the kernel started ({t_kernel - t0:.1f}s):\n"
                              f"{self.timeline(t0)}")
        return self._after(frames, first, t0, t_shell)


TEST_OWNER = "ironflockostest"
TEST_FLOCK_NAME = "ironflockos-ci"
# The device the factory reset enrolls it as.
RESET_OWNER = "ironflockosreset"
RESET_FLOCK_NAME = "ironflockos-ci-reset"
# The device it becomes for a while with `ironflock agent configure -c`.
OTHER_OWNER = "ironflockosother"
OTHER_FLOCK_NAME = "ironflockos-ci-other"
# The static network profile the IRONFLOCKOS partition hands over (ADR-0016).
STATIC_PROFILE = "ironflockos-ci-static"


def test_picture():
    """The device's own splash picture of the test: 200x120, opaque, a white
    frame around two colours."""
    width, height = 200, 120
    px = bytearray()
    for y in range(height):
        for x in range(width):
            if x < 8 or y < 8 or x >= width - 8 or y >= height - 8:
                px += b"\xff\xff\xff"
            else:
                px += b"\xf0\x80\x10" if x < width // 2 else b"\x10\xc0\x40"
    return png_encode(width, height, bytes(px))


# KDGETMODE on the first virtual terminal: 0 text, 1 graphics. perl-base is
# in every Debian image.
KD_MODE = "perl -e 'open(my $t, \"<\", \"/dev/tty1\") or die $!; my $m = pack(\"L\", 0); ioctl($t, 0x4B3B, $m) or die $!; print unpack(\"L\", $m)'"


def test_flock(name, owner, device_key):
    """A .flock with a throwaway key: enough for ironflock enroll (SSH
    user, agent unit), useless to the platform."""
    key = subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519"], check=True,
                         capture_output=True, text=True).stdout
    return {"name": name, "swarm_owner_name": owner, "device_key": device_key,
            "secret": "not-a-real-secret", "wlanssid": "", "password": "",
            "authentication": {"key": key}}


def put_test_flock(disk, workdir):
    """The test .flock on the test copy's IRONFLOCKOS partition. Returns its file
    name."""
    flock = test_flock(TEST_FLOCK_NAME, TEST_OWNER, "4711")
    path = os.path.join(workdir, "ironflockos-ci.flock")
    with open(path, "w") as fh:
        json.dump(flock, fh)
    subprocess.run(["mcopy", "-n", "-o", "-i", f"{disk}@@{esp_offset(disk)}", path, "::/ironflockos-ci.flock"], check=True)
    log("test copy: ironflockos-ci.flock on the IRONFLOCKOS partition")
    return "ironflockos-ci.flock"


def set_test_cmdline(disk, workdir, cmdline):
    offset = esp_offset(disk)
    image = f"{disk}@@{offset}"
    env_file = os.path.join(workdir, "grubenv")
    subprocess.run(["mcopy", "-n", "-o", "-i", image, "::/EFI/BOOT/grubenv", env_file], check=True)
    with open(env_file, "rb") as fh:
        env = grubenv_parse(fh.read())
    env["IRONFLOCKOS_CMDLINE"] = cmdline
    with open(env_file, "wb") as fh:
        fh.write(grubenv_render(env))
    subprocess.run(["mcopy", "-n", "-o", "-i", image, env_file, "::/EFI/BOOT/grubenv"], check=True)
    log(f"test copy: grubenv IRONFLOCKOS_CMDLINE={cmdline!r}")


# --- the VM ------------------------------------------------------------------


class VM:
    def __init__(self, arch, disk, workdir, accel, stick=None, nvme=False, secure_boot=False):
        self.arch, self.disk, self.workdir, self.accel = arch, disk, workdir, accel
        self.secure_boot = secure_boot
        self.debug_cmdline = debug_cmdline(arch)
        # stick: an image attached as a USB stick (booted first); nvme: the
        # disk is an NVMe drive instead of virtio.
        self.stick, self.nvme = stick, nvme
        self.sock_path = os.path.join(workdir, "shell.sock")
        self.qmp_path = os.path.join(workdir, "qmp.sock")
        self.console = os.path.join(workdir, "console.log")
        self.proc = None
        self.sock = None
        self.qmp = None
        self.buf = b""
        self.transcript = open(os.path.join(workdir, "shell.log"), "ab")

    def firmware(self):
        table = SECURE_BOOT_FIRMWARE if self.secure_boot else FIRMWARE
        for code, vars_ in table[self.arch]:
            if os.path.exists(code) and (vars_ is None or os.path.exists(vars_)):
                return code, vars_
        kind = "Secure Boot UEFI firmware with Microsoft's keys" if self.secure_boot else "UEFI firmware"
        raise TestFailure(f"no {kind} for {self.arch} found (install ovmf / qemu-efi-aarch64)")

    def start(self, qemu, http_port):
        code, vars_template = self.firmware()
        vars_copy = os.path.join(self.workdir, "efivars.fd")
        if vars_template and not os.path.exists(vars_copy):
            shutil.copy(vars_template, vars_copy)
        cmd = [qemu, "-m", "2048", "-smp", "2", "-display", "none", "-no-user-config", "-nodefaults"]
        if self.arch == "amd64":
            cmd += ["-machine", "q35,smm=on" if self.secure_boot else "q35", "-device", "i6300esb"]
            if self.secure_boot:
                cmd += ["-global", "driver=cfi.pflash01,property=secure,value=on"]
        else:
            cmd += ["-machine", "virt"]
        # Emulated arm64: QEMU's own pointer-authentication algorithm is far
        # faster to emulate than the architected one.
        cpu = "host" if self.accel != "tcg" else ("max,pauth-impdef=on" if self.arch == "arm64" else "max")
        cmd += ["-accel", self.accel, "-cpu", cpu]
        cmd += ["-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}"]
        if vars_template:
            cmd += ["-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}"]
        if self.nvme:
            cmd += ["-drive", f"if=none,id=nvm,file={self.disk},format=raw,cache=unsafe",
                    "-device", "nvme,drive=nvm,serial=IRONFLOCKOSCI,bootindex=1"]
        else:
            cmd += ["-drive", f"file={self.disk},format=raw,if=virtio,cache=unsafe"]
        if self.stick:
            cmd += ["-device", "qemu-xhci", "-drive", f"if=none,id=stick,file={self.stick},format=raw,cache=unsafe",
                    "-device", "usb-storage,drive=stick,bootindex=0"]
        cmd += [
            # No option ROM: the UEFI firmware has its own virtio-net driver, and
            # the iPXE ROMs are only a recommendation of the QEMU packages.
            "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-serial", f"file:{self.console}",
            "-device", "virtio-rng-pci",
            # A screen and what a panel PC has for input (docs/build.md, "The
            # screen"): the firmware draws through it, the kernel takes it
            # over from the firmware (bochs on amd64, virtio-gpu on arm64),
            # and screendump reads it through QMP.
            "-device", "VGA" if self.arch == "amd64" else "virtio-gpu-pci",
            "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
        ]
        if self.arch == "amd64":
            cmd += ["-serial", f"unix:{self.sock_path},server=on,wait=off"]
        else:
            cmd += ["-device", "virtio-serial-pci",
                    "-chardev", f"socket,id=shell,path={self.sock_path},server=on,wait=off",
                    "-device", "virtconsole,chardev=shell"]
        log("qemu: " + " ".join(cmd))
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        deadline = time.time() + 30
        while not os.path.exists(self.sock_path):
            if self.proc.poll() is not None:
                raise TestFailure(f"qemu exited with {self.proc.returncode}")
            if time.time() > deadline:
                raise TestFailure("qemu made no serial socket")
            time.sleep(0.2)
        # The socket file exists from bind(); QEMU listens a moment later, or
        # has exited on a bad option.
        while True:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                self.sock.connect(self.sock_path)
                break
            except ConnectionRefusedError:
                self.sock.close()
                if self.proc.poll() is not None:
                    raise TestFailure(f"qemu exited with {self.proc.returncode}")
                if time.time() > deadline:
                    raise TestFailure("qemu does not accept on its serial socket")
                time.sleep(0.2)
        self.sock.setblocking(False)

    def screen_qmp(self):
        """QMP for the screen, connected at the first use."""
        if self.qmp is None:
            self.qmp = QMP(self.qmp_path)
        return self.qmp

    def wait_exit(self, timeout):
        """Wait for the guest to power off (QEMU exits)."""
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            raise TestFailure(f"the VM did not power off within {timeout}s") from None

    def stop(self):
        if self.qmp:
            self.qmp.close()
            self.qmp = None
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.sock:
            self.sock.close()

    def _send(self, text):
        data = text.encode()
        self.transcript.write(b">>> " + data)
        while data:
            _, w, _ = select.select([], [self.sock], [], 5)
            if not w:
                raise TestFailure("the serial shell does not accept input")
            n = self.sock.send(data)
            data = data[n:]

    def _read_until(self, pattern, timeout):
        regex = re.compile(pattern, re.DOTALL)
        deadline = time.time() + timeout
        while True:
            m = regex.search(self.buf)
            if m:
                return m
            if self.proc.poll() is not None:
                raise TestFailure(f"qemu exited with {self.proc.returncode}")
            left = deadline - time.time()
            if left <= 0:
                return None
            r, _, _ = select.select([self.sock], [], [], min(left, 1))
            if r:
                chunk = self.sock.recv(65536)
                self.transcript.write(chunk)
                self.transcript.flush()
                self.buf += chunk

    def kernel_starts(self):
        """How many kernels have started on the console so far."""
        try:
            with open(self.console, "rb") as fh:
                return fh.read().count(b"Linux version ")
        except FileNotFoundError:
            return 0

    def wait_shell(self, timeout, starts_before=0):
        """Wait until the debug shell answers; returns its boot id.

        Nothing is typed before a kernel newer than starts_before runs: on
        arm64 the firmware and GRUB read the shell's virtio console as a
        keyboard, and a ping during GRUB's menu stops the boot."""
        deadline = time.time() + timeout
        while self.kernel_starts() <= starts_before:
            if self.proc.poll() is not None:
                raise TestFailure(f"qemu exited with {self.proc.returncode}")
            if time.time() > deadline:
                raise TestFailure(f"no kernel started within {timeout}s (see console.log)")
            time.sleep(1)
        n = 0
        while time.time() < deadline:
            n += 1
            tag = uuid.uuid4().hex[:8]
            self.buf = b""
            # The quotes split the marker, so the terminal's echo of the command
            # line never matches the output.
            self._send(f"\recho __PI''NG_{tag}\r")
            if self._read_until(rb"__PING_" + tag.encode(), 5):
                self.run("stty -echo; PS1=; PS2=; export PS1 PS2 SYSTEMD_PAGER= PAGER=cat SYSTEMD_COLORS=0 "
                         "COLUMNS=1000 TERM=dumb", timeout=10, check=False)
                # run() puts its command into a subshell, so the exports above
                # never reach the shell: a pager would wait for a key on any
                # line longer than the terminal, and colours would be in what
                # the checks read. This line is the shell's own.
                self._send("export SYSTEMD_PAGER= PAGER=cat SYSTEMD_COLORS=0 NO_COLOR=1\r")
                return self.run("cat /proc/sys/kernel/random/boot_id", timeout=30).strip()
        raise TestFailure(f"no shell on the second serial port after {timeout}s (see console.log)")

    def run(self, command, timeout=120, check=True):
        tag = uuid.uuid4().hex[:8]
        self.buf = b""
        self._send(f"echo __BE''GIN_{tag}; ( {command} ) 2>&1; echo __R''C_{tag}=$?\r")
        m = self._read_until(rb"__BEGIN_" + tag.encode() + rb"\r?\n(.*?)__RC_" + tag.encode() + rb"=(\d+)", timeout)
        if not m:
            raise TestFailure(f"no answer within {timeout}s to: {command}")
        out = m.group(1).decode("utf-8", "replace").replace("\r", "")
        rc = int(m.group(2))
        if check and rc != 0:
            raise TestFailure(f"`{command}` exited {rc}:\n{out}")
        return out

    def reboot(self, timeout, quiet=False):
        """Restart and wait for the new system's shell. quiet: the kernel
        writes no "Linux version" to the console (the splash), so the shell
        is asked from the start; GRUB's hidden menu takes no key but Esc."""
        old = self.run("cat /proc/sys/kernel/random/boot_id").strip()
        starts = -1 if quiet else self.kernel_starts()
        self._send("systemctl reboot\r")
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(5)
            # The old shell may still answer while the system goes down, or
            # answer the ping and die before the next command (a wide window
            # when the VM is emulated): wait on for the new one.
            try:
                new = self.wait_shell(max(10, deadline - time.time()), starts)
            except TestFailure as e:
                log(f"reboot: {e}; waiting on")
                continue
            if new != old:
                return new
        raise TestFailure("the VM did not reboot")


# --- HTTP for the bundle and test data ---------------------------------------


def serve(directory):
    """An HTTP server for directory on a free port of the host, which the VM
    reaches as 10.0.2.2. Each request is logged on stderr, and its path is
    kept in the server's `requests`, in order."""
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=directory, **k)

        def send_head(self):
            requests.append(self.path)
            return super().send_head()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.requests = requests
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def link_or_copy(src, dst):
    """dst as a hard link of src where both are on one file system, else a copy."""
    if os.stat(src).st_dev == os.stat(os.path.dirname(dst)).st_dev:
        os.link(src, dst)
    else:
        shutil.copy(src, dst)


# --- a catalog of the test's own (WP-5.2 of the CLI's plan) ------------------
#
# `ironflock os update` installs what the signed catalog
# <download base>/ironflockos/manifest.json names (docs/manifest.schema.json,
# ADR-0009). The ironflock in the image trusts IronFlock's catalog key alone,
# which only a release run may use. The test serves a catalog of its own from
# the host: a valid one that names a release above this build, with this
# build's bundle, signed with a key made for this run. The ironflock of a
# release refuses it; one that trusts the run's key would install from it
# (docs/testing.md, "What os update needs").

CATALOG_CONTEXT = "ironflockos-manifest:v1"
CATALOG_PATH = "ironflockos/manifest.json"
# An Ed25519 public key in DER (SubjectPublicKeyInfo) before its 32 raw bytes.
ED25519_SPKI = bytes.fromhex("302a300506032b6570032100")


def next_version(version):
    """A release above version: the next patch release, or the release of a
    pre-release."""
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?", version)
    if not m:
        raise TestFailure(f"VERSION {version!r} is not a release version")
    major, minor, patch = (int(x) for x in m.groups()[:3])
    return f"{major}.{minor}.{patch}" if m.group(4) else f"{major}.{minor}.{patch + 1}"


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(16 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def sign_catalog(payload, keydir):
    """The envelope of payload as a release publishes the catalog,
    {"payload": <base64>, "signature": <base64 Ed25519 signature>}, signed over
    the three lines "ironflockos-manifest:v1", "ironflockos/manifest.json" and
    the payload's SHA-256 (docs/manifest.schema.json), with a key made here.
    The key stays in keydir, which is neither served nor uploaded. Returns the
    envelope, the key's id as ironflock names keys (the first 8 hex digits of
    the SHA-256 of the raw key) and the raw public key in base64."""
    os.makedirs(keydir, mode=0o700, exist_ok=True)
    key, pub = os.path.join(keydir, "catalog.key"), os.path.join(keydir, "catalog.pub")
    message, sig = os.path.join(keydir, "message"), os.path.join(keydir, "signature")
    openssl = lambda *args: subprocess.run(["openssl", *args], check=True, capture_output=True).stdout  # noqa: E731
    openssl("genpkey", "-algorithm", "ed25519", "-out", key)
    openssl("pkey", "-in", key, "-pubout", "-out", pub)
    der = openssl("pkey", "-in", key, "-pubout", "-outform", "DER")
    if len(der) != len(ED25519_SPKI) + 32 or not der.startswith(ED25519_SPKI):
        raise TestFailure("openssl made no Ed25519 key for the test catalog")
    with open(message, "wb") as fh:
        fh.write(f"{CATALOG_CONTEXT}\n{CATALOG_PATH}\n{hashlib.sha256(payload).hexdigest()}".encode())
    openssl("pkeyutl", "-sign", "-inkey", key, "-rawin", "-in", message, "-out", sig)
    # The signature verifies with the run's key: a refusal of the catalog is
    # the key's, not a fault of the envelope.
    openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub, "-rawin", "-in", message, "-sigfile", sig)
    with open(sig, "rb") as fh:
        signature = fh.read()
    if len(signature) != 64:
        raise TestFailure(f"the test catalog's signature has {len(signature)} bytes, not 64")
    envelope = json.dumps({"payload": base64.b64encode(payload).decode(),
                           "signature": base64.b64encode(signature).decode()}, indent=2).encode() + b"\n"
    if len(envelope) > 64 * 1024:
        raise TestFailure(f"the test catalog has {len(envelope)} bytes; ironflock reads at most 64 KiB")
    raw = der[len(ED25519_SPKI):]
    return envelope, hashlib.sha256(raw).hexdigest()[:8], base64.b64encode(raw).decode()


def put_test_catalog(serve_dir, workdir, image_id, version, artefacts, image):
    """The test catalog below serve_dir as a download base serves it:
    ironflockos/manifest.json, and the bundle at
    ironflockos/<release>/<image id>-<release>.raucb, a link of this build's.
    The catalog names one release, above VERSION, in both channels, with this
    build's image and bundle (their sizes and SHA-256) for image_id; image
    has the image's target, variant, kernel and architecture. Returns the
    release it names."""
    release = next_version(version)
    name = f"{image_id}-{version}"
    osr_file = os.path.join(artefacts, f"{name}.os-release")
    build_id = load_conf(osr_file).get("BUILD_ID", "") if os.path.exists(osr_file) else ""
    # A build of a tree with changes has "-dirty" on its BUILD_ID, which the
    # catalog's build_id does not take.
    build_id_pattern = r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z-g[0-9a-f]{7,40}"
    build_id = build_id.removesuffix("-dirty")
    if not re.fullmatch(build_id_pattern, build_id):
        build_id = "19700101T000000Z-g0000000"
    m = re.fullmatch(build_id_pattern, build_id)
    url = f"https://ironflockos-ci.invalid/dl/ironflockos/{release}/{image_id}-{release}"
    img_gz, bundle = os.path.join(artefacts, f"{name}.img.gz"), os.path.join(artefacts, f"{name}.raucb")
    disk = {"url": f"{url}.img.gz", "sha256": file_sha256(img_gz), "size": os.path.getsize(img_gz)}
    sizes = os.path.join(artefacts, f"{name}.sizes")
    if os.path.exists(sizes):
        s = load_conf(sizes)
        disk["raw_size"], disk["min_disk_size"] = int(s["raw_size"]), int(s["min_disk_size"])
    min_agent = load_conf(os.path.join(REPO, "build", "release.conf")).get("CATALOG_MIN_AGENT", "1.6.3")
    payload = {
        "schema": 1,
        "issued_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "channels": {"production": release, "test": release},
        "releases": {release: {
            "build_id": build_id,
            "buildtime": "{}-{}-{}T{}:{}:{}Z".format(*m.groups()),
            "min_agent": min_agent,
            "images": {image_id: dict(image, image=disk, bundle={
                "url": f"{url}.raucb", "sha256": file_sha256(bundle), "size": os.path.getsize(bundle),
                "compatible": image_id})},
        }},
        "boards": [],
    }
    data = json.dumps(payload, indent=2).encode() + b"\n"
    envelope, key_id, public = sign_catalog(data, os.path.join(workdir, "catalog-key"))
    folder = os.path.join(serve_dir, "ironflockos")
    os.makedirs(os.path.join(folder, release), exist_ok=True)
    with open(os.path.join(folder, "manifest.json"), "wb") as fh:
        fh.write(envelope)
    link_or_copy(bundle, os.path.join(folder, release, f"{image_id}-{release}.raucb"))
    log(f"test catalog: IronFlockOS {release} with this build's bundle, signed with the run's key {key_id} ({public})")
    return release


# --- what ironflock reads and runs on the device (cli/ironflockos) -----------

RAUC_STATUS = ["rauc", "status", "--detailed", "--output-format=json"]
GRUBENV = "/boot/efi/EFI/BOOT/grubenv"
CACHE = "/var/cache/ironflockos"
TEST_BUNDLE = f"{CACHE}/test.raucb"
# RAUC's own word on whether it installs (its D-Bus property Operation).
RAUC_OPERATION = "busctl get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation"
# Where a command that restarts the device leaves what it printed: /data
# outlives the restart.
REBOOT_OUT = "/data/ironflockos-ci"
# What `ironflock os update` and `os rollback` say while RAUC installs
# (docs/cli.md of IronFlock/ironflock-cli).
RAUC_BUSY = "RAUC is installing an update right now"


def grub_next(env):
    """The slot GRUB starts next with this grubenv (targets/*/grub/grub.cfg):
    the first of ORDER that is OK and not tried; when every slot was tried,
    the first that is OK; else A."""
    order = [s for s in env.get("ORDER", "A B").split() if s in ("A", "B")]
    for s in order:
        if env.get(f"{s}_OK", "0") == "1" and env.get(f"{s}_TRY", "0") == "0":
            return s
    for s in order:
        if env.get(f"{s}_OK", "0") == "1":
            return s
    return "A"


# --- the tests ---------------------------------------------------------------


class Runner:
    def __init__(self, vm, conf, image_id, http_port, docker_tar, boot_timeout, disk_dev="/dev/vda", flock=None,
                 requests=None, captured=None):
        self.vm, self.conf, self.image_id = vm, conf, image_id
        self.secure_boot = vm.secure_boot
        self.disk_dev = disk_dev
        self.flock = flock
        self.http = f"http://10.0.2.2:{http_port}"
        self.docker_tar = docker_tar
        self.boot_timeout = boot_timeout
        self.results = []
        # The paths the VM asked the host's HTTP server for (serve), and where
        # what ironflock reads and prints is kept (keep).
        self.requests = requests if requests is not None else []
        self.captured = captured
        self.kept = 0

    def step(self, name, fn):
        log(f"--- {name}")
        start = time.time()
        try:
            fn()
        except TestFailure as e:
            self.results.append((name, False, time.time() - start))
            log(f"FAIL {name}: {e}")
            raise
        self.results.append((name, True, time.time() - start))
        log(f"ok   {name} ({time.time() - start:.0f}s)")

    def wait_running(self):
        state = self.vm.run("systemctl is-system-running --wait", timeout=self.boot_timeout, check=False).strip()
        if state != "running":
            failed = self.vm.run("systemctl --failed --no-legend --plain --no-pager --full; "
                                 "systemctl status --failed --no-pager -l -n 20", check=False)
            raise TestFailure(f"system state {state!r}; failed units:\n{failed}")

    def rauc_status(self):
        # stdout only: RAUC warns on stderr, e.g. when no slot in ORDER is
        # bootable after a fallback.
        return json.loads(self.vm.run("rauc status --output-format=json 2>/dev/null"))

    def booted(self):
        return self.rauc_status().get("booted")

    def mark_good(self, name, slot):
        """What the device-agent does once it has reached the platform: mark
        the booted slot good. Nothing in the image does it at boot, and the
        test .flock's agent never reaches a platform, so the test stands in."""
        env = self.vm.run("grub-editenv /boot/efi/EFI/BOOT/grubenv list")
        if f"{name}_TRY=1" not in env.split():
            raise TestFailure(f"slot {name} was marked good before the agent's turn:\n{env}")
        self.vm.run("rauc status mark-good")
        env = self.vm.run("grub-editenv /boot/efi/EFI/BOOT/grubenv list").split()
        state = self._slots().get(slot, {}).get("boot_status")
        if f"{name}_OK=1" not in env or f"{name}_TRY=0" not in env or state != "good":
            raise TestFailure(f"slot {name} is not good after rauc status mark-good: {state}, {env}")

    def boot_chain(self):
        """ADR-0011: the IRONFLOCKOS partition boots the image's own shim and
        Debian's signed GRUB, and Secure Boot is what the test asked for: on,
        the kernel booted through every check and runs locked down."""
        efi_arch, grub_format = self.conf["EFI_ARCH"], self.conf["GRUB_FORMAT"]
        boot = "/boot/efi/EFI/BOOT"
        self.vm.run(f"cmp {boot}/{self.conf['EFI_LOADER']} /usr/lib/shim/shim{efi_arch}.efi.signed")
        self.vm.run(f"cmp {boot}/mm{efi_arch}.efi /usr/lib/shim/mm{efi_arch}.efi.signed")
        self.vm.run(f"cmp {boot}/grub{efi_arch}.efi /usr/lib/grub/{grub_format}-signed/grub{efi_arch}.efi.signed")
        self.vm.run(f"test ! -e {boot}/fb{efi_arch}.efi && grep -q '^source ' /boot/efi/EFI/debian/grub.cfg")
        # fwupd's capsule helper starts through the shim in the OS's folder.
        self.vm.run("systemctl start ironflockos-fwupd-shim.service")
        self.vm.run(f"cmp {boot}/{self.conf['EFI_LOADER']} /boot/efi/EFI/debian/shim{efi_arch}.efi")
        # shim hands its MOK state to the kernel in a configuration table,
        # which the kernel lists at boot (its sysfs view needs EFI runtime
        # services): shim started GRUB, with Secure Boot on or off.
        klog = "journalctl -k -b --no-pager -o cat"
        self.vm.run(f"{klog} | grep -q '^efi: .* MOKvar=0x'")
        want_state, want_lockdown = ("enabled", "[integrity]") if self.secure_boot else ("disabled", "[none]")
        kernel = self.vm.run(f"{klog} | grep -m 1 -o 'secureboot: Secure boot [a-z]*'", check=False).strip()
        lockdown = self.vm.run("cat /sys/kernel/security/lockdown").strip()
        if kernel != f"secureboot: Secure boot {want_state}" or want_lockdown not in lockdown:
            raise TestFailure(f"Secure Boot should be {want_state}: the kernel says {kernel!r}, lockdown {lockdown!r}")
        # PREEMPT_RT kernels turn EFI runtime services off: no variables to
        # read. Elsewhere mokutil, what a user asks, has to agree.
        if self.vm.run("ls /sys/firmware/efi/efivars 2>/dev/null | head -n 1", check=False).strip():
            state = self.vm.run("mokutil --sb-state", check=False).strip()
            if f"SecureBoot {want_state}" not in state:
                raise TestFailure(f"Secure Boot should be {want_state}: mokutil says {state!r}")

    def first_boot(self):
        self.vm.wait_shell(self.boot_timeout)
        self.wait_running()
        osr = self.vm.run("cat /etc/os-release")
        if f"IMAGE_ID={self.image_id}" not in osr or "ID=ironflockos" not in osr:
            raise TestFailure(f"unexpected os-release:\n{osr}")
        self.boot_chain()
        parts = self.vm.run(f"lsblk -bnro PARTLABEL,SIZE {self.disk_dev} | sed '/^ /d'")
        sizes = dict(line.split() for line in parts.splitlines() if len(line.split()) == 2)
        for label in ("IRONFLOCKOS", "rootfs-a", "rootfs-b", "data"):
            if label not in sizes:
                raise TestFailure(f"partition {label} missing:\n{parts}")
        if int(sizes["rootfs-b"]) != int(sizes["rootfs-a"]):
            raise TestFailure(f"slot B ({sizes['rootfs-b']}) differs from slot A ({sizes['rootfs-a']})")
        if int(sizes["data"]) < 10 * 1024**3:
            raise TestFailure(f"/data was not grown to the disk: {sizes['data']} bytes")
        for path, source in (("/data", None), ("/opt/ironflock", "/data/ironflock"), ("/home", "/data/home"),
                             ("/var/log", "/data/log"), ("/var/lib/fwupd", "/data/fwupd"),
                             ("/var/lib/systemd/pstore", "/data/pstore"),
                             ("/etc/NetworkManager/system-connections", "/data/network/connections"),
                             ("/boot/efi", None)):
            out = self.vm.run(f"findmnt -no SOURCE,FSROOT {path}", check=False).strip()
            if not out:
                raise TestFailure(f"{path} is not mounted")
            if source and not out.endswith(source[len('/data'):]):
                raise TestFailure(f"{path} is mounted from {out}, expected {source}")
        self.apps_on_data()
        mid = self.vm.run("cat /etc/machine-id").strip()
        if not re.fullmatch(r"[0-9a-f]{32}", mid):
            raise TestFailure(f"machine-id not initialised: {mid!r}")
        self.machine_id = mid
        self.vm.run("test -s /data/etc/ssh/ssh_host_ed25519_key && test ! -e /etc/ssh/ssh_host_ed25519_key")
        sshd = self.vm.run("sshd -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) '")
        for want in ("permitrootlogin no", "passwordauthentication no", "kbdinteractiveauthentication no"):
            if want not in sshd.lower():
                raise TestFailure(f"sshd policy: expected {want!r} in:\n{sshd}")
        self.host_key = self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip()
        self.vm.run("awk -F: '$2 !~ /^[!*]/ { print \"account with a password: \" $1; bad = 1 } END { exit bad }' /etc/shadow")
        status = self.rauc_status()
        if status.get("booted") != "A" or status.get("compatible") != self.image_id:
            raise TestFailure(f"rauc status: {status}")
        self.mark_good("A", "rootfs.0")
        self.vm.run("! systemctl is-enabled rauc-mark-good.service 2>/dev/null | grep -qx enabled")
        root = self.vm.run("docker info --format '{{.DockerRootDir}}'").strip()
        if root != "/opt/ironflock/device-agent/docker-apps":
            raise TestFailure(f"Docker data-root is {root}")
        if self.docker_tar:
            self.vm.run(f"curl -fsS {self.http}/{os.path.basename(self.docker_tar)} | docker load", timeout=300)
            out = self.vm.run("docker run --rm hello-world", timeout=120)
            if "Hello from Docker" not in out:
                raise TestFailure(f"hello-world did not run:\n{out}")
        fw = self.vm.run("fwupdmgr get-devices --json 2>&1; true", timeout=120)
        if "Devices" not in fw and "No detected devices" not in fw:
            raise TestFailure(f"fwupd gave no inventory:\n{fw}")
        if self.flock:
            self.enrolled(first=True)
        self.vm.run("echo ironflockos-test > /data/ironflockos-test-marker")
        # An app's data, which the reboot and the update into slot B keep.
        self.vm.run("mkdir -p /apps/prod/ironflockos-test && echo ironflockos-test > /apps/prod/ironflockos-test/data.txt")
        self.text_screen()

    def explain(self, *units):
        """What a step prints when the units it waited for are not as it
        expected: their state and this boot's journal of them."""
        names = " ".join(units)
        journal = " ".join(f"-u {u}" for u in units)
        return self.vm.run(f"systemctl status --no-pager -l -n 0 {names}; "
                           f"journalctl -b --no-pager -o short-monotonic -n 80 {journal}", check=False)

    def apps_on_data(self):
        """/apps, the device-agent's -appsDir, is the bind mount of /data/apps
        (/etc/fstab, nofail), Docker (and the agent, when enrolled) are ordered
        after it, and ironflockos-apps-check found it so."""
        units = ("apps.mount", "ironflockos-data-layout.service", "ironflockos-apps-check.service")
        out = self.vm.run("findmnt -no SOURCE,FSROOT /apps", check=False).strip()
        same = self.vm.run("[ \"$(stat -c %d:%i /apps)\" = \"$(stat -c %d:%i /data/apps)\" ] && echo same",
                           check=False).strip()
        check = self.vm.run("systemctl is-active ironflockos-apps-check.service", check=False).strip()
        if not out.endswith("/apps") or same != "same" or check != "active":
            raise TestFailure(f"/apps is not the bind mount of /data/apps (findmnt {out!r}, "
                              f"apps-check {check!r}):\n{self.explain(*units)}")
        self.vm.run("test ! -e /run/ironflockos/apps-not-persistent")
        ordered = ["docker.service"] + (["ironflock-device-agent.service"] if self.flock else [])
        for unit in ordered:
            after = self.vm.run(f"systemctl show --no-pager -p After --value {unit}").split()
            if "apps.mount" not in after:
                raise TestFailure(f"{unit} is not ordered after apps.mount: {after}\n{self.explain(*units)}")

    def rt_kernel(self):
        """An -rt image (WP-4b.1): the PREEMPT_RT kernel, and a new rt.conf
        written into grubenv by ironflockos-rt-tuning (applied at the next boot,
        which reboot_persists checks)."""
        version = self.vm.run("uname -v")
        if "PREEMPT_RT" not in version:
            raise TestFailure(f"not a PREEMPT_RT kernel: {version.strip()}")
        self.vm.run("systemctl is-active ironflockos-rt-tuning.service")
        self.vm.run("printf 'isolate=1\\nirq=0\\n' > /data/ironflockos/rt.conf")
        deadline = time.time() + 60
        while time.time() < deadline:
            env = self.vm.run("grub-editenv /boot/efi/EFI/BOOT/grubenv list")
            if "isolcpus=managed_irq,domain,1" in env:
                break
            time.sleep(2)
        else:
            raise TestFailure(f"rt.conf did not reach grubenv:\n{env}")
        self.vm.run("test -e /run/ironflockos/rt-reboot-required")
        self.rt_pending = True

    def confinement(self):
        """AppArmor (docs/build.md, "AppArmor"): on in the kernel, its profiles
        loaded, Docker's default profile on a container that is not
        privileged, and chronyd under Debian's profile. That chronyd still
        reads the PTP source and the NTP servers of proxy.conf, which that
        profile allows only through the image's local file, is what the time
        and the proxy steps check after this one."""
        enabled = self.vm.run("cat /sys/module/apparmor/parameters/enabled", check=False).strip()
        if enabled != "Y":
            raise TestFailure(f"AppArmor is not on in the kernel: {enabled!r}")
        state = self.vm.run("systemctl is-active apparmor.service", check=False).strip()
        if state != "active":
            raise TestFailure(f"apparmor.service is {state}:\n{self.explain('apparmor.service')}")
        options = self.vm.run("docker info --format '{{.SecurityOptions}}'").strip()
        if "name=apparmor" not in options:
            raise TestFailure(f"Docker does not confine containers with AppArmor: {options}")
        self.vm.run("grep -qx 'docker-default (enforce)' /sys/kernel/security/apparmor/profiles")
        label = self.vm.run("cat /proc/$(pidof chronyd | awk '{print $1}')/attr/current").strip()
        if label != "/usr/sbin/chronyd (enforce)":
            raise TestFailure(f"chronyd does not run under its profile: {label!r}")
        # A process that is not root still makes a user namespace: a browser's
        # sandbox in an app needs it (docs/kiosk-plan.md, the contract).
        self.vm.run("runuser -u nobody -- unshare --user true")
        if self.docker_tar:
            label = self.vm.run("cid=$(docker run -d hello-world) && "
                                "docker inspect --format '{{.AppArmorProfile}}' \"$cid\"; docker rm -f \"$cid\" >/dev/null",
                                timeout=120).strip()
            if label != "docker-default":
                raise TestFailure(f"a container that is not privileged has the profile {label!r}")

    # --- the screen (docs/build.md, "The screen") ----------------------------

    GRUBENV = "/boot/efi/EFI/BOOT/grubenv"
    ARCHIVE = "/boot/efi/EFI/BOOT/splash.cpio"
    THEME = "/usr/share/plymouth/themes/ironflockos"

    def text_screen(self):
        """boot=text, which every step but the splash's boots with: no
        Plymouth, the kernel's messages, a login prompt on tty1, as before
        the splash."""
        cmdline = self.vm.run("cat /proc/cmdline").split()
        if "plymouth.enable=0" not in cmdline or "splash" in cmdline or "quiet" in cmdline:
            raise TestFailure(f"not a text boot: {' '.join(cmdline)}")
        self.vm.run("! pidof plymouthd")
        self.vm.run("systemctl is-active getty@tty1.service")

    def put_file(self, path, data):
        """A file of the test's into the VM, as an app writes it: under a
        temporary name, synced, renamed. The shell's line is short, so the
        data goes in pieces."""
        tmp = f"{os.path.dirname(path)}/.{os.path.basename(path)}.partial"
        text = base64.b64encode(data).decode()
        self.vm.run(f": > {tmp}.b64")
        for i in range(0, len(text), 2000):
            self.vm.run(f"printf %s {text[i:i + 2000]} >> {tmp}.b64")
        self.vm.run(f"base64 -d {tmp}.b64 > {tmp} && rm {tmp}.b64 && sync {tmp} && mv {tmp} {path}")

    def set_boot_cmdline(self, splash):
        """The test's kernel parameters for the next boots, with the splash
        or on text."""
        self.vm.run(f"grub-editenv {self.GRUBENV} set 'IRONFLOCKOS_CMDLINE={debug_cmdline(self.vm.arch, splash)}'")

    def splash_boot(self, expect, name, grub=False):
        """Restart with the splash; the screen is watched from the restart to
        the end of the boot and must be the splash (expect) from before the
        root filesystem on, faded in and never back; Plymouth ran from the
        initramfs and is gone at the end. grub: GRUB draws the splash
        (WP-8.7), checked by ScreenWatch.check_grub instead."""
        watch = ScreenWatch(self.vm.screen_qmp(), expect, self.vm.workdir, name)
        t0 = time.time()
        try:
            self.vm.reboot(self.boot_timeout, quiet=True)
            t_shell = time.time()
            t_kernel = t_shell - float(self.vm.run("cut -d' ' -f1 /proc/uptime").strip())
            self.wait_running()
            # Plymouth quits at the end of the boot; the frames after it count.
            time.sleep(5)
        finally:
            watch.stop()
        log(f"the screen from the restart ({name}; the kernel started at {t_kernel - t0:.1f}s, "
            f"the root filesystem's shell answered at {t_shell - t0:.1f}s):\n{watch.timeline(t0)}")
        if grub:
            gaps = watch.check_grub(t0, t_kernel, t_shell)
        else:
            gaps = watch.check(t0, t_kernel, t_shell)
        log(f"frames without the whole picture before the root filesystem's system answered, after the picture "
            f"showed: {gaps} (a graphics driver taking the screen over; QEMU's start with an empty one)")
        # A crashed plymouthd leaves the system "running" (the drop-in for
        # plymouth-start.service); the journal says how it ended.
        crashed = self.vm.run("journalctl -b --no-pager -o cat -u plymouth-start.service | "
                              "grep -E 'code=(killed|dumped)'", check=False).strip()
        if crashed:
            raise TestFailure(f"plymouthd crashed in the root filesystem: {crashed}")
        # Plymouth started in the initramfs: before systemd. keep-splash,
        # which ends Plymouth, writes when Plymouth started (the kernel's
        # record of the process); systemd keeps its own start (microseconds
        # after the kernel's). A probe from the shell would come too late on
        # a fast boot: Plymouth may be gone before the shell first answers.
        quit = self.vm.run("journalctl -b --no-pager -o cat -u plymouth-quit.service | "
                           "grep -m 1 '^keep-splash: Plymouth (pid'", check=False).strip()
        systemd = self.vm.run("systemctl show -p UserspaceTimestampMonotonic --value").strip()
        m = re.search(r"started ([0-9.]+) s after the kernel", quit)
        if not m or not systemd.isdigit():
            raise TestFailure(f"no record of when Plymouth started (plymouth-quit.service): {quit!r}\n"
                              f"{self.explain('plymouth-start.service', 'plymouth-quit.service')}")
        started, systemd = float(m.group(1)), int(systemd) / 1e6
        if not 0 < started < systemd:
            raise TestFailure(f"Plymouth started at {started:.2f}s, not in the initramfs (systemd at {systemd:.2f}s)")
        cmdline = self.vm.run("cat /proc/cmdline").split()
        for want in ("quiet", "splash", "plymouth.ignore-serial-consoles", "plymouth.force-frame-buffer-on-boot",
                     "vt.global_cursor_default=0", "fbcon=map:9"):
            if want not in cmdline:
                raise TestFailure(f"{want} is not on the kernel command line: {' '.join(cmdline)}")
        self.vm.run("! pidof plymouthd")
        # The terminals have their console back (ironflockos-consoles): the
        # framebuffer console is bound.
        self.vm.run("for v in /sys/class/vtconsole/vtcon*; do grep -q 'frame buffer' \"$v/name\" && "
                    "[ \"$(cat \"$v/bind\")\" = 1 ] && exit 0; done; exit 1")

    def splash(self):
        """WP-8.1 (docs/kiosk-plan.md): the splash by default. The initramfs
        carries Plymouth and the theme. A boot with the splash, and an
        archive of random bytes next to grubenv (a damaged splash.cpio): it
        boots, and the screen shows IronFlock's logo on black from before the
        root filesystem to the end of the boot and 30 seconds later, with no
        text; ironflockos-splash then removes the archive, as /data names no
        picture. After the boot tty1 is in front, in graphics mode, without
        a login prompt; an error on the kernel's log goes to the serial
        console and leaves the screen as it is; every input device has its
        ID_INPUT properties."""
        self.vm.run("test ! -e /data/ironflockos/screen/splash.png && test -d /data/ironflockos/screen")
        self.vm.run(f"test \"$(stat -c '%U %a' /data/ironflockos/screen)\" = 'root 755'")
        initramfs = self.vm.run("lsinitramfs /initrd.img | grep -E 'plymouth|ironflockos'", timeout=300)
        for want in (f"{self.THEME[1:]}/ironflockos.script", f"{self.THEME[1:]}/ironflock.png",
                     "etc/plymouth/plymouthd.conf", "/plymouth/script.so", "/plymouth/renderers/frame-buffer.so",
                     "/plymouth/label-pango.so", "usr/sbin/plymouthd"):
            if want not in initramfs:
                raise TestFailure(f"the initramfs has no {want}")
        log("sizes: " + self.vm.run("du -h --apparent-size /boot/initrd.img-* | tr '\\t\\n' '  '; "
                                    "df -h --output=used,size / | tail -n 1"))
        self.vm.run(f"head -c 8192 /dev/urandom > {self.ARCHIVE} && sync")
        self.set_boot_cmdline(splash=True)
        with open(os.path.join(REPO, "docs", "assets", "ironflock-splash.png"), "rb") as fh:
            logo = Splash(fh.read(), (0, 0, 0))
        self.splash_boot(logo, "logo")
        self.vm.run("journalctl -k -b --no-pager -o cat | grep -q 'Initramfs unpacking failed'")
        self.wait_for(f"test ! -e {self.ARCHIVE}", 60, "ironflockos-splash to remove the damaged archive")
        # The first virtual terminal belongs to the screen.
        if self.vm.run("cat /sys/class/tty/tty0/active").strip() != "tty1":
            raise TestFailure("tty1 is not the virtual terminal in front")
        if self.vm.run(KD_MODE).strip() != "1":
            raise TestFailure("tty1 is not in graphics mode after the boot")
        self.vm.run("! systemctl -q is-active getty@tty1.service")
        qmp = self.vm.screen_qmp()
        shot = os.path.join(self.vm.workdir, "screendump.ppm")
        before = qmp.screen(shot)
        ok, _, why = logo.match(before)
        if not ok:
            save_screen(before, os.path.join(self.vm.workdir, "screen-logo-after-boot.png"))
            raise TestFailure(f"after the boot the screen is not the splash: {why}")
        mark = f"ironflockos-ci: an error on the kernel log {uuid.uuid4().hex[:8]}"
        self.vm.run(f"echo '<3>{mark}' > /dev/kmsg")
        time.sleep(3)
        if qmp.screen(shot) != before:
            raise TestFailure("an error on the kernel's log changed the screen")
        with open(self.vm.console, "rb") as fh:
            if mark.encode() not in fh.read():
                raise TestFailure("an error on the kernel's log did not reach the serial console")
        time.sleep(30)
        after = qmp.screen(shot)
        if after != before:
            save_screen(after, os.path.join(self.vm.workdir, "screen-logo-30s.png"))
            raise TestFailure(f"the screen changed within 30 seconds after the boot: {logo.match(after)[2]}")
        # Every input device is named for what it is (the contract).
        bad = self.vm.run("for d in /dev/input/event*; do udevadm info -q property -n \"$d\" | grep -qx ID_INPUT=1 "
                          "|| echo \"$d\"; done").strip()
        if bad:
            raise TestFailure(f"input devices without ID_INPUT: {bad}")
        self.vm.run("udevadm info -q property -n /dev/input/event0 >/dev/null && "
                    "for d in /dev/input/event*; do udevadm info -q property -n \"$d\"; done | grep -qx ID_INPUT_KEYBOARD=1")

    def own_splash(self):
        """WP-8.4: the device's own picture. A screen app's temporary file
        changes nothing; the renamed picture and splash.conf become
        splash.cpio; a file that is no PNG, one too large, one with another
        chunk and a splash.conf with an unknown key are refused, and the
        splash stays; the theme for the shutdown has the picture. The next
        boot shows the picture on its background, without a fade (animation
        none), and the boot before it ended with Plymouth's shutdown splash."""
        screen = "/data/ironflockos/screen"
        picture = test_picture()
        bg = (0x20, 0x40, 0x60)
        journal = "journalctl -b --no-pager -o cat -u ironflockos-splash.service"
        self.vm.run(f"printf x > {screen}/.splash.png.partial && sleep 3")
        self.vm.run(f"test ! -e {self.ARCHIVE} && rm {screen}/.splash.png.partial")
        self.put_file(f"{screen}/splash.conf", b"background=#204060\nanimation=none\n")
        self.put_file(f"{screen}/splash.png", picture)
        taken = "the splash from the next boot on: the device's picture, background #204060, animation none"
        self.wait_for(f"{journal} | grep -qF \"{taken}\" && [ -s {self.ARCHIVE} ]", 60, "the picture to become splash.cpio")
        # The journal line comes before the run ends (GRUB's files, the theme
        # for the shutdown): each next file is written once it has ended, so
        # that the test knows which run took which file.
        settled = ("[ \"$(systemctl show -p ActiveState --value ironflockos-splash.service)\" != activating ] && "
                   "! systemctl list-jobs --no-legend | grep -q ironflockos-splash")
        self.wait_for(settled, 120, "ironflockos-splash to end")
        good = self.vm.run(f"cksum < {self.ARCHIVE}").strip()
        wrong = [
            (b"no picture\n", "splash.png is not a PNG"),
            (None, "splash.png is larger than 4 MiB"),
            (picture[:33] + png_chunk(b"tEXt", b"Comment\0x") + picture[33:],
             "splash.png has the chunk tEXt: only IHDR, PLTE, tRNS, IDAT and IEND are taken"),
        ]
        for data, reason in wrong:
            if data is None:
                self.vm.run(f"head -c 4194305 /dev/zero > {screen}/.big && sync && mv {screen}/.big {screen}/splash.png")
            else:
                self.put_file(f"{screen}/splash.png", data)
            self.wait_for(f"{journal} | grep -qF 'refused: {reason}; the splash stays as it was'", 60,
                          f"the refusal of {reason!r}")
            self.wait_for(settled, 120, "ironflockos-splash to end")
            if self.vm.run(f"cksum < {self.ARCHIVE}").strip() != good:
                raise TestFailure(f"splash.cpio changed with {reason!r}")
        self.put_file(f"{screen}/splash.png", picture)
        self.put_file(f"{screen}/splash.conf", b"background=#204060\nfont=big\n")
        self.wait_for(f"{journal} | grep -qF 'refused: splash.conf: line 2: unknown key font'", 60,
                      "the refusal of an unknown key")
        self.wait_for(settled, 120, "ironflockos-splash to end")
        self.put_file(f"{screen}/splash.conf", b"background=#204060\nanimation=none\n")
        self.wait_for(f"! systemctl -q is-failed ironflockos-splash.service && [ \"$(cksum < {self.ARCHIVE})\" = '{good}' ]",
                      60, "the splash to be taken again")
        self.wait_for(settled, 120, "ironflockos-splash to end")
        # The running system's theme has the picture, for the shutdown.
        self.vm.run(f"findmnt -n {self.THEME} >/dev/null && cmp {self.THEME}/splash.png {screen}/splash.png"
                    f" && grep -qx 'animation = \"none\";' {self.THEME}/ironflockos.script")
        self.splash_boot(Splash(picture, bg), "own")
        self.vm.run("journalctl -b -1 --no-pager -o cat -u plymouth-reboot.service | grep -q '^Started '")
        if self.vm.run(f"cksum < {self.ARCHIVE}").strip() != good:
            raise TestFailure("the boot did not keep splash.cpio as it was")
        self.splash_archive = good
        # WP-8.7: with animation=none the screen at the end of this boot,
        # which started with the archive, becomes the picture GRUB draws; it
        # is what the screen shows, pixel for pixel.
        boot = "/boot/efi/EFI/BOOT"
        self.wait_for(f"test -s {boot}/splash-screen.png && grub-editenv {boot}/splash.env list | "
                      "grep -q '^IRONFLOCKOS_SPLASH_MODE='", 120, "ironflockos-splash-capture to take the screen")
        self.vm.run(f"grub-editenv {boot}/splash.env list | grep -qx 'IRONFLOCKOS_SPLASH_BACKGROUND=#204060'")
        taken = base64.b64decode(self.vm.run(f"base64 -w0 {boot}/splash-screen.png").strip())
        width, height, rgba = png_decode(taken)
        screen = self.vm.screen_qmp().screen(os.path.join(self.vm.workdir, "screendump.ppm"))
        rgb = bytes(b for i, b in enumerate(rgba) if i % 4 != 3)
        if (width, height) != screen[:2] or rgb != screen[2]:
            save_screen((width, height, rgb), os.path.join(self.vm.workdir, "screen-own-taken.png"))
            raise TestFailure(f"the picture taken for GRUB ({width}x{height}) is not what the screen shows "
                              f"({screen[0]}x{screen[1]})")

    def grub_splash(self):
        """WP-8.7: the boot after the screen was taken. GRUB draws the
        splash before the kernel starts, the kernel keeps its framebuffer and
        its console off the screen, and Plymouth draws the same picture; from
        GRUB's picture to the end of the boot the screen is the splash and
        nothing else, and the terminals have their console back. Then the
        steps after this one boot on text again: they read the serial
        console."""
        self.splash_boot(Splash(test_picture(), (0x20, 0x40, 0x60)), "grub", grub=True)
        self.set_boot_cmdline(splash=False)

    def keys(self, *names):
        """Keys pressed together on the VM's keyboard (QMP send-key, QEMU's
        key names)."""
        self.vm.screen_qmp().command("send-key", keys=[{"type": "qcode", "data": n} for n in names])
        time.sleep(0.3)

    def type_line(self, text):
        for ch in text:
            self.keys(ch)
        self.keys("ret")

    # The first terminal's state, for the switches' diagnostics: which
    # terminal is in front, tty1's display mode (KDGETMODE: 0 text,
    # 1 graphics), keyboard mode (KDGKBMODE: 0 raw, 1 xlate, 2 mediumraw,
    # 3 unicode, 4 off) and switching mode (VT_GETMODE: 0 auto, 1 process,
    # with the signal asked for), and whether a plymouthd runs.
    VT_STATE = ("echo front=$(cat /sys/class/tty/tty0/active) plymouthd=$(pidof plymouthd || echo none); "
                "perl -e 'open(my $t, \"<\", \"/dev/tty1\") or die $!; "
                "my $kd = pack(\"L\", 0); ioctl($t, 0x4B3B, $kd) or die \"KDGETMODE $!\"; "
                "my $kb = pack(\"L\", 0); ioctl($t, 0x4B44, $kb) or die \"KDGKBMODE $!\"; "
                "my $vm = \"\\0\" x 8; ioctl($t, 0x5601, $vm) or die \"VT_GETMODE $!\"; "
                "my ($mode, $waitv, $rel) = unpack(\"CCs\", $vm); "
                "printf \"tty1: display=%d keyboard=%d switching=%d relsig=%d\\n\", unpack(\"L\", $kd), unpack(\"L\", $kb), $mode, $rel'")

    def switch_to_tty2(self, when):
        """Ctrl+Alt+F2 switches to tty2. On failure, what the first terminal
        was like and whether a switch asked for from the shell (VT_ACTIVATE,
        what chvt does) gets through: that tells a key that does not reach
        the kernel's keyboard from a switch the kernel refuses."""
        before = self.vm.run(self.VT_STATE, check=False).strip()
        log(f"before Ctrl+Alt+F2 ({when}): {before}")
        self.keys("ctrl", "alt", "f2")
        try:
            self.wait_for("[ \"$(cat /sys/class/tty/tty0/active)\" = tty2 ]", 30, f"Ctrl+Alt+F2 to switch to tty2 ({when})")
        except TestFailure as e:
            after = self.vm.run(self.VT_STATE, check=False).strip()
            chvt = self.vm.run("perl -e 'open(my $t, \"<\", \"/dev/tty0\") or die $!; my $n = 2; "
                               "ioctl($t, 0x5606, $n) or die \"VT_ACTIVATE $!\"'; sleep 2; "
                               "echo front after VT_ACTIVATE 2: $(cat /sys/class/tty/tty0/active)", check=False).strip()
            raise TestFailure(f"{e}\nbefore: {before}\nafter: {after}\n{chvt}") from None

    def usual_keys(self):
        """WP-8.2 on the system booted with its own splash. After the boot
        as it is: Ctrl+Alt+F2 gives a login prompt, Ctrl+Alt+F1 leads back
        to tty1; with an enrolled device, the console password (D8): a hash
        in /data/ironflockos/console-password becomes the enrolled user's
        password and no one else's, the user logs in with it on tty2, SSH
        still refuses passwords, and without the file the password is
        locked again. Then with a Plymouth started by hand: Esc shows the
        messages and Esc again the splash, a message goes below the picture
        and stays when Plymouth quits, and Ctrl+Alt+F2 again switches."""
        qmp = self.vm.screen_qmp()
        shot = os.path.join(self.vm.workdir, "screendump.ppm")
        expect = Splash(test_picture(), (0x20, 0x40, 0x60))
        # The other terminals have a login prompt, after the boot as a person
        # at the device finds it.
        self.switch_to_tty2("after the boot")
        self.wait_for("systemctl -q is-active autovt@tty2.service || systemctl -q is-active getty@tty2.service", 60,
                      "a login prompt on tty2")
        frame = qmp.screen(shot)
        save_screen(frame, os.path.join(self.vm.workdir, "screen-keys-tty2.png"))
        if expect.match(frame)[0]:
            raise TestFailure("tty2 shows the splash, not its login prompt")
        if self.flock:
            self.console_password()
        self.keys("ctrl", "alt", "f1")
        self.wait_for("[ \"$(cat /sys/class/tty/tty0/active)\" = tty1 ]", 30, "Ctrl+Alt+F1 to lead back to tty1")
        # Plymouth as at boot, on the running system: Esc toggles the messages.
        self.vm.run("plymouthd --mode=boot --attach-to-session --pid-file=/run/plymouth/pid && plymouth show-splash")
        try:
            self.wait_for("plymouth --ping", 30, "Plymouth to answer")
            time.sleep(3)
            ok, _, why = expect.match(qmp.screen(shot))
            if not ok:
                raise TestFailure(f"Plymouth started by hand does not show the splash: {why}")
            self.keys("esc")
            time.sleep(3)
            frame = qmp.screen(shot)
            if expect.match(frame)[0]:
                raise TestFailure("Esc did not show the boot messages")
            save_screen(frame, os.path.join(self.vm.workdir, "screen-keys-esc.png"))
            self.keys("esc")
            time.sleep(3)
            ok, _, why = expect.match(qmp.screen(shot))
            if not ok:
                raise TestFailure(f"Esc again did not bring the splash back: {why}")
            # WP-8.3: what the image says to a person at the device, below
            # the picture; it stays when Plymouth quits.
            self.vm.run("/usr/lib/ironflockos/screen-message 'IronFlockOS: a message for the screen'")
            time.sleep(3)
            frame = qmp.screen(shot)
            save_screen(frame, os.path.join(self.vm.workdir, "screen-keys-message.png"))
            ok, why = expect.match_message(frame)
            if not ok:
                raise TestFailure(f"the message is not on the splash: {why}")
        finally:
            # As at the end of the boot (plymouth-quit.service).
            kept = self.vm.run("/usr/lib/ironflockos/keep-splash", check=False)
        if "could not be" in kept:
            raise TestFailure(f"keep-splash did not do all of its steps:\n{kept}")
        self.vm.run("! pidof plymouthd")
        time.sleep(2)
        ok, why = expect.match_message(qmp.screen(shot))
        if not ok:
            raise TestFailure(f"the message did not stay when Plymouth quit: {why}")
        # Without Plymouth (boot=text) a message changes nothing and fails nothing.
        self.vm.run("/usr/lib/ironflockos/screen-message 'not shown'")
        self.vm.run("! journalctl -b --no-pager -o cat | grep -q 'keep-splash: .* could not be'")
        # And after this Plymouth too the switch works.
        self.switch_to_tty2("after a Plymouth started by hand")
        self.keys("ctrl", "alt", "f1")
        self.wait_for("[ \"$(cat /sys/class/tty/tty0/active)\" = tty1 ]", 30, "Ctrl+Alt+F1 to lead back to tty1")

    def console_password(self):
        password = "ironflock" + uuid.uuid4().hex[:6]
        hashed = subprocess.run(["openssl", "passwd", "-6", password], check=True, capture_output=True,
                                text=True).stdout.strip()
        others = "awk -F: -v u=%s '$1 != u && $2 !~ /^[!*]/' /etc/shadow" % TEST_OWNER
        locked = f"getent shadow {TEST_OWNER} | cut -d: -f2 | grep -q '^!'"
        self.vm.run(locked)
        self.vm.run(f"umask 077 && printf '%s\\n' '{hashed}' > /data/ironflockos/.console-password.partial"
                    " && mv /data/ironflockos/.console-password.partial /data/ironflockos/console-password")
        self.wait_for(f"[ \"$(getent shadow {TEST_OWNER} | cut -d: -f2)\" = '{hashed}' ]", 60,
                      "the console password to be applied")
        if self.vm.run(others).strip():
            raise TestFailure(f"another account has a password: {self.vm.run(others)}")
        self.vm.run("test \"$(getent shadow root | cut -d: -f2)\" = '*'")
        for user in (TEST_OWNER, "root"):
            conf = self.vm.run(f"sshd -T -C user={user},host=localhost,addr=127.0.0.1")
            for want in ("passwordauthentication no", "kbdinteractiveauthentication no"):
                if want not in conf.splitlines():
                    raise TestFailure(f"sshd does not say {want!r} for {user}")
        # A person at the screen logs in on tty2.
        self.type_line(TEST_OWNER)
        time.sleep(2)
        self.type_line(password)
        self.wait_for(f"loginctl list-sessions --no-legend | grep -E ' {TEST_OWNER} .*tty2'", 60,
                      f"{TEST_OWNER} to log in on tty2 with the console password")
        self.vm.run(f"loginctl terminate-user {TEST_OWNER}")
        self.vm.run("rm /data/ironflockos/console-password")
        self.wait_for(locked, 60, "the password to be locked again")

    def fsck_repair(self):
        """A filesystem that a preen gives up on is repaired at boot
        (ADR-0020): fsck.repair=yes is on the kernel command line, and
        systemd-fsck, the program the boot runs for /data and the IRONFLOCKOS
        partition, takes it from there. Tried on a small filesystem of the
        test's own with an illegal block number in a file, which `e2fsck -p`
        refuses."""
        if "fsck.repair=yes" not in self.vm.run("cat /proc/cmdline").split():
            raise TestFailure("fsck.repair=yes is not on the kernel command line")
        out = self.vm.run(
            "d=$(mktemp -d /run/ironflockos-fsck.XXXXXX) && cd \"$d\" && truncate -s 16M fs.img && "
            "mkfs.ext4 -q -F fs.img && debugfs -w -R 'write /etc/hostname victim' fs.img >/dev/null 2>&1 && "
            "debugfs -w -R 'sif victim block[0] 4000000000' fs.img >/dev/null 2>&1 && "
            "debugfs -w -R 'ssv state 2' fs.img >/dev/null 2>&1 && cp fs.img control.img; "
            "e2fsck -p control.img >/dev/null 2>&1; echo preen=$?; "
            "dev=$(losetup --find --show fs.img) && udevadm settle && "
            "{ /usr/lib/systemd/systemd-fsck \"$dev\" >/dev/null 2>&1; echo boot=$?; "
            "e2fsck -fn \"$dev\" >/dev/null 2>&1; echo after=$?; losetup -d \"$dev\"; }; "
            "cd / && rm -rf \"$d\"", timeout=120, check=False)
        got = dict(line.split("=", 1) for line in out.split() if "=" in line)
        if not got.get("preen", "").isdigit() or not int(got["preen"]) & 4:
            raise TestFailure(f"the test's damage is not one a preen refuses:\n{out}")
        if got.get("boot") != "0" or got.get("after") != "0":
            raise TestFailure(f"systemd-fsck did not repair the filesystem:\n{out}")

    def time_sync(self):
        """Time (docs/build.md, "Time"): chrony instead of systemd-timesyncd.
        A ptp.conf that names the NIC gives chrony a PTP source and starts
        ptp4l and phc2sys; role=server makes ptp4l a master and takes the
        source away; removing the file stops them. QEMU's NIC has no hardware
        time stamps, so ptp4l cannot run PTP here: this checks the wiring,
        PTP itself is a hardware check."""
        for unit in ("chrony.service", "ironflockos-ptp.service", "ironflockos-ptp.path"):
            state = self.vm.run(f"systemctl is-active {unit}", check=False).strip()
            if state != "active":
                info = self.vm.run(f"systemctl status --no-pager -l {unit}; "
                                   f"journalctl -b --no-pager -u {unit} | tail -30; "
                                   "systemctl list-units --no-pager --all 'chrony*' timemaster.service", check=False)
                raise TestFailure(f"{unit} is {state}:\n{info}")
        # The first boot's presets enabled nothing that takes chrony's place
        # (10-ironflockos-time.preset).
        for unit in ("chronyd-restricted.service", "timemaster.service", "chrony-wait.service"):
            self.vm.run(f"! systemctl -q is-enabled {unit}")
        self.vm.run("test ! -e /usr/lib/systemd/system/systemd-timesyncd.service")
        self.vm.run("chronyc -n tracking")
        self.vm.run("test -L /etc/ironflockos/ptp.conf")
        nic = self.vm.run("ip -o route show default | awk '{print $5; exit}'").strip()
        if not nic:
            raise TestFailure("no default route to name as the PTP interface")
        self.vm.run(f"printf 'interface={nic}\\ndomain=24\\n' > /data/ironflockos/ptp.conf")
        self.wait_for("chronyc -n sources | grep -q '^#. PTP '", 60, "chrony's PTP source")
        self.vm.run(f"grep -qx '\\[{nic}\\]' /run/ironflockos/ptp/ptp4l.conf")
        self.vm.run("grep -qx 'domainNumber 24' /run/ironflockos/ptp/ptp4l.conf")
        for unit in ("ironflockos-ptp4l.service", "ironflockos-phc2sys.service"):
            started = self.vm.run(f"systemctl show --no-pager -p InvocationID --value {unit}").strip()
            if not started:
                raise TestFailure(f"{unit} did not start for ptp.conf")
        # role=server: master on the interface, from the system clock; chrony
        # keeps NTP only.
        self.vm.run(f"printf 'interface={nic}\\nrole=server\\npriority1=10\\n' > /data/ironflockos/ptp.conf")
        self.wait_for("grep -qx 'serverOnly 1' /run/ironflockos/ptp/ptp4l.conf", 60, "ptp4l's server settings")
        self.vm.run("grep -qx 'priority1 10' /run/ironflockos/ptp/ptp4l.conf")
        self.wait_for("chronyc -n sources >/dev/null && ! chronyc -n sources | grep -q '^#. PTP '", 60,
                      "chrony to drop the PTP source of a server")
        self.vm.run("rm /data/ironflockos/ptp.conf")
        self.wait_for("test ! -e /run/ironflockos/ptp/ptp4l.conf", 60, "the PTP settings to go")
        self.wait_for("! systemctl -q is-active ironflockos-ptp4l.service ironflockos-phc2sys.service", 60,
                      "ptp4l and phc2sys to stop")
        # ptp4l failed on the NIC without hardware time stamps, as expected.
        self.vm.run("systemctl reset-failed ironflockos-ptp4l.service ironflockos-phc2sys.service 2>/dev/null || true")

    def proxy(self):
        """Proxy (docs/build.md, "Proxy"): a proxy.conf reaches Docker (its
        info names the proxy and NO_PROXY), the agent's environment while it
        runs, and chrony (ntp=). Nothing listens on the proxy address, so
        this checks the wiring; the hardware checklist uses a real proxy. A
        proxy.conf on the IRONFLOCKOS partition is taken over at the next boot
        (checked in reboot_persists)."""
        for unit in ("ironflockos-proxy.service", "ironflockos-proxy.path"):
            self.vm.run(f"systemctl is-active {unit}")
        self.vm.run("test -L /etc/ironflockos/proxy.conf")
        if self.vm.run("docker info --format '{{.HTTPProxy}}'").strip():
            raise TestFailure("Docker has a proxy before any proxy.conf")
        self.vm.run("printf 'http_proxy=http://10.0.2.2:3128\\nno_proxy=registry.example\\nntp=10.0.2.2\\n'"
                    " > /data/ironflockos/proxy.conf")
        self.wait_for("[ \"$(docker info --format '{{.HTTPSProxy}}')\" = http://10.0.2.2:3128 ]", 120,
                      "Docker to take the proxy")
        no_proxy = self.vm.run("docker info --format '{{.NoProxy}}'").strip().split(",")
        for want in ("localhost", "127.0.0.1", "registry.example"):
            if want not in no_proxy:
                raise TestFailure(f"Docker's NO_PROXY lacks {want}: {no_proxy}")
        self.vm.run("test \"$(stat -c %a /run/ironflockos/proxy.env)\" = 600")
        self.wait_for("chronyc -n sources | grep -q ' 10\\.0\\.2\\.2 '", 60, "chrony's NTP server from proxy.conf")
        # The agent runs on an enrolled slot; it gets the proxy when it restarts.
        self.wait_for("pid=$(systemctl show --no-pager -p MainPID --value ironflock-device-agent.service); "
                      "[ \"${pid:-0}\" = 0 ] || tr '\\0' '\\n' </proc/$pid/environ | "
                      "grep -qx HTTPS_PROXY=http://10.0.2.2:3128", 60, "the agent to take the proxy")
        # For the next boot: the IRONFLOCKOS partition's proxy.conf replaces the device's.
        self.vm.run("printf 'http_proxy=http://10.0.2.2:3129\\n' > /boot/efi/proxy.conf")
        self.proxy_seeded = True

    def network_profile(self):
        """Network profiles from the IRONFLOCKOS partition (ADR-0016, docs/build.md
        "Network profiles"): a profile for a static address goes to the
        partition's network/ folder as `ironflock os install` writes one: the
        address, gateway and DNS server the VM has now, on the card matched by
        its MAC address. The next boot takes it (checked in reboot_persists).
        QEMU's user network hands out the same address by DHCP, so the device
        stays reachable either way; the profile is what tells them apart."""
        self.vm.run("systemctl is-enabled ironflockos-network-profiles.service")
        # ip colours what it writes to a terminal, and the test shell is one:
        # through a pipe it does not.
        route = self.vm.run("ip -o -4 route show default | cat").split()
        if len(route) < 5 or route[0] != "default" or route[1] != "via" or route[3] != "dev":
            raise TestFailure(f"no default route to copy: {' '.join(route)}")
        gateway, nic = route[2], route[4]
        mac = self.vm.run(f"cat /sys/class/net/{nic}/address").strip()
        address = self.vm.run(f"ip -o -4 addr show dev {nic} | awk '{{print $4; exit}}'").strip()
        dns = self.vm.run(f"nmcli -g IP4.DNS device show {nic}").split("|")[0].strip()
        if not re.fullmatch(r"[0-9.]+/[0-9]+", address) or not dns:
            raise TestFailure(f"{nic} has no IPv4 address or DNS server to copy: {address!r}, {dns!r}")
        profile = (f"[connection]\nid={STATIC_PROFILE}\nuuid={uuid.uuid4()}\ntype=ethernet\n\n"
                   f"[ethernet]\nmac-address={mac}\n\n"
                   f"[ipv4]\nmethod=manual\naddress1={address}\ngateway={gateway}\ndns={dns};\n\n"
                   "[ipv6]\nmethod=disabled\n")
        data = base64.b64encode(profile.encode()).decode()
        path = f"/boot/efi/network/{STATIC_PROFILE}.nmconnection"
        self.vm.run(f"mkdir -p /boot/efi/network && echo {data} | base64 -d > {path} && sync")
        self.vm.run(f"/usr/lib/ironflockos/network-profiles check {path}")
        self.profile_seeded = (nic, address, gateway)

    def enrolled(self, first, owner=TEST_OWNER, name=TEST_FLOCK_NAME, flock=None):
        """The slot is enrolled from the test .flock: SSH user, sudo rule,
        the agent's unit; on the first boot the .flock left the IRONFLOCKOS
        partition for the agent's 0600 copy."""
        self.vm.run(f"id {owner}")
        self.vm.run(f"test -f /etc/sudoers.d/ironflock-{owner}")
        self.vm.run(f"grep -q ironflock-device- /home/{owner}/.ssh/authorized_keys")
        self.vm.run("systemctl is-enabled ironflock-device-agent.service")
        self.vm.run("test -s /var/lib/ironflockos/enrolled")
        hostname = self.vm.run("hostname").strip()
        if hostname != name:
            raise TestFailure(f"the hostname is {hostname!r}, not the .flock's name {name!r}")
        self.vm.run("test -L /etc/ironflockos/enroll.conf")
        mode = self.vm.run("stat -c %a /opt/ironflock/device-agent/device-config.flock").strip()
        if mode != "600":
            raise TestFailure(f"the agent's .flock copy has mode {mode}")
        if first:
            self.vm.run(f"test ! -e /boot/efi/{flock or self.flock}")

    def exit_code(self, command, timeout=120):
        """The exit code of command and what it wrote (stdout and stderr, through
        a file: no terminal)."""
        out = "/run/ironflockos-ci-out"
        lines = self.vm.run(f"{command} >{out} 2>&1; rc=$?; cat {out}; rm -f {out}; echo __rc=$rc",
                            timeout=timeout, check=False).rstrip().splitlines()
        if not lines or not lines[-1].startswith("__rc="):
            raise TestFailure(f"no exit code from `{command}`:\n{lines}")
        return int(lines[-1][len("__rc="):]), "\n".join(lines[:-1])

    def device_state(self):
        """What the refused commands must leave as it is: the agent's .flock and
        unit, the accounts, the sudo rules, the hostname."""
        return self.vm.run("sha256sum /opt/ironflock/device-agent/device-config.flock 2>&1; "
                           "systemctl is-enabled ironflock-device-agent.service 2>&1; "
                           "cut -d: -f1 /etc/passwd | sort | sha256sum; ls /etc/sudoers.d; hostname", check=False)

    def ironflock_cli(self):
        """WP-5.1 of the CLI's plan: the image carries ironflock (IronFlock/ironflock-cli) as
        /usr/bin/ironflock, nothing named ironflock-init, and image.json names
        its version. `ironflock status --json` describes this device. The agent
        commands IronFlockOS has no use for refuse (exit code 3) and change
        nothing, as root and not. `ironflock enroll` does not accept a .flock
        that is not JSON (exit code 4) and leaves it where it is. Enrolled: such
        a .flock, the newest on the IRONFLOCKOS partition, is kept as .rejected
        and the enrolment takes the agent's copy; agent configure -c refuses
        while a factory reset is requested, and with a proxy flag."""
        where = self.vm.run("command -v ironflock").strip()
        if where != "/usr/bin/ironflock":
            raise TestFailure(f"ironflock is {where!r}, not /usr/bin/ironflock")
        self.vm.run("test ! -e /usr/sbin/ironflock-init && ! find / -xdev -name '*ironflock-init*' | grep .", timeout=300)
        image = json.loads(self.vm.run("cat /usr/lib/ironflock/image.json"))
        version = self.vm.run("ironflock version </dev/null 2>/dev/null | cat").split()
        if "init_version" in image or version[:1] != ["ironflock"] or version[1:2] != [image.get("ironflock_version")]:
            raise TestFailure(f"ironflock version says {' '.join(version)!r}; image.json: {image}")

        osr = self.vm.run("cat /etc/os-release").splitlines()
        image_version = next((line.split("=", 1)[1].strip('"') for line in osr if line.startswith("IMAGE_VERSION=")), None)
        status = json.loads(self.vm.run("ironflock status --json </dev/null 2>/dev/null | cat"))
        system, agent = status.get("os") or {}, status.get("agent") or {}
        want = {"ironflockos": True, "image": self.image_id, "version": image_version, "booted_slot": self.booted()}
        got = {key: system.get(key) for key in want}
        if got != want:
            raise TestFailure(f"ironflock status: the system is {got}, expected {want}:\n{status}")
        if self.flock:
            # The test's agent never reaches a platform: whether it runs just
            # now is not this test's; that ironflock finds its unit is.
            service = agent.get("service") or {}
            if (not agent.get("installed") or agent.get("layout") != "current" or agent.get("device") != TEST_FLOCK_NAME
                    or not agent.get("version") or service.get("unit") != "ironflock-device-agent.service"
                    or service.get("state") not in ("running", "starting", "stopping", "stopped", "failed")):
                raise TestFailure(f"ironflock status: the agent of an enrolled device is {agent}")
        elif agent.get("installed"):
            raise TestFailure(f"ironflock status: the agent of a device that did not enroll is {agent}")

        other = "/tmp/ironflockos-ci-other.flock"
        data = base64.b64encode(json.dumps(test_flock(OTHER_FLOCK_NAME, OTHER_OWNER, "4713")).encode()).decode()
        self.vm.run(f"echo {data} | base64 -d > {other} && chmod 644 {other}")
        before = self.device_state()
        for user in ("", "runuser -u nobody -- "):
            for command in (f"/usr/bin/ironflock agent install -c {other} --yes", "/usr/bin/ironflock agent remove --yes"):
                rc, out = self.exit_code(f"{user}{command} </dev/null")
                if rc != 3 or f"this device runs IronFlockOS {image_version} ({self.image_id})" not in out:
                    raise TestFailure(f"`{user}{command}` ended with {rc}, expected 3 and IronFlockOS named:\n{out}")
        self.vm.run(f"rm -f {other}")

        broken = "/boot/efi/ironflockos-ci-broken.flock"
        self.vm.run(f"printf 'not json' > {broken} && sync")
        rc, out = self.exit_code(f"ironflock enroll -c {broken} --shred-source </dev/null")
        if rc != 4 or self.exit_code(f"test -f {broken}")[0] != 0:
            raise TestFailure(f"ironflock enroll with a .flock that is not JSON ended with {rc}, expected 4, "
                              f"and the file there:\n{out}")
        if self.device_state() != before:
            raise TestFailure(f"a refused command changed the device:\n{before}\n{self.device_state()}")
        if not self.flock:
            self.vm.run(f"rm -f {broken} && sync")
            return

        # The enrolment with it as the newest .flock on the partition: kept as
        # .rejected, the agent's copy taken instead.
        rc, out = self.exit_code("systemctl start ironflockos-enroll.service", timeout=600)
        if rc != 0:
            raise TestFailure(f"the enrolment with a .flock that is not accepted failed:\n{out}\n"
                              f"{self.explain('ironflockos-enroll.service')}")
        self.vm.run(f"test -f {broken}.rejected && test ! -e {broken}")
        journal = self.vm.run("journalctl -b --no-pager -o cat -u ironflockos-enroll.service")
        for want in ("kept as ironflockos-ci-broken.flock.rejected", "enrolled from device-config.flock"):
            if want not in journal:
                raise TestFailure(f"the enrolment's journal lacks {want!r}:\n{journal}")
        self.enrolled(first=False)
        self.vm.run(f"rm -f {broken}.rejected && sync")

        first = "/root/ironflockos-ci-first.flock"
        self.vm.run(f"install -m 600 /opt/ironflock/device-agent/device-config.flock {first}")
        before = self.device_state()
        self.vm.run("printf 'keep-network=yes\\n' > /boot/efi/factory-reset.conf && sync")
        try:
            rc, out = self.exit_code(f"ironflock agent configure -c {first} </dev/null")
        finally:
            self.vm.run("rm -f /boot/efi/factory-reset.conf && sync")
        if rc != 3 or "factory reset is requested" not in out:
            raise TestFailure(f"agent configure -c with a factory reset requested ended with {rc}, expected 3:\n{out}")
        rc, out = self.exit_code(f"ironflock agent configure -c {first} --https-proxy http://10.0.2.2:3129 </dev/null")
        if rc != 3:
            raise TestFailure(f"agent configure -c --https-proxy ended with {rc}, expected 3:\n{out}")
        if self.device_state() != before:
            raise TestFailure(f"a refused agent configure changed the device:\n{before}\n{self.device_state()}")
        self.vm.run(f"rm -f {first}")

    def change_hands(self):
        """The device changes hands as the platform's device terminal would do
        it: the first owner, logged in over SSH, runs `sudo ironflock agent
        configure -c` with the .flock of another owner. The device enrolls as
        the other device (the agent's copy, the hostname, the other owner's
        account and sudo rule) and the first owner's account and sudo rule go,
        with its sessions, the one that runs the command among them: the
        command finishes all the same. Then back, as root, for the rest of the
        test. The device key in a .flock is PKCS#8, which ssh does not read: the
        login uses a key of the test's own, added for the first owner."""
        first, other = "/root/ironflockos-ci-first.flock", "/root/ironflockos-ci-other.flock"
        key = "/root/ironflockos-ci-ssh"
        data = base64.b64encode(json.dumps(test_flock(OTHER_FLOCK_NAME, OTHER_OWNER, "4713")).encode()).decode()
        self.vm.run(f"install -m 600 /opt/ironflock/device-agent/device-config.flock {first}")
        self.vm.run(f"echo {data} | base64 -d > {other} && chmod 600 {other}")
        self.vm.run(f"rm -f {key} {key}.pub && ssh-keygen -q -t ed25519 -N '' -f {key}")
        self.vm.run(f"cat {key}.pub >> /home/{TEST_OWNER}/.ssh/authorized_keys")
        ssh = (f"timeout 300 ssh -F /dev/null -i {key} -o BatchMode=yes -o StrictHostKeyChecking=no "
               f"-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR {TEST_OWNER}@127.0.0.1")
        out = self.vm.run(f"{ssh} 'id -un && sudo -n true && echo sudo-ok' </dev/null", timeout=120)
        if f"{TEST_OWNER}\n" not in out or "sudo-ok" not in out:
            raise TestFailure(f"the first owner's SSH login with sudo:\n{out}")
        rc, out = self.exit_code(f"{ssh} 'sudo -n /usr/bin/ironflock agent configure -c {other} --yes' </dev/null",
                                 timeout=360)
        log(f"change hands: the first owner's session ended with exit code {rc}:\n{out}")
        changed = (f"! id {TEST_OWNER} && id {OTHER_OWNER} && test -f /etc/sudoers.d/ironflock-{OTHER_OWNER}"
                   f" && test ! -e /etc/sudoers.d/ironflock-{TEST_OWNER} && [ \"$(hostname)\" = {OTHER_FLOCK_NAME} ]"
                   f" && grep -q ironflock-device-4713 /home/{OTHER_OWNER}/.ssh/authorized_keys")
        try:
            self.wait_for(changed, 300, "the device to change hands")
        except TestFailure as e:
            raise TestFailure(f"{e}\n{self.vm.run('journalctl -b --no-pager -o cat -n 80; ' + changed, check=False)}") from None
        copy = json.loads(self.vm.run("cat /opt/ironflock/device-agent/device-config.flock"))
        if copy.get("device_key") != "4713" or copy.get("name") != OTHER_FLOCK_NAME:
            raise TestFailure(f"the agent's .flock is not the other device's: device_key {copy.get('device_key')!r}")
        self.vm.run("systemctl is-enabled ironflock-device-agent.service")

        rc, out = self.exit_code(f"ironflock agent configure -c {first} --yes </dev/null", timeout=300)
        if rc != 0:
            raise TestFailure(f"agent configure -c back to the first device ended with {rc}:\n{out}")
        self.vm.run(f"! id {OTHER_OWNER} && test ! -e /etc/sudoers.d/ironflock-{OTHER_OWNER}")
        self.enrolled(first=False)
        self.vm.run(f"rm -f {first} {other} {key} {key}.pub")

    def nvidia(self):
        """An nvidia image (WP-4.1) on a VM without a GPU: the driver and the
        open modules at the pinned version, built for the image's kernel; no
        compiler, DKMS or headers left; nouveau blacklisted in the initramfs;
        the nvidia runtime in Docker; nothing of NVIDIA's runs, so nothing
        fails (wait_running checked that)."""
        nv = load_conf(os.path.join(REPO, "profiles", "nvidia", "versions"))
        driver = nv["NVIDIA_DRIVER_VERSION"]
        modver = driver.rsplit("-", 1)[0]
        got = self.vm.run("modinfo -F version nvidia").strip()
        if got != modver:
            raise TestFailure(f"the nvidia module is version {got!r}, not {modver}")
        kver = self.vm.run("uname -r").strip()
        vermagic = self.vm.run("modinfo -F vermagic nvidia").split()
        if not vermagic or vermagic[0] != kver:
            raise TestFailure(f"the nvidia module is built for {vermagic[:1]}, the kernel is {kver}")
        want = {"nvidia-driver-cuda": driver, "ironflockos-nvidia-modules": driver, "firmware-nvidia-gsp": driver,
                "nvidia-container-toolkit": nv["NVIDIA_CONTAINER_TOOLKIT_VERSION"]}
        out = self.vm.run("dpkg-query -W -f '${Package} ${Version}\\n' " + " ".join(want))
        have = dict(line.split() for line in out.splitlines() if len(line.split()) == 2)
        for pkg, ver in want.items():
            if have.get(pkg) != ver:
                raise TestFailure(f"{pkg} is {have.get(pkg)!r}, not {ver}")
        self.vm.run("for t in cc gcc g++ make dkms; do if command -v $t; then exit 1; fi; done")
        self.vm.run("test ! -e /var/lib/dkms && ! ls -d /usr/src/linux-headers-* /usr/src/nvidia-* 2>/dev/null")
        self.vm.run("test -x /usr/bin/nvidia-smi && test -x /usr/bin/nvidia-container-runtime")
        self.vm.run(f"test -n \"$(ls /lib/firmware/nvidia/{modver}/gsp_*.bin)\"")
        self.vm.run("modprobe -c | grep -qx 'blacklist nouveau'")
        self.vm.run("lsinitramfs /initrd.img | grep -q 'etc/modprobe.d/nvidia.conf'", timeout=180)
        self.vm.run("! lsmod | grep -qE '^(nvidia|nouveau) '")
        self.vm.run("! systemctl -q is-enabled nvidia-persistenced.service nvidia-powerd.service")
        runtimes = self.vm.run("docker info --format '{{json .Runtimes}}'")
        if '"nvidia"' not in runtimes:
            raise TestFailure(f"Docker has no nvidia runtime: {runtimes}")
        self.vm.run("nvidia-ctk --version && nvidia-container-cli --version")

    def reboot_persists(self):
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if getattr(self, "rt_pending", False):
            cmdline = self.vm.run("cat /proc/cmdline")
            for want in ("isolcpus=managed_irq,domain,1", "nohz_full=1", "irqaffinity=0"):
                if want not in cmdline:
                    raise TestFailure(f"{want} is not on the kernel command line after the reboot: {cmdline}")
        if self.vm.run("cat /etc/machine-id").strip() != self.machine_id:
            raise TestFailure("machine-id changed across a reboot")
        if self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip() != self.host_key:
            raise TestFailure("the SSH host key changed across a reboot")
        boots = self.vm.run("journalctl --list-boots --no-pager | grep -cE '^ *-?[0-9]+ '").strip()
        if int(boots) < 2:
            raise TestFailure(f"the journal is not persistent ({boots} boot)")
        if self.booted() != "A":
            raise TestFailure("not on slot A after a plain reboot")
        if getattr(self, "proxy_seeded", False):
            self.vm.run("test ! -e /boot/efi/proxy.conf")
            self.vm.run("grep -qx 'http_proxy=http://10.0.2.2:3129' /data/ironflockos/proxy.conf")
            self.vm.run("test \"$(stat -c %a /data/ironflockos/proxy.conf)\" = 600")
            proxy = self.vm.run("docker info --format '{{.HTTPSProxy}}'").strip()
            if proxy != "http://10.0.2.2:3129":
                raise TestFailure(f"Docker's proxy after the boot with a IRONFLOCKOS proxy.conf is {proxy!r}")
            # No proxy for the rest of the test: the update downloads directly.
            self.vm.run("rm /data/ironflockos/proxy.conf")
            self.wait_for("[ -z \"$(docker info --format '{{.HTTPSProxy}}')\" ]", 120, "Docker to drop the proxy")
        # The app's data of the first boot: /apps is on /data.
        self.apps_on_data()
        self.vm.run("grep -qx ironflockos-test /apps/prod/ironflockos-test/data.txt")
        if getattr(self, "profile_seeded", None):
            try:
                self.static_profile_taken()
            except TestFailure as e:
                units = ("ironflockos-network-profiles.service", "ironflockos-network-profiles-trial.service",
                         "NetworkManager.service")
                raise TestFailure(f"{e}\n{self.explain(*units)}") from None

    def static_profile_taken(self):
        """The static profile of network_profile, after the reboot: taken,
        brought up by NetworkManager, on trial, and kept by the trial."""
        nic, address, gateway = self.profile_seeded
        name = f"{STATIC_PROFILE}.nmconnection"
        self.vm.run(f"test ! -e /boot/efi/network/{name}")
        self.vm.run(f"test \"$(stat -c '%a %U' /data/network/connections/{name})\" = '600 root'")
        self.vm.run("journalctl -b --no-pager -o cat -u ironflockos-network-profiles"
                    f" | grep -q 'took {name} (ethernet)'")
        # NetworkManager runs the card on the profile: the address without
        # DHCP's "dynamic", the gateway, and the host stays reachable (the
        # update downloads from it).
        self.wait_for(f"[ \"$(nmcli -g GENERAL.CONNECTION device show {nic})\" = {STATIC_PROFILE} ]", 60,
                      "NetworkManager to bring up the static profile")
        addr = self.vm.run(f"ip -o -4 addr show dev {nic} | cat")
        if f" {address} " not in addr or "dynamic" in addr:
            raise TestFailure(f"{nic} does not have the static address {address}:\n{addr}")
        self.vm.run(f"ip -o -4 route show default | grep -q '^default via {gateway} dev {nic} '")
        self.vm.run(f"curl -fsS -o /dev/null {self.http}/")
        # The profile is on trial (ADR-0016, section 10): the device it
        # replaced nothing on goes back to no profile after 15 minutes
        # unless the agent connects. The test .flock's agent never does,
        # so the test leaves its mark of a connection, and the trial ends
        # with the profile kept, before the update needs the network.
        self.vm.run("systemctl is-active ironflockos-network-profiles-trial.service")
        self.vm.run(f"test -e /data/network/trial/new/{name} && grep -qx phase=new /data/network/trial/state")
        # Written again at every look: a restart of the agent's unit
        # empties its folder.
        self.wait_for("mkdir -p /run/ironflock-device-agent && echo test >/run/ironflock-device-agent/connected"
                      " && test ! -e /data/network/trial", 150, "the trial to keep the profile")
        self.vm.run(f"test -e /data/network/connections/{name}")
        self.vm.run("journalctl -b --no-pager -o cat -u ironflockos-network-profiles-trial"
                    " | grep -q 'the profiles from the IRONFLOCKOS partition stay'")

    def fetch_bundle(self):
        self.vm.run(f"curl -fsS -o {TEST_BUNDLE} {self.http}/bundle.raucb", timeout=600)

    def install_bundle(self):
        self.fetch_bundle()
        out = self.vm.run(f"rauc install {TEST_BUNDLE}", timeout=900)
        self.vm.run(f"rm -f {TEST_BUNDLE}")
        return out

    def update_to_b(self):
        """The update into slot B, as before, with `ironflock os` around it
        (WP-5.2, WP-5.3 of the CLI's plan): while RAUC writes slot B, `os
        rollback` and `os update` refuse (exit code 3) and say that RAUC
        installs; once it is installed and waits for the restart, `os rollback`
        refuses that too and changes nothing."""
        self.os_while_installing()
        primary = self.rauc_status().get("boot_primary")
        if primary != "rootfs.1":
            raise TestFailure(f"after the install the primary slot is {primary}, expected rootfs.1")
        self.snapshot("pending")
        upcoming = self.rollback_refused("pending", "chosen to start with the next restart")
        if upcoming != "B":
            raise TestFailure(f"with the update installed, GRUB would start slot {upcoming}, not B")
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()} after the update, expected B")
        if self.vm.run("cat /etc/machine-id").strip() != self.machine_id:
            raise TestFailure("machine-id changed with the update")
        self.vm.run("grep -qx ironflockos-test /data/ironflockos-test-marker")
        # The app's data of slot A is there in slot B: /apps is on /data.
        self.apps_on_data()
        self.vm.run("grep -qx ironflockos-test /apps/prod/ironflockos-test/data.txt")
        if self.flock:
            self.enrolled(first=False)
        if self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip() != self.host_key:
            raise TestFailure("the SSH host key changed with the update")
        self.mark_good("B", "rootfs.1")
        self.wait_for("test -e /var/lib/ironflockos/slot-proven", 60, "slot B to remember it was marked good")
        # The device's own splash outlives the update: splash.cpio is on the
        # IRONFLOCKOS partition, and slot B's ironflockos-splash makes the same.
        if getattr(self, "splash_archive", None):
            self.vm.run("! systemctl -q is-failed ironflockos-splash.service")
            if self.vm.run(f"cksum < {self.ARCHIVE}").strip() != self.splash_archive:
                raise TestFailure("the device's splash.cpio changed with the update")
        self.snapshot("updated")

    # --- ironflock os: update and rollback (WP-5.2, WP-5.3 of the CLI's plan) --
    #
    # The captures (keep) are what the CLI's fixtures can take over
    # (cli/ironflockos/testdata/<state>/ in IronFlock/ironflock-cli): one file
    # per command, <NN>-<state>--<name>.json with the command line as the
    # fixtures key it (its words joined by spaces), its exit code, stdout and
    # stderr; and the files ironflock reads, as they are.

    def keep(self, state, name, data):
        """Keeps data as captured/<NN>-<state>--<name>."""
        if not self.captured:
            return
        os.makedirs(self.captured, exist_ok=True)
        self.kept += 1
        with open(os.path.join(self.captured, f"{self.kept:02d}-{state}--{name}"), "wb") as fh:
            fh.write(data if isinstance(data, bytes) else data.encode())

    @staticmethod
    def capture_snippet(argv, prefix):
        """The shell line that runs argv without a terminal and leaves its
        stdout, stderr and exit code in prefix.1, prefix.2 and prefix.rc."""
        line = " ".join(shlex.quote(a) for a in argv)
        return f"{line} >{prefix}.1 2>{prefix}.2 </dev/null; echo $? >{prefix}.rc"

    def collect(self, state, name, argv, prefix):
        """What capture_snippet left at prefix: kept, and returned as (exit code,
        stdout, stderr); the exit code is None when none was written."""
        lines = self.vm.run(f"cat {prefix}.rc 2>/dev/null || echo none; base64 -w0 {prefix}.1 2>/dev/null; echo; "
                            f"base64 -w0 {prefix}.2 2>/dev/null; echo").splitlines()
        if len(lines) < 3 or not (lines[-3].strip().isdigit() or lines[-3].strip() == "none"):
            raise TestFailure(f"no exit code and output of `{' '.join(argv)}` in {prefix}.*:\n{lines}")
        rc = int(lines[-3]) if lines[-3].strip().isdigit() else None
        out, err = (base64.b64decode(x.strip()).decode("utf-8", "replace") for x in lines[-2:])
        self.keep(state, f"{name}.json", json.dumps({"command": " ".join(argv), "exit": rc, "stdout": out,
                                                     "stderr": err}, indent=2) + "\n")
        return rc, out, err

    def capture(self, state, name, argv, timeout=120):
        """Runs argv in the VM as root, without a terminal and with an empty
        stdin, keeps what it printed and returns (exit code, stdout, stderr)."""
        prefix = "/run/ironflockos-ci-capture"
        self.vm.run(self.capture_snippet(argv, prefix), timeout=timeout)
        try:
            return self.collect(state, name, argv, prefix)
        finally:
            self.vm.run(f"rm -f {prefix}.*")

    def capture_file(self, state, name, path):
        data = base64.b64decode(self.vm.run(f"base64 -w0 {path}").strip())
        self.keep(state, name, data)
        return data

    def json_result(self, stdout, what):
        """The result of a command run with --json: the JSON object on the last
        line of stdout. Other lines there are not the contract's (docs/cli.md:
        stdout carries the result and nothing else); they are logged, not
        judged."""
        lines = [line for line in stdout.splitlines() if line.strip()]
        if not lines:
            raise TestFailure(f"`{what}` wrote no result on stdout")
        if len(lines) > 1:
            log(f"note: stdout of `{what}` carries more than its JSON result: {lines[:-1]}")
        try:
            result = json.loads(lines[-1])
        except ValueError:
            result = None
        if not isinstance(result, dict):
            raise TestFailure(f"the last line on stdout of `{what}` is no JSON object: {lines[-1]!r}")
        return result

    def failure(self, argv, rc, out, err, kind):
        """The message of a command that failed: stderr's, or with --json the
        error object's on stdout, which must be of this kind."""
        if "--json" not in argv:
            return err
        error = self.json_result(out, " ".join(argv)).get("error")
        if not isinstance(error, dict) or error.get("kind") != kind:
            raise TestFailure(f"`{' '.join(argv)}` ended with {rc} without an error of the kind {kind}:\n{out}{err}")
        return str(error.get("message"))

    def grubenv(self):
        out = self.vm.run(f"grub-editenv {GRUBENV} list")
        return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)

    def slots_state(self):
        """What a refused `ironflock os` command must leave as it was: GRUB's
        environment and RAUC's view of the slots."""
        return self.grubenv(), json.loads(self.vm.run(" ".join(RAUC_STATUS) + " 2>/dev/null"))

    def snapshot(self, state):
        """What ironflock reads of the slots in this state, kept: RAUC's status
        as ironflock asks for it, grubenv, and on slot B the image's version in
        slot A, read with debugfs as ironflock reads it; then `ironflock status
        --json`, whose result it returns."""
        rc, out, err = self.capture(state, "rauc-status", RAUC_STATUS)
        if rc != 0:
            raise TestFailure(f"`{' '.join(RAUC_STATUS)}` ended with {rc}:\n{err}")
        self.capture_file(state, "grubenv", GRUBENV)
        if json.loads(out).get("booted") == "B":
            self.capture(state, "debugfs-rootfs-a-os-release",
                         ["debugfs", "-c", "-R", "cat /usr/lib/os-release", "/dev/disk/by-partlabel/rootfs-a"])
        argv = ["ironflock", "status", "--json"]
        _, out, _ = self.capture(state, "ironflock-status-json", argv)
        return self.json_result(out, " ".join(argv))

    def image_version(self):
        osr = self.vm.run("cat /etc/os-release").splitlines()
        return next((line.split("=", 1)[1].strip('"') for line in osr if line.startswith("IMAGE_VERSION=")), None)

    def rollback_refused(self, state, reason):
        """`ironflock os rollback --yes` refuses in this state, as text and with
        --json: exit code 3 and the reason docs/cli.md gives. It changes
        nothing: GRUB's environment and RAUC's slots are as they were, so the
        device starts what it would have started. Returns that slot."""
        before = self.slots_state()
        for name, argv in (("ironflock-os-rollback", ["ironflock", "os", "rollback", "--yes"]),
                           ("ironflock-os-rollback-json", ["ironflock", "os", "rollback", "--yes", "--json"])):
            rc, out, err = self.capture(state, name, argv)
            if rc != 3 or reason not in self.failure(argv, rc, out, err, "precondition"):
                raise TestFailure(f"`{' '.join(argv)}` ended with {rc}, expected 3 and {reason!r}:\n{out}{err}")
        after = self.slots_state()
        if after != before:
            raise TestFailure(f"a refused os rollback changed the slots:\nbefore: {before}\nafter: {after}")
        return grub_next(after[0])

    def update_refused(self, state):
        """`ironflock os update --yes --download-base <the test host>` reads the
        test catalog (put_test_catalog), which names a release above this
        build with this build's bundle and is signed with the run's key. The
        image's ironflock trusts IronFlock's catalog key alone and refuses it,
        as text and with --json: exit code 1, the catalog refused for its
        signature. It refuses before anything is downloaded: the host was asked
        for the catalog and nothing else, /var/cache/ironflockos keeps no bundle
        and no copy of the catalog, and the slots are as they were."""
        before = self.slots_state()
        asked = len(self.requests)
        for name, argv in (("ironflock-os-update", ["ironflock", "os", "update", "--yes", "--download-base", self.http]),
                           ("ironflock-os-update-json",
                            ["ironflock", "os", "update", "--yes", "--json", "--download-base", self.http])):
            rc, out, err = self.capture(state, name, argv)
            message = self.failure(argv, rc, out, err, "failed")
            if rc != 1 or "is refused" not in message or "does not verify" not in message:
                raise TestFailure(f"`{' '.join(argv)}` ended with {rc}, expected 1 and the catalog refused for its "
                                  f"signature:\n{out}{err}")
        got = self.requests[asked:]
        if got != ["/" + CATALOG_PATH] * 2:
            raise TestFailure(f"os update asked the test host for {got}, expected the catalog once per run and nothing else")
        self.vm.run(f"test -z \"$(find {CACHE} \\( -name '*.raucb*' -o -name manifest.json \\) -print 2>/dev/null)\"")
        after = self.slots_state()
        if after != before:
            raise TestFailure(f"a refused os update changed the slots:\nbefore: {before}\nafter: {after}")

    def os_fresh(self):
        """`ironflock os` on the device as it was written: slot A runs and is
        good, slot B holds nothing. `os rollback` refuses, as there is nothing to
        go back to, and the device keeps starting slot A; `os update` refuses
        the test's catalog (update_refused). What ironflock reads of the
        device is kept, with RAUC's system.conf and os-release."""
        status = self.snapshot("fresh")
        self.capture_file("fresh", "system.conf", "/etc/rauc/system.conf")
        self.capture_file("fresh", "os-release", "/etc/os-release")
        if (status.get("os") or {}).get("booted_slot") != "A":
            raise TestFailure(f"ironflock status: the device as written does not run from slot A:\n{status}")
        upcoming = self.rollback_refused("fresh", "slot B holds no system yet")
        if upcoming != "A":
            raise TestFailure(f"after the refused rollback GRUB would start slot {upcoming}, not A")
        self.update_refused("fresh")

    def os_while_installing(self):
        """The update's bundle, installed by `rauc install` in the background.
        As soon as RAUC reports that it installs (Operation on D-Bus), the
        checks run back to back in the VM: `rauc status` as ironflock asks it,
        `ironflock os rollback --yes` and `ironflock os update --yes` (each also
        with --json), then RAUC is asked again. Installing before and after,
        RAUC was busy all through the checks: then both commands refuse with
        exit code 3, saying that RAUC installs. An installation that ended
        during the checks leaves them kept but not judged (logged). rauc
        install's own output is kept as well."""
        update = ["ironflock", "os", "update", "--yes", "--download-base", self.http]
        checks = [("rauc-status", RAUC_STATUS),
                  ("ironflock-os-rollback", ["ironflock", "os", "rollback", "--yes"]),
                  ("ironflock-os-rollback-json", ["ironflock", "os", "rollback", "--yes", "--json"]),
                  ("ironflock-os-update", update),
                  ("ironflock-os-update-json", update[:4] + ["--json"] + update[4:])]
        self.fetch_bundle()
        d = "/run/ironflockos-ci-install"
        install = ["rauc", "install", TEST_BUNDLE]
        script = [f"rm -rf {d} && mkdir -p {d}",
                  f"setsid -f sh -c {shlex.quote(self.capture_snippet(install, d + '/install'))} </dev/null >/dev/null 2>&1",
                  # Until RAUC installs, or the installation has ended.
                  f"i=0; until {RAUC_OPERATION} 2>/dev/null | grep -q '\"installing\"' || [ -e {d}/install.rc ] "
                  f"|| [ $i -ge 3000 ]; do i=$((i+1)); sleep 0.1; done",
                  f"{RAUC_OPERATION} >{d}/before 2>&1"]
        script += [self.capture_snippet(argv, f"{d}/{name}") for name, argv in checks]
        script += [f"{RAUC_OPERATION} >{d}/after 2>&1"]
        # Its exit code is busctl's; what before and after say is judged below.
        self.vm.run("; ".join(script), timeout=400, check=False)
        before = self.vm.run(f"cat {d}/before", check=False).strip()
        after = self.vm.run(f"cat {d}/after", check=False).strip()
        results = [(argv, self.collect("busy", name, argv, f"{d}/{name}")) for name, argv in checks]
        self.wait_for(f"test -e {d}/install.rc", 900, "rauc install to end")
        rc, out, err = self.collect("install", "rauc-install", install, f"{d}/install")
        self.vm.run(f"rm -rf {d}; rm -f {TEST_BUNDLE}")
        if rc != 0:
            raise TestFailure(f"`{' '.join(install)}` exited {rc}:\n{out}{err}")
        if '"installing"' not in before:
            if '"idle"' not in before:
                raise TestFailure(f"RAUC does not say whether it installs (`{RAUC_OPERATION}`: {before!r})")
            log(f"RAUC had installed before the checks began: they are kept, not judged ({before!r})")
            return
        if '"installing"' not in after:
            log(f"RAUC's installation ended during the checks: they are kept, not judged ({after!r})")
            return
        for argv, (rc, out, err) in results[1:]:
            if rc != 3 or RAUC_BUSY not in self.failure(argv, rc, out, err, "precondition"):
                raise TestFailure(f"`{' '.join(argv)}` while RAUC installs ended with {rc}, expected 3 and "
                                  f"{RAUC_BUSY!r}:\n{out}{err}")

    def reboot_by(self, state, name, argv):
        """Runs argv, an ironflock command that restarts the device when it
        succeeds, and waits for the restart. What it prints and its exit code
        go to files on /data, synced before the shell says the command ended;
        /data outlives the restart. They are read once the device runs again:
        the debug shell answers early in the boot, before /data is mounted,
        and a read right after the restart finds the root slot's empty folder
        under it. The exit code is the file's, else the one the shell printed
        before the restart, else None (the restart came first). A command
        that ends without the restart fails the step at once."""
        prefix = f"{REBOOT_OUT}/{name}"
        line = " ".join(argv)
        self.vm.run(f"mkdir -p {REBOOT_OUT} && rm -f {prefix}.*")
        old = self.vm.run("cat /proc/sys/kernel/random/boot_id").strip()
        starts = self.vm.kernel_starts()
        tag = uuid.uuid4().hex[:8]
        self.vm.buf = b""
        self.vm._send(f"{self.capture_snippet(argv, prefix)}; sync; echo __EN''D_{tag}=$(cat {prefix}.rc)\r")
        deadline = time.time() + self.boot_timeout
        said = None
        while self.vm.kernel_starts() <= starts:
            m = self.vm._read_until(rb"__END_" + tag.encode() + rb"=(\d+)", 2)
            if m:
                said = int(m.group(1))
            if said not in (None, 0):
                rc, out, err = self.collect(state, name, argv, prefix)
                raise TestFailure(f"`{line}` ended with {said} and did not restart the device:\n{out}{err}")
            if time.time() > deadline:
                raise TestFailure(f"`{line}` did not restart the device within {self.boot_timeout}s")
            if m:
                time.sleep(1)
        if self.vm.wait_shell(max(10, deadline - time.time()), starts) == old:
            raise TestFailure(f"`{line}`: the same boot answers after the restart")
        self.wait_running()
        self.vm.run("mountpoint -q /data")
        rc, out, err = self.collect(state, name, argv, prefix)
        self.vm.run(f"rm -rf {REBOOT_OUT}")
        if rc is None:
            rc = said
        if rc is None:
            log(f"note: `{line}` restarted the device before its exit code was written; judged by its result")
        elif rc != 0:
            raise TestFailure(f"`{line}` ended with {rc}, yet the device restarted:\n{out}{err}")
        return out

    def back_on(self, slot, other, installed_b):
        """The device after a rollback: up on slot, online (the test host
        answers), the same device as before (machine-id, host key, /data and
        the app's file in /apps, enrolled again from the agent's copy); RAUC's
        record of the update in slot B is the one it had: a rollback changes no
        slot's content. GRUB starts slot from now on, and other, the slot it
        came from, is kept good: if slot does not prove itself, the device goes
        back there."""
        self.wait_running()
        if self.booted() != slot:
            raise TestFailure(f"booted {self.booted()} after the rollback, expected {slot}")
        self.vm.run(f"curl -fsS -o /dev/null {self.http}/")
        if self.vm.run("cat /etc/machine-id").strip() != self.machine_id:
            raise TestFailure("machine-id changed with the rollback")
        if self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip() != self.host_key:
            raise TestFailure("the SSH host key changed with the rollback")
        self.vm.run("grep -qx ironflockos-test /data/ironflockos-test-marker")
        self.apps_on_data()
        self.vm.run("grep -qx ironflockos-test /apps/prod/ironflockos-test/data.txt")
        if self.flock:
            self.enrolled(first=False)
        if self.slot_installed("rootfs.1") != installed_b:
            raise TestFailure(f"RAUC's record of slot B changed with the rollback: {installed_b} before")
        env = self.grubenv()
        if env.get("ORDER", "").split()[:1] != [slot] or env.get(f"{other}_OK") != "1" or env.get(f"{other}_TRY") != "0":
            raise TestFailure(f"after the rollback to {slot}, slot {other} is not kept good behind it: {env}")

    def keep_good(self, slot, proven):
        """In the agent's place, the slot the device rolled back to is marked
        good (ironflockos-slot-keep may have been first, on a slot that had
        proven itself before). It is still the system it was: its slot-proven
        mark is there exactly when it was there before the rollback."""
        self.vm.run("rauc status mark-good")
        env = self.grubenv()
        if env.get(f"{slot}_OK") != "1" or env.get(f"{slot}_TRY") != "0":
            raise TestFailure(f"slot {slot} is not good after rauc status mark-good: {env}")
        if (self.exit_code("test -e /var/lib/ironflockos/slot-proven")[0] == 0) != proven:
            raise TestFailure(f"slot {slot}'s slot-proven mark {'went' if proven else 'came'} with the rollback")

    def slot_a_proven(self):
        """Whether slot A, which does not run, has the slot-proven mark,
        read with debugfs."""
        out = self.vm.run("debugfs -c -R 'stat /var/lib/ironflockos/slot-proven' /dev/disk/by-partlabel/rootfs-a 2>&1",
                          check=False)
        return "Inode:" in out

    def rollback(self):
        """`ironflock os rollback` (WP-5.3 of the CLI's plan) on the device
        that runs the update in slot B, good, with slot A holding the system it
        was written with: nothing was installed into it, so the command takes
        it whether or not it was tried since it was last marked good (the CLI
        contract's rule for the image's slot; in CI it usually was, at the
        reboot before the update). The command restarts the device into slot
        A, which runs again (back_on, `ironflock status` reports slot A and its
        version); marked good, the device goes forward to slot B the same
        way, with --json. Both slots hold this build: the versions the command
        and `ironflock status` report are the same on both, the slot tells
        the systems apart. Whether the agent reaches IronFlock again QEMU
        cannot show (no platform answers)."""
        version = self.image_version()
        installed_b = self.slot_installed("rootfs.1")
        proven_a = self.slot_a_proven()
        argv = ["ironflock", "os", "rollback", "--yes"]
        out = self.reboot_by("updated", "ironflock-os-rollback", argv)
        if f"Rolled back to IronFlockOS {version} in slot A" not in out:
            raise TestFailure(f"`{' '.join(argv)}` printed no rollback to IronFlockOS {version} in slot A:\n{out}")
        self.back_on("A", "B", installed_b)
        system = self.snapshot("rolled-back").get("os") or {}
        if system.get("booted_slot") != "A" or system.get("version") != version:
            raise TestFailure(f"ironflock status after the rollback: {system}, expected slot A and {version}")
        self.keep_good("A", proven_a)

        argv = ["ironflock", "os", "rollback", "--yes", "--json"]
        result = self.json_result(self.reboot_by("rolled-back", "ironflock-os-rollback-json", argv), " ".join(argv))
        want = {"action": "rolled_back", "slot": "B", "version": version, "from_slot": "A", "from_version": version}
        if {key: result.get(key) for key in want} != want:
            raise TestFailure(f"`{' '.join(argv)}` reported {result}, expected {want}")
        self.back_on("B", "A", installed_b)
        # update_to_b waited for B's mark.
        self.keep_good("B", True)
        system = self.snapshot("rolled-forward").get("os") or {}
        if system.get("booted_slot") != "B" or system.get("primary_slot") != "B":
            raise TestFailure(f"ironflock status after the rollback to slot B: {system}")

    def rollback_after_fallback(self):
        """After the fallback, slot A holds the update that was tried once and
        never marked good: `ironflock os rollback` refuses it and changes
        nothing, and the device keeps starting slot B."""
        self.snapshot("fell-back")
        upcoming = self.rollback_refused("fell-back", "which did not start successfully")
        if upcoming != "B":
            raise TestFailure(f"after the refused rollback GRUB would start slot {upcoming}, not B")

    def slot_installed(self, slot):
        """When RAUC recorded the installation of a slot (its state on /data)."""
        out = json.loads(self.vm.run("rauc status --detailed --output-format=json 2>/dev/null"))
        for entry in out.get("slots", []):
            if slot in entry:
                return (entry[slot].get("slot_status") or {}).get("installed", {}).get("timestamp")
        return None

    def reset_reboot(self):
        """Restart into a factory reset: the reset boot restarts by itself once
        it is done, so the shell is the one of the second kernel after this."""
        starts = self.vm.kernel_starts()
        self.vm._send("systemctl reboot\r")
        try:
            self.vm.wait_shell(self.boot_timeout * 2, starts + 1)
        except TestFailure as e:
            info = ""
            if self.vm.kernel_starts() == starts + 1:
                # The reset boot did not restart: its shell says why.
                try:
                    self.vm.wait_shell(60, starts)
                    info = self.vm.run("journalctl -b --no-pager -o cat -u ironflockos-factory-reset; "
                                       "cat /boot/efi/factory-reset.log; systemctl --failed --no-pager", check=False)
                except TestFailure:
                    pass
            raise TestFailure(f"{e}; the factory reset did not restart the device by itself\n{info}") from None

    RESET_UNITS = ("ironflockos-factory-reset.service", "ironflockos-data-missing.service", "data.mount",
                   "ironflockos-data-layout.service", "ironflockos-proxy.service", "ironflockos-enroll.service",
                   "ironflock-device-agent.service")

    def reset_diagnostics(self):
        """What a failed factory reset step needs in CI's log: the units it
        waited for, their journal, the reset's record and state, the IRONFLOCKOS
        partition, and the reset boot's own lines from the serial console (its
        journal is lost with its restart)."""
        units = " ".join(self.RESET_UNITS)
        out = []
        try:
            out.append(self.vm.run(
                f"systemctl status --no-pager -l {units}; "
                f"journalctl -b --no-pager -o short-monotonic {' '.join('-u ' + u for u in self.RESET_UNITS)} | tail -n 300; "
                "for f in /boot/efi/factory-reset.log /var/lib/ironflockos/factory-reset.log "
                "/var/lib/ironflockos/factory-reset.state /run/ironflockos/factory-reset-hold /run/ironflockos/data-missing; do "
                "echo \"== $f\"; cat \"$f\" 2>&1; done; ls -la /boot/efi; findmnt /data; systemctl --failed --no-pager",
                timeout=120, check=False))
        except TestFailure as e:
            out.append(f"(no shell for the diagnostics: {e})")
        try:
            with open(self.vm.console, "rb") as fh:
                lines = [line for line in fh.read().decode("utf-8", "replace").splitlines()
                         if "factory-reset" in line or "data-missing" in line]
            out.append("== the serial console's lines of the reset\n" + "\n".join(lines[-200:]))
        except OSError:
            pass
        return "\n".join(out)

    def factory_reset(self):
        try:
            self._factory_reset()
        except TestFailure as e:
            raise TestFailure(f"{e}\n{self.reset_diagnostics()}") from None

    def _factory_reset(self):
        """Factory reset (ADR-0015, docs/build.md "Factory reset") of the
        device in slot B, with the system it was updated from in slot A. Before
        it: an app's container runs (an image made in the VM from its own
        sleep and libc, with a restart policy), an app's files are in /apps, the
        site has a network profile and a proxy.conf. A request with
        keep-network=yes and a new .flock go onto the IRONFLOCKOS partition, as
        `ironflock os reset -c` puts them there. The boot after it resets and
        restarts by itself; the device then comes up on slot B without the old
        identity, containers, logs and data, with its network settings and
        RAUC's state, enrolled as the new device; slot A is cleared too, and B,
        which had proven itself, is kept good. The same request, put back as it
        was (as when the IRONFLOCKOS partition could not remove it), is not done a
        second time. With --no-flock the device stays unenrolled."""
        if self.booted() != "B":
            raise TestFailure(f"the factory reset starts on slot {self.booted()}, expected B")
        self.vm.run("test -x /usr/lib/ironflockos/factory-reset")
        # No registry and no image with a process that keeps running: sleep and
        # what it links become one.
        self.vm.run("d=$(mktemp -d) && for f in /usr/bin/sleep $(ldd /usr/bin/sleep | grep -o '/[^ ]*'); do "
                    "mkdir -p \"$d$(dirname \"$f\")\" && cp -L \"$f\" \"$d$f\" || exit 1; done && "
                    "tar -C \"$d\" -c . | docker import - ironflockos-reset-test && rm -rf \"$d\"", timeout=300)
        self.vm.run("docker run -d --name ironflockos-reset-test --restart always ironflockos-reset-test /usr/bin/sleep infinity",
                    timeout=120)
        self.wait_for("[ \"$(docker inspect -f '{{.State.Running}}' ironflockos-reset-test)\" = true ]", 60,
                      "the test container to run")
        self.vm.run("mkdir -p /apps/prod/ironflockos-reset-test && echo app > /apps/prod/ironflockos-reset-test/data.txt")
        profile = "/etc/NetworkManager/system-connections/ironflockos-reset-test.nmconnection"
        self.vm.run(f"printf '[connection]\\nid=ironflockos-reset-test\\ntype=dummy\\ninterface-name=frt0\\n"
                    f"autoconnect=false\\n\\n[ipv4]\\nmethod=disabled\\n\\n[ipv6]\\nmethod=ignore\\n' > {profile}"
                    f" && chmod 600 {profile}")
        self.vm.run("printf 'ntp=10.0.2.2\\n' > /data/ironflockos/proxy.conf")
        installed = self.slot_installed("rootfs.1")
        if not installed:
            raise TestFailure("RAUC has no record of the installation into slot B")
        # The request as the contract says (docs/build.md) and `ironflock os
        # reset` writes it: the whole file under a temporary name, checked,
        # renamed; then the .flock the same way, the only one on the partition.
        self.vm.run("printf 'keep-network=yes\\n' > /boot/efi/.factory-reset.conf.part && sync")
        out = self.vm.run("/usr/lib/ironflockos/factory-reset check /boot/efi/.factory-reset.conf.part").strip()
        if out != "keep-network=yes":
            raise TestFailure(f"factory-reset check says {out!r}")
        self.vm.run("mv /boot/efi/.factory-reset.conf.part /boot/efi/factory-reset.conf && sync")
        request_time = self.vm.run("stat -c %Y /boot/efi/factory-reset.conf").strip()
        new_flock = None
        if self.flock:
            new_flock = "ironflockos-ci-reset.flock"
            data = base64.b64encode(json.dumps(test_flock(RESET_FLOCK_NAME, RESET_OWNER, "4712")).encode()).decode()
            self.vm.run("test -z \"$(ls /boot/efi/*.flock 2>/dev/null)\"")
            self.vm.run(f"echo {data} | base64 -d > /boot/efi/.factory-reset.flock.part && sync"
                        f" && mv /boot/efi/.factory-reset.flock.part /boot/efi/{new_flock} && sync")

        self.reset_reboot()
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()} after the factory reset, expected B: the reset's restart "
                              "must not count as a failed try")
        record = self.vm.run("cat /boot/efi/factory-reset.log")
        for want in ("result=done", "keep-network=yes", "slot=B", "other-slot=cleaned", "attempt=1"):
            if want not in record.splitlines():
                raise TestFailure(f"the record lacks {want!r}:\n{record}")
        kept = next((line for line in record.splitlines() if line.startswith("kept=")), "").split("=", 1)[-1].split()
        for want in ("rauc", "network/connections", "ironflockos/proxy.conf"):
            if want not in kept:
                raise TestFailure(f"the record does not list {want} as kept:\n{record}")
        self.vm.run("test ! -e /boot/efi/factory-reset.conf && test ! -e /boot/efi/factory-reset.keep"
                    " && test -z \"$(ls -A /boot/efi | grep '^\\.factory-reset.*\\.part$')\"")

        # Nothing of the old device: its identity, containers, app files, data
        # and logs.
        # systemd makes the machine-id anew; from a VM's UUID it would be the
        # same as on the first boot, but QEMU without -uuid gives none.
        mid = self.vm.run("cat /etc/machine-id").strip()
        made = self.vm.run("journalctl -b --no-pager -o cat | grep 'Initializing machine ID'", check=False)
        if not re.fullmatch(r"[0-9a-f]{32}", mid) or (mid == self.machine_id and "VM UUID" not in made):
            raise TestFailure(f"the machine-id after the reset is {mid!r} (before: {self.machine_id}; {made.strip()!r})")
        host_key = self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip()
        if host_key == self.host_key:
            raise TestFailure("the SSH host key survived the reset")
        # The old containers and images are gone; the newly enrolled agent
        # may have made its own, so they are checked by name.
        for kind, name in (("container", "ironflockos-reset-test"), ("image", "ironflockos-reset-test"),
                           ("image", "hello-world")):
            self.vm.run(f"! docker {kind} inspect {name} >/dev/null 2>&1")
        self.vm.run("test ! -e /apps/prod/ironflockos-reset-test && test ! -e /data/ironflockos-test-marker")
        # The device's own splash went with the old owner's data: IronFlock's
        # logo from the restart on, and an empty screen folder.
        self.vm.run(f"test ! -e {self.ARCHIVE} && test ! -e /boot/efi/EFI/BOOT/splash-screen.png && test -d /data/ironflockos/screen"
                    " && test -z \"$(ls -A /data/ironflockos/screen)\"")
        boots = self.vm.run("journalctl --list-boots --no-pager | grep -cE '^ *-?[0-9]+ '").strip()
        if boots != "1":
            raise TestFailure(f"the journal holds {boots} boots after the reset, expected only this one")
        if self.flock:
            self.vm.run(f"! id {TEST_OWNER} && test ! -e /etc/sudoers.d/ironflock-{TEST_OWNER} && test ! -e /home/{TEST_OWNER}")
            self.enrolled(first=True, owner=RESET_OWNER, name=RESET_FLOCK_NAME, flock=new_flock)
            copy = json.loads(self.vm.run("cat /opt/ironflock/device-agent/device-config.flock"))
            if copy.get("device_key") != "4712" or copy.get("name") != RESET_FLOCK_NAME:
                raise TestFailure(f"the agent's .flock is not the new one: device_key {copy.get('device_key')!r}")
        else:
            hostname = self.vm.run("hostname").strip()
            if hostname != "ironflockos":
                raise TestFailure(f"the hostname of an unenrolled device is {hostname!r}, not the image's")
            self.vm.run("! awk -F: '$3 >= 1000 && $3 < 60000' /etc/passwd | grep -q .")
            self.vm.run("test ! -e /var/lib/ironflockos/enrolled && test ! -e /etc/systemd/system/ironflock-device-agent.service")

        # What was kept: the network settings and RAUC's state.
        self.vm.run(f"grep -qx id=ironflockos-reset-test {profile} && test \"$(stat -c %a {profile})\" = 600")
        self.vm.run("grep -qx ntp=10.0.2.2 /data/ironflockos/proxy.conf")
        if self.slot_installed("rootfs.1") != installed:
            raise TestFailure(f"RAUC's record of slot B changed with the reset: {installed} before")

        # Slot A, the system B was updated from, is cleared as well.
        dev = "/dev/disk/by-partlabel/rootfs-a"
        for path, want in (("/etc/hostname", "ironflockos"), ("/etc/machine-id", "uninitialized")):
            got = self.vm.run(f"debugfs -c -R 'cat {path}' {dev} 2>/dev/null").strip()
            if got != want:
                raise TestFailure(f"slot A's {path} is {got!r} after the reset, expected {want!r}")
        self.vm.run(f"debugfs -c -R 'stat /var/lib/ironflockos/enrolled' {dev} 2>&1 | grep -q 'File not found'")
        if self.flock:
            self.vm.run(f"! debugfs -c -R 'cat /etc/passwd' {dev} 2>/dev/null | grep -q '^{TEST_OWNER}:'")

        # B had proven itself before the reset, so it is kept good once it has
        # stayed up, without the agent; the rest of the test needs it good.
        self.vm.run("test -e /var/lib/ironflockos/slot-proven")
        keep_b = "grub-editenv /boot/efi/EFI/BOOT/grubenv list | grep -qx B_TRY=0"
        self.wait_for(keep_b, 300, "slot B, proven before the reset, to be marked good again")

        # The same request put back as it was (content and time): the reset was
        # completed, so it is not done again, and the device keeps its new
        # identity.
        self.vm.run(f"printf 'keep-network=yes\\n' > /boot/efi/factory-reset.conf"
                    f" && touch -d @{request_time} /boot/efi/factory-reset.conf && sync")
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()} after the reboot with the old request, expected B")
        self.vm.run("journalctl -b --no-pager -o cat -u ironflockos-factory-reset | grep -q 'it is not done again'")
        self.vm.run("test ! -e /boot/efi/factory-reset.conf")
        if self.vm.run("cat /etc/machine-id").strip() != mid:
            raise TestFailure("the machine-id changed: the completed reset was done again")
        if self.flock:
            self.enrolled(first=False, owner=RESET_OWNER, name=RESET_FLOCK_NAME)
        self.wait_for(keep_b, 300, "slot B to be marked good again")
        self.machine_id, self.host_key = mid, host_key
        self.vm.run("rm /data/ironflockos/proxy.conf")

    def _slots(self):
        out = {}
        for entry in self.rauc_status().get("slots", []):
            for name, info in entry.items():
                out[name] = info
        return out

    def fallback(self):
        """A slot nobody marks good (the agent never reached the platform)
        is tried once; the next boot falls back to the good slot."""
        self.install_bundle()
        primary = self.rauc_status().get("boot_primary")
        if primary != "rootfs.0":
            raise TestFailure(f"after the second install the primary slot is {primary}, expected rootfs.0")
        self.vm.reboot(self.boot_timeout)
        self.vm.run("systemctl is-system-running --wait", timeout=self.boot_timeout, check=False)
        if self.booted() != "A":
            raise TestFailure(f"booted {self.booted()} after the second update, expected A (untested)")
        env = self.vm.run("grub-editenv /boot/efi/EFI/BOOT/grubenv list")
        if "A_TRY=1" not in env:
            raise TestFailure(f"slot A is not marked as tried:\n{env}")
        # Slot A was proven before; the update replaced that system.
        self.vm.run("test ! -e /var/lib/ironflockos/slot-proven")
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()}: an untested slot A must fall back to B")
        self.vm.run("rauc status mark-good")

    def wait_for(self, command, timeout, what):
        deadline = time.time() + timeout
        while self.vm.run(f"{command}; echo rc=$?").strip().splitlines()[-1] != "rc=0":
            if time.time() > deadline:
                raise TestFailure(f"timed out after {timeout}s waiting for {what}")
            time.sleep(3)

    def crash(self):
        self.vm.run("sync")
        starts = self.vm.kernel_starts()
        self.vm._send("echo c > /proc/sysrq-trigger\r")
        self.vm.wait_shell(self.boot_timeout, starts)
        self.wait_running()

    def crash_offline(self):
        """A kernel crash on a device without a connection, with a proven
        system in slot B and a good one in slot A. Nothing but the image marks
        a slot good here: the test .flock's agent never reaches a platform.

        A slot that has stayed up keeps running after the crash; a crash
        sooner than that counts as a failed try."""
        self.vm.run("rauc status mark-active booted && rauc status mark-good other")
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()} before the crash, expected B")
        for key, want in (("kernel.panic", "10"), ("kernel.panic_on_oops", "1"), ("kernel.softlockup_panic", "1")):
            got = self.vm.run(f"sysctl -n {key}").strip()
            if got != want:
                raise TestFailure(f"{key} is {got!r}, expected {want}")
        tried = "grub-editenv /boot/efi/EFI/BOOT/grubenv list | grep -qx B_TRY=1"
        self.vm.run(tried)
        self.wait_for(f"! {{ {tried}; }}", 300, "the proven slot B to be marked good again")
        self.crash()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()} after a crash on a proven slot, expected B")
        # PREEMPT_RT kernels turn EFI runtime services off: nowhere to record.
        if "PREEMPT_RT" not in self.vm.run("uname -v"):
            self.vm.run("find /data/pstore -type f -name 'dmesg*' | grep -q .")
        self.vm.run(tried)
        self.crash()
        if self.booted() != "A":
            raise TestFailure(f"booted {self.booted()} after a crash soon after boot, expected the fallback to A")


def installer_conf(payload_id):
    """installer.conf as FlockFlasher writes it (payload=<image id>: the stick
    carries every variant of its target), unattended."""
    return f"payload={payload_id}\nconfirm=no\nafter=poweroff\n"


def install_test(args, conf, arch, version, accel, boot_timeout, port):
    """WP-3.2: the installer stick (USB) writes the base image, one of the
    images it carries, to a blank NVMe unattended and powers off; the NVMe
    then boots alone like a flashed disk."""
    installer_id = f"ironflockos-{args.target}-installer"
    base_id = f"ironflockos-{args.target}-base"
    conf_text = installer_conf(base_id)
    img_gz = os.path.join(args.out, installer_id, f"{installer_id}-{version}.img.gz")
    if not os.path.exists(img_gz):
        sys.exit(f"{img_gz} not found: run `just build {args.target} installer` first")
    workdir = args.work or tempfile.mkdtemp(prefix="ironflockos-install-")
    os.makedirs(workdir, exist_ok=True)
    stick = os.path.join(workdir, "stick.img")
    nvme = os.path.join(workdir, "nvme.img")
    with gzip.open(img_gz, "rb") as src, open(stick, "wb") as dst:
        shutil.copyfileobj(src, dst, 16 * 1024 * 1024)
    with open(nvme, "wb") as fh:
        fh.truncate(20 * 1024**3)
    offset = esp_offset(stick)
    conf_file = os.path.join(workdir, "installer.conf")
    with open(conf_file, "w") as fh:
        fh.write(conf_text)
    subprocess.run(["mcopy", "-n", "-o", "-i", f"{stick}@@{offset}", conf_file, "::/installer.conf"], check=True)
    set_test_cmdline(stick, workdir, debug_cmdline(arch))
    # The installer hands the stick's .flock to the new disk, which enrolls with it.
    flock = None if args.no_flock else put_test_flock(stick, workdir)
    log(f"stick: {installer_id}-{version}, installer.conf {conf_text!r}; blank 20 GiB NVMe")

    results = []
    ok = False
    vm = VM(arch, nvme, workdir, accel, stick=stick, nvme=True, secure_boot=args.secure_boot)
    try:
        log("--- install from the stick")
        start = time.time()
        vm.start(conf["QEMU_SYSTEM"], port)
        vm.wait_exit(boot_timeout * 3)
        vm.sock.close()
        vm.sock = None
        os.replace(vm.console, os.path.join(workdir, "console-installer.log"))
        logfile = os.path.join(workdir, "ironflockos-installer.log")
        subprocess.run(["mcopy", "-n", "-o", "-i", f"{stick}@@{offset}", "::/ironflockos-installer.log", logfile], check=True)
        text = open(logfile, encoding="utf-8", errors="replace").read()
        print(text)
        if "IronFlockOS is installed on /dev/nvme0n1" not in text:
            raise TestFailure("the installer did not report an installation on /dev/nvme0n1")
        if f"image: {base_id}-{version}.img.zst" not in text:
            raise TestFailure(f"the installer did not write the payload installer.conf names ({base_id})")
        if flock and f"copying {flock} to the new IRONFLOCKOS partition" not in text:
            raise TestFailure(f"the installer did not copy {flock} to the new disk")
        results.append(("install from the stick", True, time.time() - start))
        log(f"ok   install from the stick ({time.time() - start:.0f}s)")

        # Boot the NVMe alone, with the UEFI variables the installer wrote.
        set_test_cmdline(nvme, workdir, debug_cmdline(arch))
        if os.path.exists(vm.sock_path):
            os.remove(vm.sock_path)
        if os.path.exists(vm.qmp_path):
            os.remove(vm.qmp_path)
        vm2 = VM(arch, nvme, workdir, accel, nvme=True, secure_boot=args.secure_boot)
        runner = Runner(vm2, conf, base_id, port, None, boot_timeout, disk_dev="/dev/nvme0n1", flock=flock)
        try:
            vm2.start(conf["QEMU_SYSTEM"], port)
            runner.step("the installed NVMe boots alone like a flashed disk"
                        + (" and enrolls with the stick's .flock" if flock else ""), runner.first_boot)
        finally:
            vm2.stop()
            results.extend(runner.results)
        ok = True
    except TestFailure as e:
        log(f"FAIL {e}")
    finally:
        vm.stop()
        print("\nresults:")
        for name, passed, secs in results:
            print(f"  {'ok  ' if passed else 'FAIL'} {name} ({secs:.0f}s)")
        print(f"consoles: {os.path.join(workdir, 'console-installer.log')}, {vm.console}\n"
              f"shell transcript: {os.path.join(workdir, 'shell.log')}")
        if not args.keep and ok:
            shutil.rmtree(workdir, ignore_errors=True)
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--target", default="amd64-efi")
    ap.add_argument("--variant", default="base")
    ap.add_argument("--kernel", default="std")
    ap.add_argument("--out", default=os.path.join(REPO, "out"))
    ap.add_argument("--work")
    ap.add_argument("--disk-size", help="virtual disk size (default 20G; 32G for nvidia's 8 GiB slots)")
    ap.add_argument("--docker-image-tar", help="docker save output of hello-world, loaded and run in the VM")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--only", choices=["boot", "update"], help="stop after this part")
    ap.add_argument("--no-flock", action="store_true", help="boot without a test .flock (an unenrolled device)")
    ap.add_argument("--secure-boot", action="store_true",
                    help="boot with Secure Boot on and Microsoft's keys enrolled, as PCs ship (ADR-0011)")
    args = ap.parse_args()

    conf = load_conf(os.path.join(REPO, "targets", args.target, "target.conf"))
    arch = conf["ARCH"]
    image_id = f"ironflockos-{args.target}-{args.variant}" + ("-rt" if args.kernel == "rt" else "")
    with open(os.path.join(REPO, "VERSION")) as fh:
        version = fh.read().strip()
    if args.variant == "installer":
        accel = pick_accel(arch)
        server, port = serve(tempfile.mkdtemp(prefix="ironflockos-http-"))
        try:
            sys.exit(0 if install_test(args, conf, arch, version, accel, 300 if accel != "tcg" else 1500, port) else 1)
        finally:
            server.shutdown()
    artefacts = os.path.join(args.out, image_id)
    img_gz = os.path.join(artefacts, f"{image_id}-{version}.img.gz")
    bundle = os.path.join(artefacts, f"{image_id}-{version}.raucb")
    for f in (img_gz, bundle):
        if not os.path.exists(f):
            sys.exit(f"{f} not found: run `just build {args.target} {args.variant}` first")
    for tool in (conf["QEMU_SYSTEM"], "mcopy", "openssl"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is required")

    workdir = args.work or tempfile.mkdtemp(prefix="ironflockos-qemu-")
    os.makedirs(workdir, exist_ok=True)
    disk = os.path.join(workdir, "disk.img")
    log(f"work directory {workdir}")
    with gzip.open(img_gz, "rb") as src, open(disk, "wb") as dst:
        shutil.copyfileobj(src, dst, 16 * 1024 * 1024)
    disk_size = args.disk_size or ("32G" if args.variant == "nvidia" else "20G")
    size = {"G": 1024**3, "M": 1024**2}[disk_size[-1]] * int(disk_size[:-1])
    os.truncate(disk, size)
    set_test_cmdline(disk, workdir, debug_cmdline(arch))
    flock = None if args.no_flock else put_test_flock(disk, workdir)

    serve_dir = os.path.join(workdir, "http")
    os.makedirs(serve_dir, exist_ok=True)
    link_or_copy(bundle, os.path.join(serve_dir, "bundle.raucb"))
    if args.docker_image_tar:
        shutil.copy(args.docker_image_tar, serve_dir)
    put_test_catalog(serve_dir, workdir, image_id, version, artefacts,
                     {"target": args.target, "variant": args.variant, "kernel": args.kernel, "architecture": arch})
    server, port = serve(serve_dir)

    accel = pick_accel(arch)
    boot_timeout = 300 if accel != "tcg" else 1500
    log(f"accelerator: {accel}{' (slow)' if accel == 'tcg' else ''}; Secure Boot {'on' if args.secure_boot else 'off'}")
    vm = VM(arch, disk, workdir, accel, secure_boot=args.secure_boot)
    runner = Runner(vm, conf, image_id, port, args.docker_image_tar, boot_timeout, flock=flock,
                    requests=server.requests, captured=os.path.join(workdir, "captured"))
    ok = False
    try:
        vm.start(conf["QEMU_SYSTEM"], port)
        runner.step("first boot: boot chain, Secure Boot "
                    + ("on" if args.secure_boot else "off")
                    + ", partitions, /data, identity, SSH, RAUC, Docker, fwupd", runner.first_boot)
        runner.step("ironflock: /usr/bin/ironflock, status, refusals, a .flock that is not accepted",
                    runner.ironflock_cli)
        runner.step("ironflock os as written: rollback refuses, update refuses a catalog IronFlock did not sign",
                    runner.os_fresh)
        if flock:
            runner.step("change hands: sudo ironflock agent configure -c over SSH by the owner, and back",
                        runner.change_hands)
        if args.kernel == "rt":
            runner.step("rt kernel: PREEMPT_RT, tuning from rt.conf into grubenv", runner.rt_kernel)
        if args.variant == "nvidia":
            runner.step("nvidia: driver, open modules, container runtime, no toolchain", runner.nvidia)
        runner.step("confinement: AppArmor on, Docker's profile on containers, chronyd under its profile",
                    runner.confinement)
        runner.step("filesystem check: the boot repairs what a preen refuses", runner.fsck_repair)
        runner.step("time: chrony, PTP from ptp.conf as chrony's source", runner.time_sync)
        runner.step("proxy: proxy.conf to Docker, the agent and chrony", runner.proxy)
        runner.step("network profile: a static profile on the IRONFLOCKOS partition, for the next boot",
                    runner.network_profile)
        runner.step("reboot: machine-id, host key, journal persist, proxy.conf and the static profile from IRONFLOCKOS",
                    runner.reboot_persists)
        runner.step("splash: Plymouth from the initramfs, IronFlock's logo to the end of the boot and after, "
                    "a damaged splash.cpio, tty1 in graphics mode, input devices", runner.splash)
        runner.step("own splash: a screen app's picture and splash.conf, refusals, the next boot shows it",
                    runner.own_splash)
        runner.step("keys and messages: Esc for the boot messages, a message below the picture, Ctrl+Alt+F2 and back"
                    + (", the console password on tty2" if flock else ""), runner.usual_keys)
        runner.step("GRUB draws the splash: from GRUB's picture to the end of the boot nothing but the splash",
                    runner.grub_splash)
        if args.only != "boot":
            runner.step("update into slot B; ironflock os refuses while RAUC installs and while the update waits",
                        runner.update_to_b)
            if args.only != "update":
                # Two restarts more: under emulation (the arm64 runners) each
                # takes minutes, so there only the refusals run.
                if accel != "tcg":
                    runner.step("os rollback: back to slot A, which runs again, and forward to slot B",
                                runner.rollback)
                else:
                    log("--- os rollback back to slot A and forward: left out under emulation")
                runner.step("factory reset: identity, containers and data gone, network kept, "
                            + ("enrolled anew" if flock else "unenrolled") + ", slot A cleared", runner.factory_reset)
                runner.step("fallback: an untested slot A falls back to B", runner.fallback)
                runner.step("os rollback refuses the slot that was tried and not marked good",
                            runner.rollback_after_fallback)
                runner.step("crash: restarts by itself on a proven slot, on record on /data", runner.crash_offline)
        ok = True
    except TestFailure:
        ok = False
    finally:
        vm.stop()
        server.shutdown()
        print("\nresults:")
        for name, passed, secs in runner.results:
            print(f"  {'ok  ' if passed else 'FAIL'} {name} ({secs:.0f}s)")
        print(f"console: {vm.console}\nshell transcript: {os.path.join(workdir, 'shell.log')}\n"
              f"what ironflock read and printed: {runner.captured}")
        if not args.keep and ok:
            shutil.rmtree(workdir, ignore_errors=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
