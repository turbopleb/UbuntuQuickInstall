#!/bin/bash

# Argo CD installer for MicroK8s
# Fully automated, idempotent, exposes via Ingress at argocd.local
# Uses dynamic pod readiness check

set -e

MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="argocd"
INGRESS_HOST="argocd.local"

echo "=== Ensuring MicroK8s is ready ==="
sudo microk8s status --wait-ready >/dev/null

echo "=== Creating namespace $NAMESPACE ==="
$MICROK8S_KUBECTL get namespace $NAMESPACE >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create namespace $NAMESPACE

echo "=== Deploying Argo CD ==="
# Apply official Argo CD manifests
$MICROK8S_KUBECTL apply -n $NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "=== Waiting for all pods in $NAMESPACE to be Ready ==="
while true; do
    NOT_READY=$($MICROK8S_KUBECTL -n $NAMESPACE get pods --no-headers 2>/dev/null | \
        awk '{if($3!="Running" && $3!="Completed") print $0}' | wc -l)
    
    if [ "$NOT_READY" -eq 0 ]; then
        echo "All pods are running."
        break
    else
        echo "$NOT_READY pods not ready yet..."
        sleep 5
    fi
done

echo "=== Creating Ingress for Argo CD ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: $INGRESS_HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOF

echo "=== Updating /etc/hosts ==="
if ! grep -q "$INGRESS_HOST" /etc/hosts; then
    echo "127.0.0.1 $INGRESS_HOST" | sudo tee -a /etc/hosts
fi

echo ""
echo "=== MANUAL STEPS / NOTES ==="
echo "1. Argo CD URL: https://$INGRESS_HOST"
echo "2. Initial admin password:"
echo "   Run: $MICROK8S_KUBECTL -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "3. Namespace: $NAMESPACE"
echo "4. Hosts file updated automatically."
echo "5. Ensure Ingress addon is enabled in MicroK8s:"
echo "   sudo microk8s enable ingress"
