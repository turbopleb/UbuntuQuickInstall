#!/bin/bash
set -e

echo "[+] Updating system..."
sudo apt update -y

echo "[+] Installing required packages..."
sudo apt install -y curl

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
microk8s enable metrics-server
microk8s enable dashboard
microk8s enable ingress

echo "[+] Creating admin service account + RBAC..."
microk8s kubectl create serviceaccount admin-user -n kube-system || true
microk8s kubectl create clusterrolebinding admin-user-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:admin-user || true

echo "[+] Setting Kubernetes Dashboard Service to ClusterIP for Ingress access..."
microk8s kubectl -n kube-system patch svc kubernetes-dashboard -p '{"spec":{"type":"ClusterIP"}}'

# Optional: create a dashboard Ingress for future hostname access
microk8s kubectl -n kube-system apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: kube-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: k8s.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
YAML

echo "[+] Retrieving admin token..."
ADMIN_SECRET=$(microk8s kubectl -n kube-system get secret | grep admin-user-token | awk '{print $1}')
ADMIN_TOKEN=$(microk8s kubectl -n kube-system describe secret $ADMIN_SECRET | grep "token:" | awk '{print $2}')

# Save token to file in user home
TOKEN_FILE="/home/$USER/k8stoken.txt"
echo "$ADMIN_TOKEN" > "$TOKEN_FILE"
chown $USER:$USER "$TOKEN_FILE"

echo "==========================================="
echo " MicroK8s + Dashboard Installation Complete"
echo "==========================================="
echo "Dashboard URL via Ingress (once k8s.local is in hosts file): https://k8s.local/"
echo ""
echo "Admin Token (also saved to $TOKEN_FILE):"
echo "$ADMIN_TOKEN"
echo ""
echo "==========================================="

echo ""
echo "[!] NOTE: Your user has been permanently added to the 'microk8s' group."
echo "[!] If you open a new terminal or run 'newgrp microk8s', your session will be updated"
echo "[!] but the admin token displayed here will not persist. Save it now!"

# -------- Dashboard readiness check --------
echo "[+] Waiting for the Kubernetes Dashboard to become ready..."
until microk8s kubectl -n kube-system get pods -l k8s-app=kubernetes-dashboard | grep Running >/dev/null; do
    echo -n "."
    sleep 2
done
echo ""
echo "[+] Dashboard is ready at: https://k8s.local/"
EOF
