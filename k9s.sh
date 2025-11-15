#!/bin/bash
set -euo pipefail

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    echo "Adding user $USER_NAME to microk8s group..."
    sudo usermod -aG microk8s $USER_NAME
    echo "You may need to log out and back in for group changes to take effect."
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Making 'k' command work immediately ==="
function k() { k9s "$@"; }
if ! grep -q 'function k()' ~/.bashrc; then
    echo 'function k() { k9s "$@"; }' >> ~/.bashrc
fi
echo "Run 'k' now in this shell to launch K9s."

echo "=== Enabling MicroK8s dashboard and ingress ==="
microk8s enable ingress
microk8s enable dashboard

echo "=== Exposing Kubernetes Dashboard as NodePort ==="
$MICROK8S_KUBECTL -n $DASHBOARD_NS patch service kubernetes-dashboard -p '{"spec":{"type":"NodePort"}}'

# Get the assigned NodePort
DASHBOARD_PORT=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get service kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}')

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
spec:
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

echo "=== Updating /etc/hosts with node IP for dashboard.local ==="
NODE_IP=$($MICROK8S_KUBECTL get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
sudo sed -i '/dashboard.local/d' /etc/hosts
echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts > /dev/null
echo "/etc/hosts updated: $NODE_IP dashboard.local"

echo "=== Waiting for ingress controller and dashboard pods to be Running ==="
END=$((SECONDS+300)) # 5 min timeout
while [ $SECONDS -lt $END ]; do
    INGRESS_READY=$($MICROK8S_KUBECTL -n $INGRESS_NS get pods -l app.kubernetes.io/name=nginx-ingress-microk8s -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
    DASH_READY=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get pods -l k8s-app=kubernetes-dashboard -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
    if [[ "$INGRESS_READY" == *"true"* && "$DASH_READY" == *"true"* ]]; then
        echo "Ingress controller and dashboard pods are running"
        break
    fi
    echo "Waiting for ingress/dashboard pods to be ready..."
    sleep 5
done

echo "=== Dashboard should now be accessible ==="
echo "URL: https://dashboard.local (NodePort $DASHBOARD_PORT, Node IP $NODE_IP)"
echo "You can run 'k' in this shell to start K9s immediately."
