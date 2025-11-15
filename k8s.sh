#!/bin/bash
set -euo pipefail

# Flag file to avoid infinite newgrp recursion
FLAG="/tmp/k8s_newgrp_done"

USER_NAME=$(whoami)

###############################################
# 1) Handle microk8s group BEFORE anything
###############################################

if ! groups "$USER_NAME" | grep -qw microk8s; then
    echo "=== Adding user '$USER_NAME' to microk8s group ==="
    sudo usermod -aG microk8s "$USER_NAME"

    echo "=== Fixing ~/.kube permissions ==="
    sudo mkdir -p ~/.kube
    sudo chown -R "$USER_NAME":"$USER_NAME" ~/.kube

    echo "=== Restarting script inside 'microk8s' group (using newgrp) ==="
    touch "$FLAG"
    exec newgrp microk8s <<EOF
bash "$0"
EOF
    exit 0
fi

# Prevent re-entering newgrp recursion
if [[ -f "$FLAG" ]]; then
    rm -f "$FLAG"
fi

###############################################
# 2) Now safe: rest of script runs as microk8s user
###############################################

echo "=== Updating system packages ==="
sudo apt update -y

echo "=== Installing snapd if missing ==="
if ! command -v snap >/dev/null 2>&1; then
    sudo apt install -y snapd
fi

echo "=== Installing MicroK8s if missing ==="
if ! snap list | grep -q microk8s; then
    sudo snap install microk8s --classic
fi

echo "=== Waiting for MicroK8s to become ready ==="
sudo microk8s status --wait-ready

echo "=== Configuring kubectl ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config

if [[ ! -e /usr/local/bin/kubectl ]]; then
    sudo ln -s /snap/bin/microk8s.kubectl /usr/local/bin/kubectl
fi

echo "=== Enabling required addons ==="
sudo microk8s enable dns
sudo microk8s enable storage
sudo microk8s enable hostpath-storage
sudo microk8s enable metrics-server --force
sudo microk8s enable dashboard --force
sudo microk8s enable ingress --force

###############################################
# 3) Wait for ingress controller
###############################################
echo "=== Waiting for ingress controller ==="
while true; do
    if microk8s kubectl -n ingress get pods | grep -q "Running"; then
        break
    fi
    echo "Waiting for ingress pod..."
    sleep 3
done
echo "Ingress is ready."

###############################################
# 4) Create dashboard admin-user + token
###############################################
echo "=== Creating Dashboard admin-user ==="
cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kube-system
EOF

cat <<EOF | microk8s kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kube-system
EOF

###############################################
# 5) Wait for token
###############################################
echo "=== Waiting for admin-user token ==="
while true; do
    TOKEN=$(microk8s kubectl -n kube-system get secret | grep admin-user | awk '{print $1}' || true)

    if [[ -n "$TOKEN" ]]; then
        ADMIN_TOKEN=$(microk8s kubectl -n kube-system describe secret "$TOKEN" | grep -E '^token:' | awk '{print $2}')
        if [[ -n "$ADMIN_TOKEN" ]]; then
            break
        fi
    fi

    echo "Waiting for Dashboard token..."
    sleep 3
done

###############################################
# 6) Display output
###############################################
echo ""
echo "==============================================="
echo " MicroK8s Setup Complete"
echo "-----------------------------------------------"
echo "Dashboard URL:"
echo "    https://dashboard.local"
echo ""
echo "Dashboard Admin Token:"
echo "    $ADMIN_TOKEN"
echo ""
echo "Test kubectl with:"
echo "    kubectl get nodes"
echo "==============================================="
