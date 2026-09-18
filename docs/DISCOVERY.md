# Discovery

`mas-cluster-discovery.sh` is read-only and creates a current-state assessment before isolation.

It discovers OpenShift workers/capacity, MAS Core/Manage namespaces, Suite/Manage CRs, optional AppConfig/Graphite, dynamic Manage runtime topology, SLS, MongoDB Community, Db2U, PVC/storage information, workload ownership, affinity and placement.

Run:

```bash
./scripts/discovery/mas-cluster-discovery.sh
```

Optional:

```bash
./scripts/discovery/mas-cluster-discovery.sh --include-all-pods
```

Review `REPORT.html` first, then `REPORT.txt` and raw TSV/JSON data when deeper evidence is needed.

Discovery does not label nodes or modify workloads.
