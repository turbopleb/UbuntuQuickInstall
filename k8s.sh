#!/usr/bin/env bash
set -e

USER_NAME="$USER"

echo "=== Updating system packages ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Installing snapd if missing ==="
sudo apt install -y snapd

echo "=== Installing MicroK8s if missing ==="
sudo snap install microk8s --classic

echo "=== Wait for 'microk8s' group to exist ==="
while ! getent group microk8s >/dev/null; do
    echo "Waiting for microk8s group to be created..."
    sleep 1
done

echo "=== Adding user '$USER_NAME' to microk8s group ==="
sudo usermod -aG microk8s "$USER_NAME"

echo "=== Ensuring ~/.kube directory exists ==="
mkdir -p ~/.kube

echo "=== Fixing permissions ==="
sudo chown -R "$USER_NAME":"$USER_NAME" ~/.kube

echo "=== Applying new group membership ==="
# Continue script AS the new group
newgrp microk8s <<EOF

echo "=== Checking microk8s status ==="
microk8s status --wait-ready

echo "=== Enabling common addons ==="
microk8s enable dns storage ingress

echo "=== Setting up kubeconfig ==="
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config

echo "=== Verifying ingress is running ==="
microk8s kubectl get pods -A --selector=app.kubernetes.io/name=ingress-nginx

echo "=== Kubernetes setup complete! ==="
EOF
