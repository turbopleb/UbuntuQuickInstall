#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=300  # 5 minutes
SLEEP_INTERVAL=5  # seconds
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    echo "Adding user $USER_NAME to microk8s group..."
    sudo usermod -aG microk8s $USER_NAME
    echo "Reloading group membership with newgrp..."
    exec sg microk8s "$0 $@"
    exit 0
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Enabling MicroK8s dashboard and ingress ==="
microk8s enable ingress dashboard

# Give ingress and dashboard a few seconds to initialize
sleep 10

NODE_IP=$(hostname -I | awk '{print $1}')
HOST_ENTRY="$NODE_IP dashboard.local"

echo "=== Setting up dashboard ingress for external access ==="
microk8s kubectl -n $DASHBOARD_NS delete ingress kubernetes-dashboard-ingress --ignore-not-found

# Create TLS secret if missing
if ! microk8s kubectl -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    microk8s kubectl -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

# Apply ingress YAML
cat <<EOF | microk8s kubectl apply -f -
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

# Add /etc/hosts entry if missing
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
    echo "/etc/hosts updated: $HOST_ENTRY"
fi

echo "=== Installing K9s if missing ==="
ARCH=$(uname -m)
TARGET="amd64"
[[ "$ARCH" != "x86_64" ]] && TARGET="$ARCH"

if ! command -v k9s >/dev/null 2>&1; then
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
fi

# Alias 'k' works immediately
alias k='k9s'
echo "=== Alias 'k' for K9s set for current session ==="

# Optional: configure K9s resource hotkeys
mkdir -p ~/.k9s
cat <<EOF > ~/.k9s/skin.yml
k9s:
  resource:
    pods: "p"
    deployments: "d"
    services: "s"
    ingresses: "i"
    configmaps: "c"
    secrets: "S"
EOF

echo "=== Setup Complete ==="
echo "Run 'k' to start K9s."
echo "Dashboard available at: https://dashboard.local"
