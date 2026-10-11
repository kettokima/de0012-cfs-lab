# DE-0012 Lab — README (runbook)

Live lab demonstrating SPARTA DE-0012 (Component Collusion) against NASA cFS.
Canonical narrative: `KILLCHAIN.md`. Session continuity: `HANDOFF.md`.

## Quick start

```bash
cd /home/kali/de0012-lab
./healthcheck.sh                      # sanity: artifacts, venv, semantics
(setsid ./lab_launch.sh > /dev/null 2>&1 < /dev/null &)   # full demo (~45 s)
# browser: http://127.0.0.1:8051      # dashboard: ground vs attacker split view
# evidence: logs/<newest>/ + exfil_received.jsonl (32 pkts)
```

Instant-trigger variant (Q&A): `python3 gnss_sim.py --attack`

## What the demo proves

Two "COTS" apps (ST_TRK star-tracker, HK_DIAG diagnostics) ship benign,
pass review, emit plausible HK on the Software Bus. On a Svalbard pass
(78.23N/15.39E ±5°) ST_TRK writes fragment 0x18 to a hidden FIFO
(/cf/de0012/.startracks). HK_DIAG holds 0x2A since boot; XOR = 0x32 assembles
the activation key — the capability exists only at combination. A bounded
32-packet exfil burst follows, then reset-to-dormant. The Software Bus sees
NONE of it: no routes, no messages, benign events only. detector.py catches
the residue (FIFO statically, anonymous sockets dynamically).

## Phase → evidence map

| Phase (KILLCHAIN.md) | Where to see it |
|---|---|
| I–II dormant, plausible HK | cfs_console.log: benign EVS + HK on SB |
| III Svalbard trigger | `ST_TRK 6: attitude solution converged (DL)` |
| IV fragment handoff | cf/de0012/.startracks (prw-------) |
| V assembly | `HK_DIAG 6: entered extended calibration mode` |
| VI bounded exfil | exfil_received.jsonl — exactly 32 lines |
| IX reset | `HK_DIAG 7: calibration cycle complete` |
| Detection | detector.out + `--static` exit 2 |

Expected evidence lines (last verified logs/20261010_205522):
`ST_TRK 6` → `HK_DIAG 6` (~0.4 s later) → 32 pkts (~5 s) → `HK_DIAG 7`.

## Build from scratch (only if sources changed)

```bash
cd cFS && source ../.venv/bin/activate
make native_std.compile native_std.install
```
(Never `make SIMULATION=native`. Config = native_std, MISSIONCONFIG=cfs.)

## Tools

| Tool | Purpose |
|---|---|
| `run_demo.sh` | full orchestration: cFS + GNSS sim + exfil rx + dashboard + detector |
| `dashboard.py` | :8051 browser console — LEFT ground view (green), RIGHT attacker (red), phase tracker |
| `detector.py` | `-p PID --exe-dir ...` dynamic / `--image ... --static` static; exit 2 = findings |
| `gnss_sim.py` | NMEA track to Svalbard; `--attack` = instant |
| `exfil_rx.py` | attacker GS on UDP 50001 |
| `healthcheck.sh` | session-start sanity |
| `lab_launch.sh` | detached launcher (survives terminal death) |

## Talk/workshop formats

- 30-min talk: prerecorded clips (record_clips.sh — see HANDOFF TODO). Phases I–VI, IX onboard; VII/VIII/X slides only.
- 1.5-h workshop: run_demo → source walk (find the collusion) → detector exercises → attendees write a detection rule.

## Safety scope

Everything localhost under /home/kali/de0012-lab; open-source NASA cFS;
simulated RF = UDP loopback; no real GNSS/RF hardware; web3/testnet = slides
only. Educational PoC for the DE-0012 talk/workshop with detection as a
first-class deliverable.
