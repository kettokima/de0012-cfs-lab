# DE-0012 Component Collusion — Finalized Kill Chain (canonical narrative)

The definitive version, merging the abstract + 7-stage logic + Svalbard + Web3 C2 + multi-GS leverage.
Status column = what the lab actually demonstrates vs. what is slides-only.

---

## Phase I — Supply chain implant (pre-launch, invisible)
A malicious fragment ships inside a benign COTS catalog component (star-tracker utility). Flight-readiness review passes it: individually it does nothing wrong, emits plausible ADCS/HK telemetry. The malware's *other half* ships in a second, unrelated COTS component (diagnostics utility) — reviewed by a different reviewer. **The capability does not exist in either app's reviewable logic; it exists only in their combination.**

**Lab:** st_app ("StarTracker Toolkit") + hk_diag ("HK Diagnostics") ship as normal .so modules in cf/, loaded by cfe_es_startup.scr. Both pass review — plausible HK, benign events. ✅ BUILT

## Phase II — Dormant (LEO ops, weeks)
Both fragments run nominally. SB baselines record them as quiet-but-plausible apps. The trigger's environmental gate — GNSS geofence over Svalbard (78.23N, 15.39E, ±5°) + epoch gate — can *never* be satisfied on the ground or in flat-sat test: the condition only becomes true in the operational orbit. Every sun-sync orbit overflies the fence ~14×/day — the attacker needs only patience.

**Lab:** both apps send plausible HK on the SB; fence is Svalbard; epoch gate present. ✅ BUILT

## Phase III — Trigger evaluation (local, zero side effects)
Fragment A parses GNSS locally (raw AF_UNIX socket, not SB), compares lat/lon against the fence. Pure local computation — bus-level monitoring sees nothing. No message, no event, no counter moves.

**Lab:** ST_ParseRMC + ST_CheckTrigger, verified. ✅ BUILT

## Phase IV — Local handoff (the collusion moment)
Condition met → A writes a **fragment** — not a command, an incomplete half-key (0x18) — to a hidden FIFO (/cf/de0012/.startracks) via raw syscalls. B has held the complementary fragment (0x2A) since boot. **Neither fragment alone means anything; only the combination (XOR = 0x32) reconstructs the activation key.** The handoff rides an OS-level IPC channel that SB baselining was never scoped to watch.

**Lab:** verified — trigger fires, byte crosses FIFO, B assembles key. ✅ BUILT

## Phase V — Assembly & action (onboard)
B combines fragments → complete instruction → stages the exfil payload. No new SB subscription, no new MID, nothing for HS/HK counters to trip on.

**Lab:** HKD_CheckCovert XOR gate → HkdActive. ✅ BUILT

## Phase VI — Blended exfil (RF downlink during Svalbard pass)
B embeds the payload inside its legitimate telemetry stream riding the normal downlink during the Svalbard contact window — the one time a burst is *expected*. The ground station accepts it as normal (or "slightly alert, it's fine"): traffic pattern, timing, and format all match the baseline. Exfiltration is indistinguishable from ops by construction.

**Lab (honest version):** exfil is a bounded 32-packet burst (8 frames × 4 keys) on a separate UDP socket gated to the pass — timing-correlation demonstrated; **CCSDS blending into the real TO_LAB downlink NOT built** (slides: "stronger variant"). ◐ PARTIAL

## Phase VII — Ground pivot (the inversion)
The satellite was never the prize — it's the delivery vehicle. The GS data pipeline processes the blob; a trust-boundary failure in a ground parser executes/installs relay logic *inside the ground station*. The beacon is ordinary HTTPS egress to a blockchain RPC endpoint — indistinguishable from the GS's constant legitimate API traffic (TLE fetches, weather, orbit data). It posts a C2 hash/data chunk to a smart-contract dead-drop on a testnet chain.

**Lab:** NOT built (scope decision — slides with real threat-research citations; simulate as "naive parser trusts a TLM field"). ❌ SLIDES ONLY

## Phase VIII — C2 via dead-drop (attacker side)
Attacker reads the chain passively — no infrastructure to seize, no endpoint to block, takedown-resistant by design. Instructions flow back the same way: posted on-chain, relayed up through the GS's legitimate command path. The immutable ledger is also the attacker's one big mistake — a permanent public forensic record.

**Lab:** NOT built (slides; local anvil + ~20-line dead-drop contract was scoped but cut for time). ❌ SLIDES ONLY

## Phase IX — Reset to dormant (imperfect)
Onboard state clears, latch resets. But cleanup is never perfect — the persistent FIFO artifact, post-trigger socket timing, ledger entries: exactly the residue OS-level detection catches. Deliberate teaching moment.

**Lab:** built and verified — `calibration cycle complete` clears the latch after the burst; the FIFO persists on disk and detector.py flags it statically + the sockets dynamically. ✅ BUILT (the imperfection is the detection story)

## Phase X — Strategic leverage (the close)
One compromised COTS component, integrated by *many missions* (supply chains converge on few vendors). Each infected satellite overflies multiple shared ground stations (KSAT-style networks serve 100+ missions per site). **One implant → N satellites → M ground stations → an entire ground segment**, quietly, over weeks. The kill chain isn't an attack on a satellite; it's a worm through the space ecosystem's trust graph.

**Lab:** slides only (constellation→GS map visual). ❌ SLIDES ONLY

---

## Dual-track overlay (the slide that IS the workshop)

| Stage | SB-only monitoring sees | OS-level monitoring sees |
|---|---|---|
| I–II Dormant | Plausible apps ✓ | Plausible apps ✓ |
| III Trigger | **Nothing** | GNSS parse loop (local CPU) |
| IV FIFO handoff | **Nothing** | mkfifo/write on dot-file ✓ |
| V Assembly | **Nothing** | process state change |
| VI Blended exfil | **Normal downlink ✓** | normal socket use — payload inspection needed |
| VII GS pivot | n/a (ground IT) | GS egress to RPC ✓ |
| VIII Chain C2 | n/a | public ledger (subpoena-able) ✓ |

**Lab evidence for the overlay:** zero CFE_SB routes between ST_TRK↔HK_DIAG, zero CFE_SB_TransmitMsg on the covert path, benign EVS log throughout; detector.py catches FIFO (static) + anonymous sockets (dynamic). Verified logs/20261010_205522.

---

## Formats
- **30-min talk:** prerecorded clips only. Clips 1–6 from onboard phases (I–VI, IX); VII/VIII/X as slides with citations.
- **1.5h workshop:** attendees run run_demo.sh, source-walk the collusion, run detector.py, write their own detection rule (exercise).
