"""
Redis HA client — validates writes, reads, and sentinel-based reconnection.
Connects via Sentinel so it always finds the current master automatically.
"""
import time
import redis
from redis.sentinel import Sentinel

SENTINEL_HOSTS = [
    ("redis-ha-node-0.redis-ha-headless.redis-ha.svc.cluster.local", 26379),
    ("redis-ha-node-1.redis-ha-headless.redis-ha.svc.cluster.local", 26379),
    ("redis-ha-node-2.redis-ha-headless.redis-ha.svc.cluster.local", 26379),
]
MASTER_NAME   = "mymaster"
REDIS_PASSWORD = "StrongRedisPass123!"   # injected via env in production


def get_sentinel_client():
    sentinel = Sentinel(
        SENTINEL_HOSTS,
        socket_timeout=2,
        password=REDIS_PASSWORD,
        sentinel_kwargs={"password": REDIS_PASSWORD},
    )
    master  = sentinel.master_for(MASTER_NAME, socket_timeout=2)
    replica = sentinel.slave_for(MASTER_NAME,  socket_timeout=2)
    return master, replica


def run_write_read_test(master, replica):
    print("\n--- Write/Read Test ---")
    master.set("hello", "redis-ha-works")
    master.set("counter", 0)
    master.incr("counter")
    master.incr("counter")

    val     = replica.get("hello").decode()
    counter = replica.get("counter").decode()
    print(f"  hello   = {val}")       # redis-ha-works
    print(f"  counter = {counter}")   # 2
    assert val == "redis-ha-works"
    assert counter == "2"
    print("  PASSED")


def run_failover_watch(master, replica):
    """
    Write a key, then poll until the value is readable — simulates
    client behaviour during a failover (master pod killed externally).
    """
    print("\n--- Failover Watch ---")
    master.set("failover-key", "before-failover")
    print("  Key written. Kill the master pod now:")
    print("  kubectl delete pod -n redis-ha -l redis-role=master")
    print("  Polling for reconnection...\n")

    for attempt in range(30):
        try:
            new_master, new_replica = get_sentinel_client()
            val = new_master.get("failover-key")
            print(f"  [{attempt+1}] master reachable — failover-key = {val.decode()}")
            return
        except redis.exceptions.ConnectionError as exc:
            print(f"  [{attempt+1}] not yet: {exc}")
            time.sleep(2)

    print("  FAILED — master did not recover in 60s")


if __name__ == "__main__":
    master, replica = get_sentinel_client()
    run_write_read_test(master, replica)
    run_failover_watch(master, replica)
