#!/bin/bash

# K9s Installer Script for MicroK8s
# Works out-of-the-box on Ubuntu
# Handles architecture detection, kubeconfig setup, and alias creation

set -euo pipefail

K9S_BIN="/usr/local/bin/k9s"
USER_NAME=$(whoami)

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq) ==="
sudo apt install -y curl tar jq

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)   K9S_ARCH="amd64" ;;
    aarch64)  K9S_ARCH="arm64" ;;
    armv7l)   K9S_ARCH="arm" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Architecture detected: $ARCH → K9s target: $K9S_ARCH"
echo ""

echo "=== Checking if K9s is already installed ==="
if command -v k9s >/dev/null 2>&1; then
    echo "K9s is already installed at $(which k9s)"
    INSTALLED=true
else
    INSTALLED=false
fi

if [ "$INSTALLED" = false ]; then
    echo "=== Fetching latest K9s release metadata ==="

    RELEASE_URL=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
        | jq -r ".assets[] | select(.name | test(\"Linux_${K9S_ARCH}\\.tar\\.gz$\")) | .browser_download_url")

    if [[ -z "$RELEASE_URL" || "$RELEASE_URL" == "null" ]]; then
        echo "ERROR: Could not determine latest K9s release URL for architecture: $K9S_ARCH"
        exit 1
    fi

    echo "Latest release download URL: $RELEASE_URL"
    echo ""

    TMPDIR=$(mktemp -d)
    TARFILE="$TMPDIR/k9s.tar.gz"

    echo "=== Downloading K9s archive ==="
    curl -L "$RELEASE_URL" -o "$TARFILE"

    echo "=== Extracting K9s ==="
    tar -xzf "$TARFILE" -C "$TMPDIR"

    echo "=== Installing K9s to /usr/local/bin ==="
    sudo mv "$TMPDIR/k9s" "$K9S_BIN"
    sudo chmod +x "$K9S_BIN"

    echo "=== Cleaning up temporary files ==="
    rm -rf "$TMPDIR"

    echo "K9s installation complete."
    echo ""
fi

echo "=== Creating alias 'k' for K9s (if missing) ==="
if ! grep -q 'alias k=k9s' ~/.bashrc; then
    echo 'alias k=k9s' >> ~/.bashrc
    echo "Alias 'k' added to ~/.bashrc"
else
    echo "Alias 'k' already exists in ~/.bashrc"
fi
alias k=k9s

echo "=== Setting up kubeconfig for MicroK8s ==="

mkdir -p ~/.kube

# Write kubeconfig from MicroK8s into ~/.kube/config
if microk8s config > ~/.kube/config 2>/dev/null; then
    chmod 600 ~/.kube/config
    echo "Kubeconfig successfully written to ~/.kube/config"
else
    echo "ERROR: Could not generate kubeconfig from MicroK8s."
    echo "Make sure MicroK8s is running:"
    echo "  microk8s status --wait-ready"
    exit 1
fi

echo ""
echo "=============================================="
echo " K9s Installation Complete"
echo "=============================================="
echo "Run K9s using:"
echo ""
echo "    k9s"
echo "or:"
echo "    k"
echo ""
echo "K9s is now connected to your MicroK8s cluster."
echo "Ensure MicroK8s is running before using K9s:"
echo "    microk8s status --wait-ready"
echo "=============================================="
echo ""
