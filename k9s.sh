#!/bin/bash
set -e  # Exit on any error

# --- Step 0: Prerequisites ---
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

# --- Step 2: Ensure user is in microk8s group ---
echo "Adding user '$USER' to microk8s group..."
if groups $USER | grep &>/dev/null "\bmicrok8s\b"; then
    echo "User is already in microk8s group."
else
    sudo usermod -aG microk8s $USER
    echo "User added to microk8s group. Permissions will take effect after next login."
fi

# --- Step 3: Setup kubeconfig for MicroK8s ---
MICROK8S_CONFIG="/var/snap/microk8s/current/credentials/client.config"
echo "Setting up kubeconfig..."
mkdir -p ~/.kube
if [ -f "$MICROK8S_CONFIG" ]; then
    cp "$MICROK8S_CONFIG" ~/.kube/config
    chmod 600 ~/.kube/config
    echo "MicroK8s kubeconfig copied to ~/.kube/config."
else
    echo "Warning: MicroK8s config not found at $MICROK8S_CONFIG"
    echo "k9s may not detect clusters until MicroK8s is installed and running."
fi

# --- Step 4: Add alias 'k' for k9s permanently ---
ALIAS_LINE="alias k='k9s'"
SHELL_RC="$HOME/.bashrc"
grep -qxF "$ALIAS_LINE" "$SHELL_RC" || echo "$ALIAS_LINE" >> "$SHELL_RC"

# Make alias available immediately in current shell
alias k='k9s'

# --- Step 5: Done ---
echo
echo "Setup complete!"
echo "k9s is installed, and the alias 'k' has been added to your shell."
echo
echo "Important:"
echo "  - To use 'k' in this terminal immediately, run:  source ~/.bashrc"
echo "  - MicroK8s will be detected by k9s only after you log out and log back in"
echo "    (or reconnect via SSH), because new group permissions take effect at login."
echo "  - After relogging, you can run 'k9s' or simply 'k' to manage your MicroK8s cluster."
