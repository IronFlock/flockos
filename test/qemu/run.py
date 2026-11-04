#!/usr/bin/env python3
"""Boot a built FlockOS image in QEMU and test it (docs/testing.md).

  run.py --target amd64-efi --variant base [--out out] [--work DIR]
         [--docker-image-tar FILE] [--keep]

The image under test is the artefact from `just build`, unchanged except for
one value in the FLOCKOS partition's grubenv of the test copy:
FLOCKOS_CMDLINE asks systemd for a root debug shell on the second serial
port (systemd.debug_shell=ttyS1), which this script drives. grubenv lives on
the FLOCKOS partition, so the shell is there on both slots, before and after
an update.

Sequence (WP-1.3, WP-1.4, WP-1.7): first boot (partitions grown, /data
layout, identity, SSH policy, RAUC slot A good, Docker, fwupd); reboot
(state persists); update into slot B with the bundle of the same build;
fallback: an update into slot A that is never marked good falls back to B.

Needs: qemu-system-<arch>, OVMF/AAVMF firmware, mtools (mcopy). Standard
library only; run with `python3 -I`.
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
DEBUG_CMDLINE = "systemd.debug_shell=ttyS1"
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
    def __init__(self, arch, disk, workdir, kvm):
        self.arch, self.disk, self.workdir, self.kvm = arch, disk, workdir, kvm
        self.sock_path = os.path.join(workdir, "shell.sock")
        self.console = os.path.join(workdir, "console.log")
        self.proc = None
        self.sock = None
        self.buf = b""
        self.transcript = open(os.path.join(workdir, "shell.log"), "ab")

    def firmware(self):
        for code, vars_ in FIRMWARE[self.arch]:
            if os.path.exists(code):
                return code, vars_
        raise TestFailure(f"no UEFI firmware for {self.arch} found (install ovmf / qemu-efi-aarch64)")

    def start(self, qemu, http_port):
        code, vars_template = self.firmware()
        vars_copy = os.path.join(self.workdir, "efivars.fd")
        if vars_template and not os.path.exists(vars_copy):
            shutil.copy(vars_template, vars_copy)
        cmd = [qemu, "-m", "2048", "-smp", "2", "-display", "none", "-no-user-config", "-nodefaults"]
        if self.arch == "amd64":
            cmd += ["-machine", "q35", "-device", "i6300esb"]
        else:
            cmd += ["-machine", "virt"]
        cmd += ["-accel", "kvm", "-cpu", "host"] if self.kvm else ["-accel", "tcg", "-cpu", "max"]
        cmd += ["-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}"]
        if vars_template:
            cmd += ["-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}"]
        cmd += [
            "-drive", f"file={self.disk},format=raw,if=virtio,cache=unsafe",
            "-nic", "user,model=virtio-net-pci",
            "-serial", f"file:{self.console}",
            "-serial", f"unix:{self.sock_path},server=on,wait=off",
            "-device", "virtio-rng-pci",
        ]
        log("qemu: " + " ".join(cmd))
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        deadline = time.time() + 30
        while not os.path.exists(self.sock_path):
            if self.proc.poll() is not None:
                raise TestFailure(f"qemu exited with {self.proc.returncode}")
            if time.time() > deadline:
                raise TestFailure("qemu made no serial socket")
            time.sleep(0.2)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.sock_path)
        self.sock.setblocking(False)

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

    def wait_shell(self, timeout):
        """Wait until the debug shell on ttyS1 answers; returns its boot id."""
        deadline = time.time() + timeout
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
                return self.run("cat /proc/sys/kernel/random/boot_id").strip()
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
        self._send("systemctl reboot\r")
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(5)
            # The old shell may still answer while the system goes down.
            new = self.wait_shell(max(10, deadline - time.time()))
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
    def __init__(self, vm, conf, image_id, http_port, docker_tar, boot_timeout):
        self.vm, self.conf, self.image_id = vm, conf, image_id
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
        return json.loads(self.vm.run("rauc status --output-format=json"))

    def booted(self):
        return self.rauc_status().get("booted")

    def first_boot(self):
        self.vm.wait_shell(self.boot_timeout)
        self.wait_running()
        osr = self.vm.run("cat /etc/os-release")
        if f"IMAGE_ID={self.image_id}" not in osr or "ID=flockos" not in osr:
            raise TestFailure(f"unexpected os-release:\n{osr}")
        parts = self.vm.run("lsblk -bnro PARTLABEL,SIZE /dev/vda | sed '/^ /d'")
        sizes = dict(line.split() for line in parts.splitlines() if len(line.split()) == 2)
        for label in ("FLOCKOS", "rootfs-a", "rootfs-b", "data"):
            if label not in sizes:
                raise TestFailure(f"partition {label} missing:\n{parts}")
        if int(sizes["rootfs-b"]) != int(sizes["rootfs-a"]):
            raise TestFailure(f"slot B ({sizes['rootfs-b']}) differs from slot A ({sizes['rootfs-a']})")
        if int(sizes["data"]) < 10 * 1024**3:
            raise TestFailure(f"/data was not grown to the disk: {sizes['data']} bytes")
        for path, source in (("/data", None), ("/opt/ironflock", "/data/ironflock"), ("/home", "/data/home"),
                             ("/var/log/journal", "/data/log/journal"), ("/var/lib/fwupd", "/data/fwupd"),
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
        if self._slots().get("rootfs.0", {}).get("boot_status") != "good":
            raise TestFailure(f"slot A was not marked good: {status}")
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
        self.vm.run("echo flockos-test > /data/flockos-test-marker")

    def reboot_persists(self):
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
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
        if self.vm.run("ssh-keygen -lf /data/etc/ssh/ssh_host_ed25519_key.pub").strip() != self.host_key:
            raise TestFailure("the SSH host key changed with the update")
        state = self._slots().get("rootfs.1", {}).get("boot_status")
        if state != "good":
            raise TestFailure(f"slot B was not marked good: {state}")

    def _slots(self):
        out = {}
        for entry in self.rauc_status().get("slots", []):
            for name, info in entry.items():
                out[name] = info
        return out

    def fallback(self):
        self.vm.run(f"grub-editenv /boot/efi/EFI/BOOT/grubenv set 'FLOCKOS_CMDLINE={DEBUG_CMDLINE} flockos.no-mark-good'")
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
        self.vm.reboot(self.boot_timeout)
        self.wait_running()
        if self.booted() != "B":
            raise TestFailure(f"booted {self.booted()}: an untested slot A must fall back to B")
        self.vm.run(f"grub-editenv /boot/efi/EFI/BOOT/grubenv set 'FLOCKOS_CMDLINE={DEBUG_CMDLINE}'")
        self.vm.run("rauc status mark-good")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--target", default="amd64-efi")
    ap.add_argument("--variant", default="base")
    ap.add_argument("--kernel", default="std")
    ap.add_argument("--out", default=os.path.join(REPO, "out"))
    ap.add_argument("--work")
    ap.add_argument("--disk-size", default="20G")
    ap.add_argument("--docker-image-tar", help="docker save output of hello-world, loaded and run in the VM")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--only", choices=["boot", "update"], help="stop after this part")
    args = ap.parse_args()

    conf = load_conf(os.path.join(REPO, "targets", args.target, "target.conf"))
    arch = conf["ARCH"]
    image_id = f"flockos-{args.target}-{args.variant}" + ("-rt" if args.kernel == "rt" else "")
    with open(os.path.join(REPO, "VERSION")) as fh:
        version = fh.read().strip()
    artefacts = os.path.join(args.out, image_id)
    img_gz = os.path.join(artefacts, f"{image_id}-{version}.img.gz")
    bundle = os.path.join(artefacts, f"{image_id}-{version}.raucb")
    for f in (img_gz, bundle):
        if not os.path.exists(f):
            sys.exit(f"{f} not found: run `just build {args.target} {args.variant}` first")
    for tool in (conf["QEMU_SYSTEM"], "mcopy"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is required")

    workdir = args.work or tempfile.mkdtemp(prefix="flockos-qemu-")
    os.makedirs(workdir, exist_ok=True)
    disk = os.path.join(workdir, "disk.img")
    log(f"work directory {workdir}")
    with gzip.open(img_gz, "rb") as src, open(disk, "wb") as dst:
        shutil.copyfileobj(src, dst, 16 * 1024 * 1024)
    size = {"G": 1024**3, "M": 1024**2}[args.disk_size[-1]] * int(args.disk_size[:-1])
    os.truncate(disk, size)
    set_test_cmdline(disk, workdir, DEBUG_CMDLINE)

    serve_dir = os.path.join(workdir, "http")
    os.makedirs(serve_dir, exist_ok=True)
    os.link(bundle, os.path.join(serve_dir, "bundle.raucb")) if os.stat(bundle).st_dev == os.stat(serve_dir).st_dev else shutil.copy(bundle, os.path.join(serve_dir, "bundle.raucb"))
    if args.docker_image_tar:
        shutil.copy(args.docker_image_tar, serve_dir)
    server, port = serve(serve_dir)

    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK) and arch == {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine)
    boot_timeout = 300 if kvm else 1500
    log(f"accelerator: {'kvm' if kvm else 'tcg (slow)'}")
    vm = VM(arch, disk, workdir, kvm)
    runner = Runner(vm, conf, image_id, port, args.docker_image_tar, boot_timeout)
    ok = False
    try:
        vm.start(conf["QEMU_SYSTEM"], port)
        runner.step("first boot: partitions, /data, identity, SSH, RAUC, Docker, fwupd", runner.first_boot)
        runner.step("reboot: machine-id, host key, journal persist", runner.reboot_persists)
        if args.only != "boot":
            runner.step("update into slot B", runner.update_to_b)
            if args.only != "update":
                runner.step("fallback: an untested slot A falls back to B", runner.fallback)
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
