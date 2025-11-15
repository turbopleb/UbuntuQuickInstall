#!/bin/bash
set -e

echo "=== Updating packages ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq, openssl) ==="
sudo apt install -y curl tar jq openssl

echo "=== Ensuring user is in microk8s group ==="
if groups $USER | grep &>/dev/null '\bmicrok8s\b'; then
    echo "User $USER already in microk8s group."
else
    echo "Adding user $USER to microk8s group..."
    sudo usermod -aG microk8s $USER
    echo "You need to log out and back in for group changes to take effect."
fi

echo "=== Verifying MicroK8s access ==="
if microk8s status --wait-ready >/dev/null 2>&1; then
    echo "MicroK8s is running"
else
    echo "MicroK8s is not running. Please start MicroK8s."
    exit 1
fi

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    TARGET="amd64"
else
    TARGET="$ARCH"
fi
echo "Architecture detected: $ARCH → K9s target: $TARGET"

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    echo "Downloading latest K9s..."
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Adding alias 'k' for K9s (if missing) ==="
if ! grep -q "alias k=" ~/.bashrc; then
    echo "alias k='k9s'" >> ~/.bashrc
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Enabling MicroK8s ingress ==="
microk8s enable ingress

echo "=== Fixing Kubernetes Dashboard Ingress ==="
# Delete old ingress if exists
microk8s kubectl -n kube-system delete ingress kubernetes-dashboard-ingress --ignore-not-found

# Create TLS secret if missing
if ! microk8s kubectl -n kube-system get secret dashboard-tls >/dev/null 2>&1; then
    microk8s kubectl -n kube-system create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

# Apply ingress YAML
cat <<EOF | microk8s kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: kube-system
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

echo "=== Adding /etc/hosts entry for dashboard.local ==="
NODE_IP=$(hostname -I | awk '{print $1}')
HOST_ENTRY="$NODE_IP dashboard.local"
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
    echo "/etc/hosts updated: $HOST_ENTRY"
else
    echo "/etc/hosts already has an entry for dashboard.local"
fi

echo "=== K9s Installation & Dashboard Ingress Fix Complete ==="
echo "Run 'k' or 'k9s' to launch K9s."
echo "Dashboard URL: https://dashboard.local"
echo "MicroK8s kubeconfig is ready."
