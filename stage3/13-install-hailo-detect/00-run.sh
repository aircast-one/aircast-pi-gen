#!/bin/bash -e
# aircast-detect: on-device object detection on the Hailo-8. Installs the Hailo
# stack (hailo_pci driver + HailoRT + Python bindings via hailo-all), the
# inference sidecar, and a YOLO model. The sidecar pulls each enabled camera,
# runs the model on the Hailo-8, and posts normalized boxes back to aircastd,
# which relays them to the web and QGC overlays. The video path is untouched.
#
# This stage is a no-op at runtime on devices without a Hailo-8 HAT: the sidecar
# service starts, finds no /dev/hailo0, and restart-loops harmlessly until the
# board is present. Everything else (video, telemetry) is unaffected.

# Hailo-8 HAT runs on the Pi 5 PCIe connector at Gen3.
CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
if [ -f "${CONFIG}" ] && ! grep -q '^dtparam=pciex1_gen=3' "${CONFIG}"; then
	printf '\n# Hailo-8 AI HAT on the PCIe connector\ndtparam=pciex1_gen=3\n' >> "${CONFIG}"
fi

# Hailo stack from the Raspberry Pi OS repos: hailo-all pulls the hailo_pci DKMS
# driver, firmware, HailoRT, TAPPAS core, and the python3 hailort bindings
# (hailo_platform). Plus OpenCV + NumPy for the sidecar's frame handling.
on_chroot << 'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends hailo-all python3-opencv python3-numpy
EOF

# Sidecar worker + its unit and env file.
install -d -m 755 "${ROOTFS_DIR}/usr/local/lib/aircast-detect"
install -m 755 files/detect.py "${ROOTFS_DIR}/usr/local/lib/aircast-detect/detect.py"
install -m 644 files/aircast-detect.default "${ROOTFS_DIR}/etc/default/aircast-detect"
install -m 644 files/aircast-detect.service "${ROOTFS_DIR}/etc/systemd/system/aircast-detect.service"

# Models live where aircastd expects them; the active one is an operator setting
# in the UI. Two are shipped:
#   * visdrone.hef — the default. A YOLOv8s trained on the VisDrone aerial
#     dataset (10 classes: pedestrian/car/truck/bus/…), compiled to Hailo-8.
#     COCO's ground-level classes misread a top-down drone view (a truck seen
#     from above becomes "boat"/"train"); this is the model a drone actually
#     needs. Its labels are served from <model>.labels.
#   * yolov8m.hef — COCO-80, the broader ground-level model, kept as an
#     alternative the operator can switch to. Symlinked from the hailo-all build
#     (or downloaded), so it costs no image space.
install -d -m 755 "${ROOTFS_DIR}/var/lib/aircast/models"
install -m 644 files/visdrone.hef "${ROOTFS_DIR}/var/lib/aircast/models/visdrone.hef"
install -m 644 files/visdrone.labels "${ROOTFS_DIR}/var/lib/aircast/models/visdrone.labels"

install -m 644 files/coco.labels "${ROOTFS_DIR}/var/lib/aircast/models/yolov8m.labels"
COCO_DST="${ROOTFS_DIR}/var/lib/aircast/models/yolov8m.hef"
SHIPPED="/usr/share/hailo-models/yolov8s_h8.hef"
if [ -f "${ROOTFS_DIR}${SHIPPED}" ]; then
	ln -sf "${SHIPPED}" "${COCO_DST}"
	echo "aircast-detect: COCO model -> ${SHIPPED}"
elif curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 30 -o "${COCO_DST}" \
	"${HAILO_MODEL_URL:-https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.13.0/hailo8/yolov8s.hef}"; then
	chmod 644 "${COCO_DST}"
else
	rm -f "${COCO_DST}"
	echo "WARNING: aircast-detect: COCO model absent; visdrone.hef remains the default."
fi

on_chroot << 'EOF'
systemctl enable aircast-detect.service
EOF
