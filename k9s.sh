#!/bin/bash
set -e  # Exit immediately if a command fails

# --- Step 0: Check prerequisites ---
echo "Checking prerequisites..."

command -v wget >/dev/null 2>&1 || { echo "Error: wget is not installed. Please install it first."; exit 1; }
command -v apt >/dev/null 2>&1 || { echo "Error: apt is not available. Are you on Ubuntu/Debian?"; exit 1; }

# --- Step 1: Download and install k9s ---
echo "Downloading and installing k9s..."
wget -q https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.deb -O k9s_linux_amd64.deb
sudo apt update
sudo apt install -y ./k9s_linux_amd64.deb
rm k9s_linux_amd64.deb
echo "k9s installed successfully."

# --- Step 2: Setup kubeconfig for MicroK8s ---
echo "Setting up kubeconfig for MicroK8s..."
mkdir -p ~/.kube

MICROK8S_CONFIG="/var/snap/microk8s/current/credentials/client.config"
if [ -f "$MICROK8S_CONFIG" ]; then
    sudo cp "$MICROK8S_CONFIG" ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    chmod 600 ~/.kube/config
    echo "MicroK8s kubeconfig copied to ~/.kube/config."
else
    echo "Warning: MicroK8s kubeconfig not found at $MICROK8S_CONFIG"
    echo "k9s may not detect clusters until MicroK8s is installed and running."
fi

# --- Step 3: Add alias 'k' for k9s permanently ---
ALIAS_LINE="alias k='k9s'"
SHELL_RC="$HOME/.bashrc"

# Avoid duplicate alias
grep -qxF "$ALIAS_LINE" "$SHELL_RC" || echo "$ALIAS_LINE" >> "$SHELL_RC"

# Make alias available immediately
eval "$ALIAS_LINE"
echo "Alias 'k' set for k9s (works in this terminal and future ones)."

# --- Step 4: Done ---
echo "Setup complete! You can now run 'k9s' or simply 'k'."
