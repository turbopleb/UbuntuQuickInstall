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

echo "=== Checking kube-system core components ==="
CORE_PODS=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "kube-proxy" "coredns")

for pod in "${CORE_PODS[@]}"; do
    echo "Checking pod '$pod'..."
    spinner="/|\\-"
    i=0
    for attempt in {1..30}; do
        POD_STATUS=$(microk8s kubectl -n kube-system get pod -l "component=$pod" -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
        if [[ -z "$POD_STATUS" ]]; then
            # Pod does not exist yet
            printf "\r${spinner:$i:1} Waiting for pod '$pod' to appear..."
        elif [[ "$POD_STATUS" == "Running" ]]; then
            # Pod exists and running
            echo "Pod '$pod' is running, continuing..."
            break
        elif [[ "$POD_STATUS" == "Pending" || "$POD_STATUS" == "Failed" || "$POD_STATUS" == "Evicted" ]]; then
            # Pod exists but not ready, skip
            echo "Pod '$pod' is $POD_STATUS, skipping check..."
            break
        fi
        i=$(( (i+1) %4 ))
        printf "\r${spinner:$i:1} "
        sleep 2
    done
done

echo "=== MicroK8s cluster is ready! ==="
echo "DNS and hostpath storage are enabled."
echo "Other addons (dashboard, ingress, metrics-server, k9s) can be added later."
