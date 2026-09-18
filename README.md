# IBM MAS Workload Isolation Orchestrator V4.0

GitHub-ready OpenShift workload-placement project for IBM Maximo
Application Suite (MAS) **Manage**.

> **Scope:** V4.0 covers MAS Manage, SLS, MongoDB Community and Manage
> Db2U. Monitor/Predict-specific DB2 designs are intentionally excluded
> until separately validated.

## Repository layout

``` text
mas-workload-isolation-V4.0/
├── README.md
├── scripts/
│   └── mas-workload-isolation-V4.0.sh
└── docs/
    └── README.md
```

## Reference architecture

``` text
OpenShift
├─ worker-1, worker-2   workload-group=eam1
│  ├─ EAM1 MAS Core + Manage
│  ├─ EAM1 MAS Core/Manage OLM operators
│  ├─ EAM1 SLS
│  └─ EAM1 MongoDB
├─ worker-3, worker-4   workload-group=eam2
│  ├─ EAM2 MAS Core + Manage
│  ├─ EAM2 MAS Core/Manage OLM operators
│  ├─ EAM2 SLS
│  └─ EAM2 MongoDB
└─ worker-5             workload-group=db2
   ├─ EAM1 Manage DB2 + ETCD + LDAP
   ├─ EAM2 Manage DB2 + ETCD + LDAP
   ├─ db2u-operator-manager
   └─ db2u-day2-ops-controller-manager
```

The script adds a missing target label automatically, but **never
overwrites a conflicting existing label**.

## Components

`--components` accepts `mas`, `sls`, `mongodb`, `db2`, or a
comma-separated combination.

-   **mas** --- MAS Core/Manage CR pod templates, Manage workspace,
    MAXINST, server bundles, build selectors and MAS OLM operator
    Subscriptions.
-   **sls** --- SLS API placement using
    `LicenseService.spec.podTemplates`.
-   **mongodb** --- MongoDBCommunity CR affinity, generated StatefulSet
    affinity and actual member placement.
-   **db2** --- Manage Db2U `Db2uCluster.spec.affinity` plus
    `Subscription/db2u-operator.spec.config.affinity`.

## Processing model

``` text
Discover → Precheck → Capacity/health → Compare current vs desired
        → COMPLIANT: SKIP change, validate
        → DRIFT: backup → server dry-run → patch → reconcile
        → final PASS / WARNING / FAIL
```

Completed/Succeeded pods are historical/informational; Running workloads
drive placement validation.

## Prerequisites

`oc`, `jq`, `python3`, an authenticated OpenShift session with required
RBAC, and adequate target-node/storage capacity. Run `--precheck-only`
first in customer environments.

