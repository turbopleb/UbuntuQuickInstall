#!/usr/bin/env bash
set -e

echo "=== Updating packages ==="
sudo apt update
sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq, openssl) ==="
sudo apt install -y curl tar jq openssl

echo "=== Ensuring user is in microk8s group ==="
if id -nG "$USER" | grep -qw "microk8s"; then
    echo "User $USER already in microk8s group."
else
    sudo usermod -a -G microk8s "$USER"
    echo "Added $USER to microk8s group. Log out/in for changes to take effect."
fi

echo "=== Verifying MicroK8s access ==="
if ! microk8s status --wait-ready; then
    echo "MicroK8s is not ready. Exiting."
    exit 1
fi

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    K9S_ARCH="amd64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "=== Installing K9s if missing ==="
if ! command -v k9s &>/dev/null; then
    echo "Downloading K9s..."
    TMPDIR=$(mktemp -d)
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
    curl -Lo "$TMPDIR/k9s.tar.gz" "https://github.com/derailed/k9s/releases/download/$K9S_VERSION/k9s_${K9S_VERSION:1}_Linux_$K9S_ARCH.tar.gz"
    tar -xzf "$TMPDIR/k9s.tar.gz" -C "$TMPDIR"
    sudo mv "$TMPDIR/k9s" /usr/local/bin/k9s
    rm -rf "$TMPDIR"
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

# Delete previous ingress and TLS secret if they exist
microk8s kubectl delete ingress kubernetes-dashboard-ingress -n kube-system || true
microk8s kubectl delete secret dashboard-tls -n kube-system || true

# Create self-signed certificate
CERT_DIR="$HOME/.microk8s-dashboard-certs"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/dashboard.key" \
    -out "$CERT_DIR/dashboard.crt" \
    -subj "/CN=dashboard.local/O=dashboard.local"

# Create Kubernetes TLS secret
microk8s kubectl create secret tls dashboard-tls \
    --key="$CERT_DIR/dashboard.key" \
    --cert="$CERT_DIR/dashboard.crt" -n kube-system

# Apply ingress
cat <<EOF | microk8s kubectl apply -f -
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

echo "=== Adding /etc/hosts entry for dashboard.local ==="
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "127.0.0.1 dashboard.local" | sudo tee -a /etc/hosts
fi

echo "=== K9s Installation & Dashboard Ingress Fix Complete ==="
echo "Run 'k' or 'k9s' to launch K9s."
echo "Dashboard URL: https://dashboard.local"
echo "MicroK8s kubeconfig is ready."
