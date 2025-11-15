#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# Ensures kubectl, MicroK8s addons, dashboard, admin-user, NodePort access
# Fixes admin-user secret retrieval for token login
# Adds system-wide kubectl symlink

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

echo "=== Creating system-wide kubectl symlink ==="
if [ ! -f /usr/local/bin/kubectl ]; then
    sudo ln -s /snap/bin/microk8s.kubectl /usr/local/bin/kubectl
fi

echo "=== Enabling MicroK8s addons ==="
ADDONS=(dns dashboard ingress metrics-server storage hostpath-storage)
for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

# Determine dashboard namespace
if $MICROK8S_KUBECTL get ns kubernetes-dashboard >/dev/null 2>&1; then
    DASHBOARD_NS="kubernetes-dashboard"
else
    DASHBOARD_NS="kube-system"
fi
echo "Dashboard namespace detected: $DASHBOARD_NS"

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

$MICROK8S_KUBECTL apply -f $ADMIN_USER_FILE >/dev/null

echo "=== Exposing Dashboard via NodePort ==="
SERVICE_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc -o jsonpath='{.items[0].metadata.name}')
$MICROK8S_KUBECTL -n $DASHBOARD_NS patch service $SERVICE_NAME -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1
sleep 5

NODE_PORT=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc $SERVICE_NAME -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(hostname -I | awk '{print $1}')

# Wait for the admin-user secret to exist
echo "=== Waiting for admin-user token secret ==="
TOKEN=""
for i in {1..12}; do
    ADMIN_SECRET=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret \
        -o jsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="admin-user")].metadata.name}' || true)
    if [ -n "$ADMIN_SECRET" ]; then
        TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS describe secret $ADMIN_SECRET \
            | grep '^token' | awk '{print $2}')
        break
    fi
    echo "Waiting for admin-user secret... attempt $i/12"
    sleep 5
done

if [ -z "$TOKEN" ]; then
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
