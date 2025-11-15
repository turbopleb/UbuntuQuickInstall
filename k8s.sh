#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# Installs MicroK8s, enables addons, sets up dashboard access
# Auto-writes kubeconfig, prints dashboard URL and token at the end
# Compatible with NGINX ingress and CoreDNS

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

# Determine dashboard addon name
if microk8s status --help | grep -q "kubedashboard"; then
    DASHBOARD_ADDON="kubedashboard"
else
    DASHBOARD_ADDON="dashboard"
fi

ADDONS=(dns $DASHBOARD_ADDON ingress metrics-server storage hostpath-storage)

for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

echo "Using dashboard addon: $DASHBOARD_ADDON"

# Set dashboard namespace depending on addon
if [ "$DASHBOARD_ADDON" = "kubedashboard" ]; then
    DASHBOARD_NS="kube-system"
else
    DASHBOARD_NS="kubernetes-dashboard"
fi

echo ""
echo "=== Waiting for dashboard namespace to exist ==="
RETRIES=10
until $MICROK8S_KUBECTL get ns $DASHBOARD_NS >/dev/null 2>&1 || [ $RETRIES -le 0 ]; do
    echo "Waiting for namespace $DASHBOARD_NS..."
    sleep 5
    ((RETRIES--))
done

if ! $MICROK8S_KUBECTL get ns $DASHBOARD_NS >/dev/null 2>&1; then
    echo "ERROR: Namespace $DASHBOARD_NS not found. Dashboard may not be ready."
    exit 1
fi

echo "=== Creating admin-user for Dashboard ==="
ADMIN_USER_FILE="/tmp/admin-user.yaml"

cat <<EOF > $ADMIN_USER_FILE
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: $DASHBOARD_NS
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
  namespace: $DASHBOARD_NS
EOF

if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get sa admin-user >/dev/null 2>&1; then
    $MICROK8S_KUBECTL apply -f $ADMIN_USER_FILE >/dev/null
    echo "Admin-user created."
else
    echo "Admin-user already exists."
fi

echo ""
echo "=== Exposing Dashboard via NodePort ==="
SERVICE_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc -o jsonpath='{.items[0].metadata.name}' || true)

if [ -n "$SERVICE_NAME" ]; then
    $MICROK8S_KUBECTL -n $DASHBOARD_NS patch service $SERVICE_NAME -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1 || true
fi

# Wait a few seconds for NodePort to appear
sleep 5

NODE_PORT=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc $SERVICE_NAME -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(hostname -I | awk '{print $1}')

ADMIN_SECRET=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret | grep admin-user | awk '{print $1}')

if [ -n "$ADMIN_SECRET" ]; then
    TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS describe secret $ADMIN_SECRET | grep '^token' | awk '{print $2}')
else
    TOKEN="<token not available yet>"
fi

echo ""
echo "=============================================="
echo " MicroK8s Setup Complete"
echo "----------------------------------------------"
echo "kubectl is ready. Test with:"
echo "    kubectl get nodes"
echo ""
echo "Kubernetes Dashboard URL:"
echo "    https://$NODE_IP:$NODE_PORT"
echo ""
echo "Dashboard Admin Token:"
echo "    $TOKEN"
echo "=============================================="
