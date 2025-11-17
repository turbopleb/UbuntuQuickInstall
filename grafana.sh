#!/bin/bash

# MicroK8s Grafana Deployment + Nginx Proxy Manager integration
# TLS enabled, PVC for persistence, automatic NPM proxy host
# Idempotent & safe to run multiple times

set -euo pipefail

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="monitoring"
HOSTNAME="grafana.local"
TLS_SECRET="grafana-tls"
PVC_NAME="grafana-data-pvc"
NPM_NAMESPACE="nginx"
NPM_SERVICE_LABEL="app=nginx-proxy-manager"

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
NODE_IP=$(hostname -I | awk '{print $1}')
echo "Detected node IP: $NODE_IP"

# Ensure monitoring namespace exists
$MICROK8S_KUBECTL get ns $NAMESPACE >/dev/null 2>&1 || $MICROK8S_KUBECTL create ns $NAMESPACE

# Create PVC for Grafana
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

# Service
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

# TLS
openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout grafana.key \
    -out grafana.crt \
    -subj "/CN=${HOSTNAME}/O=LocalOrg" >/dev/null 2>&1

$MICROK8S_KUBECTL delete secret $TLS_SECRET -n $NAMESPACE --ignore-not-found >/dev/null 2>&1
$MICROK8S_KUBECTL create secret tls $TLS_SECRET \
    --namespace=$NAMESPACE \
    --cert=grafana.crt \
    --key=grafana.key

# Ingress
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

$MICROK8S_KUBECTL rollout status deployment/grafana -n $NAMESPACE

# /etc/hosts
if grep -q "$HOSTNAME" /etc/hosts; then
    sudo sed -i "s/.*$HOSTNAME/$NODE_IP $HOSTNAME/" /etc/hosts
else
    echo "$NODE_IP $HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

# === NPM Proxy Host ===
echo "=== Configuring Nginx Proxy Manager for $HOSTNAME ==="
NPM_POD=$($MICROK8S_KUBECTL get pod -n $NPM_NAMESPACE -l $NPM_SERVICE_LABEL -o jsonpath='{.items[0].metadata.name}')
$MICROK8S_KUBECTL exec -n $NPM_NAMESPACE $NPM_POD -- /bin/sh -c "
curl -s -X POST http://localhost:81/api/nginx/proxy-hosts \
-H 'Content-Type: application/json' \
-d '{
  \"domain_names\": [\"$HOSTNAME\"],
  \"forward_scheme\": \"http\",
  \"forward_host\": \"$NODE_IP\",
  \"forward_port\": 3000,
  \"ssl\": true,
  \"ssl_forced\": true
}' || echo 'Proxy host might already exist or NPM API unavailable'
"

echo ""
echo "=== DONE ==="
echo "Grafana URL via Nginx Proxy Manager: https://$HOSTNAME"
echo "Default login: admin / admin (change password immediately)"
echo "(Browsers will show a warning due to self-signed certificate.)"
