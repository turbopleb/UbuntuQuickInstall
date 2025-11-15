#!/bin/bash

# Full MicroK8s Setup Script for Ubuntu
# Includes kubectl alias, all core addons, dashboard external access

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
    sudo chown -R $USER_NAME ~/.kube
    echo "Reloading group membership..."
    exec sg microk8s "$0 $@"
    exit
fi

echo "=== Ensuring MicroK8s is ready ==="
sudo microk8s status --wait-ready >/dev/null
echo "MicroK8s is ready."

echo "=== Setting up kubectl alias ==="
# Add alias for interactive shells
if ! grep -q 'alias kubectl="microk8s kubectl"' ~/.bashrc; then
    echo 'alias kubectl="microk8s kubectl"' >> ~/.bashrc
fi
# Also set temporary alias for this script/session
alias kubectl="$MICROK8S_KUBECTL"

echo "=== Enabling MicroK8s addons ==="
ADDONS=(dns dashboard ingress metrics-server storage hostpath-storage)
for addon in "${ADDONS[@]}"; do
    echo "--- Enabling $addon ---"
    sudo microk8s enable $addon
done

echo "=== Making Kubernetes Dashboard externally accessible ==="
DASHBOARD_NS="kubernetes-dashboard"
SERVICE_NAME=$($MICROK8S_KUBECTL -n $DASHBOARD_NS get svc -o jsonpath='{.items[0].metadata.name}')

if [ -n "$SERVICE_NAME" ]; then
    echo "Patching Dashboard service $SERVICE_NAME to NodePort..."
    $MICROK8S_KUBECTL -n $DASHBOARD_NS patch service $SERVICE_NAME -p '{"spec": {"type": "NodePort"}}'
    echo "Dashboard service patched successfully."
else
    echo "Warning: Kubernetes Dashboard service not found in $DASHBOARD_NS namespace."
    echo "You may need to wait a few minutes for the dashboard pod to be fully deployed."
fi

echo ""
echo "=== MANUAL STEPS / NOTES ==="
echo "1. MicroK8s is installed and ready."
echo "2. Use 'kubectl' (alias for 'microk8s kubectl') for all commands."
echo "3. Dashboard is exposed externally via NodePort. You can get the port with:"
echo "   kubectl -n kubernetes-dashboard get service"
echo "4. To access dashboard, generate token:"
echo "   kubectl -n kubernetes-dashboard get secret | grep admin-user"
echo "   kubectl -n kubernetes-dashboard describe secret <secret-name>"
echo "5. If you add a new user to MicroK8s, run:"
echo "   sudo usermod -a -G microk8s <username>"
echo "   sudo chown -R <username> ~/.kube"
echo "   newgrp microk8s (or log out/in)"
