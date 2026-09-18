# Examples

## Three-worker external-database MAS instance

```bash
./scripts/isolation/mas-workload-isolation.sh   --components mas,sls,mongodb   --instance eam   --core-namespace mas-eam-core   --manage-namespace mas-eam-manage   --workspace maximo   --sls-namespace ibm-sls-eam   --mongodb-namespace mongoce-eam   --mongodb-name mas-mongo-ce   --label-key workload-group   --label-value eam   --allowed-nodes worker-1,worker-2,worker-3   --external-db   --precheck-only
```

After reviewing precheck output, repeat without `--precheck-only`.

## Read-only validation

```bash
./scripts/validation/mas-workload-isolation-validation.sh   --instance eam   --core-namespace mas-eam-core   --manage-namespace mas-eam-manage   --sls-namespace ibm-sls-eam   --mongodb-namespace mongoce-eam   --label-value eam   --allowed-nodes worker-1,worker-2,worker-3
```
