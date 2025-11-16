#!/bin/bash
set -euo pipefail

# === Install required system packages ===
echo "[+] Installing required packages..."
sudo apt update
sudo apt install -y curl tar jq openssl ca-certificates gnupg apt-transport-https

# === Install kubectl via snap if missing ===
if ! command -v kubectl &> /dev/null; then
    echo "[+] Installing kubectl via snap..."
    sudo snap install kubectl --classic
fi

# === Install K9s if missing ===
if ! command -v k9s &> /dev/null; then
    echo "[+] Installing K9s..."
    K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -LO https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz
    tar xvf k9s_Linux_amd64.tar.gz
    sudo mv k9s /usr/local/bin/
    rm k9s_Linux_amd64.tar.gz
fi

# === Ensure user is in microk8s group ===
echo "[+] Ensuring user is in microk8s group..."
sudo usermod -aG microk8s "$USER"
sudo chown -R "$USER" ~/.kube || true

# === Define 'k' function for immediate use ===
echo "[+] Creating 'k' function for microk8s kubectl..."
k() { microk8s kubectl "$@"; }
export -f k
echo "[+] Use 'k' in this shell to run kubectl commands, or 'k9s' to launch K9s."

# === Determine external node IP ===
DASHBOARD_IP=$(ip route get 1 | awk '{print $7; exit}')

# === Wait for dashboard NodePort to be ready ===
echo "[+] Checking if Kubernetes Dashboard NodePort is ready..."
until NODEPORT=$(microk8s kubectl -n kube-system get svc kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null) && [ -n "$NODEPORT" ]; do
    echo -n "."
    sleep 2
done
echo ""
echo "[+] Kubernetes Dashboard is available at NodePort: https://${DASHBOARD_IP}:${NODEPORT}/"

# === Wait until dashboard responds on correct NodeIP:NodePort ===
echo "[+] Waiting for Kubernetes Dashboard to respond..."
until curl -k -s "https://${DASHBOARD_IP}:${NODEPORT}/" > /dev/null; do
    echo -n "."
    sleep 2
done
echo ""
echo "[+] Dashboard is ready!"

# === Inform about admin token ===
TOKEN_FILE="$HOME/k8stoken.txt"
if [ -f "$TOKEN_FILE" ]; then
    echo "[+] Admin token is already saved in $TOKEN_FILE"
else
    echo "[!] Admin token not found in $TOKEN_FILE."
    echo "[!] Please retrieve it using your k8s.sh installation output."
fi

echo ""
echo "[+] K9s & MicroK8s Dashboard setup complete!"
echo "Dashboard NodePort URL: https://${DASHBOARD_IP}:${NODEPORT}/"
echo "Launch K9s now with: k9s"
