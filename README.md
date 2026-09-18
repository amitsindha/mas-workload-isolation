# IBM MAS Workload Isolation Toolkit

A practical OpenShift toolkit for **IBM Maximo Application Suite (MAS)** workload discovery, worker-node isolation, and independent post-migration validation.

The toolkit is organized around a simple operational workflow:

```text
Install → Discover → Review / Plan → Isolate → Validate
```

## Stable commands

The README always uses versionless stable entry points:

```bash
./scripts/discovery/mas-cluster-discovery.sh
./scripts/isolation/mas-workload-isolation.sh
./scripts/validation/mas-workload-isolation-validation.sh
```

Exact tested versions are retained under each component's `versions/` directory for traceability.

## Repository layout

```text
mas-workload-isolation/
├── README.md
├── CHANGELOG.md
├── .gitignore
├── install/
│   ├── install-toolkit.sh
│   ├── mas-toolkit-resources.yaml
│   └── README.md
├── scripts/
│   ├── discovery/
│   │   ├── mas-cluster-discovery.sh
│   │   └── versions/mas-cluster-discovery-v1.5.sh
│   ├── isolation/
│   │   ├── mas-workload-isolation.sh
│   │   └── versions/mas-workload-isolation-V4.1.sh
│   └── validation/
│       ├── mas-workload-isolation-validation.sh
│       └── versions/mas-workload-isolation-validation-V1.0.sh
├── docs/
│   ├── DISCOVERY.md
│   ├── ISOLATION.md
│   ├── VALIDATION.md
│   └── TROUBLESHOOTING.md
└── examples/
    └── README.md
```

## 1. Install the toolkit runtime

The developer workstation needs the `oc` CLI and a local copy of this repository. The installer creates a persistent MAS CLI pod in OpenShift and copies the **local repository contents** into `/mascli/mas-workload-isolation`.

```bash
chmod +x install/install-toolkit.sh
./install/install-toolkit.sh
```

If there is no active OpenShift session, the installer prompts for the API URL, username, and a hidden password. Self-signed/untrusted API certificates are accepted by default. See [install/README.md](install/README.md).

> The supplied runtime uses a cluster-admin service account because isolation performs cluster-level placement changes. Review this RBAC with the customer's OpenShift security team.

## 2. Discovery

Discovery is read-only. It inventories worker capacity, MAS instances, Manage topology, optional AppConfig/Graphite, SLS, MongoDB, Db2U, PVCs, ownership, affinity and current placement.

```bash
./scripts/discovery/mas-cluster-discovery.sh
```

Primary output includes `REPORT.html`, `REPORT.txt`, summary files and raw structured data. See [docs/DISCOVERY.md](docs/DISCOVERY.md).

## 3. Isolation

Always run precheck first in a customer environment.

```bash
./scripts/isolation/mas-workload-isolation.sh   --components mas,sls,mongodb   --instance eam   --core-namespace mas-eam-core   --manage-namespace mas-eam-manage   --workspace maximo   --sls-namespace ibm-sls-eam   --mongodb-namespace mongoce-eam   --mongodb-name mas-mongo-ce   --label-key workload-group   --label-value eam   --allowed-nodes worker-1,worker-2,worker-3   --external-db   --precheck-only
```

Remove only `--precheck-only` after reviewing capacity, topology, target workers and labels. V4.1.1 does not mutate target labels before explicit confirmation.

Isolation supports MAS, SLS, MongoDB Community and Manage Db2U. Optional AppConfig/Graphite is discovered and handled through its supported AppCfg pod template. Manage server bundles are discovered from the environment rather than requiring an `ALL` bundle.

See [docs/ISOLATION.md](docs/ISOLATION.md).

## 4. Validation

Validation is independently read-only:

```bash
./scripts/validation/mas-workload-isolation-validation.sh   --instance eam   --core-namespace mas-eam-core   --manage-namespace mas-eam-manage   --sls-namespace ibm-sls-eam   --mongodb-namespace mongoce-eam   --label-key workload-group   --label-value eam   --allowed-nodes worker-1,worker-2,worker-3
```

It separates application/database placement from supporting controllers/operators and reports optional components as N/A when absent.

## Current stable versions

| Component | Stable source |
|---|---|
| Discovery | v1.5 |
| Isolation | V4.1.1 |
| Validation | V1.0 |
| Installer | Initial toolkit installer |

## Safety model

- Discovery and validation are read-only.
- Isolation performs a read-only precheck before confirmation.
- Missing target labels are planned first and applied only after confirmation.
- Conflicting existing workload-group labels are not overwritten.
- Isolation creates timestamped backups, patches, reports and a run log.
- Use `--precheck-only` before production changes.
- Review storage accessibility and target-node capacity before migration.

## Scope notes

MAS environments vary. JMS and AppConfig/Graphite are optional. Manage may use `ALL` or split bundles such as UI, MEA, CRON and REPORT; some environments may have no Manage runtime workload. Supporting operators/controllers are evaluated separately from application placement.

## Documentation

Start with:
- [Installation](install/README.md)
- [Discovery](docs/DISCOVERY.md)
- [Isolation](docs/ISOLATION.md)
- [Validation](docs/VALIDATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Examples](examples/README.md)

## Disclaimer

Test in a non-production environment first. Review generated backups and reports, OpenShift RBAC, storage behavior, workload capacity and IBM MAS version-specific behavior before production use.
