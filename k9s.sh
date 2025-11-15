#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=300
SLEEP_INTERVAL=5
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

echo "=== Installing required packages (curl, tar, jq, openssl, ca-certificates) ==="
sudo apt update -y
sudo apt install -y curl tar jq openssl ca-certificates

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    sudo usermod -aG microk8s $USER_NAME
    echo "User added to microk8s group. You may need to re-login."
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
export KUBECONFIG=~/.kube/config

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    ARCH=$(uname -m)
    TARGET="amd64"
    [[ "$ARCH" != "x86_64" ]] && TARGET="$ARCH"
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
fi

echo "=== Making 'k' command work immediately ==="
k() { k9s; }
export -f k
echo "Run 'k' now to launch K9s in this shell."

echo "=== Enabling MicroK8s dashboard and ingress ==="
sudo microk8s enable ingress || true
sudo microk8s enable dashboard || true

echo "=== Exposing Kubernetes Dashboard as NodePort ==="
$MICROK8S_KUBECTL -n $DASHBOARD_NS patch svc kubernetes-dashboard -p '{"spec":{"type":"NodePort"}}'

# Wait for dashboard service
echo "=== Waiting for Kubernetes Dashboard service ==="
END=$((SECONDS + WAIT_TIMEOUT))
while ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get svc kubernetes-dashboard >/dev/null 2>&1; do
    if [ $SECONDS -ge $END ]; then
        echo "Timeout waiting for dashboard service."
        exit 1
    fi
    sleep $SLEEP_INTERVAL
done

NODE_IP=$(hostname -I | awk '{print $1}')
NODEPORT=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}')
echo "Dashboard NodePort: https://$NODE_IP:$NODEPORT"

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
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
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
HOST_ENTRY="$NODE_IP dashboard.local"
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
else
    sudo sed -i "s/.*dashboard.local/$HOST_ENTRY/" /etc/hosts
fi

echo "=== Adding dashboard.local cert to system trusted CA ==="
sudo cp /var/snap/microk8s/current/certs/server.crt /usr/local/share/ca-certificates/dashboard.local.crt
sudo update-ca-certificates

echo "=== Generating Kubernetes Dashboard admin token ==="
$MICROK8S_KUBECTL -n $DASHBOARD_NS apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: $DASHBOARD_NS
EOF

$MICROK8S_KUBECTL create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=$DASHBOARD_NS:dashboard-admin --dry-run=client -o yaml | $MICROK8S_KUBECTL apply -f -

echo "=== Retrieving Kubernetes Dashboard admin token ==="
END=$((SECONDS + WAIT_TIMEOUT))
TOKEN=""
while [ -z "$TOKEN" ]; do
    SECRET_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get sa dashboard-admin -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
    if [ -n "$SECRET_NAME" ]; then
        TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret $SECRET_NAME -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode)
    fi
    [ -z "$TOKEN" ] && sleep $SLEEP_INTERVAL
    [ $SECONDS -ge $END ] && break
done

echo ""
echo "=== K9s & Dashboard Setup Complete ==="
echo "Dashboard accessible at:"
echo "  NodePort: https://$NODE_IP:$NODEPORT"
echo "  Ingress : https://dashboard.local"
if [ -n "$TOKEN" ]; then
    echo ""
    echo "Kubernetes Dashboard admin token:"
    echo "$TOKEN"
else
    echo "WARNING: Could not retrieve admin token."
fi
echo "Run 'k' to launch K9s immediately in this shell."
