#!/bin/bash

# MicroK8s Deployment Script:
# Nginx Proxy Manager + Kubernetes Dashboard with PVCs
# TLS enabled for main site
# Admin panel exposed via NodePort for full functionality
# Idempotent & safe to re-run

set -euo pipefail

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
NODE_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$NODE_IP" ]]; then
    echo "ERROR: Could not detect node IP"
    exit 1
fi
echo "Detected node IP: $NODE_IP"

# Enable ingress
echo "=== Enabling MicroK8s ingress module ==="
microk8s enable ingress >/dev/null 2>&1 || true

# -----------------------------
# 1️⃣ Nginx Proxy Manager with PVCs
# -----------------------------
NPM_NAMESPACE="nginx"
NPM_HOSTNAME="nginx.local"
NPM_TLS_SECRET="nginx-tls"
ADMIN_NODEPORT=30801

echo "=== Ensuring namespace exists: $NPM_NAMESPACE ==="
$MICROK8S_KUBECTL get ns $NPM_NAMESPACE >/dev/null 2>&1 || \
$MICROK8S_KUBECTL create ns $NPM_NAMESPACE

echo "=== Creating PVCs for NPM data and letsencrypt ==="
$MICROK8S_KUBECTL apply -n $NPM_NAMESPACE -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: npm-data-pvc
  namespace: $NPM_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: npm-lets-pvc
  namespace: $NPM_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 512Mi
EOF

echo "=== Deploying Nginx Proxy Manager ==="
$MICROK8S_KUBECTL apply -n $NPM_NAMESPACE -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-proxy-manager
  namespace: $NPM_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-proxy-manager
  template:
    metadata:
      labels:
        app: nginx-proxy-manager
    spec:
      containers:
      - name: npm
        image: jc21/nginx-proxy-manager:latest
        ports:
        - containerPort: 80
        - containerPort: 81
        - containerPort: 443
        env:
        - name: DB_SQLITE_FILE
          value: "/data/database.sqlite"
        volumeMounts:
        - name: npm-data
          mountPath: /data
        - name: npm-lets
          mountPath: /etc/letsencrypt
      volumes:
      - name: npm-data
        persistentVolumeClaim:
          claimName: npm-data-pvc
      - name: npm-lets
        persistentVolumeClaim:
          claimName: npm-lets-pvc
EOF

echo "=== Exposing Nginx Proxy Manager Service ==="
$MICROK8S_KUBECTL apply -n $NPM_NAMESPACE -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx-proxy-manager
  namespace: $NPM_NAMESPACE
spec:
  selector:
    app: nginx-proxy-manager
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: admin
      port: 81
      targetPort: 81
      nodePort: $ADMIN_NODEPORT
    - name: https
      port: 443
      targetPort: 443
  type: NodePort
EOF

echo "=== Creating self-signed TLS for NPM ==="
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout npm.key \
  -out npm.crt \
  -subj "/CN=$NPM_HOSTNAME/O=LocalOrg" >/dev/null 2>&1

$MICROK8S_KUBECTL delete secret $NPM_TLS_SECRET -n $NPM_NAMESPACE --ignore-not-found
$MICROK8S_KUBECTL create secret tls $NPM_TLS_SECRET \
  --namespace=$NPM_NAMESPACE \
  --cert=npm.crt \
  --key=npm.key

echo "=== Creating Ingress for NPM main site ==="
$MICROK8S_KUBECTL apply -n $NPM_NAMESPACE -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-proxy-manager-ingress
  namespace: $NPM_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  tls:
  - hosts:
    - $NPM_HOSTNAME
    secretName: $NPM_TLS_SECRET
  rules:
  - host: $NPM_HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-proxy-manager
            port:
              number: 80
EOF

$MICROK8S_KUBECTL rollout status deployment/nginx-proxy-manager -n $NPM_NAMESPACE

# -----------------------------
# 2️⃣ Kubernetes Dashboard
# -----------------------------
K8S_NAMESPACE="kube-system"
K8S_HOSTNAME="k8s.local"
K8S_TLS_SECRET="k8s-tls"

echo "=== Enabling Kubernetes Dashboard ==="
microk8s enable dashboard >/dev/null 2>&1 || true

echo "=== Creating self-signed TLS for Kubernetes Dashboard ==="
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout k8s.key \
  -out k8s.crt \
  -subj "/CN=$K8S_HOSTNAME/O=LocalOrg" >/dev/null 2>&1

$MICROK8S_KUBECTL delete secret $K8S_TLS_SECRET -n $K8S_NAMESPACE --ignore-not-found
$MICROK8S_KUBECTL create secret tls $K8S_TLS_SECRET \
  --namespace=$K8S_NAMESPACE \
  --cert=k8s.crt \
  --key=k8s.key

echo "=== Creating Ingress for Kubernetes Dashboard ==="
$MICROK8S_KUBECTL apply -n $K8S_NAMESPACE -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: $K8S_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  tls:
  - hosts:
    - $K8S_HOSTNAME
    secretName: $K8S_TLS_SECRET
  rules:
  - host: $K8S_HOSTNAME
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

# -----------------------------
# 3️⃣ Update /etc/hosts
# -----------------------------
for host in $NPM_HOSTNAME $K8S_HOSTNAME; do
    if grep -q "$host" /etc/hosts; then
        echo "Updating /etc/hosts for $host..."
        sudo sed -i "s/.*$host/$NODE_IP $host/" /etc/hosts
    else
        echo "Adding /etc/hosts entry for $host..."
        echo "$NODE_IP $host" | sudo tee -a /etc/hosts >/dev/null
    fi
done

echo ""
echo "=== DONE ==="
echo "Nginx Proxy Manager admin panel accessible at:"
echo "   http://$NODE_IP:$ADMIN_NODEPORT  (full admin panel with persistent data)"
echo "Main site placeholder at: https://$NPM_HOSTNAME"
echo "Kubernetes Dashboard: https://$K8S_HOSTNAME"
echo ""
echo "(Browsers will show a warning because these are self-signed certificates.)"
