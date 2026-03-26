# Redis HA on Kubernetes

Sentinel-based Redis HA deployment using Bitnami Helm chart.
3 Redis nodes (1 master + 2 replicas) + 3 Sentinel processes, AOF + RDB persistence, PVCs, and automatic failover.

---

## Architecture

```
Redis Sentinel HA Topology
===========================

  ┌──────────────────────────────────────────────┐
  │            Single EC2 Node (k3s)             │
  │                                              │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
  │  │ node-0   │  │ node-1   │  │ node-2   │  │
  │  │ replica  │  │ MASTER   │  │ replica  │  │
  │  │  PVC-0   │  │  PVC-1   │  │  PVC-2   │  │
  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
  │       │              │              │        │
  │  ┌────▼──────────────▼──────────────▼──────┐ │
  │  │   Sentinel x3 (quorum=2, port 26379)    │ │
  │  └─────────────────────────────────────────┘ │
  └──────────────────────────────────────────────┘

Each pod: redis container + sentinel container (2/2)
Failover: sentinel quorum=2 elects new master in ~10s
```

---

## Prerequisites

| Tool    | Version | Purpose                  |
|---------|---------|--------------------------|
| kubectl | 1.28+   | Kubernetes CLI           |
| helm    | 3.14+   | Chart deployment         |
| k3s     | 1.34+   | Lightweight Kubernetes   |

StorageClass `local-path` is used (k3s default).

---

## Setup

### 1. Install tools on Ubuntu 22.04

```bash
git clone <your-repo-url> redis-k8s-ha
cd redis-k8s-ha
bash install.sh
```

`install.sh` installs kubectl, helm, and k3s, and configures kubeconfig automatically.

### 2. Verify cluster

```bash
kubectl get nodes
# NAME              STATUS   ROLES           VERSION
# ip-xxx-xxx        Ready    control-plane   v1.34.x+k3s1

kubectl get storageclass
# NAME                   PROVISIONER
# local-path (default)   rancher.io/local-path
```

---

## Deployment

```bash
# 1. Create namespace + secret
kubectl create namespace redis-ha
kubectl apply -f secret.yaml

# 2. Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# 3. Deploy Redis HA
helm upgrade --install redis-ha bitnami/redis \
  --namespace redis-ha \
  --version 25.3.9 \
  --values values.yaml \
  --wait --timeout 5m

# 4. Verify pods
kubectl get pods -n redis-ha
```

Expected output:
```
NAME              READY   STATUS    AGE
redis-ha-node-0   2/2     Running   2m
redis-ha-node-1   2/2     Running   2m
redis-ha-node-2   2/2     Running   2m
```

Each pod runs 2 containers: `redis` + `sentinel`.

---

## Configuration (values.yaml)

| Key | Value | Why |
|-----|-------|-----|
| `architecture` | `replication` | Master-replica mode |
| `sentinel.enabled` | `true` | Automatic failover |
| `sentinel.quorum` | `2` | 2 of 3 sentinels must agree |
| `sentinel.downAfterMilliseconds` | `5000` | Declare master down after 5s |
| `replica.replicaCount` | `3` | Total nodes (1 master + 2 replicas) in chart v25.x |
| `commonConfiguration.appendonly` | `yes` | AOF persistence |
| `commonConfiguration.maxmemory-policy` | `allkeys-lru` | LRU eviction for cache workloads |
| `commonConfiguration.maxmemory` | `100mb` | Memory cap per node |
| `master/replica.persistence.size` | `2Gi` | PVC per node |
| `master/replica.persistence.storageClass` | `local-path` | k3s default StorageClass |
| `metrics.enabled` | `false` | Disabled for demo (saves RAM) |

> **Note:** In Bitnami Redis chart v25.x, `replica.replicaCount` sets the **total** StatefulSet size
> (master + replicas combined), unlike older chart versions where it counted only replicas.

---

## Verify Health

```bash
# Get Redis password
REDIS_PASS=$(kubectl get secret redis-secret -n redis-ha \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# Find current master via sentinel
kubectl exec -n redis-ha redis-ha-node-0 -c sentinel -- \
  redis-cli -p 26379 -a "$REDIS_PASS" SENTINEL get-master-addr-by-name mymaster

# Check replication on master (replace node-X with actual master pod)
kubectl exec -n redis-ha redis-ha-node-X -c redis -- \
  redis-cli -a "$REDIS_PASS" INFO replication | grep -E "role:|connected_slaves:"

# Expected:
# role:master
# connected_slaves:2
```

---

## Write / Read Test

```bash
# Write to master
kubectl exec -n redis-ha redis-ha-node-X -c redis -- \
  redis-cli -a "$REDIS_PASS" SET mykey "hello-redis-ha"

# Read from master
kubectl exec -n redis-ha redis-ha-node-X -c redis -- \
  redis-cli -a "$REDIS_PASS" GET mykey

# Read from replica — confirms replication
kubectl exec -n redis-ha redis-ha-node-0 -c redis -- \
  redis-cli -a "$REDIS_PASS" GET mykey
```

---

## Failover Demonstration

```bash
# Step 1: Write a key
kubectl exec -n redis-ha redis-ha-node-X -c redis -- \
  redis-cli -a "$REDIS_PASS" SET failover-test "before"

# Step 2: Kill the master pod
kubectl delete pod redis-ha-node-X -n redis-ha

# Step 3: Watch sentinel elect a new master (~10s)
watch kubectl get pods -n redis-ha

# Step 4: Find new master
kubectl exec -n redis-ha redis-ha-node-0 -c sentinel -- \
  redis-cli -p 26379 -a "$REDIS_PASS" SENTINEL get-master-addr-by-name mymaster

# Step 5: Confirm key survived
kubectl exec -n redis-ha <new-master-pod> -c redis -- \
  redis-cli -a "$REDIS_PASS" GET failover-test
# Expected: "before"
```

