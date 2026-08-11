# Capture timing instrumentation — archive only

This branch preserves the temporary kernel-driver probes used to isolate the
restart-dependent capture latency observed by OnTimeCM.

## Status

**Diagnostic archive. Not intended for merge or production deployment.**

The validated production correction is intentionally smaller and lives in
`agent/fix-capture-sac-repeatability`. That branch only re-derives the capture
jitter-buffer position from an atomic SAC snapshot on each PTP TIC and adds
the persistent module/Butler installer.

## Experiments preserved here

- capture SAC, jitter-buffer and TIC snapshots exposed through a read-only
  module parameter;
- PTP-to-monotonic and optional experimental `CLOCK_TAI` timeline comparison;
- RX software/hardware timestamp propagation for diagnostic correlation;
- TIC period, servo and lock-state telemetry;
- the module activation helper and the userspace `ravenna-clock-probe.cpp`.

Several experiments in this branch were rejected as production solutions.
In particular, deriving the driver timeline directly from `CLOCK_TAI` caused
ALSA failures (`Broken pipe`) and is retained only to document the negative
test. None of these probes performs latency filtering or compensation.

## Reproduction warning

The activation helper unloads and reloads a locally built kernel module. It
requires all ALSA users to be closed, must match the running kernel, and is
for a controlled diagnostic host only. Do not install this branch through the
persistent production installer.

The read-only userspace probe can be built with:

```bash
g++ -std=c++17 -O2 tools/ravenna-clock-probe.cpp -o /tmp/ravenna-clock-probe
```
