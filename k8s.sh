#!/usr/bin/env bash
set -e

USER_NAME=$(whoami)

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing MicroK8s..."
sudo snap install microk8s --classic

echo "[+] Permanently adding $USER_NAME to the microk8s group..."
sudo usermod -aG microk8s $USER_NAME

echo "[+] Preparing kube directory..."
mkdir -p /home/$USER_NAME/.kube
sudo chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.kube

echo "[+] Activating microk8s permissions in the current shell..."
# Use sg to temporarily run a shell with correct group membership
sg microk8s bash <<'EOGROUP'
set -e

echo "[+] Enabling MicroK8s add-ons..."
microk8s enable dns
microk8s enable hostpath-storage
microk8s enable ingress
microk8s enable metrics-server

echo "[+] Waiting for MicroK8s to be ready..."
microk8s status --wait-ready

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
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$NODE_IP dashboard.local" | sudo tee -a /etc/hosts > /dev/null
fi

echo "[+] Waiting a few seconds for admin secret creation..."
sleep 5

echo "[+] Retrieving admin token..."
ADMIN_SECRET=$(microk8s kubectl -n kube-system get secret | grep admin-user-token | awk '{print $1}')
ADMIN_TOKEN=$(microk8s kubectl -n kube-system describe secret $ADMIN_SECRET | grep "token:" | awk '{print $2}')

echo ""
echo "=================================================="
echo " MicroK8s + Dashboard Installation Complete! 🎉"
echo " Dashboard URL: https://dashboard.local/"
echo ""
echo " Admin Token (use this to login):"
echo "$ADMIN_TOKEN"
echo "=================================================="

# Export kubeconfig for the user
microk8s kubectl config view --raw > /home/$USER/.kube/config
chown $USER:$USER /home/$USER/.kube/config

EOGROUP

echo ""
echo "[+] Installation finished! You now have full MicroK8s access without logout."
