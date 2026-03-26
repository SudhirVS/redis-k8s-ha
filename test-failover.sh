#!/usr/bin/env bash
# =============================================================================
# Redis HA Failover Test — Evidence Collection Script
# Saves full evidence to: redis-ha-test-report-<timestamp>.txt
# =============================================================================
set -euo pipefail

NAMESPACE="redis-ha"
REPORT="redis-ha-test-report-$(date +%Y%m%d-%H%M%S).txt"
PASS=0
FAIL=0

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()    { echo "$1" | tee -a "$REPORT"; }
header() { log ""; log "================================================================"; log "$1"; log "================================================================"; }
result() { 
  if [[ "$1" == "PASS" ]]; then
    PASS=$((PASS+1)); log "  RESULT : ✅ PASS"
  else
    FAIL=$((FAIL+1)); log "  RESULT : ❌ FAIL — $2"
  fi
}

# ─── Init report ─────────────────────────────────────────────────────────────
log "Redis HA Test Report"
log "Generated : $(date)"
log "Cluster   : $(kubectl config current-context)"
log "Namespace : $NAMESPACE"

# ─── Get password ─────────────────────────────────────────────────────────────
REDIS_PASS=$(kubectl get secret redis-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# ─── TEST 1: All pods running ─────────────────────────────────────────────────
header "TEST 1 — Pod Health"
POD_OUTPUT=$(kubectl get pods -n "$NAMESPACE" -o wide)
log "$POD_OUTPUT"
RUNNING=$(echo "$POD_OUTPUT" | grep -c "2/2.*Running" || true)
log "  Running pods : $RUNNING / 3"
[[ "$RUNNING" -eq 3 ]] && result "PASS" || result "FAIL" "Expected 3 running pods, got $RUNNING"

# ─── TEST 2: PVCs bound ───────────────────────────────────────────────────────
header "TEST 2 — Persistent Volume Claims"
PVC_OUTPUT=$(kubectl get pvc -n "$NAMESPACE")
log "$PVC_OUTPUT"
BOUND=$(echo "$PVC_OUTPUT" | grep -c "Bound" || true)
log "  Bound PVCs : $BOUND / 3"
[[ "$BOUND" -eq 3 ]] && result "PASS" || result "FAIL" "Expected 3 bound PVCs, got $BOUND"

# ─── TEST 3: Sentinel finds master ────────────────────────────────────────────
header "TEST 3 — Sentinel Master Discovery"
MASTER_ADDR=$(kubectl exec -n "$NAMESPACE" redis-ha-node-0 -c sentinel -- \
  redis-cli -p 26379 -a "$REDIS_PASS" SENTINEL get-master-addr-by-name mymaster 2>/dev/null | grep -v Warning)
MASTER_HOST=$(echo "$MASTER_ADDR" | head -1)
MASTER_PORT=$(echo "$MASTER_ADDR" | tail -1)
log "  Master host : $MASTER_HOST"
log "  Master port : $MASTER_PORT"
MASTER_POD=$(kubectl get pods -n "$NAMESPACE" -o wide | grep "${MASTER_HOST%%.*}" | awk '{print $1}' || true)
# fallback — find master pod by querying each pod
for pod in redis-ha-node-0 redis-ha-node-1 redis-ha-node-2; do
  ROLE=$(kubectl exec -n "$NAMESPACE" "$pod" -c redis -- \
    redis-cli -a "$REDIS_PASS" INFO replication 2>/dev/null | grep "^role:" | tr -d '\r' || true)
  if [[ "$ROLE" == "role:master" ]]; then
    MASTER_POD="$pod"
    break
  fi
done
log "  Master pod  : $MASTER_POD"
[[ -n "$MASTER_POD" ]] && result "PASS" || result "FAIL" "Could not identify master pod"

# ─── TEST 4: Replication status ───────────────────────────────────────────────
header "TEST 4 — Replication Status"
REPL_INFO=$(kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
  redis-cli -a "$REDIS_PASS" INFO replication 2>/dev/null | grep -v Warning)
log "$REPL_INFO"
SLAVES=$(echo "$REPL_INFO" | grep "connected_slaves:" | tr -d '\r' | cut -d: -f2)
log "  Connected replicas : $SLAVES"
[[ "$SLAVES" -eq 2 ]] && result "PASS" || result "FAIL" "Expected 2 connected replicas, got $SLAVES"

# ─── TEST 5: Write to master ──────────────────────────────────────────────────
header "TEST 5 — Write to Master"
SET_RESULT=$(kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
  redis-cli -a "$REDIS_PASS" SET testkey "hello-redis-ha" 2>/dev/null | grep -v Warning)
log "  SET testkey hello-redis-ha → $SET_RESULT"
[[ "$SET_RESULT" == "OK" ]] && result "PASS" || result "FAIL" "SET command did not return OK"

# ─── TEST 6: Read from master ─────────────────────────────────────────────────
header "TEST 6 — Read from Master"
GET_MASTER=$(kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
  redis-cli -a "$REDIS_PASS" GET testkey 2>/dev/null | grep -v Warning)
log "  GET testkey (master) → $GET_MASTER"
[[ "$GET_MASTER" == "hello-redis-ha" ]] && result "PASS" || result "FAIL" "Expected hello-redis-ha, got $GET_MASTER"

# ─── TEST 7: Read from replica ────────────────────────────────────────────────
header "TEST 7 — Read from Replica (Replication Verify)"
REPLICA_POD=""
for pod in redis-ha-node-0 redis-ha-node-1 redis-ha-node-2; do
  [[ "$pod" == "$MASTER_POD" ]] && continue
  REPLICA_POD="$pod"
  break
done
sleep 1  # allow replication lag
GET_REPLICA=$(kubectl exec -n "$NAMESPACE" "$REPLICA_POD" -c redis -- \
  redis-cli -a "$REDIS_PASS" GET testkey 2>/dev/null | grep -v Warning)
log "  GET testkey ($REPLICA_POD) → $GET_REPLICA"
[[ "$GET_REPLICA" == "hello-redis-ha" ]] && result "PASS" || result "FAIL" "Replica returned: $GET_REPLICA"

# ─── TEST 8: Failover ─────────────────────────────────────────────────────────
header "TEST 8 — Failover (Kill Master, Elect New Master)"
log "  Pre-failover master : $MASTER_POD"

# Write key before failover
kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
  redis-cli -a "$REDIS_PASS" SET failover-test "before-failover" &>/dev/null
log "  Wrote failover-test=before-failover to master"

# Kill master
log "  Killing master pod: $MASTER_POD..."
kubectl delete pod "$MASTER_POD" -n "$NAMESPACE"
FAILOVER_START=$(date +%s)

# Wait for new master (up to 30s)
log "  Waiting for new master election..."
NEW_MASTER=""
for i in $(seq 1 15); do
  sleep 2
  for pod in redis-ha-node-0 redis-ha-node-1 redis-ha-node-2; do
    [[ "$pod" == "$MASTER_POD" ]] && continue
    ROLE=$(kubectl exec -n "$NAMESPACE" "$pod" -c redis -- \
      redis-cli -a "$REDIS_PASS" INFO replication 2>/dev/null | grep "^role:" | tr -d '\r' || true)
    if [[ "$ROLE" == "role:master" ]]; then
      NEW_MASTER="$pod"
      break 2
    fi
  done
  log "  [$((i*2))s] Waiting..."
done

FAILOVER_END=$(date +%s)
FAILOVER_TIME=$((FAILOVER_END - FAILOVER_START))

log "  New master          : $NEW_MASTER"
log "  Failover time       : ${FAILOVER_TIME}s"
[[ -n "$NEW_MASTER" && "$NEW_MASTER" != "$MASTER_POD" ]] && result "PASS" || result "FAIL" "No new master elected within 30s"

# ─── TEST 9: Key survived failover ────────────────────────────────────────────
header "TEST 9 — Data Persistence After Failover"
sleep 2
SURVIVED=$(kubectl exec -n "$NAMESPACE" "$NEW_MASTER" -c redis -- \
  redis-cli -a "$REDIS_PASS" GET failover-test 2>/dev/null | grep -v Warning)
log "  GET failover-test (new master: $NEW_MASTER) → $SURVIVED"
[[ "$SURVIVED" == "before-failover" ]] && result "PASS" || result "FAIL" "Expected before-failover, got $SURVIVED"

# ─── TEST 10: Pod recovery ────────────────────────────────────────────────────
header "TEST 10 — Old Master Recovers as Replica"
log "  Waiting for $MASTER_POD to restart (up to 60s)..."
kubectl wait --for=condition=Ready pod/"$MASTER_POD" -n "$NAMESPACE" --timeout=60s || true
RECOVERED_ROLE=$(kubectl exec -n "$NAMESPACE" "$MASTER_POD" -c redis -- \
  redis-cli -a "$REDIS_PASS" INFO replication 2>/dev/null | grep "^role:" | tr -d '\r' || true)
log "  $MASTER_POD role after recovery : $RECOVERED_ROLE"
FINAL_PODS=$(kubectl get pods -n "$NAMESPACE" -o wide)
log "$FINAL_PODS"
[[ "$RECOVERED_ROLE" == "role:slave" ]] && result "PASS" || result "FAIL" "Expected role:slave, got $RECOVERED_ROLE"

# ─── Summary ──────────────────────────────────────────────────────────────────
header "SUMMARY"
TOTAL=$((PASS + FAIL))
log "  Total  : $TOTAL"
log "  Passed : $PASS"
log "  Failed : $FAIL"
log ""
if [[ "$FAIL" -eq 0 ]]; then
  log "  ✅ ALL TESTS PASSED — Redis HA is working correctly"
else
  log "  ❌ $FAIL TEST(S) FAILED — Review report above"
fi
log ""
log "Full report saved to: $REPORT"
