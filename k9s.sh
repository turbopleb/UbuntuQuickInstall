#!/bin/bash
set -euo pipefail

# ==============================
# K9s + MicroK8s Dashboard Setup
# ==============================

USER_NAME=$(whoami)

echo "[+] Installing required packages..."
sudo apt update -y
sudo apt install -y curl tar jq openssl ca-certificates gnupg apt-transport-https

# ------------------------------
# Ensure kubectl is installed
# ------------------------------
if ! command -v kubectl &>/dev/null; then
    echo "[+] Installing kubectl via snap..."
    sudo snap install kubectl --classic
fi

# ------------------------------
# Install K9s if missing
# ------------------------------
if ! command -v k9s &>/dev/null; then
    echo "[+] Installing K9s..."
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -LO "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
    tar xvf k9s_Linux_amd64.tar.gz
    sudo mv k9s /usr/local/bin/
    rm k9s_Linux_amd64.tar.gz
fi

# ------------------------------
# Set KUBECONFIG for user
# ------------------------------
echo "[+] Configuring kubeconfig for user..."
mkdir -p $HOME/.kube
microk8s config > $HOME/.kube/config
chown $USER_NAME:$USER_NAME $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config

# ------------------------------
# Ensure user in microk8s group
# ------------------------------
sudo usermod -aG microk8s $USER_NAME
sudo chown -R $USER_NAME $HOME/.kube || true

# ------------------------------
# Expose Kubernetes Dashboard via NodePort
# ------------------------------
echo "[+] Exposing Kubernetes Dashboard as NodePort..."
microk8s kubectl -n kube-system patch svc kubernetes-dashboard -p '{"spec": {"type": "NodePort"}}'

# Wait for NodePort assignment
sleep 3

# ------------------------------
# Detect NodePort and Node IP
# ------------------------------
NODE_PORT=$(microk8s kubectl -n kube-system get svc kubernetes-dashboard \
            -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(microk8s kubectl -n kube-system get endpoints kubernetes-dashboard \
          -o jsonpath='{.subsets[0].addresses[0].ip}')

echo "[+] Kubernetes Dashboard NodePort: https://${NODE_IP}:${NODE_PORT}"

# ------------------------------
# Wait for Dashboard readiness
# ------------------------------
echo "[+] Waiting for the Kubernetes Dashboard to become ready..."
until curl -k -s "https://${NODE_IP}:${NODE_PORT}/" > /dev/null; do
    echo -n "."
    sleep 2
done
echo ""
echo "[+] Dashboard is ready at: https://${NODE_IP}:${NODE_PORT}"

# ------------------------------
# Generate admin token
# ------------------------------
if ! microk8s kubectl -n kube-system get sa dashboard-admin &>/dev/null; then
    echo "[+] Creating dashboard-admin service account..."
    microk8s kubectl -n kube-system create sa dashboard-admin
    microk8s kubectl create clusterrolebinding dashboard-admin \
        --clusterrole=cluster-admin \
        --serviceaccount=kube-system:dashboard-admin
fi

ADMIN_SECRET=$(microk8s kubectl -n kube-system get sa dashboard-admin -o jsonpath='{.secrets[0].name}')
ADMIN_TOKEN=$(microk8s kubectl -n kube-system describe secret $ADMIN_SECRET | grep '^token:' | awk '{print $2}')

TOKEN_FILE="$HOME/k8stoken.txt"
echo "$ADMIN_TOKEN" > "$TOKEN_FILE"
chown $USER_NAME:$USER_NAME "$TOKEN_FILE"

# ------------------------------
# Print final instructions
# ------------------------------
echo "==========================================="
echo " K9s + MicroK8s Dashboard Setup Complete"
echo "==========================================="
echo "Dashboard URL (NodePort): https://${NODE_IP}:${NODE_PORT}/"
echo ""
echo "Admin Token (saved to $TOKEN_FILE):"
echo "$ADMIN_TOKEN"
echo ""
echo "You can now run 'k9s' to manage your cluster."
echo "If using a new terminal, you may need to run 'newgrp microk8s' to update permissions."
echo "==========================================="

# ------------------------------
# Optional: alias k for kubectl via microk8s
# ------------------------------
alias k='microk8s kubectl'
echo "[+] Alias 'k' for microk8s kubectl is now available in this shell."
