#!/bin/bash
set -e

echo "=== Updating packages ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq, openssl) ==="
sudo apt install -y curl tar jq openssl

echo "=== Ensuring user is in microk8s group ==="
if groups $USER | grep &>/dev/null '\bmicrok8s\b'; then
    echo "User $USER already in microk8s group."
else
    echo "Adding user $USER to microk8s group..."
    sudo usermod -aG microk8s $USER
    echo "You need to log out and back in for group changes to take effect."
fi

echo "=== Verifying MicroK8s access ==="
if microk8s status --wait-ready >/dev/null 2>&1; then
    echo "MicroK8s is running"
else
    echo "MicroK8s is not running. Please start MicroK8s."
    exit 1
fi

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    TARGET="amd64"
else
    TARGET="$ARCH"
fi
echo "Architecture detected: $ARCH → K9s target: $TARGET"

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    echo "Downloading latest K9s..."
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Adding alias 'k' for K9s (if missing) ==="
if ! grep -q "alias k=" ~/.bashrc; then
    echo "alias k='k9s'" >> ~/.bashrc
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
echo "Kubeconfig written to ~/.kube/config"

echo ""
echo "=============================================="
echo " K9s Installation Complete"
echo "----------------------------------------------"
echo "Run 'k' or 'k9s' to launch K9s."
echo "MicroK8s kubeconfig is ready at ~/.kube/config"
echo "=============================================="
