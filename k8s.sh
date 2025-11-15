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

# If user just got added to microk8s group, use newgrp
if [ "$NEEDS_NEWGRP" = true ]; then
    echo "=== Switching to microk8s group using newgrp ==="
    exec sg microk8s "$0 $*"
fi

echo "=== Waiting for MicroK8s to become ready ==="
microk8s status --wait-ready

echo "=== Enabling core addons (DNS + hostpath storage) ==="
microk8s enable dns
microk8s enable hostpath-storage

echo "=== Waiting for kube-system core components ==="
CORE_LABELS=("k8s-app=kube-dns" "component=kube-apiserver" "component=kube-controller-manager" "component=kube-scheduler" "k8s-app=kube-proxy")

for label in "${CORE_LABELS[@]}"; do
    echo "Waiting for pods with label '$label' to be Ready..."
    spinner="/|\\-"
    i=0
    until microk8s kubectl -n kube-system get pods -l $label -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -q true; do
        i=$(( (i+1) %4 ))
        printf "\r${spinner:$i:1} "
        sleep 1
    done
    printf "\rPods with label '$label' are Ready!        \n"
done

echo "=== Cluster Ready! ==="
echo "DNS and hostpath storage are enabled."
echo "Metrics-server, dashboard, and ingress can be enabled later via your next script."
