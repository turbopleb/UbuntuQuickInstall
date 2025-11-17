#!/bin/bash

# MicroK8s Nginx Deployment Script (TLS Always Enabled)
# Idempotent & safe to re-run
# Exposes Nginx at https://nginx.local

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="nginx"
HOSTNAME="nginx.local"

echo "=== Running as user: $USER_NAME ==="

echo "=== Waiting for MicroK8s to be ready ==="
microk8s status --wait-ready >/dev/null

echo "=== Detecting node IP ==="
NODE_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$NODE_IP" ]]; then
    echo "ERROR: Could not detect node IP"
    exit 1
fi
echo "Detected node IP: $NODE_IP"

echo "=== Ensuring namespace exists ==="
$MICROK8S_KUBECTL get ns $NAMESPACE >/dev/null 2>&1 || \
$MICROK8S_KUBECTL create ns $NAMESPACE

echo "=== Applying Nginx Deployment ==="
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
EOF

echo "=== Applying Service ==="
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  namespace: $NAMESPACE
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
EOF

echo "=== Generating self-signed TLS certificate ==="
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout tls.key \
    -out tls.crt \
    -subj "/CN=${HOSTNAME}/O=LocalOrg" >/dev/null 2>&1

echo "=== Creating TLS Secret ==="
$MICROK8S_KUBECTL delete secret nginx-tls -n $NAMESPACE --ignore-not-found >/dev/null 2>&1
$MICROK8S_KUBECTL create secret tls nginx-tls \
    --namespace=$NAMESPACE \
    --cert=tls.crt \
    --key=tls.key

echo "=== Applying Ingress with TLS enabled ==="
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - $HOSTNAME
    secretName: nginx-tls
  rules:
  - host: $HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-service
            port:
              number: 80
EOF

echo "=== Waiting for Deployment rollout ==="
$MICROK8S_KUBECTL rollout status deployment/nginx -n $NAMESPACE

echo "=== Ensuring MicroK8s ingress module is enabled ==="
microk8s enable ingress >/dev/null 2>&1 || true

echo "=== Updating /etc/hosts ==="
if grep -q "$HOSTNAME" /etc/hosts; then
    echo "Updating existing /etc/hosts entry..."
    sudo sed -i "s/.*$HOSTNAME/$NODE_IP $HOSTNAME/" /etc/hosts
else
    echo "$NODE_IP $HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

echo ""
echo "=== DONE ==="
echo "Nginx is available at:"
echo "   https://$HOSTNAME"
echo ""
echo "(A browser warning will appear because this is a self-signed certificate.)"
