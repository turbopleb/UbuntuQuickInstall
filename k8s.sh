#!/bin/bash
set -e

USER_NAME=$(whoami)

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
sudo usermod -aG microk8s "$USER_NAME"

echo "=== Ensuring ~/.kube exists ==="
mkdir -p "$HOME/.kube"

echo "=== Fixing permissions ==="
sudo chown -R "$USER_NAME":microk8s "$HOME/.kube"
sudo chown -R "$USER_NAME":microk8s /var/snap/microk8s || true

echo "=== Applying group membership via sg (avoiding newgrp) ==="

echo "=== Waiting for MicroK8s to become ready ==="
sg microk8s -c "microk8s status --wait-ready"

echo "=== Enabling core addons (DNS + hostpath storage) ==="
sg microk8s -c "microk8s enable dns hostpath-storage"

echo "=== Waiting for kube-system core components ==="
CORE_PODS=("kube-dns" "kube-apiserver" "kube-controller-manager" "kube-scheduler" "kube-proxy")

for pod_label in "${CORE_PODS[@]}"; do
    echo "Waiting for pods with label '$pod_label' to be Ready..."
    sg microk8s -c "
    until kubectl -n kube-system get pods -l k8s-app=$pod_label -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep -q true; do
        sleep 2
    done
    "
    echo "$pod_label pods are Ready"
done

echo "=== Cluster setup complete! ==="
sg microk8s -c "microk8s kubectl get nodes"
echo "You can now run MicroK8s commands as '$USER_NAME' without using newgrp."
