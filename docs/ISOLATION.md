# Isolation

`mas-workload-isolation.sh` is the change-producing component.

## Recommended sequence

1. Run Discovery.
2. Select dedicated target workers.
3. Run Isolation with `--precheck-only`.
4. Review capacity, current placement and target labels.
5. Run without `--precheck-only`.
6. Type `YES` only after confirming the displayed change plan.
7. Monitor reconciliation.
8. Run independent Validation.

## Important V4.1.1 behavior

- No target-node label mutation before explicit confirmation.
- Default OpenShift request timeout is 300 seconds.
- Progress is displayed during reconciliation.
- AppConfig/Graphite is optional and handled through AppCfg when present.
- Manage server bundles are enumerated dynamically.
- SLS and MongoDB can be selected independently.
- Db2U is supported for the validated MAS Manage scope.

Each run creates `backups/`, `patches/`, `reports/`, and `run.log`.

Use `--help` for the complete parameter list.

## Transient OpenShift API retry

V4.1.1 retries transient OpenShift API/query failures during MongoDB reconciliation instead of aborting immediately. The overall `TIMEOUT` remains the final failure boundary. This protects long-running customer migrations from temporary API connectivity interruptions while preserving a bounded failure condition.
