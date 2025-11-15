#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# Includes dashboard, ingress, hostpath storage, admin-user token fix
# Adds system-wide kubectl symlink
# Exposes dashboard via NGINX Ingress
# Waits for all required pods to be Running before exiting

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=600  # 10 minutes
SLEEP_INTERVAL=5  # seconds

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

# Dashboard namespace
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

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

NODE_IP=$(hostname -I | awk '{print $1}')

# Add entry to /etc/hosts
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "Adding dashboard.local -> $NODE_IP in /etc/hosts"
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
fi

echo "=== Waiting for all required pods to be Running ==="
END=$((SECONDS+WAIT_TIMEOUT))

# function to wait for pods in a namespace
wait_for_pods() {
    local ns=$1
    echo "Waiting for pods in namespace: $ns"
    while [ $SECONDS -lt $END ]; do
        NOT_READY=$($MICROK8S_KUBECTL -n $ns get pods --no-headers 2>/dev/null | awk '{if($3!="Running" && $3!="Completed") print $1}' || true)
        if [ -z "$NOT_READY" ]; then
            echo "All pods in $ns are Running"
            break
        else
            echo "Waiting for pods to be ready: $NOT_READY"
            sleep $SLEEP_INTERVAL
        fi
    done

    # If timeout exceeded
    if [ $SECONDS -ge $END ]; then
        echo "Timeout waiting for pods in $ns. Some pods are not ready:"
        $MICROK8S_KUBECTL -n $ns get pods
    fi
}

# Wait for both namespaces
wait_for_pods $DASHBOARD_NS
wait_for_pods $INGRESS_NS

echo "=== Fetching admin-user token ==="
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
