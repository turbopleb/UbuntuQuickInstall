#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"

echo "=== Updating packages ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Installing required packages ==="
sudo apt install -y curl tar jq openssl

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    sudo usermod -aG microk8s $USER_NAME
    echo "You need to log out and back in for group changes to take effect."
fi

echo "=== Verifying MicroK8s access ==="
if microk8s status --wait-ready >/dev/null 2>&1; then
    echo "MicroK8s is running"
else
    echo "MicroK8s is not running. Please start MicroK8s."
    exit 1
fi

echo "=== Installing K9s if missing ==="
ARCH=$(uname -m)
TARGET=${ARCH/x86_64/amd64}
if ! command -v k9s >/dev/null 2>&1; then
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Adding alias 'k' for K9s ==="
if ! grep -q "alias k=" ~/.bashrc; then
    echo "alias k='k9s'" >> ~/.bashrc
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Enabling MicroK8s core addons (DNS + hostpath storage + ingress) ==="
microk8s enable dns
microk8s enable hostpath-storage
microk8s enable ingress

echo "=== MicroK8s setup complete! ==="
echo "DNS, storage, and ingress controller are enabled."
echo "Dashboard and other services can be installed later via your next script."
echo "Run 'k' or 'k9s' to launch K9s."
