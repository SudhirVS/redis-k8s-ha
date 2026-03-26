# Redis HA on Kubernetes

Sentinel-based Redis HA deployment using Bitnami Helm chart.
3 Redis nodes (1 master + 2 replicas) + 3 Sentinel processes, AOF persistence, PVCs, and automatic failover.

---

## Prerequisites

| Tool | Min Version | Install |
|------|-------------|---------|
| kubectl | 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| helm | 3.14 | https://helm.sh/docs/intro/install/ |
| minikube | 1.32 | https://minikube.sigs.k8s.io/docs/start/ |

StorageClass `standard` is used (Minikube default). For EKS use `gp2`, for GKE use `standard-rwo`.

---

## Quick Start

```bash
# 1. Start 3-node Minikube cluster
minikube start --nodes=3 --cpus=2 --memory=2048 --driver=docker

# 2. Create namespace + secret
kubectl create namespace redis-ha
kubectl apply -f secret.yaml

# 3. Add Bitnami repo and deploy
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm upgrade --install redis-ha bitnami/redis \
  --namespace redis-ha \
  --version 19.6.4 \
  --values values.yaml \
  --wait --timeout 5m

# 4. Verify pods
kubectl get pods -n redis-ha -o wide
```

Expected output:
```
NAME                  READY   STATUS    NODE
redis-ha-node-0       3/3     Running   minikube
redis-ha-node-1       3/3     Running   minikube-m02
redis-ha-node-2       3/3     Running   minikube-m03
```
Each pod runs 3 containers: `redis`, `sentinel`, `metrics`.

---

## Configuration (values.yaml)

| Key | Value | Why |
|-----|-------|-----|
| `architecture` | `replication` | Enables master-replica mode |
| `sentinel.enabled` | `true` | Enables automatic failover |
| `sentinel.quorum` | `2` | Majority of 3 sentinels needed to elect |
| `sentinel.downAfterMilliseconds` | `5000` | Declare master down after 5s |
| `commonConfiguration.appendonly` | `yes` | AOF persistence |
| `commonConfiguration.maxmemory-policy` | `allkeys-lru` | Evict LRU keys when full |
| `commonConfiguration.maxmemory` | `400mb` | Hard memory cap |
| `master/replica.persistence.size` | `2Gi` | PVC per node |
| `metrics.enabled` | `true` | Exposes `/metrics` for Prometheus |

---

## Verify Health

```bash
# Get Redis password
REDIS_PASS=$(kubectl get secret redis-secret -n redis-ha \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# Check replication status from master
kubectl exec -n redis-ha redis-ha-node-0 -c redis -- \
  redis-cli -a "$REDIS_PASS" INFO replication

# Expected: role:master, connected_slaves:2

# Check sentinel
kubectl exec -n redis-ha redis-ha-node-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL masters
```

---

## Write / Read Test

```bash
# Deploy test client pod
kubectl apply -f redis-client.yaml
kubectl wait --for=condition=Ready pod/redis-client -n redis-ha --timeout=60s

# Discover current master via sentinel
kubectl exec -n redis-ha redis-client -- \
  redis-cli -h redis-ha-node-0.redis-ha-headless.redis-ha.svc.cluster.local \
  -p 26379 SENTINEL get-master-addr-by-name mymaster

# Write to master (replace MASTER_IP with output above)
kubectl exec -n redis-ha redis-client -- \
  redis-cli -h <MASTER_IP> -a "$REDIS_PASS" SET mykey "hello"

# Read from replica
kubectl exec -n redis-ha redis-client -- \
  redis-cli -h redis-ha-node-1.redis-ha-headless.redis-ha.svc.cluster.local \
  -a "$REDIS_PASS" GET mykey
```

---

## Failover Demonstration

```bash
# Step 1: Write a key
kubectl exec -n redis-ha redis-ha-node-0 -c redis -- \
  redis-cli -a "$REDIS_PASS" SET failover-test "before"

# Step 2: Kill the master pod
kubectl delete pod redis-ha-node-0 -n redis-ha

# Step 3: Watch sentinel elect a new master (takes ~10s)
watch kubectl get pods -n redis-ha

# Step 4: Confirm new master
kubectl exec -n redis-ha redis-ha-node-1 -c redis -- \
  redis-cli -a "$REDIS_PASS" INFO replication | grep role

# Step 5: Confirm key survived
kubectl exec -n redis-ha redis-ha-node-1 -c redis -- \
  redis-cli -a "$REDIS_PASS" GET failover-test
# Expected: "before"
```

Failover timeline:
1. `0s` — master pod deleted
2. `5s` — sentinels mark master as `s_down` (subjectively down)
3. `5s` — sentinels reach quorum → `o_down` (objectively down)
4. `~8s` — sentinel leader elected, best replica chosen
5. `~10s` — replica promoted, others repoint, client reconnects

