#!/usr/bin/env python3
"""Boot a built IronFlockOS image in QEMU and test it (docs/testing.md).

  run.py --target amd64-efi --variant base [--out out] [--work DIR]
         [--docker-image-tar FILE] [--secure-boot] [--keep]

The image under test is the artefact from `just build`, unchanged except for
one value in the FLOCKOS partition's grubenv of the test copy:
FLOCKOS_CMDLINE asks systemd for a root debug shell, which this script drives:
on the second serial port on amd64 (ttyS1), on a virtio console on arm64
(hvc0; QEMU's virt machine has one UART). grubenv lives on the FLOCKOS
partition, so the shell is there on both slots, before and after an update.

With --secure-boot the firmware has Microsoft's keys enrolled and Secure
Boot on, as on a PC from the factory (ADR-0011): the image's shim, GRUB and
kernel have to pass its checks, and the kernel runs locked down.

Sequence (WP-1.3, WP-1.4, WP-1.7): first boot (boot chain and Secure Boot
state, partitions grown, /data layout, identity, SSH policy, RAUC slot A good,
Docker, fwupd); for nvidia
the driver, its modules and the container runtime without a GPU; reboot
(state persists); update into slot B with the bundle of the same build;
fallback: an update into slot A that is never marked good falls back to B;
a kernel crash without a connection: the device restarts by itself on a slot
that has proven itself, and the crash is on record on /data.

Needs: qemu-system-<arch>, OVMF/AAVMF firmware (for --secure-boot the
builds with Microsoft's keys: Debian's and Ubuntu's ovmf, qemu-efi-aarch64),
mtools (mcopy). Standard library only; run with `python3 -I`.
"""

import argparse
import gzip
import http.server
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The guest device of the debug shell per architecture (see the docstring).
# systemd starts a getty on a virtio console by itself; on the test's hvc0 it
# would take the terminal from the shell.
DEBUG_SHELL = {"amd64": "ttyS1", "arm64": "hvc0"}
HOST_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(os.uname().machine)


def debug_cmdline(arch):
    tty = DEBUG_SHELL[arch]
    extra = f" systemd.mask=serial-getty@{tty}.service" if tty.startswith("hvc") else ""
    return f"systemd.debug_shell={tty}{extra}"


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


TEST_OWNER = "flockostest"
TEST_FLOCK_NAME = "flockos-ci"


def put_test_flock(disk, workdir):
    """A .flock with a throwaway key on the test copy's FLOCKOS partition:
    enough for ironflock-init enroll (SSH user, agent unit), useless to the
    platform. Returns its file name."""
    key = subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519"], check=True,
                         capture_output=True, text=True).stdout
    flock = {"name": TEST_FLOCK_NAME, "swarm_owner_name": TEST_OWNER, "device_key": "4711",
             "secret": "not-a-real-secret", "wlanssid": "", "password": "",
             "authentication": {"key": key}}
    path = os.path.join(workdir, "flockos-ci.flock")
    with open(path, "w") as fh:
        json.dump(flock, fh)
    subprocess.run(["mcopy", "-n", "-o", "-i", f"{disk}@@{esp_offset(disk)}", path, "::/flockos-ci.flock"], check=True)
    log("test copy: flockos-ci.flock on the FLOCKOS partition")
    return "flockos-ci.flock"


def set_test_cmdline(disk, workdir, cmdline):
    offset = esp_offset(disk)
    image = f"{disk}@@{offset}"
    env_file = os.path.join(workdir, "grubenv")
    subprocess.run(["mcopy", "-n", "-o", "-i", image, "::/EFI/BOOT/grubenv", env_file], check=True)
    with open(env_file, "rb") as fh:
        env = grubenv_parse(fh.read())
    env["FLOCKOS_CMDLINE"] = cmdline
    with open(env_file, "wb") as fh:
        fh.write(grubenv_render(env))
    subprocess.run(["mcopy", "-n", "-o", "-i", image, env_file, "::/EFI/BOOT/grubenv"], check=True)
    log(f"test copy: grubenv FLOCKOS_CMDLINE={cmdline!r}")


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
        self.console = os.path.join(workdir, "console.log")
        self.proc = None
        self.sock = None
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
                    "-device", "nvme,drive=nvm,serial=FLOCKOSCI,bootindex=1"]
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

    def wait_exit(self, timeout):
        """Wait for the guest to power off (QEMU exits)."""
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            raise TestFailure(f"the VM did not power off within {timeout}s") from None

    def stop(self):
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

    def reboot(self, timeout):
        old = self.run("cat /proc/sys/kernel/random/boot_id").strip()
        starts = self.kernel_starts()
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
    handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=directory, **k)  # noqa: E731
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.RequestHandlerClass.log_message = lambda *a: None
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


