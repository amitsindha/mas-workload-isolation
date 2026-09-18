# Troubleshooting

## Script appears to be waiting
Use a second terminal to inspect Pending, Terminating, CrashLoopBackOff, ContainerCreating and image-pull states. V4.1 also prints reconciliation progress.

## Graphite outside target workers
Graphite/Application Configuration is optional and is owned by AppCfg. V4.1 uses the supported `graphite-configuration` AppCfg pod template when the component is active.

## Supporting operators outside target workers
Do not automatically interpret supporting controller/operator placement as an application isolation failure. Use the independent validator to distinguish application/database workloads from supporting components.

## Manage ALL is missing
`ALL` is not mandatory. A customer can use split server bundles such as UI, MEA, CRON and REPORT, or may have no Manage runtime workload for a particular use case.

## PVC considerations
Isolation moves workloads; it does not recreate PVC/PV objects. Confirm that storage remains Bound and accessible from the target worker pool.

## Recovery
Every isolation run captures backups before supported CR changes. Preserve the complete timestamped run directory before performing manual remediation.
