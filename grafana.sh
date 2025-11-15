#!/bin/bash

# MicroK8s Grafana Deployment Script with automatic permission fix
# Idempotent, safe to run multiple times
# Exposes Grafana via Ingress on grafana.local
# Run as normal user (uses sudo where required)

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="monitoring"
HOSTNAME="grafana.local"

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

echo "=== Creating namespace monitoring ==="
$MICROK8S_KUBECTL get namespace $NAMESPACE >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create namespace $NAMESPACE

echo "=== Deploying Grafana ==="
$MICROK8S_KUBECTL get deployment grafana -n $NAMESPACE >/dev/null 2>&1 || \
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
EOF

echo "=== Exposing Grafana via ClusterIP service ==="
$MICROK8S_KUBECTL get service grafana-service -n $NAMESPACE >/dev/null 2>&1 || \
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  namespace: $NAMESPACE
spec:
  selector:
    app: grafana
  ports:
    - protocol: TCP
      port: 3000
      targetPort: 3000
  type: ClusterIP
EOF

echo "=== Creating Ingress for Grafana ==="
$MICROK8S_KUBECTL get ingress grafana-ingress -n $NAMESPACE >/dev/null 2>&1 || \
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
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
            name: grafana-service
            port:
              number: 3000
EOF

echo "=== Configuring hosts file ==="
if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "127.0.0.1 $HOSTNAME" | sudo tee -a /etc/hosts
fi

echo ""
echo "=== MANUAL STEPS / NOTES ==="
echo "1. Grafana URL: http://$HOSTNAME"
echo "2. Default login: admin / admin (change password immediately after first login)"
echo "3. Hosts file updated automatically."
