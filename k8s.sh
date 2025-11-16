#!/usr/bin/env bash
set -e

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing MicroK8s..."
sudo snap install microk8s --classic

echo "[+] Adding user '$USER' to microk8s group..."
sudo usermod -aG microk8s "$USER"

echo "[+] Preparing kube directory..."
mkdir -p ~/.kube
sudo chown "$USER":"$USER" ~/.kube

echo "[+] Switching to newgrp 'microk8s' so no logout is required..."
# After this line, heredoc content runs inside the new group environment
newgrp microk8s << 'EOF'
set -e

echo "[group-shell] Enabling MicroK8s add-ons..."
sudo microk8s enable dns
sudo microk8s enable storage
sudo microk8s enable ingress
sudo microk8s enable metrics-server

echo "[group-shell] Waiting for MicroK8s to be ready..."
sudo microk8s status --wait-ready

echo "[group-shell] Enabling Kubernetes Dashboard..."
sudo microk8s enable dashboard

echo "[group-shell] Exporting kubeconfig..."
sudo microk8s kubectl config view --raw > ~/.kube/config
sudo chown "$USER":"$USER" ~/.kube/config

echo "[group-shell] Creating ingress for Kubernetes Dashboard..."
sudo microk8s kubectl apply -f - <<EOT
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

echo "[group-shell] Detecting node IP..."
NODE_IP=$(hostname -I | awk '{print $1}')

echo "[group-shell] Updating /etc/hosts..."
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts
fi

echo "[group-shell] Creating admin user for Dashboard..."
sudo microk8s kubectl apply -f - <<EOT
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kube-system
EOT

sudo microk8s kubectl apply -f - <<EOT
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

echo "[group-shell] Retrieving admin token..."
ADMIN_TOKEN=$(sudo microk8s kubectl -n kube-system create token admin-user)

echo ""
echo "============================================================"
echo " MicroK8s Installation Complete! 🎉"
echo ""
echo " 🌐 Dashboard: https://dashboard.local/"
echo ""
echo " 🔑 Admin Token:"
echo "$ADMIN_TOKEN"
echo "============================================================"

EOF
