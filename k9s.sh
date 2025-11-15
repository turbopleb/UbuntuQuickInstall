#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=300
SLEEP_INTERVAL=5
DASHBOARD_NS="kube-system"

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

echo "=== Enabling MicroK8s ingress ==="
microk8s enable ingress

echo "=== Enabling Kubernetes Dashboard ==="
microk8s enable dashboard

echo "=== Enabling Metrics Server ==="
microk8s enable metrics-server

# Wait for metrics-server pod to be Running
echo "=== Waiting for metrics-server pod ==="
END=$((SECONDS+WAIT_TIMEOUT))
while [ $SECONDS -lt $END ]; do
    METRICS_READY=$($MICROK8S_KUBECTL -n kube-system get pods -l k8s-app=metrics-server --no-headers 2>/dev/null | awk '{if($3=="Running") print $1}')
    if [ -n "$METRICS_READY" ]; then
        echo "Metrics-server pod is running: $METRICS_READY"
        break
    fi
    echo "Waiting for metrics-server pod..."
    sleep $SLEEP_INTERVAL
done

# Ensure dashboard service exists
echo "=== Checking Kubernetes Dashboard service ==="
if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get svc kubernetes-dashboard >/dev/null 2>&1; then
    echo "Dashboard service not found. Something went wrong with addon enable."
    exit 1
fi

# Create TLS secret if missing
if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    microk8s kubectl -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

# Expose dashboard externally via ingress
echo "=== Applying dashboard ingress ==="
microk8s kubectl -n $DASHBOARD_NS delete ingress kubernetes-dashboard-ingress --ignore-not-found

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

# Correct /etc/hosts to point dashboard.local to node IP
NODE_IP=$(hostname -I | awk '{print $1}')
if grep -q "dashboard.local" /etc/hosts; then
    sudo sed -i "s/.*dashboard.local/$NODE_IP dashboard.local/" /etc/hosts
else
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts > /dev/null
fi
echo "/etc/hosts updated: dashboard.local → $NODE_IP"

# Ensure K9s installed
ARCH=$(uname -m)
TARGET="amd64"
[[ "$ARCH" != "x86_64" ]] && TARGET="$ARCH"

if ! command -v k9s >/dev/null 2>&1; then
    echo "=== Installing K9s ==="
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
fi

# Set alias immediately
alias k='k9s'
echo "Alias 'k' set for current session"

# K9s resource hotkeys
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
echo "Run 'k' to launch K9s."
echo "Dashboard URL: https://dashboard.local"
echo "Metrics-server enabled: CPU/Memory stats should now appear in K9s."
