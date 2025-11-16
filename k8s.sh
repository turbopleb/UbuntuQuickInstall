#!/bin/bash
set -e

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing MicroK8s..."
sudo snap install microk8s --classic

USER_NAME=$(whoami)

echo "[+] Adding user '$USER_NAME' to microk8s group..."
sudo usermod -aG microk8s "$USER_NAME"

echo "[+] Preparing kube directory..."
sudo mkdir -p /home/$USER_NAME/.kube
sudo chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.kube

echo "[+] Switching to newgrp 'microk8s' so no logout is required..."
newgrp microk8s <<'EOF'

echo "[+] Enabling MicroK8s add-ons..."
microk8s enable dns
microk8s enable hostpath-storage
microk8s enable ingress
microk8s enable metrics-server

echo "[+] Enabling Kubernetes Dashboard..."
microk8s enable dashboard

echo "[+] Creating admin service account + RBAC..."
microk8s kubectl create serviceaccount admin-user -n kube-system || true
microk8s kubectl create clusterrolebinding admin-user-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:admin-user || true

echo "[+] Creating Dashboard Ingress..."
cat <<ING | microk8s kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: public
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
ING

echo "[+] Updating /etc/hosts..."
NODE_IP=$(hostname -I | awk '{print $1}')
echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts > /dev/null

echo "[+] Waiting for admin token to be created..."
sleep 5

echo "[+] Retrieving admin token..."
ADMIN_SECRET=$(microk8s kubectl -n kube-system get secret | grep admin-user-token | awk '{print $1}')
ADMIN_TOKEN=$(microk8s kubectl -n kube-system describe secret $ADMIN_SECRET | grep "token:" | awk '{print $2}')

echo "==========================================="
echo " MicroK8s + Dashboard Installation Complete"
echo "==========================================="
echo "Dashboard URL: https://dashboard.local/"
echo ""
echo "Admin Token:"
echo "$ADMIN_TOKEN"
echo ""
echo "==========================================="

echo ""
echo "[!] NOTE: Your user has been permanently added to the 'microk8s' group."
echo "[!] If you open a new terminal or run 'newgrp microk8s', your session will be updated"
echo "[!] but the admin token displayed here will not persist. Save it now!"

EOF
