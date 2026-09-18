# V4.0 Source Code Component Guide

This document explains what `scripts/mas-workload-isolation-V4.0.sh`
does internally.

## 1. CLI and component dispatcher

Parses component-specific parameters and uses `has_component` so MAS,
SLS, MongoDB and DB2 can run independently or together.

## 2. Node labels

Checks target workers first. Missing labels can be added automatically;
conflicting values stop execution. DB2 has independent label/node
parameters so it can use a dedicated pool.

## 3. Discovery and placement plan

Discovers MAS instances/namespaces and reports current worker
distribution. Optional `--placement-plan` describes expected worker
pools for multiple MAS instances.

## 4. Capacity gate

Uses node allocatable CPU/memory and summed container resource
**requests**. It calculates current and projected request headroom and
compares it with configurable thresholds. Rolling updates may
temporarily need extra capacity.

## 5. Backup, patch and server dry-run

Before supported changes, current YAML is saved under `backups/`. JSON
merge patches are stored under `patches/`. Server-side dry-run is used
where supported before live patching.

## 6. MAS Core

Updates supported MAS custom-resource `podTemplates`. Existing desired
affinity is detected and reported `COMPLIANT / SKIPPED`. Health gates
check MAS application readiness after phases.

## 7. Manage

Handles ManageWorkspace, MAXINST/ManageDeployment, ManageServerBundle
resources and build selectors. Generated Deployments/StatefulSets are
checked for expected affinity.

## 8. MAS OLM operators

Configures `Subscription/ibm-mas` and `Subscription/ibm-mas-manage`
through `spec.config.affinity`. This persistently places the main MAS
operators without directly patching OLM-managed Deployments.

## 9. SLS

Uses the SLS `LicenseService` CR `spec.podTemplates` for
`api-licensing`, waits for status reconciliation, validates generated
Deployment affinity, and checks rollout health.

## 10. MongoDB

V4.0 separates three checks:

``` text
MongoDBCommunity CR affinity
Generated StatefulSet affinity
Actual MongoDB member pod placement
```

If CR and StatefulSet are already correct, the script does **not**
reapply an identical CR just because placement differs. It waits for
placement/health convergence. MongoDB must be Running, StatefulSet
replicas Ready, affinity correct and members on allowed nodes for
consecutive stable checks.

## 11. Db2U

V4.0 DB2 scope is MAS Manage only. It discovers `Db2uCluster` CRs in the
selected namespace, verifies `Ready` and `Maintenance=None`, checks
PVCs, then processes clusters sequentially.

Each cluster is controlled through `Db2uCluster.spec.affinity`. DB2,
ETCD and LDAP generated workloads are validated on the DB2 target pool.

The Db2U operators are controlled persistently through:

``` text
Subscription/db2u-operator
  spec.config.affinity
```

The script validates both `db2u-operator-manager` and
`db2u-day2-ops-controller-manager`.

## 12. Idempotency

Normal rerun logic is:

``` text
desired configuration already present
→ COMPLIANT / SKIPPED
→ health/placement validation still runs
```

`--force-reapply` deliberately bypasses the skip behavior.

## 13. Health gates

The script checks conditions such as Pending, prolonged
ContainerCreating, CrashLoopBackOff, ImagePullBackOff, FailedScheduling
and unavailable replicas for targeted MAS application workloads.
Stateful services also have component-specific readiness/stability
gates.

## 14. Running vs historical pods

Running workloads are used for placement compliance. Succeeded/Completed
jobs are shown separately as historical information and do not create
active-placement violations.

## 15. PASS / WARNING / FAIL

-   PASS: selected workload placement and health checks passed.
-   WARNING: isolation passed but a non-blocking supporting exception
    needs review.
-   FAIL: blocking health, scheduling, capacity, timeout or placement
    validation failed.

## 16. Run artifacts

A run directory is created for traceability:

``` text
mas-workload-isolation-<instance-or-label>-<timestamp>/
├── backups/
├── patches/
├── reports/
└── run.log
```

## 17. Customer rollout recommendation

Use `--precheck-only`, review capacity and discovered resources, execute
in a maintenance/change window, retain run artifacts, and rerun normally
to verify idempotent `COMPLIANT / SKIPPED` behavior. Do not use
`--force-reapply` for routine validation.

## 18. Current V4.0 boundary

Monitor/Predict DB2 topology is intentionally not implemented. Extend
only after validating that environment's Db2U resource ownership and
scheduling behavior.
