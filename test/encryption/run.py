#!/usr/bin/env python3
import argparse
import hashlib
import os
import re
import secrets
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIGEN = HERE.parents[1]
FLASHER = Path(os.environ.get("AIRCAST_FLASHER", PIGEN.parent / "aircast-flasher"))
WORK = HERE / ".work"
BUILDER = "aircast-encryption-test"
TANG = "aircast-encryption-tang"
TANG_PORT = 7500
TANG_FROM_GUEST = f"http://10.0.2.2:{TANG_PORT}"
CARD_BYTES = 4 << 30
PROMPT = re.compile(rb"Please unlock disk data")
REPORT = re.compile(rb"AIRCAST-TEST-REPORT ([^\r\n]*)")
PROGRESS = re.compile(rb"Welcome to |AIRCAST-TEST-REPORT")
ENROLLED = b"data partition encrypted"
PLAIN_READY = b"data partition ready"


@dataclass
class Boot:
    log: bytes
    prompted: bool
    timed_out: bool
    held: bool

    def report(self):
        found = REPORT.findall(self.log)
        return dict(pair.split("=", 1) for pair in found[-1].decode().split()) if found else {}


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def digest():
    roots = [HERE / "Dockerfile", HERE / "build-image.sh", HERE / "cmdline.txt", HERE / "rootfs", PIGEN / "stage0/02-firmware", PIGEN / "stage3/12-overlay"]
    files = sorted(p for r in roots for p in ([r] if r.is_file() else r.rglob("*")) if p.is_file())
    return hashlib.sha256(b"".join(str(f.relative_to(PIGEN)).encode() + f.read_bytes() for f in files)).hexdigest()


def base_key():
    parts = [HERE / "Dockerfile", PIGEN / "stage3/12-overlay/00-packages"]
    return "base-" + hashlib.sha256(b"".join(p.read_bytes() for p in parts)).hexdigest()[:16] + ".tar"


def ensure_builder():
    run("docker", "build", "-q", "-t", BUILDER, str(HERE), stdout=subprocess.DEVNULL)


def ensure_image(rebuild):
    image, stamp = WORK / "disk.img", WORK / "disk.digest"
    want = digest()
    if not rebuild and image.exists() and stamp.exists() and stamp.read_text() == want:
        return image
    print("building test image (Debian trixie arm64 + real stage3/12-overlay)…", flush=True)
    run("docker", "run", "--rm", "--privileged", "-e", f"BASE={base_key()}",
        "-v", f"{PIGEN}:/pi-gen:ro", "-v", f"{WORK}:/out", BUILDER, "bash", "/pi-gen/test/encryption/build-image.sh")
    stamp.write_text(want)
    return image


def tang_up():
    subprocess.run(["docker", "rm", "-f", TANG], capture_output=True)
    run("docker", "run", "-d", "--name", TANG, "-p", f"127.0.0.1:{TANG_PORT}:{TANG_PORT}", BUILDER, "sh", "-c",
        f"mkdir -p /var/db/tang && /usr/libexec/tangd-keygen /var/db/tang && exec socat TCP-LISTEN:{TANG_PORT},reuseaddr,fork "
        f"EXEC:'/usr/libexec/tangd /var/db/tang'", stdout=subprocess.DEVNULL)
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            return urllib.request.urlopen(f"http://127.0.0.1:{TANG_PORT}/adv", timeout=2).read().decode()
        except OSError:
            time.sleep(0.5)
    raise RuntimeError("Tang did not come up")


def tang_down():
    subprocess.run(["docker", "rm", "-f", TANG], capture_output=True)


def flash_card(image, card, adv=None, key=None, wifi=None):
    run("cargo", "build", "-q", "--release", "-p", "flasher-core", "--example", "flash_card", cwd=FLASHER)
    tool = FLASHER / "target/release/examples/flash_card"
    args = [str(tool), "--image", str(image), "--card", str(card), "--card-bytes", str(CARD_BYTES)]
    if adv is not None:
        adv_file = WORK / "adv.json"
        adv_file.write_text(adv)
        args += ["--tang-url", TANG_FROM_GUEST, "--tang-adv", str(adv_file), "--recovery-key", key]
    if wifi is not None:
        args += ["--wifi-ssid", wifi[0], "--wifi-password", wifi[1]]
    run(*args)


def fat_offset(card):
    with open(card, "rb") as f:
        mbr = f.read(512)
    return struct.unpack_from("<I", mbr, 446 + 8)[0] * 512


