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
sudo usermod -aG microk8s $USER_NAME

echo "=== Ensuring ~/.kube exists ==="
mkdir -p ~/.kube

echo "=== Fixing permissions for MicroK8s ==="
sudo chown -R $USER_NAME ~/.kube
sudo chown -R $USER_NAME /var/snap/microk8s || true

echo "=== Applying new group membership ==="
exec sg microk8s -c "$0" || true

echo "=== Waiting for MicroK8s to become ready ==="
microk8s status --wait-ready

echo "=== Enabling core addons (DNS + hostpath storage) ==="
microk8s enable dns
microk8s enable hostpath-storage

echo "=== Waiting for kube-system core components ==="
CORE_PODS=("kube-dns" "kube-apiserver" "kube-controller-manager" "kube-scheduler" "kube-proxy")

for pod_label in "${CORE_PODS[@]}"; do
    echo "Waiting for pods with label '$pod_label' to be Ready..."
    until microk8s kubectl -n kube-system get pods -l k8s-app=$pod_label -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -q true; do
        sleep 2
    done
    echo "$pod_label pods are Ready"
done

echo "=== Cluster Ready! ==="

echo "=== Printing Kubernetes dashboard admin token (if dashboard enabled) ==="
if microk8s kubectl -n kube-system get secret | grep -q kubernetes-dashboard-token; then
    SECRET_NAME=$(microk8s kubectl -n kube-system get secret | grep kubernetes-dashboard-token | awk '{print $1}')
    TOKEN=$(microk8s kubectl -n kube-system describe secret $SECRET_NAME | grep '^token:' | awk '{print $2}')
    echo "Dashboard Admin Token:"
    echo $TOKEN
else
    echo "Dashboard token not found (dashboard not enabled)"
fi

echo "=== Setup complete! Your next script can enable dashboard and ingress ==="
