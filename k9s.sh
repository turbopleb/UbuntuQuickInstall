#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=300
SLEEP_INTERVAL=5
DASHBOARD_NS="kube-system"

echo "=== Installing required packages (curl, tar, jq, openssl, ca-certificates) ==="
sudo apt update -y
sudo apt install -y curl tar jq openssl ca-certificates

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    echo "Adding user $USER_NAME to microk8s group..."
    sudo usermod -aG microk8s $USER_NAME
    echo "Please log out and back in for group changes to take effect."
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    echo "Downloading latest K9s..."
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && TARGET="amd64" || TARGET="$ARCH"
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Making 'k' command work immediately ==="
k() { k9s; }
export -f k
echo "Run 'k' now to launch K9s in this shell."

echo "=== Enabling MicroK8s dashboard and ingress ==="
sudo microk8s enable ingress || true
sudo microk8s enable dashboard || true

echo "=== Exposing Kubernetes Dashboard as NodePort ==="
sudo microk8s kubectl -n $DASHBOARD_NS patch svc kubernetes-dashboard -p '{"spec": {"type": "NodePort"}}'

echo "=== Ensuring TLS secret for dashboard ==="
if ! sudo microk8s kubectl -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    sudo microk8s kubectl -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

echo "=== Applying ingress for dashboard.local ==="
cat <<EOF | sudo microk8s kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: $DASHBOARD_NS
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  ingressClassName: public
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

echo "=== Updating /etc/hosts with node IP for dashboard.local ==="
NODE_IP=$(hostname -I | awk '{print $1}')
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts > /dev/null
    echo "/etc/hosts updated: $NODE_IP dashboard.local"
else
    echo "/etc/hosts already has an entry for dashboard.local"
fi

echo "=== Adding dashboard.local cert to system trusted CA ==="
sudo cp /var/snap/microk8s/current/certs/server.crt /usr/local/share/ca-certificates/dashboard-local.crt
sudo update-ca-certificates

echo "=== Getting NodePort for Kubernetes Dashboard ==="
NODEPORT=$(sudo microk8s kubectl -n $DASHBOARD_NS get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}')
echo "Dashboard NodePort: $NODE_IP:$NODEPORT"

echo "=== Generating Kubernetes Dashboard admin token ==="
sudo microk8s kubectl -n $DASHBOARD_NS create serviceaccount dashboard-admin || true
sudo microk8s kubectl -n $DASHBOARD_NS create clusterrolebinding dashboard-admin \
    --clusterrole=cluster-admin \
    --serviceaccount=kube-system:dashboard-admin || true

echo "Your Kubernetes Dashboard admin token is:"
sudo microk8s kubectl -n $DASHBOARD_NS get secret \
  $(sudo microk8s kubectl -n $DASHBOARD_NS get sa dashboard-admin -o jsonpath="{.secrets[0].name}") \
  -o jsonpath="{.data.token}" | base64 -d
echo

echo "=== K9s & Dashboard Setup Complete ==="
echo "Dashboard accessible at:"
echo "  NodePort: https://$NODE_IP:$NODEPORT"
echo "  Ingress : https://dashboard.local"
echo "Run 'k' to launch K9s immediately in this shell."
