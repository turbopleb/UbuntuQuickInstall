#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

echo "=== Installing required packages ==="
sudo apt update -y
sudo apt install -y curl tar jq openssl ca-certificates gnupg apt-transport-https

# ------------------------
# Install kubectl (dynamic repo)
# ------------------------
if ! command -v kubectl >/dev/null 2>&1; then
    echo "=== Installing kubectl ==="
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
    UBUNTU_CODENAME=$(lsb_release -cs)
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-${UBUNTU_CODENAME} main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt update -y || true
    sudo apt install -y kubectl || true
fi

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    sudo usermod -aG microk8s $USER_NAME
    echo "User $USER_NAME added to microk8s group; log out/in required."
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

# ------------------------
# Install K9s
# ------------------------
if ! command -v k9s >/dev/null 2>&1; then
    echo "=== Installing K9s ==="
    ARCH=$(uname -m)
    TARGET="amd64"
    [[ "$ARCH" != "x86_64" ]] && TARGET="$ARCH"
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

# ------------------------
# k alias
# ------------------------
if ! type k >/dev/null 2>&1; then
    alias k='k9s'
    export -f k
fi
echo "Run 'k' to launch K9s in this shell."

# ------------------------
# Enable dashboard and ingress
# ------------------------
sudo microk8s enable ingress
sudo microk8s enable dashboard

# ------------------------
# Expose dashboard NodePort
# ------------------------
$MICROK8S_KUBECTL -n $DASHBOARD_NS patch svc kubernetes-dashboard -p '{"spec": {"type": "NodePort"}}'

# ------------------------
# Wait for service
# ------------------------
DASH_NODEPORT=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(hostname -I | awk '{print $1}')
echo "Dashboard NodePort: https://$NODE_IP:$DASH_NODEPORT"

# ------------------------
# TLS secret for ingress
# ------------------------
if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    $MICROK8S_KUBECTL -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

# ------------------------
# Apply ingress YAML
# ------------------------
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

# ------------------------
# Update /etc/hosts
# ------------------------
HOST_ENTRY="$NODE_IP dashboard.local"
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
else
    sudo sed -i "s/.*dashboard.local/$HOST_ENTRY/" /etc/hosts
fi

# ------------------------
# Add cert to system trusted CA
# ------------------------
sudo cp /var/snap/microk8s/current/certs/server.crt /usr/local/share/ca-certificates/dashboard.local.crt
sudo update-ca-certificates

# ------------------------
# Wait for dashboard pod
# ------------------------
until [[ $($MICROK8S_KUBECTL -n $DASHBOARD_NS get pods -l k8s-app=kubernetes-dashboard -o jsonpath='{.items[0].status.phase}') == "Running" ]]; do
    sleep 3
done

# ------------------------
# Generate admin token
# ------------------------
$MICROK8S_KUBECTL -n $DASHBOARD_NS apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
EOF

$MICROK8S_KUBECTL create clusterrolebinding dashboard-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=$DASHBOARD_NS:dashboard-admin \
  --dry-run=client -o yaml | $MICROK8S_KUBECTL apply -f -

DASH_TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS create token dashboard-admin)
echo ""
echo "Your Kubernetes Dashboard admin token is:"
echo "$DASH_TOKEN"
echo ""

echo "=== K9s & Dashboard Setup Complete ==="
echo "Dashboard accessible at:"
echo "  NodePort: https://$NODE_IP:$DASH_NODEPORT"
echo "  Ingress : https://dashboard.local"
echo "Run 'k' to launch K9s immediately in this shell."
