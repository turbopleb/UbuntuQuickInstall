#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# - Installs MicroK8s if missing
# - Enables dashboard, ingress, metrics-server, storage
# - Waits for all required pods to be ready
# - Creates admin-user token for dashboard
# - Ensures NGINX ingress pod/service is running
# - Updates /etc/hosts for dashboard.local
# - Creates system-wide kubectl symlink
# - Safe, robust and idempotent

set -euo pipefail

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
DASHBOARD_NS="kube-system"

echo "=== Updating system packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing snapd if missing ==="
if ! command -v snap >/dev/null 2>&1; then
    sudo apt install -y snapd
fi

echo "=== Installing MicroK8s if missing ==="
if ! snap list | grep -q microk8s; then
    sudo snap install microk8s --classic
fi

echo "=== Adding user $USER_NAME to microk8s group ==="
if ! groups $USER_NAME | grep -qw microk8s; then
    sudo usermod -aG microk8s $USER_NAME
    echo "Reload your session or run: exec sg microk8s \"$0 $@\""
fi

echo "=== Waiting for MicroK8s to be ready ==="
sudo microk8s status --wait-ready >/dev/null
echo "MicroK8s is ready."

echo "=== Setting up ~/.kube/config ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
sudo chown -R $USER_NAME ~/.kube
chmod 600 ~/.kube/config

echo "=== Creating system-wide kubectl symlink ==="
if [ ! -f /usr/local/bin/kubectl ]; then
    sudo ln -s /snap/bin/microk8s.kubectl /usr/local/bin/kubectl
fi

echo "=== Enabling required MicroK8s addons ==="
ADDONS=(dns dashboard ingress metrics-server storage hostpath-storage)
for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

# Function to wait for pods by label in namespace
wait_for_pods() {
    local namespace="$1"
    local label_selector="$2"
    echo "=== Waiting for pods with label '$label_selector' in namespace '$namespace' to be Running ==="

    # Wait for pods to appear
    until $MICROK8S_KUBECTL -n "$namespace" get pods -l "$label_selector" --no-headers >/dev/null 2>&1; do
        echo "No pods found yet for label $label_selector, waiting..."
        sleep 3
    done

    # Wait for all pods to be Running
    while true; do
        ALL_READY=true
        PODS=$($MICROK8S_KUBECTL -n "$namespace" get pods -l "$label_selector" --no-headers | awk '{print $1}')
        for pod in $PODS; do
            STATUS=$($MICROK8S_KUBECTL -n "$namespace" get pod "$pod" -o jsonpath='{.status.phase}')
            if [[ "$STATUS" != "Running" ]]; then
                echo "Pod $pod status: $STATUS"
                ALL_READY=false
            fi
        done
        $ALL_READY && break
        sleep 3
    done
    echo "All pods with label '$label_selector' in '$namespace' are Running."
}

echo "=== Waiting for all required pods to be ready ==="
wait_for_pods kube-system k8s-app=kube-dns
wait_for_pods kube-system k8s-app=kubernetes-dashboard
wait_for_pods kube-system app=metrics-server
wait_for_pods ingress app=nginx-ingress-microk8s-controller
wait_for_pods kube-system microk8s-hostpath-storage

echo "=== Ensuring ingress service exists ==="
if ! $MICROK8S_KUBECTL -n ingress get svc nginx-ingress-microk8s-controller >/dev/null 2>&1; then
    echo "Ingress service missing. Restarting ingress addon..."
    sudo microk8s disable ingress
    sudo microk8s enable ingress
    wait_for_pods ingress app=nginx-ingress-microk8s-controller
fi

echo "=== Creating admin-user for Dashboard ==="
$MICROK8S_KUBECTL apply -f - <<EOF
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

echo "=== Waiting for admin-user token ==="
TOKEN=""
for i in {1..20}; do
    SECRET_NAME=$($MICROK8S_KUBECTL -n "$DASHBOARD_NS" get secret | grep admin-user | awk '{print $1}' || true)
    if [[ -n "$SECRET_NAME" ]]; then
        TOKEN=$($MICROK8S_KUBECTL -n "$DASHBOARD_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' | base64 --decode)
        if [[ -n "$TOKEN" ]]; then
            break
        fi
    fi
    echo "Waiting for admin-user token... attempt $i/20"
    sleep 3
done

if [[ -z "$TOKEN" ]]; then
    TOKEN="<token not available yet>"
fi

echo "=== Creating Ingress for Dashboard ==="
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: $DASHBOARD_NS
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: dashboard.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
EOF

echo "=== Ensuring /etc/hosts has dashboard.local pointing to node IP ==="
NODE_IP=$(hostname -I | awk '{print $1}')
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
    echo "/etc/hosts updated: $NODE_IP dashboard.local"
else
    echo "/etc/hosts already contains dashboard.local"
fi

echo ""
echo "=============================================="
echo " MicroK8s Setup Complete"
echo "----------------------------------------------"
echo "kubectl is ready. Test with:"
echo "    kubectl get nodes"
echo ""
echo "Kubernetes Dashboard URL via Ingress:"
echo "    https://dashboard.local"
echo ""
echo "Dashboard Admin Token:"
echo "    $TOKEN"
echo "=============================================="