Failover timeline:
1. `0s` — master pod deleted
2. `5s` — sentinels mark master `s_down` (subjectively down)
3. `5s` — quorum reached → `o_down` (objectively down)
4. `~8s` — sentinel leader elected, best replica chosen
5. `~10s` — replica promoted, others repoint, client reconnects

---

## Automated Test + Evidence Collection

Runs 10 tests end-to-end and saves a timestamped evidence report:

```bash
bash test-failover.sh
```

Tests covered:

| # | Test |
|---|------|
| 1 | All 3 pods `2/2 Running` |
| 2 | All 3 PVCs `Bound` |
| 3 | Sentinel discovers master |
| 4 | Master has 2 connected replicas |
| 5 | Write (`SET`) to master returns `OK` |
| 6 | Read (`GET`) from master returns correct value |
| 7 | Read from replica confirms replication |
| 8 | Kill master → new master elected (records failover time) |
| 9 | Key written before failover survives on new master |
| 10 | Old master restarts and rejoins as replica |

Report saved to: `redis-ha-test-report-<timestamp>.txt`

---

## Observability

### Logs

```bash
# Redis logs
kubectl logs -n redis-ha redis-ha-node-0 -c redis --tail=50

# Sentinel logs (shows failover events)
kubectl logs -n redis-ha redis-ha-node-0 -c sentinel --tail=50

# Follow all pods live
kubectl logs -n redis-ha -l app.kubernetes.io/name=redis --all-containers -f
```

### Metrics (Prometheus — optional)

Enable in `values.yaml` first:
```yaml
metrics:
  enabled: true
```

Then redeploy and port-forward:
```bash
kubectl port-forward -n redis-ha redis-ha-node-0 9121:9121
curl http://localhost:9121/metrics | grep redis_connected_slaves
```

Key metrics:
- `redis_up` — instance availability
- `redis_connected_slaves` — replication health
- `redis_memory_used_bytes` — memory pressure
- `redis_rejected_connections_total` — connection saturation

Apply alert rules (requires Prometheus Operator):
```bash
kubectl apply -f prometheus-rules.yaml
```

### Health Checks

Bitnami chart configures automatically:
- **Liveness**: `redis-cli ping` every 5s, fails after 5 attempts
- **Readiness**: `redis-cli ping` — pod removed from endpoints until ready

---

## Failure Scenarios

### Pod Failure
Sentinel detects and promotes a replica within ~10s. StatefulSet restarts
the failed pod automatically as a new replica.

### Node Failure
On a single-node setup (demo), all pods restart on the same node when it
recovers. PVCs are reattached via `local-path`. For production, use 3 nodes
with pod anti-affinity to maintain quorum during node failure.

### Network Partition (conceptual)
- Sentinel minority cannot reach quorum (need 2 of 3) → no false failover
- If master is partitioned from sentinels → quorum reached → failover proceeds
- Old master rejoins as replica automatically when partition heals

---

## Performance Tuning

| Setting | Value | Notes |
|---------|-------|-------|
| `maxmemory` | `100mb` | ~80% of container limit (demo) |
| `maxmemory-policy` | `allkeys-lru` | Best for pure cache workloads |
| `appendfsync` | `everysec` | Balance durability vs throughput |
| `tcp-keepalive` | `60` | Detect dead connections |
| `timeout` | `300` | Close idle connections after 5m |

For queue workloads change `maxmemory-policy` to `noeviction`.

---

## Production Best Practices

### Security
```bash
# Rotate password
kubectl create secret generic redis-secret \
  --from-literal=redis-password='NewStrongPass456!' \
  --namespace redis-ha --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart statefulset redis-ha-node -n redis-ha
```

- Never expose Redis as `NodePort` or `LoadBalancer` externally
- Use `NetworkPolicy` to restrict access to the `redis-ha` namespace only
- Enable TLS (`tls.enabled: true` in values.yaml) for in-transit encryption

### Backup
```bash
# Trigger RDB snapshot
kubectl exec -n redis-ha redis-ha-node-0 -c redis -- \
  redis-cli -a "$REDIS_PASS" BGSAVE

# Copy dump out
kubectl cp redis-ha/redis-ha-node-0:/data/dump.rdb ./backup-$(date +%Y%m%d).rdb -c redis
```

### Scaling Replicas
```bash
# Update replica.replicaCount in values.yaml, then:
helm upgrade redis-ha bitnami/redis \
  --namespace redis-ha \
  --version 25.3.9 \
  --values values.yaml
```

### Rolling Upgrades
```bash
helm upgrade redis-ha bitnami/redis \
  --namespace redis-ha \
  --version 25.3.9 \
  --values values.yaml \
  --wait
```

---

## Teardown

```bash
helm uninstall redis-ha -n redis-ha
kubectl delete namespace redis-ha
kubectl delete pvc -n redis-ha --all   # PVCs are NOT auto-deleted
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
| `test-failover.sh` | End-to-end failover test + evidence report |
| `prometheus-rules.yaml` | Alerting rules for Prometheus Operator |
| `runbook.sh` | Deployment automation script |
| `install.sh` | Bootstrap script (Ubuntu 22.04 — installs kubectl, helm, k3s) |
