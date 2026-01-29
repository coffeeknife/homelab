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

## Longhorn Volume Attachment Issue - LidaTube

**Volume:** `pvc-216ca943-1e92-4ecb-b5fa-1e021caca08f`

**Issue:** Volume stuck in "attaching" state, preventing lidatube pod from starting.

**Error:**
```
AttachVolume.Attach failed for volume "pvc-216ca943-1e92-4ecb-b5fa-1e021caca08f": rpc error: code = DeadlineExceeded
```

**Action Required:**
1. Check Longhorn UI for volume health
2. May need to force-detach the volume in Longhorn
3. Consider recreating the PVC if data is not critical
