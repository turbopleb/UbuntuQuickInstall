#!/bin/bash

# K9s Installer Script for MicroK8s
# Installs K9s, sets kubeconfig, defaults to kube-system, and launches K9s

set -e

K9S_BIN="/usr/local/bin/k9s"
MICROK8S_KUBECTL="microk8s kubectl"

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
if ! command -v k9s >/dev/null 2>&1; then
    RELEASE_URL=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | \
        jq -r --arg arch "$K9S_ARCH" '.assets[] | select(.name | test("k9s_Linux_\($arch).tar.gz$")) | .browser_download_url')

    TMP_FILE=$(mktemp)
    curl -L "$RELEASE_URL" -o "$TMP_FILE"
    tar -xzf "$TMP_FILE" -C /tmp
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
$MICROK8S_KUBECTL config > ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=$HOME/.kube/config

echo "=== Setting default K9s namespace to kube-system ==="
K9S_DIR="$HOME/.k9s"
mkdir -p "$K9S_DIR"
cat > "$K9S_DIR/config.yml" <<EOF
k9s:
  refreshRate: 2
  logBuffer: 200
  currentContext: microk8s
  currentNamespace: kube-system
EOF

echo ""
echo "=============================================="
echo " K9s installation complete."
echo " Launching K9s now..."
echo "=============================================="

# Launch K9s in kube-system namespace
k9s
