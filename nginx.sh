#!/usr/bin/env bash
# install-nginx-microk8s.sh
# Installs Nginx on MicroK8s with always-enabled self-signed TLS.
# Idempotent and safe to run repeatedly.

set -euo pipefail

USER_NAME=$(whoami)
MK_KUBECTL="microk8s kubectl"
NAMESPACE="nginx"
HOSTNAME="${HOSTNAME:-nginx.local}"
TLS_SECRET_NAME="nginx-tls"
CERT_VALIDITY_DAYS=365
TMPDIR="$(mktemp -d)"
OPENSSL_CN="${HOSTNAME}"

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "=== Running as user: $USER_NAME ==="

# Ensure user is in microk8s group
if ! groups "$USER_NAME" | grep -q "\bmicrok8s\b"; then
    echo "Adding $USER_NAME to microk8s group..."
    sudo usermod -a -G microk8s "$USER_NAME"
    if [ -d "$HOME/.kube" ]; then
        sudo chown -R "$USER_NAME":"$USER_NAME" "$HOME/.kube"
    fi
    echo "Reloading shell with new group membership..."
    exec sg microk8s "$0 $*"
fi

echo "=== Waiting for MicroK8s to be ready ==="
microk8s status --wait-ready >/dev/null

# Auto-detect node IP
get_node_ip() {
    if ip route get 8.8.8.8 >/dev/null 2>&1; then
        NODE_IP=$(ip route get 8.8.8.8 | awk '/src/{print $NF; exit}')
    fi

    if [ -z "${NODE_IP:-}" ]; then
        NODE_IP=$(hostname -I | awk '{print $1}')
    fi

    if [ -z "${NODE_IP:-}" ] && command -v ifconfig >/dev/null 2>&1; then
        NODE_IP=$(ifconfig | awk '/inet / && $2!="127.0.0.1"{print $2; exit}')
    fi

    echo "${NODE_IP:-127.0.0.1}"
}

NODE_IP=$(get_node_ip)
echo "Detected node IP: $NODE_IP"

echo "=== Ensuring namespace exists ==="
$MK_KUBECTL get namespace "$NAMESPACE" >/dev/null 2>&1 || \
    $MK_KUBECTL create namespace "$NAMESPACE"

echo "=== Applying Nginx Deployment ==="
$MK_KUBECTL apply -n "$NAMESPACE" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 80
EOF

echo "=== Applying Service ==="
$MK_KUBECTL apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  namespace: ${NAMESPACE}
spec:
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
EOF

echo "=== Generating self-signed TLS certificate ==="
CRT_PATH="$TMPDIR/tls.crt"
KEY_PATH="$TMPDIR/tls.key"

SAN_FILE="$TMPDIR/san.cnf"
cat > "$SAN_FILE" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${OPENSSL_CN}

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${HOSTNAME}
IP.1 = ${NODE_IP}
EOF

openssl req -x509 -nodes -days "$CERT_VALIDITY_DAYS" \
    -newkey rsa:2048 \
    -keyout "$KEY_PATH" \
    -out "$CRT_PATH" \
    -config "$SAN_FILE" >/dev/null 2>&1

echo "=== Creating TLS Secret ==="
$MK_KUBECTL -n "$NAMESPACE" create secret tls "$TLS_SECRET_NAME" \
    --cert="$CRT_PATH" --key="$KEY_PATH" \
    --dry-run=client -o yaml | $MK_KUBECTL apply -f -

echo "=== Applying Ingress with TLS enabled ==="
$MK_KUBECTL apply -n "$NAMESPACE" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: ${NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - ${HOSTNAME}
    secretName: ${TLS_SECRET_NAME}
  rules:
  - host: ${HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-service
            port:
              number: 80
EOF

echo "=== Waiting for Deployment rollout ==="
$MK_KUBECTL -n "$NAMESPACE" rollout status deployment/nginx --timeout=120s || true

echo "=== Checking for Ingress controller (best effort) ==="
if $MK_KUBECTL get pods -n ingress >/dev/null 2>&1 || \
   $MK_KUBECTL get pods -n kube-system -l app.kubernetes.io/name=ingress-nginx >/dev/null 2>&1; then
    echo "Ingress controller appears installed."
else
    echo "⚠️ Ingress controller not detected."
    echo "Install it (if not installed):   microk8s enable ingress"
fi

echo "=== Updating /etc/hosts ==="
if sudo grep -qE "^[^#]*\b${HOSTNAME}\b" /etc/hosts; then
    echo "Updating existing /etc/hosts entry..."
    sudo awk -v ip="$NODE_IP" -v host="$HOSTNAME" '
    BEGIN{OFS=FS}
    {
      if($0 ~ host){ next } else { print $0 }
    }
    END{ print ip " " host }
    ' /etc/hosts > "/tmp/hosts.new" && sudo mv /tmp/hosts.new /etc/hosts
else
    echo "Adding new hosts entry: $NODE_IP $HOSTNAME"
    echo "$NODE_IP $HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
fi

echo ""
echo "=== DONE ==="
echo "Nginx is available at:"
echo "   https://${HOSTNAME}"
echo ""
echo "This uses a self-signed TLS certificate, so browsers will show a warning."
