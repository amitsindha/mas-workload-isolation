# Validation

`mas-workload-isolation-validation.sh` is read-only and is intended to provide independent post-migration evidence.

It validates:
- target node labels;
- MAS Core placement;
- optional AppConfig/Graphite placement;
- Manage placement;
- SLS application placement;
- MongoDB member placement.

Supporting controllers/operators are reported separately from application placement.

The output directory contains `VALIDATION-REPORT.txt` and `validation.log`.
