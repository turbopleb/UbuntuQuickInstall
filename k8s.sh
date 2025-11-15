#!/bin/bash
# Full MicroK8s Setup Script for Ubuntu
# Includes dashboard, ingress, hostpath storage, admin-user token fix
# Ensures Nginx Ingress service exists
# Waits for all required pods to be running before finishing

set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"

echo "=== Updating packages ==="
sudo apt update && sudo apt upgrade -y

echo "=== Installing snapd if missing ==="
if ! command -v snap >/dev/null 2>&1; then
    sudo apt install -y snapd
fi

echo "=== Installing MicroK8s if missing ==="
if ! snap list | grep -q microk8s; then
    sudo snap install microk8s --classic
fi

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q "\bmicrok8s\b"; then
    echo "Adding $USER_NAME to microk8s group..."
    sudo usermod -a -G microk8s $USER_NAME
    mkdir -p ~/.kube
    sudo chown -R $USER_NAME ~/.kube
    echo "Reloading group membership..."
    exec sg microk8s "$0 $@"
    exit
fi

echo "=== Waiting for MicroK8s to be ready ==="
sudo microk8s status --wait-ready >/dev/null
echo "MicroK8s is ready."

echo "=== Setting up ~/.kube/config ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config
sudo chown -R $USER_NAME ~/.kube
chmod 600 ~/.kube/config

echo "=== Setting up kubectl alias ==="
if ! grep -q 'alias kubectl="microk8s kubectl"' ~/.bashrc; then
    echo 'alias kubectl="microk8s kubectl"' >> ~/.bashrc
fi
alias kubectl="$MICROK8S_KUBECTL"

echo "=== Creating system-wide kubectl symlink ==="
if [ ! -f /usr/local/bin/kubectl ]; then
    sudo ln -s /snap/bin/microk8s.kubectl /usr/local/bin/kubectl
fi

echo "=== Enabling MicroK8s addons ==="
ADDONS=(dns dashboard ingress metrics-server storage hostpath-storage)
for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

# Ensure Nginx ingress service exists
echo "=== Ensuring Nginx Ingress service exists ==="
INGRESS_NS="ingress"
SERVICE_NAME="nginx-ingress-microk8s-controller"

if ! $MICROK8S_KUBECTL -n $INGRESS_NS get svc $SERVICE_NAME >/dev/null 2>&1; then
    echo "Ingress service missing. Creating $SERVICE_NAME..."
    cat <<EOF | $MICROK8S_KUBECTL -n $INGRESS_NS apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $INGRESS_NS
spec:
  type: NodePort
  selector:
    app: nginx-ingress-microk8s
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
    - name: https
      protocol: TCP
      port: 443
      targetPort: 443
EOF
fi

echo "=== Waiting for all required pods to be ready ==="
REQUIRED_NS=("kube-system" "ingress")
for ns in "${REQUIRED_NS[@]}"; do
    PODS=$($MICROK8S_KUBECTL -n $ns get pods -o jsonpath='{.items[*].metadata.name}')
    for pod in $PODS; do
        echo -n "Waiting for pod $pod in namespace $ns..."
        until [[ "$($MICROK8S_KUBECTL -n $ns get pod $pod -o jsonpath='{.status.phase}')" == "Running" ]]; do
            echo -n "."
            sleep 5
        done
        echo " Ready!"
    done
done

# Dashboard namespace
DASHBOARD_NS="kube-system"
echo "Dashboard namespace detected: $DASHBOARD_NS"

echo "=== Creating admin-user for Dashboard ==="
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: $DASHBOARD_NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: $DASHBOARD_NS
EOF

echo "=== Waiting for admin-user token to be ready ==="
TOKEN=""
for i in {1..12}; do
    SECRET_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret | grep admin-user | awk '{print $1}' || true)
    if [ -n "$SECRET_NAME" ]; then
        TOKEN=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get secret $SECRET_NAME -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode || true)
        if [ -n "$TOKEN" ]; then
            break
        fi
    fi
    echo "Waiting for admin-user token... attempt $i/12"
    sleep 5
done

if [ -z "$TOKEN" ]; then
    TOKEN="<token not available yet>"
fi

echo "=== Creating Dashboard Ingress ==="
$MICROK8S_KUBECTL apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: $DASHBOARD_NS
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - host: dashboard.local
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

# Add entry to /etc/hosts
NODE_IP=$(hostname -I | awk '{print $1}')
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
fi

echo ""
echo "=============================================="
echo " MicroK8s Setup Complete"
echo "----------------------------------------------"
echo "kubectl is ready. Test with:"
echo "    kubectl get nodes"
echo ""
echo "Kubernetes Dashboard URL via Ingress:"
echo "    https://dashboard.local"
echo ""
echo "Dashboard Admin Token:"
echo "    $TOKEN"
echo "=============================================="