---

## Observability

### Logs
```bash
# Redis logs
kubectl logs -n redis-ha redis-ha-node-0 -c redis --tail=50

# Sentinel logs (shows failover events)
kubectl logs -n redis-ha redis-ha-node-0 -c sentinel --tail=50

# Follow all pods
kubectl logs -n redis-ha -l app.kubernetes.io/name=redis --all-containers -f
```

### Metrics (Prometheus)
The `metrics` sidecar exposes port `9121` with standard Redis metrics.

```bash
# Port-forward to scrape manually
kubectl port-forward -n redis-ha redis-ha-node-0 9121:9121
curl http://localhost:9121/metrics | grep redis_connected_slaves
```

Key metrics to watch:
- `redis_up` — instance availability
- `redis_connected_slaves` — replication health
- `redis_memory_used_bytes` — memory pressure
- `redis_rejected_connections_total` — connection saturation
- `redis_keyspace_hits_total / misses_total` — cache hit rate

Apply alert rules (requires Prometheus Operator):
```bash
kubectl apply -f prometheus-rules.yaml
```

### Health Checks
Bitnami chart configures these automatically:
- **Liveness**: `redis-cli ping` every 5s, fails after 5 attempts
- **Readiness**: `redis-cli ping` — pod removed from service endpoints until ready

---

## Failure Scenarios

### Pod Failure
Sentinel detects and promotes a replica within ~10s. StatefulSet controller
restarts the failed pod as a new replica automatically.

### Node Failure
Pod is rescheduled on another node (if resources allow). PVC is reattached.
Anti-affinity ensures the other replicas are already on different nodes,
so quorum is maintained during the reschedule window.

### Network Partition (conceptual)
If a sentinel minority is partitioned from the master:
- Minority cannot reach quorum (need 2 of 3)
- No false failover occurs
- When partition heals, minority sentinels sync state

If the master is partitioned from sentinels:
- Sentinels reach quorum → failover proceeds
- Old master rejoins as replica (Redis handles this automatically)

---

## Performance Tuning

| Setting | Value | Notes |
|---------|-------|-------|
| `maxmemory` | `400mb` | Set to ~80% of container limit |
| `maxmemory-policy` | `allkeys-lru` | Best for pure cache workloads |
| `tcp-keepalive` | `60` | Detect dead connections |
| `timeout` | `300` | Close idle connections after 5m |
| `appendfsync` | `everysec` | Balance durability vs throughput |

For queue workloads change `maxmemory-policy` to `noeviction` so keys are never silently dropped.

---

## Production Best Practices

### Security
```bash
# Rotate password — update secret then rolling restart
kubectl create secret generic redis-secret \
  --from-literal=redis-password='NewStrongPass456!' \
  --namespace redis-ha --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart statefulset redis-ha-node -n redis-ha
```

- Never expose Redis service as `NodePort` or `LoadBalancer` externally
- Use `NetworkPolicy` to restrict access to Redis namespace only
- Enable TLS (`tls.enabled: true` in values.yaml) for in-transit encryption

### Backup Strategy
```bash
# Trigger RDB snapshot
kubectl exec -n redis-ha redis-ha-node-0 -c redis -- \
  redis-cli -a "$REDIS_PASS" BGSAVE

# Copy RDB file out
kubectl cp redis-ha/redis-ha-node-0:/data/dump.rdb ./backup-$(date +%Y%m%d).rdb -c redis
```

For automated backups use a CronJob that runs `BGSAVE` + copies the dump to S3/GCS.

### Scaling Replicas
```bash
# Add a replica (update values.yaml replica.replicaCount: 3, then)
helm upgrade redis-ha bitnami/redis \
  --namespace redis-ha \
  --values values.yaml \
  --reuse-values
```

### Rolling Upgrades
```bash
# Upgrade chart version — replicas first, then master
helm upgrade redis-ha bitnami/redis \
  --namespace redis-ha \
  --version 19.7.0 \
  --values values.yaml \
  --wait
```
Bitnami chart upgrades replicas before master by default, minimising downtime.

---

## Teardown

```bash
helm uninstall redis-ha -n redis-ha
kubectl delete namespace redis-ha
# PVCs are NOT deleted automatically — delete manually if needed:
kubectl delete pvc -n redis-ha --all
```

---

## File Reference

| File | Purpose |
|------|---------|
| `values.yaml` | Helm chart configuration |
| `secret.yaml` | Redis auth password secret |
| `redis-client.yaml` | Interactive test pod |
| `test-job.yaml` | Automated write/read test Job |
| `test_client.py` | Python sentinel client (local dev) |
| `prometheus-rules.yaml` | Alerting rules for Prometheus Operator |
| `runbook.sh` | End-to-end automation script |
