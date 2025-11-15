#!/bin/bash

# K9s Installer Script for MicroK8s
# Works out-of-the-box on Ubuntu
# Sets up kubeconfig for MicroK8s automatically

set -e

USER_NAME=$(whoami)
K9S_BIN="/usr/local/bin/k9s"

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing dependencies ==="
sudo apt install -y curl tar jq

echo "=== Checking if K9s is already installed ==="
if command -v k9s >/dev/null 2>&1; then
    echo "K9s is already installed at $(which k9s)"
else
    echo "=== Downloading latest K9s release ==="
    # Get latest release URL for Linux amd64
    RELEASE_URL=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest \
        | jq -r '.assets[] | select(.name | test("Linux_x86_64.tar.gz$")) | .browser_download_url')

    if [ -z "$RELEASE_URL" ]; then
        echo "Error: Could not determine latest K9s release URL."
        exit 1
    fi

    TMP_FILE=$(mktemp)
    curl -L "$RELEASE_URL" -o "$TMP_FILE"

    echo "=== Extracting K9s ==="
    tar -xzf "$TMP_FILE" -C /tmp

    echo "=== Installing K9s to /usr/local/bin ==="
    sudo mv /tmp/k9s "$K9S_BIN"
    sudo chmod +x "$K9S_BIN"

    echo "=== Cleaning up ==="
    rm -f "$TMP_FILE"
fi

echo "=== Setting up alias 'k' for K9s ==="
if ! grep -q 'alias k=k9s' ~/.bashrc; then
    echo 'alias k=k9s' >> ~/.bashrc
fi
alias k=k9s

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=$HOME/.kube/config

echo ""
echo "=== MANUAL STEPS / NOTES ==="
echo "1. Start K9s by running 'k9s' or use alias 'k'."
echo "2. K9s automatically uses the MicroK8s cluster kubeconfig."
echo "3. Ensure MicroK8s is running (microk8s status --wait-ready) before using K9s."
echo "4. No additional configuration required unless customizing K9s settings."
