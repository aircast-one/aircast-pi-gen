#!/bin/bash -e

HAILORT_VERSION="4.23.0"
PYTHON3_HAILORT_VERSION="4.23.0-1"
HAILO_MODULE="hailo_pci"
HEF_URL="https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.14.0/hailo8/yolov8m.hef"
HEF_SHA256="8cf0a6169b4bcecd345c1361db62bfe00d1eeb9c62d287473129e92db38b3986"
MODELS_DIR="/var/lib/aircast/models"

if [ -n "${AIRCASTD_VERSION:-}" ]; then
	detect_ver="${AIRCASTD_VERSION#v}"
	detect_ver="${detect_ver/-/\~}"
	detect_pkg="aircast-detect=${detect_ver}"
	detect_listed="| ${detect_ver} |"
else
	detect_pkg="aircast-detect"
	detect_listed="| "
fi

install -d -m 755 "${ROOTFS_DIR}${MODELS_DIR}"
install -m 644 files/yolov8m.labels "${ROOTFS_DIR}${MODELS_DIR}/yolov8m.labels"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 \
	"${HEF_URL}" -o "${ROOTFS_DIR}${MODELS_DIR}/yolov8m.hef"
echo "${HEF_SHA256}  ${ROOTFS_DIR}${MODELS_DIR}/yolov8m.hef" | sha256sum -c -
chmod 644 "${ROOTFS_DIR}${MODELS_DIR}/yolov8m.hef"

on_chroot << CHROOT
set -e

n=0
until apt-get update; do
	n=\$((n + 1))
	[ "\$n" -lt 5 ] || exit 1
	sleep 30
done
apt-get install -y --no-install-recommends \
	"hailort=${HAILORT_VERSION}" \
	"python3-hailort=${PYTHON3_HAILORT_VERSION}"
apt-mark hold hailort python3-hailort

cd /tmp
apt-get download "hailort-pcie-driver=${HAILORT_VERSION}"
rm -rf /tmp/hailo-pcie
dpkg-deb -x hailort-pcie-driver_*.deb /tmp/hailo-pcie
rm -f hailort-pcie-driver_*.deb
cp -a /tmp/hailo-pcie/etc/. /etc/
cp -a /tmp/hailo-pcie/lib/. /usr/lib/
cp -a /tmp/hailo-pcie/usr/. /usr/
rm -rf /tmp/hailo-pcie
ln -sf "/usr/lib/firmware/hailo/hailo8_fw.${HAILORT_VERSION}.bin" /usr/lib/firmware/hailo/hailo8_fw.bin

rm -rf "/usr/src/${HAILO_MODULE}-${HAILORT_VERSION}"
cp -a /usr/src/hailort-pcie-driver "/usr/src/${HAILO_MODULE}-${HAILORT_VERSION}"
sed "s/@PCIE_DRIVER_VERSION@/${HAILORT_VERSION}/g" \
	/usr/src/hailort-pcie-driver/linux/pcie/dkms.conf.in \
	> "/usr/src/${HAILO_MODULE}-${HAILORT_VERSION}/dkms.conf"
dkms add -m "${HAILO_MODULE}" -v "${HAILORT_VERSION}"

built=0
for kbuild in /lib/modules/*/build; do
	[ -d "\${kbuild}" ] || continue
	kver="\$(basename "\$(dirname "\${kbuild}")")"
	echo "hailo: building ${HAILO_MODULE} for \${kver}"
	dkms build -m "${HAILO_MODULE}" -v "${HAILORT_VERSION}" -k "\${kver}"
	dkms install -m "${HAILO_MODULE}" -v "${HAILORT_VERSION}" -k "\${kver}"
	built=\$((built + 1))
done

kernels=\$(find /lib/modules -mindepth 2 -maxdepth 2 -name modules.order | wc -l)
if [ "\${built}" -eq 0 ] || [ "\${built}" -ne "\${kernels}" ]; then
	echo "hailo: built ${HAILO_MODULE} for \${built} of \${kernels} kernels" >&2
	exit 1
fi

if apt-cache madison aircast-detect | grep -qF "${detect_listed}"; then
	dpkg-divert --local --rename --add /usr/bin/systemctl
	ln -sf /bin/true /usr/bin/systemctl
	apt-get install -y --allow-downgrades "${detect_pkg}"
	rm -f /usr/bin/systemctl
	dpkg-divert --local --rename --remove /usr/bin/systemctl
	systemctl enable aircast-detect.service
elif [ -f /etc/systemd/system/aircast-detect.service ]; then
	systemctl enable aircast-detect.service
else
	echo "hailo: neither the aircast-detect package nor an aircastd with the detector; detection sidecar not installed"
fi

python3 -c "import hailo_platform, cv2, numpy; print('hailo: hailo_platform ok, opencv', cv2.__version__)"
echo "hailo: HailoRT ${HAILORT_VERSION}, ${HAILO_MODULE} for \${built} kernel(s), yolov8m.hef installed"
CHROOT
