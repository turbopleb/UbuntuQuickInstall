#!/bin/bash

# MicroK8s Grafana Deployment Script
# TLS enabled, PVC for persistence
# Exposes Grafana at https://grafana.local via Kubernetes Ingress
# Prints instructions for adding Grafana to Nginx Proxy Manager
# Fully idempotent and dynamic

set -euo pipefail

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
GRAFANA_NAMESPACE="monitoring"
GRAFANA_HOSTNAME="grafana.local"
GRAFANA_TLS_SECRET="grafana-tls"
GRAFANA_PVC="grafana-data-pvc"

echo "=== Ensuring user has MicroK8s permissions ==="
if ! groups "$USER_NAME" | grep -q "\bmicrok8s\b"; then
    echo "Adding $USER_NAME to microk8s group..."
    sudo usermod -a -G microk8s "$USER_NAME"
    sudo chown -R "$USER_NAME" ~/.kube
    echo "Reloading group membership..."
    exec sg microk8s "$0 $@"
fi

echo "=== Waiting for MicroK8s to be ready ==="
microk8s status --wait-ready >/dev/null

# Detect node IP dynamically
NODE_IP=$(hostname -I | awk '{print $1}')
echo "Detected node IP: $NODE_IP"

# Ensure monitoring namespace exists
$MICROK8S_KUBECTL get ns "$GRAFANA_NAMESPACE" >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create ns "$GRAFANA_NAMESPACE"

# Create PVC for Grafana
$MICROK8S_KUBECTL apply -n "$GRAFANA_NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $GRAFANA_PVC
  namespace: $GRAFANA_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Deploy Grafana
$MICROK8S_KUBECTL apply -n "$GRAFANA_NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $GRAFANA_NAMESPACE
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
          claimName: $GRAFANA_PVC
EOF

# Service
$MICROK8S_KUBECTL apply -n "$GRAFANA_NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: grafana-service
  namespace: $GRAFANA_NAMESPACE
spec:
  selector:
    app: grafana
  ports:
    - protocol: TCP
      port: 3000
      targetPort: 3000
  type: ClusterIP
EOF

# TLS Secret
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout grafana.key \
    -out grafana.crt \
    -subj "/CN=${GRAFANA_HOSTNAME}/O=LocalOrg" >/dev/null 2>&1

$MICROK8S_KUBECTL delete secret "$GRAFANA_TLS_SECRET" -n "$GRAFANA_NAMESPACE" --ignore-not-found >/dev/null 2>&1
$MICROK8S_KUBECTL create secret tls "$GRAFANA_TLS_SECRET" \
    --namespace="$GRAFANA_NAMESPACE" \
    --cert=grafana.crt \
    --key=grafana.key

# Ingress
$MICROK8S_KUBECTL apply -n "$GRAFANA_NAMESPACE" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: $GRAFANA_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - $GRAFANA_HOSTNAME
    secretName: $GRAFANA_TLS_SECRET
  rules:
  - host: $GRAFANA_HOSTNAME
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

# Wait for rollout
$MICROK8S_KUBECTL rollout status deployment/grafana -n "$GRAFANA_NAMESPACE"

# Update /etc/hosts
if grep -q "$GRAFANA_HOSTNAME" /etc/hosts; then
    sudo sed -i "s/.*$GRAFANA_HOSTNAME/$NODE_IP $GRAFANA_HOSTNAME/" /etc/hosts
else
    echo "$NODE_IP $GRAFANA_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

# Final instructions
echo ""
echo "=== DONE ==="
echo "Grafana is deployed and available via Kubernetes Ingress:"
echo "   https://$GRAFANA_HOSTNAME"
echo "Default login: admin / admin (change password immediately)"
echo "(Browsers may show a warning due to self-signed certificate.)"
echo ""
echo "To integrate Grafana into Nginx Proxy Manager:"
echo "1. Open Nginx Proxy Manager Admin panel."
echo "2. Go to 'Proxy Hosts' → 'Add Proxy Host'."
echo "3. Set Domain Names to: $GRAFANA_HOSTNAME"
echo "4. Forward Hostname / IP: $NODE_IP"
echo "5. Forward Port: 3000"
echo "6. Scheme: http"
echo "7. Enable SSL if desired (optional, your Ingress already provides TLS)."
echo "8. Save. Grafana should now appear in the NPM dashboard."
