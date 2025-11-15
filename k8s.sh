#!/bin/bash
set -e

USER_NAME=$(whoami)

echo "=== Updating system packages ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Installing snapd (if missing) ==="
sudo apt install -y snapd

echo "=== Installing MicroK8s ==="
sudo snap install microk8s --classic

echo "=== Ensuring microk8s group exists ==="
if ! getent group microk8s >/dev/null; then
    echo "Creating microk8s group..."
    sudo groupadd microk8s
fi

echo "=== Adding user '$USER_NAME' to microk8s group ==="
sudo usermod -aG microk8s $USER_NAME

echo "=== Ensuring ~/.kube exists ==="
mkdir -p $HOME/.kube

echo "=== Fixing permissions ==="
sudo chown -R $USER_NAME:$USER_NAME ~/.kube
sudo chown -R $USER_NAME:$USER_NAME /var/snap/microk8s

echo "=== Reload group membership ==="
newgrp microk8s

echo "=== Waiting for MicroK8s to become ready ==="
microk8s status --wait-ready

echo "=== Enabling required core addons (DNS + storage) ==="
microk8s enable dns
microk8s enable hostpath-storage

echo "=== Waiting for kube-system core components ==="
wait_for_ready() {
    NS="$1"
    LABEL="$2"
    echo -n "Waiting for pods in $NS (label=$LABEL) "
    until microk8s kubectl get pods -n "$NS" -l "$LABEL" --no-headers 2>/dev/null | grep -q "Running"; do
        echo -n "."
        sleep 2
    done
    echo " OK"
}

wait_for_ready kube-system "k8s-app=kube-dns"
wait_for_ready kube-system "component=kube-apiserver"
wait_for_ready kube-system "component=kube-controller-manager"
wait_for_ready kube-system "component=kube-scheduler"
wait_for_ready kube-system "k8s-app=kube-proxy"

echo "=== Waiting for default StorageClass ==="
until microk8s kubectl get storageclass | grep -q "(default)"; do
    echo -n "."
    sleep 2
done
echo " OK"

echo "=== Cluster Ready ==="
microk8s kubectl get nodes
microk8s kubectl get pods -A

echo "=== DONE ==="
echo "You may need to logout/login once for group membership to fully apply."