def extract_boot(card):
    out = WORK / "boot"
    out.mkdir(exist_ok=True)
    run("docker", "run", "--rm", "-e", "MTOOLS_SKIP_CHECK=1", "-v", f"{WORK}:/w", BUILDER,
        "mcopy", "-o", "-n", "-i", f"/w/{card.name}@@{fat_offset(card)}",
        "::kernel8.img", "::initramfs8", "::cmdline.txt", "/w/boot/")
    return out


def mtools(card, tool, *args, check=True):
    return subprocess.run(["docker", "run", "--rm", "-e", "MTOOLS_SKIP_CHECK=1", "-v", f"{WORK}:/w", BUILDER,
                           tool, "-i", f"/w/{card.name}@@{fat_offset(card)}", *args], capture_output=True, check=check)


def boot_log(card):
    out = mtools(card, "mtype", "::aircast-boot.log", check=False)
    return out.stdout.decode(errors="replace") if out.returncode == 0 else ""


def fight_mode(card, on):
    flag = WORK / "fight-flag"
    flag.touch()
    if on:
        mtools(card, "mcopy", "-o", f"/w/{flag.name}", "::aircast-fight-mode")
    else:
        mtools(card, "mdel", "::aircast-fight-mode")


def boot(card, extra, name, answer=None, hold=60, timeout=1800, dead_nic=False):
    files = extract_boot(card)
    cmdline = (files / "cmdline.txt").read_text().strip() + (" " + extra if extra else "")
    cmd = ["qemu-system-aarch64", "-M", "virt", "-accel", "hvf", "-cpu", "host", "-m", "2048", "-smp", "4",
           "-kernel", str(files / "kernel8.img"), "-initrd", str(files / "initramfs8"), "-append", cmdline,
           "-device", "sdhci-pci", "-drive", f"if=none,id=sd,file={card},format=raw,cache=unsafe,discard=unmap,detect-zeroes=unmap", "-device", "sd-card,drive=sd",
           *(["-netdev", "hubport,id=dead,hubid=9", "-device", "virtio-net-pci,netdev=dead"] if dead_nic else []),
           "-netdev", "user,id=net", "-device", "virtio-net-pci,netdev=net",
           "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot"]
    log_path = WORK / "logs" / f"{name}.log"
    log_path.parent.mkdir(exist_ok=True)
    buf = bytearray()
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def pump():
        with open(log_path, "wb") as log:
            for chunk in iter(lambda: proc.stdout.read1(4096), b""):
                buf.extend(chunk)
                log.write(chunk)
                log.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    deadline, answered, timed_out, prompt_at, held = time.time() + timeout, False, False, None, False
    while proc.poll() is None:
        if time.time() > deadline:
            proc.kill()
            timed_out = True
            break
        prompt = PROMPT.search(buf)
        if answer is not None and not answered and prompt:
            prompt_at = prompt_at or time.time()
            if time.time() - prompt_at >= hold:
                held = not PROGRESS.search(buf, prompt.end())
                proc.stdin.write(answer.encode() + b"\r")
                proc.stdin.flush()
                answered = True
        time.sleep(0.2)
    proc.wait()
    reader.join(timeout=5)
    return Boot(bytes(buf), bool(PROMPT.search(buf)), timed_out, held)


def on_card(card, needle):
    pattern, overlap, found = needle.encode(), len(needle), False
    with open(card, "rb") as f:
        tail = b""
        for chunk in iter(lambda: f.read(64 << 20), b""):
            if pattern in tail + chunk:
                found = True
                break
            tail = chunk[-overlap:]
    return found


