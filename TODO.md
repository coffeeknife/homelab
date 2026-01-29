# TODO

## Alertmanager Configuration Issue

**Location:** `monitoring/prometheus`

**Error:**
```
undefined receiver "null" used in route
```

**Description:** The alertmanager configuration references a receiver named "null" that is not defined. This causes repeated errors in the prometheus-operator logs.

**Action Required:** Review and fix the alertmanager configuration in `apps/monitoring/prometheus/manifests/values.yaml` to either:
1. Define the "null" receiver
2. Remove/update the route that references it
