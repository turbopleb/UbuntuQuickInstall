#!/bin/bash

# Argo CD installer for MicroK8s
# Fully automated, idempotent
# Uses node IP in /etc/hosts
# Requires manual addition to Nginx Proxy Manager

set -euo pipefail

MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="argocd"
INGRESS_HOST="argocd.local"

echo "=== Ensuring MicroK8s is ready ==="
sudo microk8s status --wait-ready >/dev/null

echo "=== Enabling Ingress if not already ==="
microk8s enable ingress >/dev/null 2>&1 || true

echo "=== Creating namespace $NAMESPACE ==="
$MICROK8S_KUBECTL get ns "$NAMESPACE" >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create ns "$NAMESPACE"

echo "=== Deploying Argo CD ==="
$MICROK8S_KUBECTL apply -n "$NAMESPACE" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "=== Waiting for all pods in $NAMESPACE to be ready ==="
while true; do
    NOT_READY=$($MICROK8S_KUBECTL -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
        awk '{if($3!="Running" && $3!="Completed") print $0}' | wc -l)
    
    if [ "$NOT_READY" -eq 0 ]; then
        echo "All pods are running."
        break
    else
        echo "$NOT_READY pods not ready yet..."
        sleep 5
    fi
done

echo "=== Creating TLS secret for Argo CD server ==="
$MICROK8S_KUBECTL delete secret argocd-server-tls -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout tls.key \
    -out tls.crt \
    -subj "/CN=${INGRESS_HOST}/O=LocalOrg" >/dev/null 2>&1
$MICROK8S_KUBECTL create secret tls argocd-server-tls \
    --namespace="$NAMESPACE" \
    --cert=tls.crt \
    --key=tls.key

echo "=== Creating Ingress for Argo CD ==="
$MICROK8S_KUBECTL apply -n "$NAMESPACE" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - $INGRESS_HOST
    secretName: argocd-server-tls
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
              number: 80
EOF

NODE_IP=$(hostname -I | awk '{print $1}')
echo "Detected node IP: $NODE_IP"

echo "=== Updating /etc/hosts ==="
if grep -q "$INGRESS_HOST" /etc/hosts; then
    sudo sed -i "s/.*$INGRESS_HOST/$NODE_IP $INGRESS_HOST/" /etc/hosts
else
    echo "$NODE_IP $INGRESS_HOST" | sudo tee -a /etc/hosts >/dev/null
fi

echo ""
echo "=== DONE ==="
echo "Argo CD is deployed and available at:"
echo "   https://$INGRESS_HOST"
echo ""
echo "Initial admin password:"
echo "   $($MICROK8S_KUBECTL -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo ""
echo "To integrate Argo CD into Nginx Proxy Manager:"
echo "1. Open Nginx Proxy Manager Admin panel."
echo "2. Go to 'Proxy Hosts' → 'Add Proxy Host'."
echo "3. Set Domain Names to: $INGRESS_HOST"
echo "4. Forward Hostname / IP: $NODE_IP"
echo "5. Forward Port: 443"
echo "6. Scheme: https"
echo "7. Save. Argo CD should now appear in the NPM dashboard."
echo ""
echo "(Browsers may show a warning due to self-signed certificate.)"
