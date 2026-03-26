#!/usr/bin/env bash
# =============================================================================
# Redis HA on Kubernetes — Full Deployment Runbook
# Tested with: Minikube 1.32+, kubectl 1.28+, Helm 3.14+
# =============================================================================
set -euo pipefail

NAMESPACE="redis-ha"
RELEASE="redis-ha"
CHART_VERSION="19.6.4"   # pin for reproducibility

# ─── 0. Prerequisites check ──────────────────────────────────────────────────
check_prerequisites() {
  echo "==> Checking prerequisites..."
  for tool in kubectl helm minikube; do
    command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found"; exit 1; }
  done
  echo "    kubectl  : $(kubectl version --client --short 2>/dev/null | head -1)"
  echo "    helm     : $(helm version --short)"
}

# ─── 1. Start Minikube (skip if using a real cluster) ────────────────────────
start_minikube() {
  echo "==> Starting Minikube (3 nodes for anti-affinity)..."
  minikube start --nodes=3 --cpus=2 --memory=2048 --driver=docker
  minikube addons enable metrics-server
  # Label nodes so anti-affinity spreads pods
  for i in 1 2; do
    kubectl label node "minikube-m0$((i+1))" node-role.kubernetes.io/worker=worker --overwrite
  done
}

# ─── 2. Namespace + Secret ───────────────────────────────────────────────────
setup_namespace() {
  echo "==> Creating namespace and secret..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f secret.yaml
}

# ─── 3. Helm repo + install ──────────────────────────────────────────────────
deploy_redis() {
  echo "==> Adding Bitnami Helm repo..."
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo update

  echo "==> Deploying Redis HA (Sentinel mode)..."
  helm upgrade --install "$RELEASE" bitnami/redis \
    --namespace "$NAMESPACE" \
    --version "$CHART_VERSION" \
    --values values.yaml \
    --wait \
    --timeout 5m

  echo "==> Deployment complete. Pods:"
  kubectl get pods -n "$NAMESPACE" -o wide
}

# ─── 4. Verify cluster health ────────────────────────────────────────────────
verify_health() {
  echo "==> Verifying Redis health..."
  MASTER_POD=$(kubectl get pods -n "$NAMESPACE" -l redis-role=master -o jsonpath='{.items[0].metadata.name}')
  REDIS_PASS=$(kubectl get secret redis-secret -n "$NAMESPACE" -o jsonpath='{.data.redis-password}' | base64 -d)

  echo "    Master pod: $MASTER_POD"

  # Check replication info
  kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
    redis-cli -a "$REDIS_PASS" INFO replication | grep -E "role:|connected_slaves:"

  # Check sentinel
  kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c sentinel -- \
    redis-cli -p 26379 SENTINEL masters | grep -E "name|flags|num-slaves"
}

# ─── 5. Basic write/read test ────────────────────────────────────────────────
test_write_read() {
  echo "==> Running write/read test..."
  kubectl apply -f redis-client.yaml
  kubectl wait --for=condition=Ready pod/redis-client -n "$NAMESPACE" --timeout=60s

  REDIS_PASS=$(kubectl get secret redis-secret -n "$NAMESPACE" -o jsonpath='{.data.redis-password}' | base64 -d)
  SENTINEL_SVC="${RELEASE}-node-0.${RELEASE}-headless.${NAMESPACE}.svc.cluster.local"

  # Discover master via sentinel
  MASTER_HOST=$(kubectl exec -n "$NAMESPACE" redis-client -- \
    redis-cli -h "$SENTINEL_SVC" -p 26379 SENTINEL get-master-addr-by-name mymaster | head -1)

  echo "    Current master: $MASTER_HOST"

  kubectl exec -n "$NAMESPACE" redis-client -- \
    redis-cli -h "$MASTER_HOST" -a "$REDIS_PASS" SET testkey "hello-redis-ha"

  VAL=$(kubectl exec -n "$NAMESPACE" redis-client -- \
    redis-cli -h "$MASTER_HOST" -a "$REDIS_PASS" GET testkey)

  echo "    GET testkey = $VAL"
  [[ "$VAL" == *"hello-redis-ha"* ]] && echo "    PASSED" || echo "    FAILED"
}

# ─── 6. Failover demonstration ───────────────────────────────────────────────
demo_failover() {
  echo ""
  echo "==> Failover Demonstration"
  echo "    Step 1: Write a key to master"

  REDIS_PASS=$(kubectl get secret redis-secret -n "$NAMESPACE" -o jsonpath='{.data.redis-password}' | base64 -d)
  MASTER_POD=$(kubectl get pods -n "$NAMESPACE" -l redis-role=master -o jsonpath='{.items[0].metadata.name}')

  kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
    redis-cli -a "$REDIS_PASS" SET pre-failover-key "written-before-failover"

  echo "    Step 2: Killing master pod: $MASTER_POD"
  kubectl delete pod -n "$NAMESPACE" "$MASTER_POD"

  echo "    Step 3: Watching for new master (up to 30s)..."
  for i in $(seq 1 15); do
    sleep 2
    NEW_MASTER=$(kubectl get pods -n "$NAMESPACE" -l redis-role=master \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$NEW_MASTER" && "$NEW_MASTER" != "$MASTER_POD" ]]; then
      echo "    New master elected: $NEW_MASTER (after $((i*2))s)"
      break
    fi
    echo "    [$i] Waiting... current master pod: ${NEW_MASTER:-none}"
  done

  echo "    Step 4: Verify key survived failover"
  NEW_MASTER=$(kubectl get pods -n "$NAMESPACE" -l redis-role=master -o jsonpath='{.items[0].metadata.name}')
  VAL=$(kubectl exec -n "$NAMESPACE" "$NEW_MASTER" -c redis -- \
    redis-cli -a "$REDIS_PASS" GET pre-failover-key 2>/dev/null || echo "NOT FOUND")
  echo "    pre-failover-key = $VAL"

  echo "    Step 5: Final pod state:"
  kubectl get pods -n "$NAMESPACE" -o wide
}

# ─── 7. Deploy Prometheus rules (optional) ───────────────────────────────────
deploy_monitoring() {
  echo "==> Deploying Prometheus alert rules (requires Prometheus Operator)..."
  kubectl apply -f prometheus-rules.yaml || echo "    Skipped — Prometheus Operator not found"
}

# ─── 8. Teardown ─────────────────────────────────────────────────────────────
teardown() {
  echo "==> Tearing down..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
  kubectl delete namespace "$NAMESPACE" || true
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-deploy}" in
  prereq)    check_prerequisites ;;
  minikube)  start_minikube ;;
  deploy)
    check_prerequisites
    setup_namespace
    deploy_redis
    verify_health
    ;;
  test)      test_write_read ;;
  failover)  demo_failover ;;
  monitor)   deploy_monitoring ;;
  teardown)  teardown ;;
  all)
    check_prerequisites
    start_minikube
    setup_namespace
    deploy_redis
    verify_health
    test_write_read
    demo_failover
    ;;
  *)
    echo "Usage: $0 {prereq|minikube|deploy|test|failover|monitor|teardown|all}"
    exit 1
    ;;
esac
