#!/bin/bash

set -e

MICROK8S_KUBECTL="microk8s kubectl"
NAMESPACE="database"
SECRET_NAME="postgres-secret"
DEPLOY_NAME="postgres-deploy"
SERVICE_NAME="postgres-service"

echo "=== Ensuring MicroK8s is ready ==="
sudo microk8s status --wait-ready >/dev/null

echo "=== Creating namespace $NAMESPACE ==="
$MICROK8S_KUBECTL get namespace $NAMESPACE >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create namespace $NAMESPACE

echo "=== Creating PostgreSQL secret ==="
$MICROK8S_KUBECTL get secret $SECRET_NAME -n $NAMESPACE >/dev/null 2>&1 || \
    $MICROK8S_KUBECTL create secret generic $SECRET_NAME \
    --from-literal=POSTGRES_USER=admin \
    --from-literal=POSTGRES_PASSWORD=admin123 \
    -n $NAMESPACE

echo "=== Deploying PostgreSQL ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15
        ports:
        - containerPort: 5432
        envFrom:
        - secretRef:
            name: $SECRET_NAME
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: postgres-data
      volumes:
      - name: postgres-data
        emptyDir: {}
EOF

echo "=== Exposing PostgreSQL via ClusterIP service ==="
$MICROK8S_KUBECTL apply -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
spec:
  selector:
    app: postgres
  ports:
    - protocol: TCP
      port: 5432
      targetPort: 5432
EOF

echo "=== Updating hosts file ==="
if ! grep -q "postgres.local" /etc/hosts; then
    echo "127.0.0.1 postgres.local" | sudo tee -a /etc/hosts
fi

echo ""
echo "=== MANUAL STEPS / NOTES ==="
echo "1. PostgreSQL URL: postgres://admin:admin123@postgres.local:5432"
echo "2. Namespace: $NAMESPACE"
echo "3. Hosts file updated automatically."
echo "4. To connect from inside the cluster, use service name '$SERVICE_NAME' in namespace '$NAMESPACE'."