def expect(results, step, ok, detail=""):
    results.append((step, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {step}{'  — ' + detail if detail and not ok else ''}", flush=True)
    return ok


def expect_report(results, step, boot, **want):
    got = boot.report()
    bad = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
    detail = "timed out" if boot.timed_out else ("no report" if not got else ", ".join(f"{k}={g!r} want {w!r}" for k, (g, w) in bad.items()))
    return expect(results, step, bool(got) and not bad and not boot.timed_out, detail)


def lifecycle(image, results):
    print("encrypted card over Ethernet + recovery key", flush=True)
    adv = tang_up()
    card, key = WORK / "card-encrypted.img", secrets.token_hex(24)
    token = "AIRCAST-PLAINTEXT-PROBE-" + secrets.token_hex(8)
    flash_card(image, card, adv=adv, key=key)

    first = boot(card, "", "encrypted-1-first-boot")
    if not expect(results, "first boot enrols LUKS2 + Tang and reboots", ENROLLED in first.log and not first.timed_out,
                  "see .work/logs/encrypted-1-first-boot.log"):
        return

    second = boot(card, f"aircast.test=1 aircast.test.write={token}", "encrypted-2-tang-unlock")
    expect(results, "second boot unlocks from Tang unattended (Clevis answers cryptsetup)",
           bool(second.report()) and not second.timed_out, "did not finish booting without a typed key")
    expect_report(results, "data partition is the LUKS mapper under the overlay", second,
                  root_fs="overlay", data_src="/dev/mapper/data", luks="yes",
                  marker="no", crypttab="luks,initramfs", ip="::::::dhcp", probe=token)
    expect(results, "the boot log on the card records the unattended unlock",
           "data partition unlocked" in boot_log(card), "no unlock entry in aircast-boot.log")

    fight_mode(card, True)
    third = boot(card, "aircast.test=1", "encrypted-3-reboot")
    expect_report(results, "data written last boot survives a reboot", third, luks="yes", probe=token)
    expect(results, "fight mode leaves no boot log on the card", boot_log(card) == "",
           "aircast-boot.log is still on a fight-mode card")
    fight_mode(card, False)
    expect(results, "written data is not readable on the raw card", not on_card(card, token),
           "plaintext probe found in card image")

    tang_down()
    fourth = boot(card, "aircast.test=1", "encrypted-4-recovery", answer=key, timeout=600)
    expect(results, "with Tang unreachable it waits at the prompt and does not unlock on its own",
           fourth.held, "booted past the prompt before the key was typed" if fourth.prompted else "no prompt")
    expect_report(results, "recovery key unlocks and the data is intact", fourth, luks="yes", probe=token)
    log = boot_log(card)
    expect(results, "the boot log shows the wait for Tang, then the unlock",
           "waiting for the data partition" in log and f"tang {TANG_FROM_GUEST}" in log and "data partition unlocked" in log,
           "see aircast-boot.log on .work/card-encrypted.img")


def plain(image, results):
    print("unencrypted card (regression)", flush=True)
    card = WORK / "card-plain.img"
    token = "AIRCAST-PLAINTEXT-PROBE-" + secrets.token_hex(8)
    flash_card(image, card)
    first = boot(card, "", "plain-1-first-boot")
    if not expect(results, "first boot creates a plain data partition", PLAIN_READY in first.log and not first.timed_out):
        return
    second = boot(card, f"aircast.test=1 aircast.test.write={token}", "plain-2")
    expect_report(results, "overlay engages on the plain data partition", second, root_fs="overlay", luks="no", probe=token)
    expect(results, "control: the probe IS visible on an unencrypted card", on_card(card, token),
           "scan failed to find plaintext — the at-rest check would be meaningless")


def wifi_card_wired(image, results):
    print("encrypted Wi-Fi card booted with no Wi-Fi, on a cable", flush=True)
    adv = tang_up()
    card, key = WORK / "card-wifi.img", secrets.token_hex(24)
    flash_card(image, card, adv=adv, key=key, wifi=("aircast-test", "correct-horse-battery"))
    first = boot(card, "", "wifi-1-first-boot")
    if not expect(results, "first boot enrols with Wi-Fi staged for the initramfs", ENROLLED in first.log and not first.timed_out):
        return
    second = boot(card, "aircast.test=1", "wifi-2-wired-fallback", dead_nic=True)
    expect_report(results, "unlocks from Tang over whichever interface answers, past a dead one", second, luks="yes")
    tang_down()
    third = boot(card, "aircast.test=1", "wifi-3-recovery", answer=key, timeout=600)
    expect(results, "with Tang unreachable it waits at the prompt instead of unlocking",
           third.held, "booted past the prompt before the key was typed" if third.prompted else "no prompt")
    expect_report(results, "recovery key still unlocks it", third, luks="yes")


SCENARIOS = {"lifecycle": lifecycle, "plain": plain, "wifi": wifi_card_wired}


def main():
    parser = argparse.ArgumentParser(description="Boot-test Aircast card encryption in a VM (QEMU/HVF, real stage3 overlay).")
    parser.add_argument("scenarios", nargs="*", metavar="scenario", help=f"any of {', '.join(SCENARIOS)} (default: all)")
    parser.add_argument("--rebuild", action="store_true", help="rebuild the test image even if inputs are unchanged")
    args = parser.parse_args()
    unknown = [s for s in args.scenarios if s not in SCENARIOS]
    if unknown:
        parser.error(f"unknown scenario: {', '.join(unknown)}")
    WORK.mkdir(exist_ok=True)
    ensure_builder()
    image = ensure_image(args.rebuild)
    results = []
    try:
        for name in args.scenarios or list(SCENARIOS):
            SCENARIOS[name](image, results)
    finally:
        tang_down()
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed; logs in {WORK / 'logs'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
