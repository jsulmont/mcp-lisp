# K8s Scheduling & Pod Lifecycle

Entities:
- **namespace** — id, name, phase (member :active :terminating)
- **node** — id, name, status (member :ready :not-ready :unknown), memory-capacity-mi, cpu-capacity-m, memory-allocatable-mi, cpu-allocatable-m, disk-capacity-gi, disk-available-gi, memory-available-mi, pid-available, has taints (list), conditions: memory-pressure (bool), disk-pressure (bool), pid-pressure (bool), unschedulable (bool)
- **pod** — id, name, namespace-id, node-id (nullable — unscheduled pods), phase (member :pending :running :succeeded :failed :unknown), qos-class (member :guaranteed :burstable :best-effort), priority (number), restart-policy (member :always :on-failure :never), termination-grace-period-seconds (number, default 30), total-cpu-request-m, total-cpu-limit-m, total-memory-request-mi, total-memory-limit-mi, ready (bool), scheduled (bool)
- **container** — id, name, pod-id, state (member :waiting :running :terminated), image, cpu-request-m, cpu-limit-m, memory-request-mi, memory-limit-mi, restart-count (number), exit-code (number nullable), liveness-probe-ok (bool), readiness-probe-ok (bool), startup-probe-ok (bool)
- **deployment** — id, name, namespace-id, replicas (number), strategy (member :rolling-update :recreate), max-surge (number), max-unavailable (number), min-ready-seconds (number, default 0), progress-deadline-seconds (number, default 600), revision-history-limit (number, default 10), condition (member :progressing :complete :failed), paused (bool)
- **replica-set** — id, name, namespace-id, deployment-id, revision (number), desired-replicas (number), current-replicas (number), ready-replicas (number), available-replicas (number), pod-template-hash (string)

Relations:
- namespace has-many pods, deployments, replica-sets
- node has-many pods
- pod has-many containers
- deployment has-many replica-sets
- replica-set has-many pods

Config:
- hard-eviction-memory-mi (number, default 50, min 0, max 1000) — hard eviction threshold for memory
- hard-eviction-disk-pct (number, default 5, min 0, max 50) — hard eviction threshold for disk %
- soft-eviction-memory-mi (number, default 100, min 0, max 2000)
- soft-eviction-disk-pct (number, default 10, min 0, max 50)
- eviction-pressure-transition-period-s (number, default 300, min 0, max 3600) — hysteresis for node condition flapping

Per-entity invariants:
1. **allocatable-le-capacity** (node): allocatable ≤ capacity for both memory and cpu
2. **pressure-matches-threshold** (node): memory-pressure = true iff memory-available-mi < soft-eviction-memory-mi (from config); disk-pressure = true iff disk-available-gi/disk-capacity-gi*100 < soft-eviction-disk-pct
3. **qos-class-derivation** (pod): qos-class is :guaranteed iff every container has requests = limits for both cpu and memory; :best-effort iff every container has zero requests and zero limits; :burstable otherwise
4. **pod-resource-aggregation** (pod): total-cpu-request-m = sum of container cpu-request-m; same for memory, limits
5. **container-request-le-limit** (container): cpu-request-m ≤ cpu-limit-m, memory-request-mi ≤ memory-limit-mi (when both set / nonzero)
6. **restart-count-non-negative** (container): restart-count ≥ 0
7. **terminated-has-exit-code** (container): if state = :terminated then exit-code is not null
8. **deployment-surge-bounds** (deployment): max-surge ≥ 0, max-unavailable ≥ 0, max-surge + max-unavailable > 0 (can't both be zero)
9. **replica-set-ready-le-current** (replica-set): ready-replicas ≤ current-replicas, available-replicas ≤ ready-replicas
10. **deployment-paused-not-progressing** (deployment): if paused = true then condition ≠ :progressing
11. **succeeded-pod-not-restarting** (pod): if phase = :succeeded then restart-policy = :never or restart-policy = :on-failure
12. **scheduled-pod-has-node** (pod): if scheduled = true then node-id is not null; if phase ≠ :pending then scheduled = true

Rules (pod lifecycle):
- **schedule-pod**: when phase = :pending, scheduled = false → ensures scheduled = true, phase remains :pending (node-id gets assigned)
- **start-pod**: when phase = :pending, scheduled = true → ensures phase = :running
- **succeed-pod**: when phase = :running, restart-policy in (:never :on-failure) → ensures phase = :succeeded
- **fail-pod**: when phase = :running → ensures phase = :failed
- **lose-node-contact**: when phase = :running → ensures phase = :unknown
- **recover-pod**: when phase = :unknown → ensures phase = :running

Rules (deployment):
- **begin-rollout**: when condition = :complete, paused = false → ensures condition = :progressing
- **complete-rollout**: when condition = :progressing → ensures condition = :complete
- **fail-rollout**: when condition = :progressing → ensures condition = :failed
- **pause-deployment**: when condition = :progressing or :complete, paused = false → ensures paused = true
- **resume-deployment**: when paused = true → ensures paused = false

Cross-entity scenarios:
- **node-scheduling**: nodes (1 3), pods (5 20) — sum of pod cpu-request-m on each node ≤ node cpu-allocatable-m; same for memory. No pod scheduled to an unschedulable node.
- **deployment-rollout**: deployment (1), replica-sets (1 3) per deployment, pods (1 10) per replica-set — during rollout: total pods across all replica-sets ≤ deployment.replicas + deployment.max-surge; available pods ≥ deployment.replicas - deployment.max-unavailable. Exactly one replica-set is "active" (current-replicas > 0 matches latest revision).
- **eviction-ordering**: node (1), pods (5 15) on that node — when node memory-pressure = true, BestEffort pods are evicted before Burstable, Burstable before Guaranteed. Within same QoS class, lower priority pods evicted first.
