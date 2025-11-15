#!/usr/bin/env bash
set -e

echo "=== Updating packages ==="
sudo apt update -y

echo "=== Installing required packages (curl, tar, jq, openssl) ==="
sudo apt install -y curl tar jq openssl

# Ensure user is in microk8s group
echo "=== Ensuring user is in microk8s group ==="
if groups $USER | grep &>/dev/null '\bmicrok8s\b'; then
    echo "User $USER already in microk8s group."
else
    sudo usermod -a -G microk8s $USER
    echo "Added $USER to microk8s group. Please log out/in or run 'newgrp microk8s'."
fi

echo "=== Verifying MicroK8s access ==="
if ! microk8s status --wait-ready &>/dev/null; then
    echo "Error: MicroK8s not ready. Please start MicroK8s first."
    exit 1
fi

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) TARGET="amd64" ;;
    aarch64) TARGET="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Architecture detected: $ARCH → K9s target: $TARGET"

echo "=== Installing K9s if missing ==="
if ! command -v k9s &>/dev/null; then
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -Lo /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGET}.tar.gz"
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/k9s
    rm /tmp/k9s.tar.gz
    echo "K9s installed at /usr/local/bin/k9s"
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Adding alias 'k' for K9s (if missing) ==="
if ! grep -q "alias k=" ~/.bashrc; then
    echo "alias k='k9s'" >> ~/.bashrc
    source ~/.bashrc
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Enabling MicroK8s ingress ==="
microk8s enable ingress

echo "=== Fixing Kubernetes Dashboard Ingress ==="
NODE_IP=$(hostname -I | awk '{print $1}')
kubectl -n kube-system delete ingress kubernetes-dashboard-ingress --ignore-not-found

# Create self-signed cert
CERT_DIR="$HOME/.microk8s-dashboard-certs"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/dashboard.key" \
    -out "$CERT_DIR/dashboard.crt" \
    -subj "/CN=dashboard.local/O=dashboard.local"

# Create Kubernetes TLS secret
kubectl -n kube-system delete secret dashboard-tls --ignore-not-found
kubectl -n kube-system create secret tls dashboard-tls \
    --key="$CERT_DIR/dashboard.key" \
    --cert="$CERT_DIR/dashboard.crt"

# Apply ingress
cat <<EOF | kubectl -n kube-system apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: kube-system
spec:
  ingressClassName: public
  tls:
  - hosts:
    - dashboard.local
    secretName: dashboard-tls
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

echo "=== Updating /etc/hosts ==="
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
fi

echo "=== Waiting for ingress pod to be ready ==="
INGRESS_POD=$(microk8s kubectl get pod -n ingress -l app=nginx-ingress -o jsonpath='{.items[0].metadata.name}')
microk8s kubectl wait pod -n ingress "$INGRESS_POD" --for=condition=Ready --timeout=90s

echo "=== K9s Installation & Dashboard HTTPS Ingress Fix Complete ==="
echo "Run 'k' or 'k9s' to launch K9s."
echo "Dashboard URL: https://dashboard.local"
echo "MicroK8s kubeconfig is ready."
