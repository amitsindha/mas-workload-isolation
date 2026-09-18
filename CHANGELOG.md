# Changelog

## Isolation V4.1.1
- Added retry protection for transient OpenShift API/query failures during MongoDB stabilization.
- Uses the configured 300-second request timeout for protected MongoDB status queries.
- A temporary API failure is logged and retried; the overall operation timeout remains the final failure boundary.
- Stable `scripts/isolation/mas-workload-isolation.sh` now points to V4.1.1.


## Toolkit refresh
- Added stable versionless entry points.
- Added Discovery v1.5.
- Added Isolation V4.1.
- Added Validation V1.0.
- Added local-to-pod toolkit installer.
- Added AppConfig/Graphite awareness.
- Added dynamic Manage runtime topology guidance.
- Added read-only independent post-migration validation.

## Isolation V4.1
- No cluster mutation before explicit YES confirmation.
- 300-second OpenShift API request timeout.
- Migration progress visibility.
- Optional AppCfg/Graphite isolation and validation.

## Discovery v1.5
- AppConfig/Graphite discovery.
- Dynamic Manage runtime topology.
- Ownership and affinity reporting.
- Isolation-readiness summary.

## Validation V1.0
- Read-only target-label and workload placement validation.
- Application vs supporting/operator classification.
