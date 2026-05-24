#!/bin/bash -e

# Create first-boot aircast update service
on_chroot << EOF
# Create the update script
cat > /usr/local/bin/aircast-first-update.sh << 'SCRIPT_EOF'
#!/bin/bash

# Wait for internet connectivity (with timeout)
TIMEOUT=300  # 5 minutes
ELAPSED=0
while ! ping -c 1 8.8.8.8 >/dev/null 2>&1; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "Timeout waiting for internet connectivity"
        exit 1
    fi
done

# Additional check for APT repository accessibility
while ! curl -s --head https://aircast-apt.s3.us-east-1.amazonaws.com >/dev/null 2>&1; do
    sleep 5
done

# Update and upgrade aircast-agent to latest
apt-get update
apt-get upgrade -y aircast-agent

# Disable this service after successful run
systemctl disable aircast-first-update.service

# Clean up
rm -f /usr/local/bin/aircast-first-update.sh
rm -f /etc/systemd/system/aircast-first-update.service

SCRIPT_EOF

chmod +x /usr/local/bin/aircast-first-update.sh

# Create systemd service
cat > /etc/systemd/system/aircast-first-update.service << 'SERVICE_EOF'
[Unit]
Description=Update aircast-agent on first boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/aircast-first-update.sh
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable the service
systemctl enable aircast-first-update.service
EOF

# Enable console login (getty on tty1)
on_chroot << EOF
systemctl enable getty@tty1.service
EOF
