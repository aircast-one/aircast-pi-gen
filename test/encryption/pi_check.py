#!/usr/bin/env python3
import argparse
import subprocess
import sys

REMOTE = r"""
set -u
case "$(uname -r)" in *2712*) initramfs=/boot/firmware/initramfs_2712 ;; *) initramfs=/boot/firmware/initramfs8 ;; esac
contents=$(lsinitramfs "$initramfs" 2>/dev/null)
has() { printf '%s\n' "$contents" | grep -q "$1" && echo yes || echo no; }
echo "root_fs=$(findmnt -no FSTYPE /)"
echo "data_src=$(findmnt -no SOURCE /data 2>/dev/null || echo none)"
echo "luks=$(sudo -n cryptsetup status data >/dev/null 2>&1 && echo yes || echo no)"
echo "marker=$([ -e /boot/firmware/aircast-encrypt ] && echo yes || echo no)"
echo "crypttab=$(awk '$1=="data"{print $4}' /etc/crypttab 2>/dev/null)"
echo "ip=$(sed -n 's/^IP=//p' /etc/initramfs-tools/conf.d/aircast-ip 2>/dev/null)"
echo "cmdline_ip=$(tr ' ' '\n' </boot/firmware/cmdline.txt | sed -n 's/^ip=//p' | grep . || echo none)"
echo "initramfs_usb_ethernet=$(has r8152.ko)"
echo "initramfs=$initramfs"
echo "initramfs_crypttab=$(has cryptroot/crypttab)"
echo "initramfs_clevis=$(has clevis-decrypt-sss)"
echo "initramfs_curlrc=$(has .curlrc)"
echo "initramfs_wifi_conf=$(has aircast-initramfs.conf)"
echo "initramfs_brcmfmac=$(has brcmfmac.ko)"
echo "initramfs_brcmfmac_vendor=$(has brcmfmac-wcc.ko)"
echo "initramfs_brcm_fw=$(has lib/firmware/brcm/brcmfmac)"
echo "wifi_staged=$([ -e /etc/wpa_supplicant/aircast-initramfs.conf ] && echo yes || echo no)"
echo "initramfs_supplicant_left=$(pgrep -f aircast-initramfs.conf >/dev/null && echo yes || echo no)"
echo "eth0_carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo none)"
"""


def facts(host):
    out = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "sh -s"],
                         input=REMOTE, capture_output=True, text=True, check=True).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def expectations(wifi, cloud):
    base = {"root_fs": "overlay", "data_src": "/dev/mapper/data", "luks": "yes", "marker": "no",
            "crypttab": "luks,initramfs", "ip": "::::::dhcp", "cmdline_ip": "none", "initramfs_usb_ethernet": "yes",
            "initramfs_crypttab": "yes", "initramfs_clevis": "yes"}
    return {**base,
            **({"initramfs_curlrc": "yes"} if cloud else {}),
            **({"wifi_staged": "yes", "initramfs_wifi_conf": "yes",
                "initramfs_brcmfmac": "yes", "initramfs_brcmfmac_vendor": "yes", "initramfs_brcm_fw": "yes",
                "initramfs_supplicant_left": "no"} if wifi else {})}


def main():
    parser = argparse.ArgumentParser(
        description="Check an encrypted Aircast card after it booted on a real Pi (run after an unattended boot).")
    parser.add_argument("host", help="ssh target, e.g. pi@falcon or pi@100.64.0.15")
    parser.add_argument("--wifi", action="store_true", help="the card was flashed with Wi-Fi")
    parser.add_argument("--cloud", action="store_true", help="the card binds to the Aircast Cloud key server (https)")
    args = parser.parse_args()

    got = facts(args.host)
    want = expectations(args.wifi, args.cloud)
    rows = [(k, got.get(k, "missing"), v) for k, v in want.items()]
    failed = [r for r in rows if r[1] != r[2]]
    print(f"{args.host}: {got.get('initramfs')}  (eth0 carrier: {got.get('eth0_carrier')})")
    print("\n".join(f"  {'PASS' if g == w else 'FAIL'}  {k} = {g}" + ("" if g == w else f"  (want {w})") for k, g, w in rows))
    if args.wifi and got.get("eth0_carrier") not in ("0", "none"):
        print("  NOTE  eth0 has a link — unplug Ethernet and reboot to prove the unlock came over Wi-Fi")
    print(f"\n{len(rows) - len(failed)}/{len(rows)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
