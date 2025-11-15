#!/bin/bash
set -e

USER_NAME=$(whoami)

echo "=== Checking microk8s group ==="
if ! getent group microk8s >/dev/null; then
    echo "Creating microk8s group..."
    sudo groupadd microk8s
fi

echo "=== Adding $USER_NAME to microk8s group ==="
sudo usermod -aG microk8s $USER_NAME

echo "=== Ensuring ~/.kube exists ==="
mkdir -p ~/.kube

echo "=== Fixing permissions ==="
sudo chown -R $USER_NAME:$USER_NAME ~/.kube
sudo chown -R $USER_NAME:$USER_NAME /var/snap/microk8s || true

echo "=== Running cluster setup inside microk8s group ==="
sg microk8s <<'EOF'

echo "=== Starting MicroK8s ==="
microk8s status --wait-ready || microk8s start

echo "=== Enabling core addons only ==="
microk8s enable dns
microk8s enable storage

echo "=== Waiting for core components ==="

# Helper function
wait_for_label() {
    NS="$1"
    LABEL="$2"

    echo "Checking pods in namespace: $NS with label: $LABEL"
    microk8s kubectl -n "$NS" get pods -l "$LABEL" --no-headers || true

    echo -n "Waiting for pods ($LABEL) in $NS to become Ready..."
    microk8s kubectl -n "$NS" wait --for=condition=Ready pod -l "$LABEL" --timeout=300s
    echo " OK"
}

# Required Kubernetes components
wait_for_label kube-system k8s-app=kube-dns
wait_for_label kube-system component=kube-apiserver
wait_for_label kube-system component=kube-controller-manager
wait_for_label kube-system component=kube-scheduler
wait_for_label kube-system k8s-app=kube-proxy

echo "=== Waiting for default StorageClass ==="
microk8s kubectl wait sc microk8s-hostpath --for=condition=Exists --timeout=60s || true

echo "=== Cluster Ready ==="
microk8s kubectl get nodes -o wide
microk8s kubectl get pods -A -o wide

EOF

echo "=== MicroK8s base cluster setup complete ==="
echo "You may now run your separate dashboard/ingress scripts."