# --- the tests ---------------------------------------------------------------


class Runner:
    def __init__(self, vm, conf, image_id, http_port, docker_tar, boot_timeout, disk_dev="/dev/vda", flock=None):
        self.vm, self.conf, self.image_id = vm, conf, image_id
        self.secure_boot = vm.secure_boot
        self.disk_dev = disk_dev
        self.flock = flock
        self.http = f"http://10.0.2.2:{http_port}"
        self.docker_tar = docker_tar
        self.boot_timeout = boot_timeout
        self.results = []

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
            failed = self.vm.run("systemctl --failed --no-legend --plain --no-pager --full", check=False)
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
        """ADR-0011: the FLOCKOS partition boots the image's own shim and
        Debian's signed GRUB, and Secure Boot is what the test asked for: on,
        the kernel booted through every check and runs locked down."""
        efi_arch, grub_format = self.conf["EFI_ARCH"], self.conf["GRUB_FORMAT"]
        boot = "/boot/efi/EFI/BOOT"
        self.vm.run(f"cmp {boot}/{self.conf['EFI_LOADER']} /usr/lib/shim/shim{efi_arch}.efi.signed")
        self.vm.run(f"cmp {boot}/mm{efi_arch}.efi /usr/lib/shim/mm{efi_arch}.efi.signed")
        self.vm.run(f"cmp {boot}/grub{efi_arch}.efi /usr/lib/grub/{grub_format}-signed/grub{efi_arch}.efi.signed")
        self.vm.run(f"test ! -e {boot}/fb{efi_arch}.efi && grep -q '^source ' /boot/efi/EFI/debian/grub.cfg")
        # fwupd's capsule helper starts through the shim in the OS's folder.
        self.vm.run("systemctl start flockos-fwupd-shim.service")
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
        if f"IMAGE_ID={self.image_id}" not in osr or "ID=flockos" not in osr:
            raise TestFailure(f"unexpected os-release:\n{osr}")
        self.boot_chain()
        parts = self.vm.run(f"lsblk -bnro PARTLABEL,SIZE {self.disk_dev} | sed '/^ /d'")
        sizes = dict(line.split() for line in parts.splitlines() if len(line.split()) == 2)
        for label in ("FLOCKOS", "rootfs-a", "rootfs-b", "data"):
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
        self.vm.run("echo flockos-test > /data/flockos-test-marker")

    def rt_kernel(self):
        """An -rt image (WP-4b.1): the PREEMPT_RT kernel, and a new rt.conf
        written into grubenv by flockos-rt-tuning (applied at the next boot,
        which reboot_persists checks)."""
        version = self.vm.run("uname -v")
        if "PREEMPT_RT" not in version:
            raise TestFailure(f"not a PREEMPT_RT kernel: {version.strip()}")
        self.vm.run("systemctl is-active flockos-rt-tuning.service")
        self.vm.run("printf 'isolate=1\\nirq=0\\n' > /data/flockos/rt.conf")
        deadline = time.time() + 60
        while time.time() < deadline:
            env = self.vm.run("grub-editenv /boot/efi/EFI/BOOT/grubenv list")
            if "isolcpus=managed_irq,domain,1" in env:
                break
            time.sleep(2)
        else:
            raise TestFailure(f"rt.conf did not reach grubenv:\n{env}")
        self.vm.run("test -e /run/flockos/rt-reboot-required")
        self.rt_pending = True

    def time_sync(self):
        """Time (docs/build.md, "Time"): chrony instead of systemd-timesyncd.
        A ptp.conf that names the NIC gives chrony a PTP source and starts
        ptp4l and phc2sys; removing it takes them away again. QEMU's NIC has
        no hardware time stamps, so ptp4l cannot follow a master here: this
        checks the wiring, PTP itself is a hardware check."""
        for unit in ("chrony.service", "flockos-ptp.service", "flockos-ptp.path"):
            self.vm.run(f"systemctl is-active {unit}")
        self.vm.run("test ! -e /usr/lib/systemd/system/systemd-timesyncd.service")
        self.vm.run("chronyc -n tracking")
        self.vm.run("test -L /etc/flockos/ptp.conf")
        nic = self.vm.run("ip -o route show default | awk '{print $5; exit}'").strip()
        if not nic:
            raise TestFailure("no default route to name as the PTP interface")
        self.vm.run(f"printf 'interface={nic}\\ndomain=24\\n' > /data/flockos/ptp.conf")
        self.wait_for("chronyc -n sources | grep -q '^#. PTP '", 60, "chrony's PTP source")
        self.vm.run(f"grep -qx '\\[{nic}\\]' /run/flockos/ptp/ptp4l.conf")
        self.vm.run("grep -qx 'domainNumber 24' /run/flockos/ptp/ptp4l.conf")
        for unit in ("flockos-ptp4l.service", "flockos-phc2sys.service"):
            started = self.vm.run(f"systemctl show -p InvocationID --value {unit}").strip()
            if not started:
                raise TestFailure(f"{unit} did not start for ptp.conf")
        self.vm.run("rm /data/flockos/ptp.conf")
        self.wait_for("! chronyc -n sources | grep -q '^#. PTP '", 60, "chrony to drop the PTP source")
        self.vm.run("! systemctl -q is-active flockos-ptp4l.service flockos-phc2sys.service")
        self.vm.run("test ! -e /run/flockos/ptp/ptp4l.conf")
        # ptp4l failed on the NIC without hardware time stamps, as expected.
        self.vm.run("systemctl reset-failed flockos-ptp4l.service flockos-phc2sys.service 2>/dev/null || true")

    def enrolled(self, first):
        """The slot is enrolled from the test .flock: SSH user, sudo rule,
        the agent's unit; on the first boot the .flock left the FLOCKOS
        partition for the agent's 0600 copy."""
        self.vm.run(f"id {TEST_OWNER}")
        self.vm.run(f"test -f /etc/sudoers.d/ironflock-{TEST_OWNER}")
        self.vm.run(f"grep -q ironflock-device- /home/{TEST_OWNER}/.ssh/authorized_keys")
        self.vm.run("systemctl is-enabled ironflock-device-agent.service")
        self.vm.run("test -s /var/lib/flockos/enrolled")
        hostname = self.vm.run("hostname").strip()
        if hostname != TEST_FLOCK_NAME:
            raise TestFailure(f"the hostname is {hostname!r}, not the .flock's name {TEST_FLOCK_NAME!r}")
        self.vm.run("test -L /etc/flockos/enroll.conf")
        mode = self.vm.run("stat -c %a /opt/ironflock/device-agent/device-config.flock").strip()
        if mode != "600":
            raise TestFailure(f"the agent's .flock copy has mode {mode}")
        if first:
            self.vm.run(f"test ! -e /boot/efi/{self.flock}")

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
        want = {"nvidia-driver-cuda": driver, "flockos-nvidia-modules": driver, "firmware-nvidia-gsp": driver,
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

    def install_bundle(self):
        self.vm.run(f"curl -fsS -o /var/cache/flockos/test.raucb {self.http}/bundle.raucb", timeout=600)
        out = self.vm.run("rauc install /var/cache/flockos/test.raucb", timeout=900)
        self.vm.run("rm -f /var/cache/flockos/test.raucb")
        return out

    def update_to_b(self):
        self.install_bundle()
        primary = self.rauc_status().get("boot_primary")
        if primary != "rootfs.1":
            raise TestFailure(f"after the install the primary slot is {primary}, expected rootfs.1")
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()} after the update, expected B")
        if self.vm.run("cat /etc/machine-id").strip() != self.machine_id:
            raise TestFailure("machine-id changed with the update")
        self.vm.run("grep -qx flockos-test /data/flockos-test-marker")
        if self.flock:
            self.enrolled(first=False)
        if self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip() != self.host_key:
            raise TestFailure("the SSH host key changed with the update")
        self.mark_good("B", "rootfs.1")
        self.wait_for("test -e /var/lib/flockos/slot-proven", 60, "slot B to remember it was marked good")

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
        self.vm.run("test ! -e /var/lib/flockos/slot-proven")
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
    installer_id = f"flockos-{args.target}-installer"
    base_id = f"flockos-{args.target}-base"
    conf_text = installer_conf(base_id)
    img_gz = os.path.join(args.out, installer_id, f"{installer_id}-{version}.img.gz")
    if not os.path.exists(img_gz):
        sys.exit(f"{img_gz} not found: run `just build {args.target} installer` first")
    workdir = args.work or tempfile.mkdtemp(prefix="flockos-install-")
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
        logfile = os.path.join(workdir, "flockos-installer.log")
        subprocess.run(["mcopy", "-n", "-o", "-i", f"{stick}@@{offset}", "::/flockos-installer.log", logfile], check=True)
        text = open(logfile, encoding="utf-8", errors="replace").read()
        print(text)
        if "IronFlockOS is installed on /dev/nvme0n1" not in text:
            raise TestFailure("the installer did not report an installation on /dev/nvme0n1")
        if f"image: {base_id}-{version}.img.zst" not in text:
            raise TestFailure(f"the installer did not write the payload installer.conf names ({base_id})")
        if flock and f"copying {flock} to the new FLOCKOS partition" not in text:
            raise TestFailure(f"the installer did not copy {flock} to the new disk")
        results.append(("install from the stick", True, time.time() - start))
        log(f"ok   install from the stick ({time.time() - start:.0f}s)")

        # Boot the NVMe alone, with the UEFI variables the installer wrote.
        set_test_cmdline(nvme, workdir, debug_cmdline(arch))
        if os.path.exists(vm.sock_path):
            os.remove(vm.sock_path)
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
    image_id = f"flockos-{args.target}-{args.variant}" + ("-rt" if args.kernel == "rt" else "")
    with open(os.path.join(REPO, "VERSION")) as fh:
        version = fh.read().strip()
    if args.variant == "installer":
        accel = pick_accel(arch)
        server, port = serve(tempfile.mkdtemp(prefix="flockos-http-"))
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

    workdir = args.work or tempfile.mkdtemp(prefix="flockos-qemu-")
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
    os.link(bundle, os.path.join(serve_dir, "bundle.raucb")) if os.stat(bundle).st_dev == os.stat(serve_dir).st_dev else shutil.copy(bundle, os.path.join(serve_dir, "bundle.raucb"))
    if args.docker_image_tar:
        shutil.copy(args.docker_image_tar, serve_dir)
    server, port = serve(serve_dir)

    accel = pick_accel(arch)
    boot_timeout = 300 if accel != "tcg" else 1500
    log(f"accelerator: {accel}{' (slow)' if accel == 'tcg' else ''}; Secure Boot {'on' if args.secure_boot else 'off'}")
    vm = VM(arch, disk, workdir, accel, secure_boot=args.secure_boot)
    runner = Runner(vm, conf, image_id, port, args.docker_image_tar, boot_timeout, flock=flock)
    ok = False
    try:
        vm.start(conf["QEMU_SYSTEM"], port)
        runner.step("first boot: boot chain, Secure Boot "
                    + ("on" if args.secure_boot else "off")
                    + ", partitions, /data, identity, SSH, RAUC, Docker, fwupd", runner.first_boot)
        if args.kernel == "rt":
            runner.step("rt kernel: PREEMPT_RT, tuning from rt.conf into grubenv", runner.rt_kernel)
        if args.variant == "nvidia":
            runner.step("nvidia: driver, open modules, container runtime, no toolchain", runner.nvidia)
        runner.step("time: chrony, PTP from ptp.conf as chrony's source", runner.time_sync)
        runner.step("reboot: machine-id, host key, journal persist", runner.reboot_persists)
        if args.only != "boot":
            runner.step("update into slot B", runner.update_to_b)
            if args.only != "update":
                runner.step("fallback: an untested slot A falls back to B", runner.fallback)
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
        print(f"console: {vm.console}\nshell transcript: {os.path.join(workdir, 'shell.log')}")
        if not args.keep and ok:
            shutil.rmtree(workdir, ignore_errors=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
