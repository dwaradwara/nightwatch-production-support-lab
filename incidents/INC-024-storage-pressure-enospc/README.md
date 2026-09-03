# INC-024 — Storage Pressure / ENOSPC

## Summary

A controlled storage-capacity incident was reproduced using a temporary 64 MB filesystem.

The filesystem was intentionally filled to approximately 94% utilization, after which an additional write exhausted the remaining capacity and failed with:

```text
No space left on device
```

The test was isolated from NIGHTWATCH application and database volumes so the actual lab environment was not put at risk.

## Baseline

The temporary filesystem started healthy:

```text
Filesystem  Size   Used  Available  Use%
tmpfs       64M    0     64M        0%
```

The real NIGHTWATCH API and PostgreSQL filesystems had substantial free capacity, so intentionally filling them would have been unnecessary and unsafe.

## Failure Injection

A 60 MB file was created:

```bash
dd if=/dev/zero of=/incident/fill.bin bs=1M count=60
```

Filesystem utilization increased to:

```text
Filesystem  Size   Used  Available  Use%
tmpfs       64M    60M   4M         94%
```

An additional 10 MB write was then attempted.

## Observed Failure

The write failed with:

```text
dd: error writing '/incident/overflow.bin': No space left on device
```

Only 4 MB of the requested write could be completed before the filesystem reached capacity.

## Investigation

### 1. Verified capacity pressure

`df -h` showed the filesystem at approximately 94% utilization before the failed write.

### 2. Confirmed ENOSPC

The decisive operating-system error was:

```text
No space left on device
```

This distinguished storage exhaustion from permission failures, network errors, application validation errors, container crashes, and database failures.

### 3. Isolated the test environment

The incident used a temporary constrained `tmpfs` rather than filling NIGHTWATCH's real Docker storage. This allowed ENOSPC behavior to be reproduced without risking application or database data.

## Root Cause

The temporary filesystem exhausted its available capacity. Once no additional blocks were available, further writes failed with an ENOSPC condition.

## Resolution

The generated files were removed:

```bash
rm -f /incident/fill.bin /incident/overflow.bin
```

Filesystem utilization returned to:

```text
Filesystem  Size   Used  Available  Use%
tmpfs       64M    0     64M        0%
```

A subsequent 5 MB write succeeded:

```text
5242880 bytes (5.0MB) copied
```

Final utilization was approximately:

```text
Filesystem  Size   Used  Available  Use%
tmpfs       64M    5M    59M        8%
```

This confirmed that storage capacity and write functionality were restored.

## Preventive Actions

- Alert on filesystem utilization before critical thresholds are reached.
- Monitor both percentage usage and absolute free space.
- Monitor inode exhaustion separately from block-space exhaustion.
- Use log rotation and retention policies.
- Monitor Docker image, container, and volume growth.
- Identify unexpectedly large files before deleting data.
- Maintain storage cleanup and capacity-expansion runbooks.
- Avoid emergency cleanup actions that could remove application or database data.
- Validate successful writes after storage recovery.

## Support Skills Demonstrated

- Linux filesystem troubleshooting
- Disk-capacity analysis
- ENOSPC diagnosis
- `df` interpretation
- Controlled failure reproduction
- Storage recovery validation
- Risk-aware incident testing
- Root-cause isolation

> This incident was intentionally reproduced in a disposable training environment. It is portfolio evidence and not employer production experience.
