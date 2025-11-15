#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=300
SLEEP_INTERVAL=5
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

echo "=== Installing dependencies ==="
sudo apt update -y
sudo apt install -y curl jq ca-certificates

echo "=== Ensuring user is in microk8s group ==="
if ! groups "$USER_NAME" | grep -q '\bmicrok8s\b'; then
    echo "Adding user $USER_NAME to microk8s group..."
    sudo usermod -aG microk8s "$USER_NAME"
    echo "You may need to log out and back in for group changes to take effect."
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
export KUBECONFIG=~/.kube/config

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    ARCH=$(uname -m)
    TARGET="amd64"
    [[ "$ARCH" != "x86_64" ]] && TARGET="$ARCH"
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
fi

echo "=== Making 'k' alias work immediately ==="
alias k='k9s'
export -f k
echo "Run 'k' now to launch K9s."

echo "=== Enabling MicroK8s dashboard and ingress ==="
sudo microk8s enable ingress
sudo microk8s enable dashboard

echo "=== Exposing Kubernetes Dashboard correctly ==="
sudo $MICROK8S_KUBECTL -n $DASHBOARD_NS patch svc kubernetes-dashboard -p '{"spec": {"type": "ClusterIP"}}'

echo "=== Ensuring TLS secret for dashboard ==="
if ! $MICROK8S_KUBECTL -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    sudo $MICROK8S_KUBECTL -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

echo "=== Applying ingress for dashboard.local ==="
cat <<EOF | sudo $MICROK8S_KUBECTL apply -f -
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

echo "=== Adding MicroK8s self-signed TLS to trusted certificates ==="
sudo cp /var/snap/microk8s/current/certs/server.crt /usr/local/share/ca-certificates/microk8s-dashboard.crt
sudo update-ca-certificates

echo "=== Waiting for ingress controller and dashboard pods to be Running ==="
END=$((SECONDS+WAIT_TIMEOUT))
while [ $SECONDS -lt $END ]; do
    INGRESS_READY=$($MICROK8S_KUBECTL -n $INGRESS_NS get pod -l app=nginx-ingress-microk8s -o jsonpath='{.items[*].status.phase}')
    DASHBOARD_READY=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get pod -l k8s-app=kubernetes-dashboard -o jsonpath='{.items[*].status.phase}')
    if [[ "$INGRESS_READY" == *"Running"* && "$DASHBOARD_READY" == *"Running"* ]]; then
        echo "Ingress controller and dashboard pods are running."
        break
    else
        echo "Waiting for ingress/dashboard pods..."
        sleep $SLEEP_INTERVAL
    fi
done

echo "=== MicroK8s Dashboard should now be reachable ==="
echo "URL: https://dashboard.local"
echo "Run 'k' or 'k9s' to launch K9s immediately."
