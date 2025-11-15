#!/bin/bash

# =========================================================
# Full MicroK8s + K9s Installer for Ubuntu
# Installs MicroK8s, dashboard, ingress, hostpath storage
# Creates admin-user for dashboard
# Installs K9s, sets up kubeconfig and alias
# =========================================================

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
DASHBOARD_HOST="dashboard.local"

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing required packages ==="
sudo apt install -y snapd curl tar jq

echo "=== Installing MicroK8s if missing ==="
if ! snap list | grep -q microk8s; then
    sudo snap install microk8s --classic
fi

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q "\bmicrok8s\b"; then
    echo "Adding $USER_NAME to microk8s group..."
    sudo usermod -a -G microk8s $USER_NAME
    echo "Please log out and log in again to refresh group membership."
    exit 0
fi

echo "=== Waiting for MicroK8s to be ready ==="
sudo microk8s status --wait-ready >/dev/null
echo "MicroK8s is ready."

echo "=== Setting up ~/.kube/config ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
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
echo "Dashboard namespace: $DASHBOARD_NS"

echo "=== Creating admin-user and token for Dashboard ==="
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
spec:
  rules:
  - host: $DASHBOARD_HOST
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

# Add /etc/hosts entry
if ! grep -q "$DASHBOARD_HOST" /etc/hosts; then
    IP=$(hostname -I | awk '{print $1}')
    echo "$IP $DASHBOARD_HOST" | sudo tee -a /etc/hosts
    echo "Added $DASHBOARD_HOST -> $IP in /etc/hosts"
fi

echo "=== Waiting for admin-user token to be ready ==="
TOKEN=""
for i in {1..12}; do
    TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='admin-user')].data.token}" 2>/dev/null | base64 --decode || true)
    if [ -n "$TOKEN" ]; then
        break
    fi
    echo "Waiting for admin-user token... attempt $i/12"
    sleep 5
done

if [ -z "$TOKEN" ]; then
    TOKEN="<token not available yet>"
fi

echo "=== Installing K9s ==="
K9S_BIN="/usr/local/bin/k9s"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) K9S_ARCH="amd64" ;;
    aarch64|arm64) K9S_ARCH="arm64" ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

if ! command -v k9s >/dev/null 2>&1; then
    RELEASE_URL=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r --arg arch "$K9S_ARCH" '.assets[] | select(.name | test("k9s_Linux_\($arch).tar.gz$")) | .browser_download_url')
    TMP_FILE=$(mktemp)
    curl -L "$RELEASE_URL" -o "$TMP_FILE"
    tar -xzf "$TMP_FILE" -C /tmp
    sudo mv /tmp/k9s "$K9S_BIN"
    sudo chmod +x "$K9S_BIN"
    rm -f "$TMP_FILE"
fi

if ! grep -q 'alias k=k9s' ~/.bashrc; then
    echo 'alias k=k9s' >> ~/.bashrc
fi
alias k=k9s

echo "=== MicroK8s + Dashboard + K9s Setup Complete ==="
echo ""
echo "Kubernetes Dashboard URL:"
echo "    https://$DASHBOARD_HOST"
echo ""
echo "Dashboard Admin Token:"
echo "    $TOKEN"
echo ""
echo "Run K9s with:"
echo "    k   or   k9s"
echo ""
echo "kubectl test:"
echo "    kubectl get nodes"
