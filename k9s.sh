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

echo "=== Waiting for MicroK8s to be ready ==="
READY=0
for i in {1..24}; do
    if microk8s status --wait-ready >/dev/null 2>&1; then
        READY=1
        echo "MicroK8s is running."
        break
    else
        echo "Waiting for MicroK8s... ($i/24)"
        sleep 5
    fi
done
if [ $READY -eq 0 ]; then
    echo "Error: MicroK8s is not ready. Exiting."
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
sudo chown $USER ~/.kube/config
chmod 600 ~/.kube/config

echo "=== Ensuring ingress is enabled and ready ==="
microk8s enable ingress >/dev/null 2>&1 || true
INGRESS_READY=0
for i in {1..24}; do
    if microk8s kubectl -n ingress get pods -l app.kubernetes.io/name=ingress-nginx --field-selector=status.phase=Running 2>/dev/null | grep -q 'Running'; then
        INGRESS_READY=1
        echo "Ingress controller is running."
        break
    else
        echo "Waiting for ingress controller... ($i/24)"
        sleep 5
    fi
done
if [ $INGRESS_READY -eq 0 ]; then
    echo "Warning: Ingress controller not ready yet."
fi

echo "=== K9s Installation & Dashboard Ingress Fix Complete ==="
echo "Run 'k' or 'k9s' to launch K9s."
echo "Dashboard URL: https://dashboard.local"
echo "MicroK8s kubeconfig is ready."
