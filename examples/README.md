# IBM MAS Workload Isolation Toolkit — Examples

Reusable command patterns for common deployment topologies. Replace example instance IDs, namespaces, and workers with values from Discovery.

> Recommended sequence: **Discovery → `--precheck-only` → review → isolation → validation**.

All examples use `./scripts/isolation/mas-workload-isolation.sh`.

## MAS only
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mas --instance eam1 \
  --core-namespace mas-eam1-core --manage-namespace mas-eam1-manage \
  --workspace maximo --label-value eam1 \
  --allowed-nodes worker-1,worker-2 --external-db --precheck-only
```

## SLS only
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components sls --sls-namespace ibm-sls-eam1 \
  --label-value eam1 --allowed-nodes worker-1,worker-2 --precheck-only
```

## MongoDB only
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mongodb --mongodb-namespace mongoce-eam1 \
  --mongodb-name mas-mongo-ce --label-value eam1 \
  --allowed-nodes worker-1,worker-2 --precheck-only
```

## Manage Db2U only
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components db2 --db2-namespace db2u \
  --db2-label-value db2 --db2-allowed-nodes worker-5 --precheck-only
```

## MAS + SLS + MongoDB — external database
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mas,sls,mongodb --instance eam \
  --core-namespace mas-eam-core --manage-namespace mas-eam-manage \
  --workspace maximo --sls-namespace ibm-sls-eam \
  --mongodb-namespace mongoce-eam --mongodb-name mas-mongo-ce \
  --label-value eam --allowed-nodes worker-1,worker-2,worker-3 \
  --external-db --precheck-only
```

## MAS + SLS + MongoDB + Manage Db2U
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mas,sls,mongodb,db2 --instance eam1 \
  --core-namespace mas-eam1-core --manage-namespace mas-eam1-manage \
  --workspace maximo --sls-namespace ibm-sls-eam1 \
  --mongodb-namespace mongoce-eam1 --label-value eam1 \
  --allowed-nodes worker-1,worker-2 \
  --db2-namespace db2u --db2-label-value db2 --db2-allowed-nodes worker-5 \
  --precheck-only
```

## Single-node instance
Single-node required affinity has reduced availability if the worker is unavailable.
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mas,sls,mongodb --instance dnxeam \
  --core-namespace mas-dnxeam-core --manage-namespace mas-dnxeam-manage \
  --workspace maximo --sls-namespace ibm-sls-dnxeam \
  --mongodb-namespace mongoce-dnxeam --label-value dnxeam \
  --allowed-nodes worker-7 --external-db --precheck-only
```

## Non-default Manage workspace — MREF
For ManageWorkspace `ifms-mref`, use `--workspace mref`.
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mas,sls,mongodb --instance ifms \
  --core-namespace mas-ifms-core --manage-namespace mas-ifms-manage \
  --workspace mref --sls-namespace ibm-sls-ifms \
  --mongodb-namespace mongoce-ifms --label-value ifms \
  --allowed-nodes worker-4,worker-5,worker-6 --external-db --precheck-only
```
ManageServerBundles are discovered dynamically; `ALL` is not mandatory.

## Two-instance placement-plan guard
```bash
./scripts/isolation/mas-workload-isolation.sh \
  --components mas,sls,mongodb --instance eam1 \
  --core-namespace mas-eam1-core --manage-namespace mas-eam1-manage \
  --sls-namespace ibm-sls-eam1 --mongodb-namespace mongoce-eam1 \
  --label-value eam1 --allowed-nodes worker-1,worker-2 --external-db \
  --mas-instances eam1,eam2 \
  --placement-plan eam1=worker-1,worker-2 \
  --placement-plan eam2=worker-3,worker-4 --precheck-only
```

## Other useful switches
- `--no-auto-label` — require target labels to exist already.
- `--dry-run` — generate/validate intended changes without normal apply.
- `--min-cpu-headroom-pct 25 --min-mem-headroom-pct 25` — custom capacity thresholds (defaults 15).
- `--skip-capacity-precheck` — bypass capacity gate; normally avoid.
- `--force-reapply` — reapply configuration even if already compliant.
- `--yes` — skip interactive confirmation for controlled automation.
- `--mongodb-stable-checks N` / `--db2-stable-checks N` — change stability check count.

## Independent validation
```bash
./scripts/validation/mas-workload-isolation-validation.sh \
  --instance eam1 --core-namespace mas-eam1-core \
  --manage-namespace mas-eam1-manage --sls-namespace ibm-sls-eam1 \
  --mongodb-namespace mongoce-eam1 --label-value eam1 \
  --allowed-nodes worker-1,worker-2
```
