# IBM MAS Workload Isolation Toolkit

OpenShift toolkit for IBM Maximo Application Suite workload discovery, controlled worker-node isolation, and independent post-migration validation.

**Workflow:** Install → Discover → Review / Plan → Isolate → Validate

## Stable commands
```bash
./scripts/discovery/mas-cluster-discovery.sh
./scripts/isolation/mas-workload-isolation.sh
./scripts/validation/mas-workload-isolation-validation.sh
```

## Stable versions
| Component | Version |
|---|---|
| Discovery | v1.5 |
| Isolation | V4.1.1 |
| Validation | V1.0 |

## Components
`--components` accepts `mas`, `sls`, `mongodb`, `db2`, or a comma-separated combination.

- `mas` — MAS Core/Manage CR pod templates, workspace, MAXINST, server bundles, build selectors and applicable OLM placement.
- `sls` — SLS API placement using LicenseService pod templates.
- `mongodb` — MongoDBCommunity affinity, generated StatefulSet affinity and member placement.
- `db2` — validated IBM MAS Manage Db2U scope.

AppConfig/Graphite is optional. JMS and `ALL` are not assumed. ManageServerBundles are discovered dynamically.

## Installation
```bash
chmod +x install/install-toolkit.sh
./install/install-toolkit.sh
```
The installer creates a persistent MAS CLI workspace and copies the local toolkit into `/mascli/mas-workload-isolation`.

## Discovery
```bash
./scripts/discovery/mas-cluster-discovery.sh
```
Discovery is read-only. Review `REPORT.html` before building isolation commands.

## Isolation model
```text
Discover → Precheck → Capacity/health → Compare current vs desired
  → COMPLIANT: skip unnecessary change, validate
  → DRIFT: backup → patch → reconcile
  → PASS / WARNING / FAIL
```
Run `--precheck-only` first in customer environments.

## Parameter reference
| Parameter | Required | Scope | Meaning |
|---|---|---|---|
| `--components` | Yes | All | `mas`, `sls`, `mongodb`, `db2`, or combination |
| `--instance` | MAS | MAS | MAS instance ID |
| `--core-namespace` | MAS | MAS | Core namespace |
| `--manage-namespace` | MAS | MAS | Manage namespace |
| `--workspace` | No | MAS | Workspace suffix; default `maximo`; e.g. `mref` |
| `--label-key` | No | App targets | Default `workload-group` |
| `--label-value` | Yes* | App targets | Desired label value |
| `--allowed-nodes` | Yes* | App targets | Comma-separated worker pool |
| `--sls-namespace` | SLS | SLS | LicenseService namespace |
| `--mongodb-namespace` | MongoDB | MongoDB | MongoDB namespace |
| `--mongodb-name` | No | MongoDB | Default `mas-mongo-ce` |
| `--mongodb-stable-checks` | No | MongoDB | Default 3 |
| `--db2-namespace` | DB2 | DB2 | Manage Db2U namespace |
| `--db2-label-key` | No | DB2 | Default `workload-group` |
| `--db2-label-value` | DB2 | DB2 | DB2 label value |
| `--db2-allowed-nodes` | DB2 | DB2 | DB2 worker pool |
| `--db2-stable-checks` | No | DB2 | Default 3 |
| `--mas-instances` | No | MAS | `auto` or comma-separated inventory scope |
| `--placement-plan` | No/repeatable | MAS | Global worker ownership planning guard |
| `--precheck-only` | No | All | Read-only precheck |
| `--dry-run` | No | All | Validate intended changes without normal apply |
| `--auto-label` | No | App targets | Add missing labels after confirmation; default |
| `--no-auto-label` | No | App targets | Require labels to exist |
| `--force-reapply` | No | All | Reapply compliant configuration |
| `--yes` | No | All | Skip interactive confirmation |
| `--external-db` | No | MAS | Manage database external to OpenShift |
| `--skip-capacity-precheck` | No | MAS | Disable capacity gate |
| `--min-cpu-headroom-pct` | No | MAS | Default 15 |
| `--min-mem-headroom-pct` | No | MAS | Default 15 |
| `--resume-from` | No | MAS | Phase-resume interface argument |

*Required when MAS/SLS/MongoDB targets are selected.

### Environment
```text
POLL_INTERVAL=20
TIMEOUT=1800
OC_REQUEST_TIMEOUT=300s
```

## Node-label behavior
Missing labels are planned during precheck and applied only after explicit confirmation. Conflicting existing values are never overwritten.

## Artifacts
Every isolation run creates timestamped `backups/`, `patches/`, `reports/`, and `run.log`.

## Results
- **PASS** — application placement and health succeeded.
- **WARNING** — application isolation passed; supporting/operator exceptions need review.
- **FAIL** — blocking health, scheduling, placement or timeout validation failed.

## Documentation
- [Installation](install/README.md)
- [Discovery](docs/DISCOVERY.md)
- [Isolation](docs/ISOLATION.md)
- [Technical design](docs/TECHNICAL-DESIGN.md)
- [Validation](docs/VALIDATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Examples](examples/README.md)
