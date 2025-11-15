#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
DASHBOARD_NS="kube-system"

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    sudo usermod -aG microk8s $USER_NAME
    echo "Reload group membership with: newgrp microk8s"
    exec sg microk8s "$0 $@"
    exit 0
fi

echo "=== Setting up kubeconfig ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Enabling addons: ingress, dashboard, metrics-server ==="
microk8s enable ingress
microk8s enable dashboard
microk8s enable metrics-server

# Wait for dashboard pod
echo "=== Waiting for kubernetes-dashboard pod ==="
while ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get pods -l k8s-app=kubernetes-dashboard --field-selector=status.phase=Running | grep kubernetes-dashboard >/dev/null 2>&1; do
    echo "Waiting for dashboard pod..."
    sleep 5
done

# TLS secret
if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    $MICROK8S_KUBECTL -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

# Apply ingress
$MICROK8S_KUBECTL -n $DASHBOARD_NS delete ingress kubernetes-dashboard-ingress --ignore-not-found
cat <<EOF | $MICROK8S_KUBECTL apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: $DASHBOARD_NS
  annotations:
    kubernetes.io/ingress.class: "public"
spec:
  tls:
  - hosts:
    - dashboard.local
    secretName: dashboard-tls
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

# Update /etc/hosts
NODE_IP=$(microk8s kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
if grep -q "dashboard.local" /etc/hosts; then
    sudo sed -i "s/.*dashboard.local/$NODE_IP dashboard.local/" /etc/hosts
else
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
fi
echo "/etc/hosts updated: dashboard.local → $NODE_IP"

# Install K9s if missing
if ! command -v k9s >/dev/null 2>&1; then
    ARCH=$(uname -m)
    TARGET="amd64"
    [[ "$ARCH" != "x86_64" ]] && TARGET="$ARCH"
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
fi

# Set alias immediately
echo "alias k='k9s'" >> ~/.bashrc
source ~/.bashrc
echo "Alias 'k' set. You can run 'k' now."

echo "=== Setup complete ==="
echo "Dashboard URL: https://dashboard.local"
