#!/usr/bin/env python3
"""Aircast detection sidecar.

Pulls the camera list + model path from aircastd, runs YOLO on the Hailo-8 via
HailoRT, and posts normalized boxes back per camera. The video path is never
touched — aircastd relays these boxes to viewers, who draw them.

Glue (config pull, frame grab, POST loop) is straightforward. The Hailo inference
call and the YOLO output decode are HailoRT-version and model specific — validate
them on the real device against your .hef. See README.md.
"""
from __future__ import annotations

import os
import time
import urllib.request
import json
import uuid
from dataclasses import dataclass, asdict
from typing import Sequence

import cv2  # opencv-python-headless, FFmpeg backend for RTSP
import numpy as np
from hailo_platform import (
    VDevice,
    HEF,
    ConfigureParams,
    HailoStreamInterface,
    InferVStreams,
    InputVStreamParams,
    OutputVStreamParams,
    FormatType,
)

API = os.environ.get("AIRCASTD_API", "http://127.0.0.1:80")
FPS = float(os.environ.get("DETECT_FPS", "5"))
CONF = float(os.environ.get("DETECT_CONF", "0.4"))
CONFIG_REFRESH = 10.0
# A dead RTSP session still reports isOpened(), so consecutive empty reads are
# the only stall signal. At DETECT_FPS this is a few seconds of black.
MAX_READ_MISSES = int(os.environ.get("DETECT_READ_MISSES", "15"))
REOPEN_BACKOFF_S = float(os.environ.get("DETECT_REOPEN_BACKOFF", "2"))
# A line per frame is a running commentary, not an event: at DETECT_FPS it is
# tens of thousands of records an hour on the device's card. The happy path is
# rolled up on this period instead; failures are never rolled up.
ROLLUP_S = float(os.environ.get("DETECT_ROLLUP", "30"))


@dataclass
class Box:
    label: str
    conf: float
    x: float
    y: float
    w: float
    h: float


def get_config() -> dict:
    with urllib.request.urlopen(f"{API}/api/detect/config", timeout=5) as r:
        return json.load(r)


def put_boxes(name: str, boxes: list[Box], request_id: str) -> None:
    body = json.dumps({"boxes": [asdict(b) for b in boxes]}).encode()
    req = urllib.request.Request(
        f"{API}/api/streams/{name}/detections",
        data=body,
        method="PUT",
        # aircastd keys its own wide event off this, so a failure here and the
        # request it caused can be read on one line.
        headers={"Content-Type": "application/json", "X-Request-Id": request_id},
    )
    urllib.request.urlopen(req, timeout=5).close()


class Model:
    """One loaded .hef. The infer() call follows HailoRT's InferVStreams API;
    input letterboxing and decode() are what you tune per model on the device."""

    def __init__(self, hef_path: str):
        self.hef = HEF(hef_path)
        self.target = VDevice()
        cfg = ConfigureParams.create_from_hef(self.hef, interface=HailoStreamInterface.PCIe)
        self.group = self.target.configure(self.hef, cfg)[0]
        self.in_info = self.hef.get_input_vstream_infos()[0]
        self.h, self.w = self.in_info.shape[0], self.in_info.shape[1]
        self.in_params = InputVStreamParams.make(self.group, format_type=FormatType.UINT8)
        self.out_params = OutputVStreamParams.make(self.group, format_type=FormatType.FLOAT32)

    def infer(self, frame_bgr: np.ndarray, labels: Sequence[str] = ()) -> list[Box]:
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        resized = cv2.resize(rgb, (self.w, self.h))
        batch = np.expand_dims(resized, axis=0)
        with self.group.activate():
            with InferVStreams(self.group, self.in_params, self.out_params) as pipe:
                out = pipe.infer({self.in_info.name: batch})
        return decode(out, CONF, labels)

    def release(self) -> None:
        try:
            self.target.release()
        except Exception:
            pass


def label_for(labels: Sequence[str], class_id: int) -> str:
    """The class list belongs to the .hef, so aircastd serves it from
    <model>.labels. With no file the honest answer is the class id — a built-in
    COCO table would put confident, wrong names on every box the moment someone
    loads a model trained on anything else."""
    return labels[class_id] if class_id < len(labels) else str(class_id)


def _box(det, label: str) -> Box:
    ymin, xmin, ymax, xmax = float(det[0]), float(det[1]), float(det[2]), float(det[3])
    return Box(label, round(float(det[4]), 3),
               round(xmin, 4), round(ymin, 4),
               round(xmax - xmin, 4), round(ymax - ymin, 4))


def decode(raw: dict, conf: float, labels: Sequence[str] = ()) -> list[Box]:
    """Turn a HAILO_NMS_BY_CLASS output into normalized boxes. The output is a
    dict keyed by output name; each value is list[batch] and batch[0] is a list
    of per-class arrays, each row [ymin, xmin, ymax, xmax, score] in 0..1."""
    return [
        _box(det, label_for(labels, class_id))
        for value in raw.values()
        if len(value)
        for class_id, dets in enumerate(value[0])
        for det in dets
        if float(det[4]) >= conf
    ]


