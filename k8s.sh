#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# Ensures dashboard and ingress are fully functional
# Waits for pods and services
# Fixes /etc/hosts for dashboard.local
# Outputs admin-user token

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
    sudo snap install microk8s --classic --channel=1.32/stable
fi

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q "\bmicrok8s\b"; then
    sudo usermod -a -G microk8s $USER_NAME
    echo "Reload group membership by logging out and in."
    exit 0
fi

echo "=== Waiting for MicroK8s to be ready ==="
sudo microk8s status --wait-ready >/dev/null
echo "MicroK8s is ready."

echo "=== Setting up kubeconfig ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
sudo chown -R $USER_NAME ~/.kube
chmod 600 ~/.kube/config

echo "=== Setting up kubectl alias and system-wide symlink ==="
if ! grep -q 'alias kubectl="microk8s kubectl"' ~/.bashrc; then
    echo 'alias kubectl="microk8s kubectl"' >> ~/.bashrc
fi
alias kubectl="$MICROK8S_KUBECTL"
if [ ! -f /usr/local/bin/kubectl ]; then
    sudo ln -s /snap/bin/microk8s.kubectl /usr/local/bin/kubectl
fi

echo "=== Enabling required MicroK8s addons ==="
ADDONS=(dns dashboard ingress metrics-server storage hostpath-storage)
for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

# Wait for all required pods to be ready
echo "=== Waiting for all required pods to be ready ==="
REQUIRED_NS=("kube-system" "ingress" "default")
for ns in "${REQUIRED_NS[@]}"; do
    pods=$($MICROK8S_KUBECTL -n $ns get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
    for pod in $($MICROK8S_KUBECTL -n $ns get pods --no-headers -o custom-columns=":metadata.name"); do
        echo "Waiting for pod $pod in namespace $ns..."
        until [[ "$($MICROK8S_KUBECTL -n $ns get pod $pod -o jsonpath='{.status.phase}')" == "Running" ]]; do
            sleep 2
        done
    done
done

# Ensure ingress service exists and is running
echo "=== Ensuring NGINX ingress service exists and running ==="
if ! $MICROK8S_KUBECTL -n ingress get svc | grep -q nginx-ingress-microk8s-controller; then
    echo "Ingress service missing, restarting ingress addon..."
    sudo microk8s disable ingress
    sudo microk8s enable ingress
fi
until $MICROK8S_KUBECTL -n ingress get pods -l app=nginx-ingress-microk8s-controller -o jsonpath='{.items[0].status.phase}' | grep -q "Running"; do
    echo "Waiting for NGINX ingress pod..."
    sleep 2
done
echo "NGINX ingress pod is running."

DASHBOARD_NS="kube-system"

# Create admin-user for dashboard
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

# Wait for dashboard pod
echo "=== Waiting for Kubernetes Dashboard pod to be ready ==="
until $MICROK8S_KUBECTL -n $DASHBOARD_NS get pods -l k8s-app=kubernetes-dashboard -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; do
    sleep 2
done

# Fix /etc/hosts
echo "=== Fixing /etc/hosts for dashboard.local ==="
NODE_IP=$(hostname -I | awk '{print $1}')
sudo sed -i '/dashboard.local/d' /etc/hosts
echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts

# Create ingress for dashboard
echo "=== Creating Ingress for Kubernetes Dashboard ==="
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
      - pathType: Prefix
        path: /
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
EOF

# Wait for admin-user token
echo "=== Waiting for admin-user token ==="
TOKEN=""
for i in {1..12}; do
    SECRET_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret | grep admin-user | awk '{print $1}' || true)
    if [ -n "$SECRET_NAME" ]; then
        TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret $SECRET_NAME -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode || true)
        if [ -n "$TOKEN" ]; then
            break
        fi
    fi
    echo "Waiting for admin-user token... attempt $i/12"
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
echo "Kubernetes Dashboard URL via Ingress:"
echo "    https://dashboard.local"
echo ""
echo "Dashboard Admin Token:"
echo "    $TOKEN"
echo "=============================================="
