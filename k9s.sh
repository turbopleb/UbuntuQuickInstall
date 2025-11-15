#!/bin/bash

# K9s Installer Script for MicroK8s (Ubuntu)
# Ensures proper kubeconfig setup for MicroK8s
# Fixes issues with MicroK8s kubeconfig being incorrectly loaded

set -e

K9S_BIN="/usr/local/bin/k9s"
MICROK8S_KUBECONFIG="$HOME/.kube/config"

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq) ==="
sudo apt install -y curl tar jq

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) K9S_ARCH="amd64" ;;
    aarch64|arm64) K9S_ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Architecture detected: $ARCH → K9s target: $K9S_ARCH"

echo "=== Installing K9s if missing ==="
if command -v k9s >/dev/null 2>&1; then
    echo "K9s already installed at $(which k9s)"
else
    echo "Fetching latest K9s release metadata..."
    RELEASE_URL=$(
        curl -s https://api.github.com/repos/derailed/k9s/releases/latest |
        jq -r --arg arch "$K9S_ARCH" '.assets[] | select(.name | test("k9s_Linux_\($arch).tar.gz$")) | .browser_download_url'
    )

    if [ -z "$RELEASE_URL" ]; then
        echo "Error: Could not determine latest K9s release URL."
        exit 1
    fi

    TMP_FILE=$(mktemp)
    echo "Downloading K9s..."
    curl -L "$RELEASE_URL" -o "$TMP_FILE"

    echo "Extracting K9s..."
    tar -xzf "$TMP_FILE" -C /tmp

    echo "Installing K9s to /usr/local/bin..."
    sudo mv /tmp/k9s "$K9S_BIN"
    sudo chmod +x "$K9S_BIN"
    rm -f "$TMP_FILE"
fi

echo "=== Adding alias 'k' for K9s ==="
if ! grep -q 'alias k=k9s' ~/.bashrc; then
    echo 'alias k=k9s' >> ~/.bashrc
fi
alias k=k9s

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube

# Correct way to get kubeconfig from MicroK8s
microk8s config > "$MICROK8S_KUBECONFIG"
chmod 600 "$MICROK8S_KUBECONFIG"
export KUBECONFIG="$MICROK8S_KUBECONFIG"

echo "=== Verifying connection ==="
kubectl get nodes

echo ""
echo "=== K9s Installation Complete ==="
echo "Run: k or k9s"
echo "MicroK8s kubeconfig is set in $MICROK8S_KUBECONFIG"
echo "All namespaces including kube-system are visible to K9s."
