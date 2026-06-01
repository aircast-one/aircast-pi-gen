#!/bin/bash -e

# Install Fluent Bit to ship aircast-agent journal logs to Loki.
#
# Fluent Bit reads the systemd journal for aircast-agent.service, parses the
# JSON payload emitted by slog, and pushes records to Grafana Loki.
#
# Loki credentials and device labels are not baked into the image. They are
# materialised by aircast-agent at activation time into:
#   /etc/aircast/loki-creds.env     (LOKI_HOST/LOKI_USERNAME/LOKI_PASSWORD)
#   /etc/aircast/device-labels.env  (DEVICE_ID/DEVICE_NAME/ENVIRONMENT/VERSION/HOST)
# Both files are sourced by the fluent-bit systemd unit via an EnvironmentFile
# drop-in. The leading "-" in EnvironmentFile makes the unit start successfully
# before activation has populated the files; Fluent Bit will simply fail to
# deliver to Loki until the env vars resolve, then a restart picks them up.

on_chroot << EOF
# Add Fluent Bit repository (Debian bookworm to match the Pi image).
curl -fsSL https://packages.fluentbit.io/fluentbit.key | gpg --dearmor -o /usr/share/keyrings/fluentbit.gpg
echo "deb [signed-by=/usr/share/keyrings/fluentbit.gpg] https://packages.fluentbit.io/debian/bookworm bookworm main" > /etc/apt/sources.list.d/fluent-bit.list

apt-get update
apt-get install -y fluent-bit
EOF

# Drop our Fluent Bit configuration. We replace the default service config and
# parsers file so the json parser understands slog's RFC3339 timestamps.
install -m 644 files/fluent-bit.conf "${ROOTFS_DIR}/etc/fluent-bit/fluent-bit.conf"
install -m 644 files/fluent-bit-parsers.conf "${ROOTFS_DIR}/etc/fluent-bit/parsers.conf"

# systemd drop-in: source Loki creds + device labels at unit start. Files are
# allowed to be missing (leading "-") so the unit starts on freshly imaged Pis
# before activation has written them.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system/fluent-bit.service.d"
install -m 644 files/fluent-bit-env.conf "${ROOTFS_DIR}/etc/systemd/system/fluent-bit.service.d/env.conf"

# Aircast runtime config directory and Fluent Bit buffer directory.
install -d -m 0750 -o root -g root "${ROOTFS_DIR}/etc/aircast"
install -d -m 0750 -o root -g root "${ROOTFS_DIR}/var/lib/fluent-bit"
install -d -m 0750 -o root -g root "${ROOTFS_DIR}/var/lib/fluent-bit/buffer"

on_chroot << EOF
systemctl enable fluent-bit.service
EOF
