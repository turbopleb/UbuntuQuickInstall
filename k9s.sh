#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
DASHBOARD_NS="kube-system"

echo "=== Installing required packages (curl, tar, jq, openssl, ca-certificates) ==="
sudo apt update -y
sudo apt install -y curl tar jq openssl ca-certificates

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    echo "Adding user $USER_NAME to microk8s group..."
    sudo usermod -aG microk8s $USER_NAME
    echo "Group added. Run 'newgrp microk8s' in this shell to apply immediately."
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    echo "Downloading latest K9s..."
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then TARGET="amd64"; else TARGET="$ARCH"; fi
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Making 'k' command work immediately ==="
k() { k9s "$@"; }
export -f k
echo "Run 'k' now to launch K9s."

echo "=== Enabling MicroK8s ingress and dashboard ==="
sudo microk8s enable ingress || true
sudo microk8s enable dashboard || true

echo "=== Waiting for dashboard service to exist ==="
SECONDS_WAITED=0
TIMEOUT=60
until $MICROK8S_KUBECTL -n $DASHBOARD_NS get svc kubernetes-dashboard >/dev/null 2>&1 || [ $SECONDS_WAITED -ge $TIMEOUT ]; do
    echo "Waiting for Kubernetes Dashboard service to appear..."
    sleep 3
    SECONDS_WAITED=$((SECONDS_WAITED+3))
done

if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get svc kubernetes-dashboard >/dev/null 2>&1; then
    echo "Error: Dashboard service still not found. Exiting."
    exit 1
fi

echo "=== Exposing Kubernetes Dashboard as NodePort ==="
$MICROK8S_KUBECTL -n $DASHBOARD_NS patch svc kubernetes-dashboard \
    -p '{"spec": {"type": "NodePort"}}'

echo "=== Ensuring TLS secret for dashboard ==="
if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    $MICROK8S_KUBECTL -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

echo "=== Applying ingress for dashboard.local ==="
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

echo "=== Updating /etc/hosts with node IP for dashboard.local ==="
NODE_IP=$(hostname -I | awk '{print $1}')
HOST_ENTRY="$NODE_IP dashboard.local"
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
    echo "/etc/hosts updated: $HOST_ENTRY"
else
    echo "/etc/hosts already has an entry for dashboard.local"
fi

echo "=== K9s & Dashboard setup complete ==="
echo "Run 'k' to launch K9s."
echo "Dashboard URL: https://dashboard.local (NodePort, TLS enabled)"
