#!/bin/bash

# MicroK8s Grafana Deployment Script with PVCs (TLS Enabled)
# Idempotent & safe to re-run
# Exposes Grafana via Ingress on grafana.local
# Run as normal user (uses sudo where required)

set -euo pipefail

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="monitoring"
HOSTNAME="grafana.local"
TLS_SECRET="grafana-tls"
PVC_NAME="grafana-data-pvc"

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

# Detect node IP
echo "=== Detecting node IP ==="
NODE_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$NODE_IP" ]]; then
    echo "ERROR: Could not detect node IP"
    exit 1
fi
echo "Detected node IP: $NODE_IP"

# Ensure namespace exists
echo "=== Creating namespace $NAMESPACE ==="
$MICROK8S_KUBECTL get namespace $NAMESPACE >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create namespace $NAMESPACE

# Create PVC for Grafana data
echo "=== Creating PersistentVolumeClaim for Grafana data ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Deploy Grafana
echo "=== Deploying Grafana ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
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
        volumeMounts:
        - name: grafana-data
          mountPath: /var/lib/grafana
      volumes:
      - name: grafana-data
        persistentVolumeClaim:
          claimName: $PVC_NAME
EOF

# Expose ClusterIP service
echo "=== Exposing Grafana via ClusterIP service ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
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

# Generate self-signed TLS
echo "=== Generating self-signed TLS certificate for Grafana ==="
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout grafana.key \
    -out grafana.crt \
    -subj "/CN=${HOSTNAME}/O=LocalOrg" >/dev/null 2>&1

# Create TLS Secret
echo "=== Creating TLS Secret ==="
$MICROK8S_KUBECTL delete secret $TLS_SECRET -n $NAMESPACE --ignore-not-found >/dev/null 2>&1
$MICROK8S_KUBECTL create secret tls $TLS_SECRET \
    --namespace=$NAMESPACE \
    --cert=grafana.crt \
    --key=grafana.key

# Apply Ingress with TLS
echo "=== Creating Ingress for Grafana (TLS enabled) ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - $HOSTNAME
    secretName: $TLS_SECRET
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

# Wait for deployment rollout
echo "=== Waiting for Deployment rollout ==="
$MICROK8S_KUBECTL rollout status deployment/grafana -n $NAMESPACE

# Update /etc/hosts
echo "=== Updating /etc/hosts ==="
if grep -q "$HOSTNAME" /etc/hosts; then
    echo "Updating existing /etc/hosts entry..."
    sudo sed -i "s/.*$HOSTNAME/$NODE_IP $HOSTNAME/" /etc/hosts
else
    echo "$NODE_IP $HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

echo ""
echo "=== DONE ==="
echo "Grafana URL: https://$HOSTNAME"
echo "Default login: admin / admin (change password immediately)"
echo "(Browsers will show a warning because this is a self-signed certificate.)"
