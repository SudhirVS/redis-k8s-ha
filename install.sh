#!/usr/bin/env bash
# =============================================================================
# Bootstrap script — Ubuntu 22.04 amd64
# Installs: kubectl, helm, k3s (single-node Kubernetes)
# Run as: bash install.sh
# =============================================================================
set -euo pipefail

echo "==> Updating apt..."
sudo apt-get update -y
sudo apt-get install -y curl wget git apt-transport-https ca-certificates

# ─── 1. kubectl ──────────────────────────────────────────────────────────────
echo "==> Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client

# ─── 2. Helm ─────────────────────────────────────────────────────────────────
echo "==> Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version --short

# ─── 3. k3s (lightweight single-node Kubernetes) ─────────────────────────────
echo "==> Installing k3s..."
curl -sfL https://get.k3s.io | sh -

# Wait for k3s to be ready
echo "==> Waiting for k3s node to be Ready..."
sleep 10
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=60s

# Make kubeconfig accessible to current user (no sudo needed for kubectl)
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER":"$USER" ~/.kube/config
chmod 600 ~/.kube/config

echo "==> Verifying cluster..."
kubectl get nodes

echo ""
echo "======================================"
echo " All tools installed successfully"
echo " kubectl  : $(kubectl version --client --short 2>/dev/null)"
echo " helm     : $(helm version --short)"
echo " k3s      : $(k3s --version | head -1)"
echo "======================================"
echo ""
echo "Next step: cd into your project folder and run the Redis deployment."
