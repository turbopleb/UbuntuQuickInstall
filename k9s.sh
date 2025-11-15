#!/bin/bash
set -e

USER_NAME=$(whoami)
MICROK8S_KUBECTL="microk8s kubectl"
WAIT_TIMEOUT=300  # 5 minutes
SLEEP_INTERVAL=5  # seconds
DASHBOARD_NS="kube-system"
INGRESS_NS="ingress"

echo "=== Updating packages ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Installing required packages (curl, tar, jq, openssl) ==="
sudo apt install -y curl tar jq openssl

echo "=== Ensuring user is in microk8s group ==="
if ! groups $USER_NAME | grep -q '\bmicrok8s\b'; then
    echo "Adding user $USER_NAME to microk8s group..."
    sudo usermod -aG microk8s $USER_NAME
    echo "You need to log out and back in for group changes to take effect."
fi

echo "=== Verifying MicroK8s access ==="
if microk8s status --wait-ready >/dev/null 2>&1; then
    echo "MicroK8s is running"
else
    echo "MicroK8s is not running. Please start MicroK8s."
    exit 1
fi

echo "=== Detecting system architecture ==="
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    TARGET="amd64"
else
    TARGET="$ARCH"
fi
echo "Architecture detected: $ARCH → K9s target: $TARGET"

echo "=== Installing K9s if missing ==="
if ! command -v k9s >/dev/null 2>&1; then
    echo "Downloading latest K9s..."
    LATEST=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')
    curl -L https://github.com/derailed/k9s/releases/download/${LATEST}/k9s_Linux_${TARGET}.tar.gz -o /tmp/k9s.tar.gz
    tar -xzf /tmp/k9s.tar.gz -C /tmp
    sudo mv /tmp/k9s /usr/local/bin/
else
    echo "K9s already installed at $(which k9s)"
fi

echo "=== Adding alias 'k' for K9s (if missing) ==="
if ! grep -q "alias k=" ~/.bashrc; then
    echo "alias k='k9s'" >> ~/.bashrc
fi

echo "=== Setting up kubeconfig for MicroK8s ==="
mkdir -p ~/.kube
microk8s config > ~/.kube/config

echo "=== Enabling MicroK8s ingress ==="
microk8s enable ingress

echo "=== Fixing Kubernetes Dashboard Ingress ==="
# Delete old ingress if exists
microk8s kubectl -n $DASHBOARD_NS delete ingress kubernetes-dashboard-ingress --ignore-not-found

# Create TLS secret if missing
if ! microk8s kubectl -n $DASHBOARD_NS get secret dashboard-tls >/dev/null 2>&1; then
    microk8s kubectl -n $DASHBOARD_NS create secret tls dashboard-tls \
        --cert=/var/snap/microk8s/current/certs/server.crt \
        --key=/var/snap/microk8s/current/certs/server.key
fi

# Apply ingress YAML
cat <<EOF | microk8s kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kubernetes-dashboard-ingress
  namespace: $DASHBOARD_NS
  annotations:
    kubernetes.io/ingress.class: "public"
spec:
  tls:
  - hosts:
    - dashboard.local
    secretName: dashboard-tls
  rules:
  - host: dashboard.local
    http:
      paths:
      - pathType: Prefix
        path: /
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
EOF

echo "=== Adding /etc/hosts entry for dashboard.local ==="
NODE_IP=$(hostname -I | awk '{print $1}')
HOST_ENTRY="$NODE_IP dashboard.local"
if ! grep -q "dashboard.local" /etc/hosts; then
    echo "$HOST_ENTRY" | sudo tee -a /etc/hosts > /dev/null
    echo "/etc/hosts updated: $HOST_ENTRY"
else
    echo "/etc/hosts already has an entry for dashboard.local"
fi

echo "=== Waiting for ingress controller and dashboard pods to be Running ==="
END=$((SECONDS+WAIT_TIMEOUT))

wait_for_pods() {
    local ns=$1
    echo "Waiting for pods in namespace: $ns"
    while [ $SECONDS -lt $END ]; do
        NOT_READY=$($MICROK8S_KUBECTL -n $ns get pods --no-headers 2>/dev/null | awk '{if($3!="Running" && $3!="Completed") print $1}' || true)
        if [ -z "$NOT_READY" ]; then
            echo "All pods in $ns are Running"
            break
        else
            echo "Waiting for pods to be ready in $ns: $NOT_READY"
            sleep $SLEEP_INTERVAL
        fi
    done

    if [ $SECONDS -ge $END ]; then
        echo "Timeout waiting for pods in $ns. Some pods are not ready:"
        $MICROK8S_KUBECTL -n $ns get pods
    fi
}

# Check both namespaces
wait_for_pods $DASHBOARD_NS
wait_for_pods $INGRESS_NS

echo "=== Testing dashboard.local URL ==="
DASHBOARD_UP=false
for i in $(seq 1 $((WAIT_TIMEOUT / SLEEP_INTERVAL))); do
    if curl -k -s -o /dev/null -w "%{http_code}" https://dashboard.local | grep -q "200"; then
        DASHBOARD_UP=true
        echo "Dashboard is reachable at https://dashboard.local"
        break
    else
        echo "Waiting for dashboard.local to respond..."
        sleep $SLEEP_INTERVAL
    fi
done

if [ "$DASHBOARD_UP" = false ]; then
    echo "WARNING: Dashboard URL is not responding after $WAIT_TIMEOUT seconds."
fi

echo "=== K9s Installation & Dashboard Ingress Fix Complete ==="
echo "Run 'k' or 'k9s' to launch K9s."
echo "Dashboard URL: https://dashboard.local"
echo "MicroK8s kubeconfig is ready."
