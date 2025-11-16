#!/usr/bin/env bash
set -e

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing MicroK8s..."
sudo snap install microk8s --classic

echo "[+] Adding user '$USER' to required groups..."
sudo usermod -aG microk8s $USER
sudo usermod -aG snap_microk8s $USER || true

echo "[+] Preparing kube directory..."
mkdir -p ~/.kube
sudo chown -R "$USER":"$USER" ~/.kube

echo "[+] Reloading group membership so no logout is needed..."
# Everything after this runs in a new shell with new groups
newgrp microk8s << 'EOF'
set -e

echo "[+] Enabling MicroK8s add-ons: dns, storage, ingress, metrics-server..."
microk8s enable dns storage ingress metrics-server

echo "[+] Waiting for MicroK8s to be ready..."
microk8s status --wait-ready

echo "[+] Deploying Kubernetes Dashboard..."
microk8s enable dashboard

echo "[+] Exporting kubeconfig..."
microk8s kubectl config view --raw > ~/.kube/config

echo "[+] Creating ingress for Kubernetes Dashboard..."
cat <<EOT | microk8s kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: kube-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
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
EOT

echo "[+] Detecting node IP..."
NODE_IP=$(hostname -I | awk '{print $1}')

echo "[+] Updating /etc/hosts with dashboard.local..."
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
fi

echo "[+] Creating admin user for Dashboard..."
microk8s kubectl apply -f - <<EOT
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kube-system
EOT

microk8s kubectl apply -f - <<EOT
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kube-system
EOT

echo "[+] Retrieving admin token..."
ADMIN_TOKEN=$(microk8s kubectl -n kube-system create token admin-user)

echo ""
echo "============================================================"
echo " MicroK8s full setup complete! 🎉"
echo ""
echo " 🔑 Admin token:"
echo "$ADMIN_TOKEN"
echo ""
echo " Dashboard URL: https://dashboard.local/"
echo ""
echo "============================================================"

EOF
