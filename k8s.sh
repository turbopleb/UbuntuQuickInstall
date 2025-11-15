#!/bin/bash
set -e

USER_NAME=$(whoami)
NEEDS_NEWGRP=false

echo "=== Updating system packages ==="
sudo apt update
sudo apt upgrade -y

echo "=== Installing snapd if missing ==="
sudo apt install -y snapd

echo "=== Installing MicroK8s if missing ==="
if ! snap list | grep -q microk8s; then
    sudo snap install microk8s --classic --channel=1.32/stable
else
    echo "microk8s already installed"
fi

echo "=== Ensuring microk8s group exists ==="
if ! getent group microk8s >/dev/null; then
    sudo groupadd microk8s
fi

echo "=== Adding user '$USER_NAME' to microk8s group ==="
if ! groups $USER_NAME | grep -q microk8s; then
    sudo usermod -aG microk8s $USER_NAME
    NEEDS_NEWGRP=true
fi

echo "=== Ensuring ~/.kube exists ==="
mkdir -p ~/.kube
sudo chown -R $USER_NAME ~/.kube
sudo chown -R $USER_NAME /var/snap/microk8s || true

# Apply new group membership immediately if user was added
if [ "$NEEDS_NEWGRP" = true ]; then
    echo "=== Switching to microk8s group using newgrp ==="
    exec sg microk8s "$0 $*"
fi

echo "=== Waiting for MicroK8s to become ready ==="
microk8s status --wait-ready

echo "=== Enabling core addons (DNS + hostpath storage) ==="
microk8s enable dns
microk8s enable hostpath-storage

echo "=== MicroK8s setup complete! ==="
echo "DNS and hostpath storage are enabled."
echo "Other addons (dashboard, ingress, metrics-server, k9s) can be added later."
