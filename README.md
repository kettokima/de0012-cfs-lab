# DE-0012 Lab — Component Collusion on NASA cFS

A hands-on security-research lab demonstrating **SPARTA matrix technique
DE-0012 (Component Collusion)** — defense evasion via fragmented malware
logic — against NASA's open-source [Core Flight Software (cFS)](https://github.com/nasa/cFS),
built and run entirely on your own machine as a simulation.

> **What this is:** an educational / defensive-research demonstration for a
> conference talk and workshop. Everything runs on localhost against
> open-source, publicly available software. The "RF downlink", "GNSS feed"
> and "ground station" are all local simulations (UDP / unix sockets).
> Detection is a first-class deliverable: the lab ships the scanner that
> catches the technique it demonstrates. No real spacecraft, no real
> infrastructure, nothing leaves your machine.

> **Credit where due — the technique is not ours.** Component Collusion
> (SPARTA DE-0012) was invented and registered in the SPARTA matrix by the
> authors of **"SpyChain: Multi-Vector Supply Chain Attacks on Small
> Satellite Systems"** (Vanlyssel, Sobrados, Anwar, Roman, Anwar —
> [arXiv:2510.06535](https://arxiv.org/abs/2510.06535)). This lab is an
> **open, reproducible implementation and hardening** of their Scenario 5,
> with these deltas: cryptographic fragment recombination (XOR halves)
> instead of plain command strings, a true geofence + epoch gate trigger,
> bounded exfil with reset-to-dormant, a standalone blue-team detector,
> and a workshop format. SpyChain deliberately published no exploit code;
> this lab is simulation-scoped (open-source target, localhost only) and
> detection-first. If you use this lab, cite SpyChain.

## The technique in one paragraph

Two individually-benign "COTS catalog" apps ship with the flight software.
A star-tracker utility watches GNSS and, when the spacecraft crosses a
Svalbard geofence (a condition that never occurs in ground test), writes a
single **fragment byte** to a hidden OS FIFO — not the cFS Software Bus. A
diagnostics utility holds the complementary fragment since boot; the XOR of
both reconstructs the activation key. Neither app contains a reviewable
"malicious instruction"; the capability exists **only at the combination**.
A bounded telemetry burst follows during the "pass window", then the state
resets to dormant. Software-Bus monitoring sees none of it; OS-level
artifacts tell the whole story.

Full phase-by-phase narrative: [`KILLCHAIN.md`](docs/KILLCHAIN.md).
Detection strategies: [`DETECTION.md`](docs/DETECTION.md).

## Quick start (Linux, ~10 min first build)

```bash
./setup.sh                    # clones NASA cFS, overlays lab apps, builds
./healthcheck.sh              # sanity check
(setsid ./lab_launch.sh > /dev/null 2>&1 < /dev/null &)   # run the demo
# browser: http://127.0.0.1:8051   (ground-vs-attacker dashboard)
```

Expected evidence (see [`docs/README.md`](docs/README.md) for the full map):

```
ST_TRK  6: attitude solution converged (DL)        <- Svalbard trigger
HK_DIAG 6: entered extended calibration mode       <- fragment assembled (XOR)
        ... 32 exfil packets to the attacker view ...
HK_DIAG 7: calibration cycle complete              <- reset to dormant
```

...while the cFS event log and Software Bus stay completely nominal.

## Prerequisites

- Linux x86_64 (tested on Debian/Kali), ~2 GB free disk
- `git`, `gcc`, `make`, `python3` + `python3-venv`
- cmake not required — the setup installs it into a local venv

## Repo layout

| Path | What |
|---|---|
| `setup.sh` | one-shot attendee setup (clone, overlay, build, install) |
| `lab-apps/` | the two colluding cFS apps (st_app, hk_diag) — readable, commented |
| `mission/` | cFS mission-config overlays (targets, startup script template) |
| `scripts/` | demo orchestration, GNSS sim, exfil receiver, detector, dashboard |
| `docs/` | KILLCHAIN.md, DETECTION.md, runbook |

After `setup.sh`, the repo root also contains the runnable scripts and docs,
plus `cFS/` (NASA cFS clone with our apps overlaid).

## Workshop exercises

1. **Run it**: `run_demo.sh`, watch the dashboard, map each event to a
   KILLCHAIN.md phase.
2. **Read it**: find the collusion in `lab-apps/*/fsw/src/*.c` — locate the
   fragment write, the XOR gate, the lazy socket.
3. **Detect it**: run `detector.py` (dynamic + static). Then write your own
   rule — e.g. flag any HK packet whose payload entropy/size deviates from
   baseline, or any FIFO created by a cFS task. Test against the live lab.

## Credits & licensing

- **SpyChain (arXiv:2510.06535)** — origin of the DE-0012 Component Collusion
  technique reproduced here. Read the paper; cite it.
- NASA cFS and its components: Apache-2.0 / NASA open-source agreements —
  see `cFS/` after setup. This lab only adds two apps and configuration.
- Lab code and docs: Apache-2.0 (this repository).
- SPARTA matrix reference: The Aerospace Corporation (public aerospace
  security framework).

## Responsible use

For education and defensive research only. Do not deploy against systems
you do not own. The value of this lab is the detection half — if you
integrate cFS or review flight software, use DETECTION.md as a checklist.
