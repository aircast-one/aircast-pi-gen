#!/bin/bash
# Setup script for GitHub Actions self-hosted runner on dev.aircast.one

set -e

echo "🚀 Setting up GitHub Actions runner environment..."

# Check if running as dev user
if [ "$(whoami)" != "dev" ]; then
    echo "❌ Please run this script as the 'dev' user"
    exit 1
fi

# Install Docker
echo "📦 Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
    echo "✅ Docker installed"
else
    echo "✅ Docker already installed"
fi

# Add dev user to docker group
echo "👤 Adding dev user to docker group..."
sudo usermod -aG docker dev
echo "✅ User added to docker group"

# Install additional build dependencies
echo "📦 Installing build dependencies..."
sudo apt-get update
sudo apt-get install -y \
    coreutils quilt parted qemu-user-static debootstrap zerofree zip \
    dosfstools libarchive-tools libcap2-bin grep rsync xz-utils file git curl bc \
    gpg pigz xxd arch-test bmap-tools

echo "✅ Dependencies installed"

# Verify Docker works without sudo
echo "🔍 Verifying Docker setup..."
if newgrp docker << EOF
docker run hello-world > /dev/null 2>&1
EOF
then
    echo "✅ Docker is working correctly"
else
    echo "⚠️  Docker group change requires logout/login or run: newgrp docker"
fi

# Restart GitHub Actions runner
echo "🔄 Restarting GitHub Actions runner..."
if [ -d ~/actions-runner ]; then
    cd ~/actions-runner
    
    # Try to stop the service if it exists
    if [ -f ./svc.sh ]; then
        sudo ./svc.sh stop 2>/dev/null || true
        sleep 2
        sudo ./svc.sh start
        echo "✅ Runner service restarted"
    else
        # Kill any existing runner process
        pkill -f Runner.Listener 2>/dev/null || true
        sleep 2
        
        # Start runner in background
        nohup ./run.sh > runner.log 2>&1 &
        echo "✅ Runner started in background (PID: $!)"
        echo "📝 Logs available at: ~/actions-runner/runner.log"
    fi
else
    echo "⚠️  GitHub Actions runner not found at ~/actions-runner"
    echo "Please ensure the runner is installed"
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "⚠️  IMPORTANT: You may need to logout and login again for Docker group changes to take effect"
echo "   Or run: newgrp docker"
echo ""
echo "📋 Next steps:"
echo "1. Verify runner is online: gh api /repos/pavliha/aircast-pi-gen/actions/runners"
echo "2. Test workflow: gh workflow run 'Build and Release Pi Development Images' --ref develop"