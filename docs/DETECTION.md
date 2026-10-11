# SPARTA DE-0012 - Component Collusion: Detection Strategies

This document is the tactical companion to the live demo. The attack we ran
against stock NASA cFS worked because two "COTS" apps used *raw* Linux IPC
( a named FIFO + an anonymous UDP socket ) instead of the cFS Software Bus and
OSAL file layer. Below are four complementary detection angles that would have
caught this, ordered from easiest-deploy to flight-grade.

---

## 1. Runtime /proc filesystem audit (deploy today)

Every object a cFS app opens through **OSAL** (`OS_open`, `OS_ModuleLoad`,
`OS_socket`) gets registered in `OS_object_table` and shows up as a known
file path like `/cf/...`. A raw `open()` + `mkfifo()` bypasses that.

**Primitive:** enumerate `/proc/<pid>/fd`; anything that is a FIFO or an
anonymous socket and is *not* in the OSAL path list is collusion fuel.

    ./detector.py -p $(pgrep -f core-cpu1) --exe-dir build-native_std/exe/cpu1

Positive hi for the lab: a FIFO named `.startracks` owned by the cFS task
pair plus a UDP socket to `127.0.0.1:50001` that never appeared pre-trigger.

## 2. Static image scan (flight-readiness / pre-shipment)

Scan the deployed `cf/` tree **before** flight:

    ./detector.py --image build-native_std/exe/cpu1 --static

Anything that is (a) `stat.S_ISFIFO`, or (b) a dot-file under `cf/`, or
(c) any `*.so` whose `strings` contain `mkfifo`/`socket(AF_UNIX` is suspect.
There is no benign cFS driver use-case for FIFOs in the current app catalog.

## 3. Syscall-level observability (eBPF / strace / Linux seccomp-bpf)

cFS native builds make thousands of OSAL calls; benign apps do **not** call
`mkfifo`, `socket(AF_UNIX,...)`, or `sendto()` on unknown destinations.
Attach a one-liner:

    strace -tt -e trace=mkfifo,openat,socket,connect,sendto -p $(pgrep -f core-cpu1)

For flight: add a seccomp-bpf profile to the PSP to block `mkfifo` for any
task except a whitelisted `IO_DRIVER`. The eBPF equivalent that survives
the RT patches is `bpftrace` on `syscalls:sys_enter_mkfifo`.

## 4. Anomaly-on-baseline telemetry (HS event pattern)

Classic HS/HK baselines watch message *counts*. DE-0012 evades that because
the covert byte never becomes a SB message. Fix by baselining **per-task
graphs**: tasks that historically send only HK should not begin emitting
socket syscalls after a GNSS event. The `state=POST-TRIGGER` transitions in
`hk_diag` are the perfect synthetic alert.

```python
# pseudocode for an "hs_ext" plugin
if task.event_stream has Event 6 ("extended calibration mode"):
    compare last 24h : if task has 0 socket syscalls before Event,
                    raise DE-0012 anomaly
```

## 5. Architecture-level controls (what "fix" means)

| Control                     | Effect on DE-0012                                  |
|-----------------------------|----------------------------------------------------|
| SB message allow-list per app | blocks any new covert MID                        |
| OSAL-only file API (seccomp)  | kills FIFO bypass; raw syscalls denied           |
| Module signature + SB manifest| unknown .so or unsign.MID pair never registers   |
| HW IOMMU + eBPF LSM          | device-tree scoped FIFO writes only               |
| SB audit log to ground        | any delta from ground truth = alarm               |

The lab in `run_demo.sh` demonstrates #1, #2 and #3 live. Points of contact:
`cfs_security@list.nasa.gov` / project disclosure process.