## Parameters

  ------------------------------------------------------------------------------------------------
  Parameter                    Required          Scope             Meaning
  ---------------------------- ----------------- ----------------- -------------------------------
  `--components`               Yes               All               `mas`, `sls`, `mongodb`, `db2`,
                                                                   or combination

  `--instance`                 MAS               MAS               MAS instance ID, e.g. `eam1`

  `--core-namespace`           MAS               MAS               e.g. `mas-eam1-core`

  `--manage-namespace`         MAS               MAS               e.g. `mas-eam1-manage`

  `--workspace`                No                MAS               Manage workspace; default
                                                                   `maximo`

  `--label-key`                No                MAS/SLS/MongoDB   Default `workload-group`

  `--label-value`              Yes\*             MAS/SLS/MongoDB   e.g. `eam1`

  `--allowed-nodes`            Yes\*             MAS/SLS/MongoDB   e.g. `worker-1,worker-2`

  `--sls-namespace`            SLS               SLS               e.g. `ibm-sls`

  `--mongodb-namespace`        MongoDB           MongoDB           e.g. `mongoce`

  `--mongodb-name`             No                MongoDB           Default `mas-mongo-ce`

  `--mongodb-stable-checks`    No                MongoDB           Default `3`

  `--db2-namespace`            DB2               DB2               e.g. `db2u`

  `--db2-label-key`            No                DB2               Default `workload-group`

  `--db2-label-value`          DB2               DB2               e.g. `db2`

  `--db2-allowed-nodes`        DB2               DB2               e.g. `worker-5`

  `--db2-stable-checks`        No                DB2               Default `3`

  `--mas-instances`            No                MAS               Inventory scope, e.g. `auto` or
                                                                   `eam1,eam2`

  `--placement-plan`           No/repeatable     MAS               e.g. `eam1=worker-1,worker-2`

  `--precheck-only`            No                All               Read-only discovery/precheck

  `--dry-run`                  No                All               Validate intended changes
                                                                   without normal apply

  `--auto-label`               No                All               Add missing labels; default

  `--no-auto-label`            No                All               Fail if target labels are
                                                                   missing

  `--force-reapply`            No                All               Reapply even if compliant

  `--yes`                      No                All               Skip interactive YES
                                                                   confirmation

  `--external-db`              No                MAS               MAS database is external to OCP

  `--skip-capacity-precheck`   No                MAS               Disable request-headroom gate

  `--min-cpu-headroom-pct`     No                MAS               Default `15`

  `--min-mem-headroom-pct`     No                MAS               Default `15`
  
  `--resume-from`              No                MAS               Script interface for phase
                                                                   resume
 
  ------------------------------------------------------------------------------------------------

`*` Required when any of MAS/SLS/MongoDB is selected.

Environment: `POLL_INTERVAL=20`, `TIMEOUT=1800` by default.

## Example: MAS only

``` bash
./scripts/mas-workload-isolation-V4.0.sh --components mas \
  --instance eam1 --core-namespace mas-eam1-core --manage-namespace mas-eam1-manage \
  --workspace maximo --label-key workload-group --label-value eam1 \
  --allowed-nodes worker-1,worker-2
```

## Example: SLS only

``` bash
./scripts/mas-workload-isolation-V4.0.sh --components sls \
  --sls-namespace ibm-sls --label-key workload-group --label-value eam1 \
  --allowed-nodes worker-1,worker-2
```

## Example: MongoDB only

``` bash
./scripts/mas-workload-isolation-V4.0.sh --components mongodb \
  --mongodb-namespace mongoce --mongodb-name mas-mongo-ce \
  --label-key workload-group --label-value eam1 --allowed-nodes worker-1,worker-2
```

## Example: DB2 only

``` bash
./scripts/mas-workload-isolation-V4.0.sh --components db2 \
  --db2-namespace db2u --db2-label-key workload-group \
  --db2-label-value db2 --db2-allowed-nodes worker-5
```

## Example: full EAM1 run

``` bash
./scripts/mas-workload-isolation-V4.0.sh \
  --components mas,sls,mongodb,db2 \
  --instance eam1 --core-namespace mas-eam1-core --manage-namespace mas-eam1-manage \
  --workspace maximo --sls-namespace ibm-sls \
  --mongodb-namespace mongoce --mongodb-name mas-mongo-ce \
  --label-key workload-group --label-value eam1 --allowed-nodes worker-1,worker-2 \
  --db2-namespace db2u --db2-label-key workload-group \
  --db2-label-value db2 --db2-allowed-nodes worker-5
```

## Two-instance placement-plan example

``` bash
--mas-instances eam1,eam2 \
--placement-plan eam1=worker-1,worker-2 \
--placement-plan eam2=worker-3,worker-4
```

## Results

-   **PASS** --- targeted workloads reached desired placement and health
    gates passed.
-   **WARNING** --- application isolation passed but a non-blocking
    supporting exception needs review.
-   **FAIL** --- blocking scheduling, capacity, health, timeout or
    placement validation failed.

Each run creates a timestamped directory with `backups/`, `patches/`,
`reports/`, and `run.log`.

See `docs/README.md` for the source-code component guide.
