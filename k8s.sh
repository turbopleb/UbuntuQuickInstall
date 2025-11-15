#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# Includes kubectl alias, addons, external dashboard access
# Auto-writes kubeconfig and prints dashboard URL + token

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing snapd if missing ==="
if ! command -v snap >/dev/null 2>&1; then
    sudo apt install -y snapd
fi

echo "=== Installing MicroK8s if missing ==="
if ! snap list | grep -q microk8s; then
    sudo snap install microk8s --classic
fi

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q "\bmicrok8s\b"; then
    echo "Adding $USER_NAME to microk8s group..."
    sudo usermod -a -G microk8s $USER_NAME

    mkdir -p ~/.kube
    sudo chown -R $USER_NAME ~/.kube

    echo "Reloading group membership..."
    exec sg microk8s "$0 $@"
    exit
fi

echo "=== Waiting for MicroK8s to be ready ==="
sudo microk8s status --wait-ready >/dev/null
echo "MicroK8s is ready."

echo "=== Setting up ~/.kube/config ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
sudo chown -R $USER_NAME ~/.kube
chmod 600 ~/.kube/config

echo "=== Setting up kubectl alias ==="
if ! grep -q 'alias kubectl="microk8s kubectl"' ~/.bashrc; then
    echo 'alias kubectl="microk8s kubectl"' >> ~/.bashrc
fi
alias kubectl="$MICROK8S_KUBECTL"

echo "=== Enabling MicroK8s addons ==="
ADDONS=(dns dashboard ingress metrics-server storage hostpath-storage)
for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

echo "=== Ensuring admin-user exists for Dashboard ==="
ADMIN_USER_FILE="/tmp/admin-user.yaml"

cat <<EOF > $ADMIN_USER_FILE
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
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
  namespace: kubernetes-dashboard
EOF

# Apply admin-user if missing
if ! $MICROK8S_KUBECTL -n kubernetes-dashboard get sa admin-user >/dev/null 2>&1; then
    echo "Creating admin-user..."
    $MICROK8S_KUBECTL apply -f $ADMIN_USER_FILE >/dev/null
else
    echo "admin-user already exists."
fi

echo "=== Making Kubernetes Dashboard externally accessible ==="
DASHBOARD_NS="kubernetes-dashboard"
SERVICE_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc -o jsonpath='{.items[0].metadata.name}' || true)

if [ -n "$SERVICE_NAME" ]; then
    echo "Patching Dashboard service to NodePort..."
    $MICROK8S_KUBECTL -n $DASHBOARD_NS patch service $SERVICE_NAME -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1 || true
else
    echo "Dashboard service not detected yet, waiting 10 seconds..."
    sleep 10
fi

echo "=== Retrieving Dashboard NodePort ==="
NODE_PORT=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc -o jsonpath='{.items[0].spec.ports[0].nodePort}')
NODE_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "--------------------------------------------"
echo " Kubernetes Dashboard is available at:"
echo ""
echo "    👉  https://$NODE_IP:$NODE_PORT"
echo ""
echo "--------------------------------------------"
echo ""

echo "=== Retrieving Dashboard Admin Token ==="
sleep 2

ADMIN_SECRET=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret | grep admin-user | awk '{print $1}')

if [ -n "$ADMIN_SECRET" ]; then
    TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS describe secret $ADMIN_SECRET | grep '^token' | awk '{print $2}')

    echo "--------------------------------------------"
    echo " Dashboard Login Token:"
    echo ""
    echo "$TOKEN"
    echo ""
    echo "--------------------------------------------"
else
    echo "ERROR: admin-user token not found."
    echo "Dashboard may still be initializing."
fi

echo ""
echo "=== SETUP COMPLETE ==="
echo "MicroK8s is fully installed and configured."
echo "Use:  kubectl get nodes"
echo ""
