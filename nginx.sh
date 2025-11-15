#!/bin/bash

# MicroK8s Nginx Deployment Script with automatic permission fix
# Idempotent, safe to run multiple times
# Exposes Nginx via Ingress on nginx.local
# Run as normal user (uses sudo where required)

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="nginx"
HOSTNAME="nginx.local"

echo "=== Ensuring user has MicroK8s permissions ==="
if ! groups $USER_NAME | grep -q "\bmicrok8s\b"; then
    echo "Adding $USER_NAME to microk8s group..."
    sudo usermod -a -G microk8s $USER_NAME
    sudo chown -R $USER_NAME ~/.kube
    echo "Reloading group membership..."
    exec sg microk8s "$0 $@"
    exit
fi

echo "=== Waiting for MicroK8s to be ready ==="
microk8s status --wait-ready >/dev/null

echo "=== Creating Nginx namespace ==="
$MICROK8S_KUBECTL get namespace $NAMESPACE >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create namespace $NAMESPACE

echo "=== Deploying Nginx ==="
$MICROK8S_KUBECTL get deployment nginx -n $NAMESPACE >/dev/null 2>&1 || \
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

echo "=== Exposing Nginx via ClusterIP service ==="
$MICROK8S_KUBECTL get service nginx-service -n $NAMESPACE >/dev/null 2>&1 || \
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
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
EOF

echo "=== Creating Ingress for Nginx ==="
$MICROK8S_KUBECTL get ingress nginx-ingress -n $NAMESPACE >/dev/null 2>&1 || \
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
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

echo "=== Configuring hosts file ==="
if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "127.0.0.1 $HOSTNAME" | sudo tee -a /etc/hosts
fi

echo ""
echo "=== MANUAL STEPS / NOTES ==="
echo "1. Nginx URL: http://$HOSTNAME"
echo "2. Hosts file updated automatically."
echo "3. All deployment and Ingress resources created automatically."
