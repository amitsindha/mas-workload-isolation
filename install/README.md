# Toolkit Installation

This installer creates a persistent MAS CLI workspace in OpenShift and copies the **local** toolkit project into it. It does not clone or download the toolkit from GitHub.

## Prerequisites

- `oc` CLI on the developer workstation
- Network connectivity to the OpenShift API
- Valid OpenShift credentials
- Privileges to create the toolkit namespace and ClusterRoleBinding
- A local extracted/checked-out copy of this toolkit
- `tar` on the workstation (standard on macOS/Linux)

## Install

From the project root:

```bash
chmod +x install/install-toolkit.sh
./install/install-toolkit.sh
```

If no active `oc` session exists, the installer prompts for the OpenShift API URL, username and password. Password input is hidden. By default the login accepts an untrusted/self-signed API certificate with `--insecure-skip-tls-verify=true`. To require certificate verification:

```bash
MAS_TOOLKIT_INSECURE_TLS=false ./install/install-toolkit.sh
```

The installer applies `install/mas-toolkit-resources.yaml`, waits for the MAS CLI Deployment, copies the local project to `/mascli/mas-workload-isolation`, makes toolkit scripts executable, and opens an interactive shell in that directory.

## Persistent workspace

The MAS CLI Deployment mounts a 10 Gi PVC at `/mascli`, so toolkit files and generated reports under that mount survive pod recreation.

## Security note

The supplied YAML creates a dedicated service account with `cluster-admin`, because the isolation workflow performs cluster-level node and workload-placement changes. Review this RBAC with the customer's OpenShift security team before production use. The installer never writes the entered password to a toolkit log.

## Re-run

Re-running the installer applies the same resources and refreshes `/mascli/mas-workload-isolation` from the local project copy. Other content under `/mascli` is not removed.
