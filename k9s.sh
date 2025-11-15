#!/bin/bash

# K9s Installer Script for MicroK8s
# Works on Ubuntu
# Fixes jq regex issues & auto-selects correct asset

set -e

K9S_BIN="/usr/local/bin/k9s"

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq) ==="
sudo apt install -y curl tar jq

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)
        K9S_ARCH="amd64"
        ;;
    aarch64 | arm64)
        K9S_ARCH="arm64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Architecture detected: $ARCH → K9s target: $K9S_ARCH"

echo "=== Checking if K9s is already installed ==="
if command -v k9s >/dev/null 2>&1; then
    echo "K9s already installed at $(which k9s)"
else
    echo "=== Fetching latest K9s release metadata ==="
    RELEASE_URL=$(
        curl -s https://api.github.com/repos/derailed/k9s/releases/latest |
            jq -r --arg arch "$K9S_ARCH" '.assets[] | select(.name | test("k9s_Linux_\($arch).tar.gz$")) | .browser_download_url'
    )

    if [ -z "$RELEASE_URL" ]; then
        echo "Error: Could not determine latest K9s release URL."
        exit 1
    fi

    echo "Download URL found:"
    echo "$RELEASE_URL"

    TMP_FILE=$(mktemp)

    echo "=== Downloading K9s ==="
    curl -L "$RELEASE_URL" -o "$TMP_FILE"

    echo "=== Extracting K9s ==="
    tar -xzf "$TMP_FILE" -C /tmp

    echo "=== Installing K9s to /usr/local/bin ==="
    sudo mv /tmp/k9s "$K9S_BIN"
    sudo chmod +x "$K9S_BIN"

    rm -f "$TMP_FILE"
fi

echo "=== Adding alias 'k' for K9s (if missing) ==="
if ! grep -q 'alias k=k9s' ~/.bashrc; then
    echo 'alias k=k9s' >> ~/.bashrc
fi
alias k=k9s

echo "=== Configuring kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=$HOME/.kube/config

echo ""
echo "=== Installation Complete ==="
echo "Run: k or k9s"
echo "MicroK8s kubeconfig is already set."