def event(**fields) -> None:
    """One wide event per thing that happened, not a running commentary. The
    device side already emits these per HTTP request; matching the shape means a
    sidecar failure and the request it caused can be read together."""
    print(json.dumps({"svc": "aircast-detect", **fields}), flush=True)


class Rollup:
    """What the happy path did since the last line. One event per camera per
    ROLLUP_S carries the same fields a per-frame line did — count, boxes, and
    the slowest inference — without burying the lines that matter."""

    def __init__(self):
        self.frames = 0
        self.boxes = 0
        self.max_infer_ms = 0.0
        self.due_at = 0.0

    def record(self, boxes: int, infer_ms: float) -> None:
        self.frames += 1
        self.boxes += boxes
        self.max_infer_ms = max(self.max_infer_ms, infer_ms)

    def flush(self, name: str, now: float) -> None:
        if not self.due_at:
            self.due_at = now + ROLLUP_S
            return
        if now < self.due_at or not self.frames:
            return
        event(msg="frames", camera=name, frames=self.frames, boxes=self.boxes,
              max_infer_ms=round(self.max_infer_ms, 1), window_s=ROLLUP_S)
        self.frames = self.boxes = 0
        self.max_infer_ms = 0.0
        self.due_at = now + ROLLUP_S


class Capture:
    """One camera's frames, and the reopening a long flight needs. OpenCV keeps
    reporting isOpened() on an RTSP session the far end has already dropped, so
    a read that stops returning frames is the only signal there is — and the
    handle it is holding has to be released before another is opened, or every
    camera flap leaks an FFmpeg context for the life of the process."""

    def __init__(self, name: str, source: str):
        self.name = name
        self.source = source
        self.cap: cv2.VideoCapture | None = None
        self.misses = 0
        self.reopens = 0
        self.retry_at = 0.0
        self.rollup = Rollup()

    def read(self, now: float):
        if self.cap is None:
            if now < self.retry_at:
                return None
            self.cap = cv2.VideoCapture(self.source, cv2.CAP_FFMPEG)
            event(msg="stream opened", camera=self.name, source=self.source,
                  reopens=self.reopens)
        ok, frame = self.cap.read()
        if ok:
            self.misses = 0
            return frame
        self.misses += 1
        if self.misses >= MAX_READ_MISSES:
            self.reopens += 1
            event(msg="stream stalled, reopening", camera=self.name,
                  misses=self.misses, reopens=self.reopens)
            self.release()
            self.retry_at = now + REOPEN_BACKOFF_S
        return None

    def release(self) -> None:
        if self.cap is not None:
            self.cap.release()
            self.cap = None
        self.misses = 0


def reconcile(caps: dict[str, Capture], cams: list[dict]) -> None:
    """Captures follow the camera list. One dropped from config, or repointed at
    a new source, must have its handle released — a dict that only ever grows
    leaks every camera the operator has ever removed."""
    wanted = {c["name"]: c["source"] for c in cams}
    for name, cap in list(caps.items()):
        if wanted.get(name) != cap.source:
            cap.release()
            del caps[name]
    for name, source in wanted.items():
        if name not in caps:
            caps[name] = Capture(name, source)


def run() -> None:
    event(msg="starting", api=API, fps=FPS, conf=CONF)
    period = 1.0 / FPS
    caps: dict[str, Capture] = {}
    model: Model | None = None
    model_path = ""
    labels: list[str] = []
    cams: list[dict] = []
    next_config = 0.0

    while True:
        loop_start = time.monotonic()

        if loop_start >= next_config:
            next_config = loop_start + CONFIG_REFRESH
            try:
                cfg = get_config()
                cams = cfg.get("cameras", [])
                labels = cfg.get("labels") or []
                reconcile(caps, cams)
                if cfg.get("hef") and cfg["hef"] != model_path:
                    if model is not None:
                        model.release()
                        model = None
                    model_path = cfg["hef"]
                    model = Model(model_path)
                    event(msg="model loaded", hef=model_path, labels=len(labels),
                          cameras=[c["name"] for c in cams])
                    if not labels:
                        event(msg="no labels for this model — boxes are named by "
                                  "class id; add <model>.labels next to the .hef",
                              hef=model_path)
            except Exception as e:
                event(msg="config refresh failed", error=repr(e))

        for cap in caps.values():
            frame = cap.read(loop_start)
            if frame is None or model is None:
                continue
            started = time.monotonic()
            request_id = uuid.uuid4().hex[:16]
            try:
                boxes = model.infer(frame, labels)
                put_boxes(cap.name, boxes, request_id)
                cap.rollup.record(len(boxes), (time.monotonic() - started) * 1000)
                cap.rollup.flush(cap.name, loop_start)
            except Exception as e:
                event(msg="infer or post failed", camera=cap.name, error=repr(e),
                      request_id=request_id,
                      infer_ms=round((time.monotonic() - started) * 1000, 1))

        elapsed = time.monotonic() - loop_start
        time.sleep(max(0.0, period - elapsed))


if __name__ == "__main__":
    run()
