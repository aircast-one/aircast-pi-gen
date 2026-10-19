import argparse
import asyncio
import base64
import gzip
import hashlib
import os
import re
import struct
import sys
import time
import zlib
from pathlib import Path

import aiortc.rtcrtpreceiver
import numpy as np
import zxingcpp
from aiortc.jitterbuffer import JitterBuffer
from jetkvm import JetKVMClient

HEADER = re.compile(rb"AIRCAST-KVM name=(\S+) size=(\d+) sha256=([0-9a-f]{64})")
QR_HEADER = struct.Struct(">2sHHHI")


class WholeFrameJitterBuffer(JitterBuffer):
    def __init__(self, capacity, prefetch=0, is_video=False):
        super().__init__(4096 if is_video else capacity, prefetch, is_video)


aiortc.rtcrtpreceiver.JitterBuffer = WholeFrameJitterBuffer


def save(name, data, elapsed):
    path = Path(Path(name).name)
    path.write_bytes(data)
    rate = len(data) / elapsed / 1024 if elapsed > 0 else 0
    print(f"saved {path} ({len(data)} bytes, {elapsed:.1f}s, {rate:.0f} KiB/s)", flush=True)


def unpack(frame):
    header, _, body = frame.partition(b"\n")
    match = HEADER.fullmatch(header)
    if match is None:
        return None, "missing AIRCAST-KVM header"
    name, size, digest = match.group(1).decode(), int(match.group(2)), match.group(3).decode()
    data = gzip.decompress(base64.b64decode(body.replace(b"\n", b"")))
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        return None, f"{name} arrived damaged"
    return (name, data), None


async def receive_serial(client, follow):
    channel = client._pc.createDataChannel("cdcacm")
    opened, arrived = asyncio.Event(), asyncio.Queue()
    channel.on("open", opened.set)
    channel.on("message", lambda m: arrived.put_nowait(m.encode() if isinstance(m, str) else m))
    await asyncio.wait_for(opened.wait(), 15)
    print("listening on the JetKVM USB serial port; run kvm-send on the Pi", flush=True)
    buffer, started = bytearray(), None
    while True:
        chunk = await arrived.get()
        started = started or time.monotonic()
        searched = max(0, len(buffer) - 4)
        buffer.extend(chunk)
        end = buffer.find(b"\nEND\n", searched)
        start = buffer.rfind(b"START\n", 0, end) if end >= 0 else -1
        if start < 0:
            continue
        result, problem = unpack(bytes(buffer[start + 6:end]))
        del buffer[:end + 5]
        if problem:
            print(problem, file=sys.stderr, flush=True)
        else:
            save(*result, time.monotonic() - started)
        started = None
        if not follow:
            return


def luma(frame):
    plane = frame.planes[0]
    rows = np.frombuffer(plane, dtype=np.uint8).reshape(frame.height, plane.line_size)
    return np.ascontiguousarray(rows[:, : frame.width])


def decode(gray):
    return [r.bytes for r in zxingcpp.read_barcodes(gray, formats=zxingcpp.BarcodeFormat.QRCode)]


async def receive_qr(client, name):
    print("watching HDMI for kvm-send QR codes", flush=True)
    parts, meta, started, last = {}, None, None, None
    while meta is None or len(parts) < meta[1]:
        client._frame_event.clear()
        try:
            await asyncio.wait_for(client._frame_event.wait(), 1)
        except TimeoutError:
            await client._request_keyframe()
            continue
        frame = client._latest_frame
        if frame is last:
            continue
        last = frame
        for blob in await asyncio.to_thread(decode, luma(frame)):
            if len(blob) < QR_HEADER.size or blob[:2] != b"AQ":
                continue
            _, xfer, index, total, crc = QR_HEADER.unpack(blob[: QR_HEADER.size])
            meta, started = meta or (xfer, total, crc), started or time.monotonic()
            if xfer == meta[0]:
                parts.setdefault(index, blob[QR_HEADER.size :])
    packed = b"".join(parts[i] for i in range(meta[1]))
    if zlib.crc32(packed) != meta[2]:
        sys.exit("the QR transfer arrived damaged")
    save(name, zlib.decompress(packed), time.monotonic() - started)


async def main():
    ap = argparse.ArgumentParser(description="Receive files a Pi sends with kvm-send through a JetKVM.")
    ap.add_argument("--qr", action="store_true", help="read QR codes from HDMI instead of the USB serial port")
    ap.add_argument("--name", default="kvm-qr.bin", help="QR: file name to save under")
    ap.add_argument("--follow", action="store_true", help="serial: keep receiving after the first file")
    args = ap.parse_args()
    url = os.environ.get("JETKVM_URL") or sys.exit("set JETKVM_URL to the KVM, e.g. http://192.168.1.102")
    client = JetKVMClient(base_url=url, password=os.environ.get("JETKVM_PASSWORD", ""), verify_tls=False)
    await client.connect()
    try:
        await (receive_qr(client, args.name) if args.qr else receive_serial(client, args.follow))
    finally:
        await client.close()


if __name__ == "__main__":
    asyncio.run(main())
