#!/bin/bash
set -e

# =========================================
# Ubuntu Quick Install: K9s + MicroK8s Dashboard
# =========================================

NODE_IP=$(hostname -I | awk '{print $1}')
DASHBOARD_HOST="dashboard.local"

echo "=== Installing required packages ==="
sudo apt update
sudo apt install -y curl tar jq openssl ca-certificates gnupg apt-transport-https

# Remove any old broken kubernetes list (xenial) to prevent 404 errors
sudo rm -f /etc/apt/sources.list.d/kubernetes.list || true

echo "=== Installing kubectl via snap if missing ==="
if ! command -v kubectl &> /dev/null; then
    sudo snap install kubectl --classic
fi

echo "=== Ensuring user is in microk8s group ==="
sudo usermod -aG microk8s $USER
sudo chown -f -R $USER ~/.kube

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Installing K9s if missing ==="
if ! command -v k9s &> /dev/null; then
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r .tag_name)
    curl -L "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | tar xz
    sudo mv k9s /usr/local/bin/
fi

echo "=== Making 'k' command work immediately ==="
alias k='microk8s kubectl'
export -f k || true
echo "Run 'k' now to launch K9s in this shell."

echo "=== Enabling MicroK8s dashboard and ingress ==="
microk8s enable ingress
microk8s enable dashboard

echo "=== Exposing Kubernetes Dashboard as NodePort ==="
microk8s kubectl -n kube-system patch svc kubernetes-dashboard -p '{"spec": {"type": "NodePort"}}'

# Wait for dashboard service to appear
until microk8s kubectl -n kube-system get svc kubernetes-dashboard &> /dev/null; do
    echo "Waiting for Kubernetes Dashboard service..."
    sleep 2
done

DASHBOARD_NODEPORT=$(microk8s kubectl -n kube-system get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}')
echo "Dashboard NodePort: https://${NODE_IP}:${DASHBOARD_NODEPORT}"

echo "=== Ensuring TLS secret for dashboard ==="
microk8s kubectl -n kube-system apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kubernetes-dashboard-certs
  namespace: kube-system
type: kubernetes.io/tls
data:
  tls.crt: ""
  tls.key: ""
EOF

echo "=== Applying ingress for ${DASHBOARD_HOST} ==="
microk8s kubectl -n kube-system apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: kube-system
spec:
  rules:
  - host: ${DASHBOARD_HOST}
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

# Update /etc/hosts
if ! grep -q "${DASHBOARD_HOST}" /etc/hosts; then
    echo "${NODE_IP} ${DASHBOARD_HOST}" | sudo tee -a /etc/hosts
else
    sudo sed -i "s/.*${DASHBOARD_HOST}.*/${NODE_IP} ${DASHBOARD_HOST}/" /etc/hosts
fi

# Add dashboard.local cert to trusted CA
echo "=== Adding dashboard.local cert to system trusted CA ==="
DASH_CERT="/usr/local/share/ca-certificates/dashboard.local.crt"
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/dashboard.local.key -out /tmp/dashboard.local.crt \
    -subj "/CN=${DASHBOARD_HOST}/O=Kubernetes Dashboard"
sudo mv /tmp/dashboard.local.crt $DASH_CERT
sudo mv /tmp/dashboard.local.key /tmp/ssl/private/dashboard.local.key || true
sudo update-ca-certificates

echo "=== Generating Kubernetes Dashboard admin token ==="
microk8s kubectl -n kube-system create serviceaccount dashboard-admin --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:dashboard-admin --dry-run=client -o yaml | microk8s kubectl apply -f -

echo "=== Retrieving Kubernetes Dashboard admin token ==="
ADMIN_TOKEN=$(microk8s kubectl -n kube-system get secret $(microk8s kubectl -n kube-system get sa/dashboard-admin -o jsonpath="{.secrets[0].name}") -o jsonpath="{.data.token}" | base64 --decode)
echo "Kubernetes Dashboard admin token:"
echo ""
echo "$ADMIN_TOKEN"
echo ""

echo "=== K9s & Dashboard Setup Complete ==="
echo "Dashboard accessible at:"
echo "  NodePort: https://${NODE_IP}:${DASHBOARD_NODEPORT}"
echo "  Ingress : https://${DASHBOARD_HOST}"
echo "Run 'k' to launch K9s immediately in this shell."
