# Isolation Script — Technical Design and Execution Flow

Technical reference for `scripts/isolation/mas-workload-isolation.sh` (stable V4.1.1).

## Execution flow
```text
Arguments
 ↓
Component/prerequisite validation
 ↓
Target-label precheck (READ ONLY)
 ↓
MAS inventory + optional AppCfg discovery
 ↓
Placement-plan validation
 ↓
Capacity + projected-capacity gates
 ↓
Current placement / health snapshot
 ↓
--precheck-only? → exit, no changes
 ↓
Explicit YES confirmation
 ↓
Apply missing target labels
 ↓
Patch supported owning CRs
 ↓
Wait for operator reconciliation
 ↓
MAS health gates
 ↓
SLS / MongoDB / Db2U phases
 ↓
Final placement validation
 ↓
PASS / WARNING / FAIL
```

## Safety model
No target-node label mutation occurs before confirmation. Missing labels are planned during precheck; conflicting existing label values are never overwritten. Backups are captured before supported CR changes.

## MAS Core
Affinity is configured through MAS-owned CR pod templates rather than editing generated application Deployments directly. Health gates verify convergence.

## AppConfig / Graphite
Graphite is optional. When AppCfg is enabled, the script backs up AppCfg, merges the supported `graphite-configuration` podTemplate while preserving other AppCfg podTemplates, waits for rollout, and validates placement. Absence is N/A.

## Manage
The script processes ManageApp, ManageWorkspace, MAXINST, build selectors where applicable, discovered ManageServerBundle resources, and MAS Manage OLM operator affinity. Server bundles are dynamic; `ALL` is not mandatory. `--workspace` defaults to `maximo`; use `--workspace mref` for `ifms-mref`.

## SLS
SLS API placement is configured through LicenseService. Supporting SLS controllers are classified separately.

## MongoDB Community
The script validates MongoDBCommunity desired affinity, generated StatefulSet affinity, actual member placement, replica health and PVC state. V4.1.1 retries transient OpenShift API/query failures during reconciliation; overall `TIMEOUT` remains the final failure boundary.

## Manage Db2U
Validated scope covers IBM MAS Manage Db2U. Db2uCluster and Db2U operator affinity can use a dedicated DB2 worker pool.

## Compliance model
```text
COMPLIANT → skip unnecessary patch → validate
DRIFT/NEW → backup → patch validation → apply → reconcile → validate
```

## Capacity gates
Default request-headroom thresholds are 15% CPU and 15% memory. Projected post-migration request headroom is also calculated. Rolling updates can temporarily require old and new replicas.

## Timing
```text
POLL_INTERVAL=20
TIMEOUT=1800
OC_REQUEST_TIMEOUT=300s
```

## Artifacts
```text
mas-workload-isolation-<instance>-YYYYMMDD-HHMMSS/
├── backups/
├── patches/
├── reports/
└── run.log
```

## Results
- **PASS** — targeted application placement and health succeeded.
- **WARNING** — application isolation succeeded but supporting/operator exceptions need review.
- **FAIL** — blocking health, scheduling, placement or timeout validation failed.
