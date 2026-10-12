#!/usr/bin/env bash
# record_clips.sh - guided capture of the 6 prerecorded talk clips.
#
# Not a screen recorder itself: it ORCHESTRATES each clip's timeline
# (start processes, hold for narration, fire the trigger, stop) while you
# record the screen with OBS. Each clip prints a big banner when to hit
# record and when the clip's timeline is done.
#
# Usage:
#   ./record_clips.sh            # run all 6 clips sequentially
#   ./record_clips.sh 3          # run only clip 3
#   DRYRUN=1 ./record_clips.sh   # print timeline without side effects
#
# Clips (match KILLCHAIN.md phases):
#   1  I-II   Boot + dormant: benign startup, plausible HK, benign log
#   2  III    Svalbard approach: gnss feed walks north, app stays quiet
#   3  IV-V   The handoff: fence entry, FIFO byte, fragment assembly
#   4  VI     Exfil burst: attacker pane fills, ground pane stays green
#   5  IX     Reset: cycle complete, back to dormant, residue remains
#   6  DET    Detection: static scan finds FIFO, dynamic flags sockets
#
# Manual control during recording (gnss_sim --approach):
#   kill -USR1 $(pgrep -f 'gnss_sim.py --approach')   # satellite ENTERS fence
#   kill -USR2 $(pgrep -f 'gnss_sim.py --approach')   # satellite LEAVES fence (re-arm)
# Each USR1/USR2 cycle = one orbital pass = one full trigger->exfil->reset.
# Repeatable: flubbed a take? USR2 to reset, USR1 to go again.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
EXE="$LAB/cFS/build-native_std/exe/cpu1"
CLIPS_DIR="$LAB/clips"
DRYRUN="${DRYRUN:-0}"
RUN_ONLY="${1:-all}"

banner() { echo; echo "=============================================================="; echo "== $1"; echo "=============================================================="; }
note()   { echo "  [$1]"; }

stop_all() {
  pkill -f gnss_sim.py  2>/dev/null || true
  pkill -f exfil_rx.py  2>/dev/null || true
  pkill -f dashboard.py 2>/dev/null || true
  pkill -f core-cpu1    2>/dev/null || true
  sleep 1
}

boot_cfs() {   # starts cFS + exfil rx + dashboard on a FRESH session logdir
  SESSLOG="$LAB/logs/recording_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$SESSLOG"
  rm -f "$LAB/exfil_received.jsonl"     # clean exfil view for the recording
  (cd "$LAB" && (setsid python3 exfil_rx.py > "$SESSLOG/exfil_rx.log" 2>&1 < /dev/null &))
  (cd "$LAB" && (setsid "$LAB/.venv/bin/python" dashboard.py --logdir "$SESSLOG" > "$SESSLOG/dashboard.log" 2>&1 < /dev/null &))
  (cd "$EXE" && (setsid stdbuf -oL ./core-cpu1 -C PO_BSP_SLEEP_USEC=1000 > "$SESSLOG/cfs_console.log" 2>&1 < /dev/null &))
  echo "$SESSLOG" > /tmp/rc_session_logdir
  note "waiting for cFS OPERATIONAL..."
  for i in $(seq 1 30); do
    grep -q "entering OPERATIONAL state" "$SESSLOG/cfs_console.log" 2>/dev/null && break
    sleep 1
  done
  sleep 2
  note "cFS up: $(grep -c 'EVS Port1' "$SESSLOG/cfs_console.log") events so far"
  note "session logdir: $SESSLOG"
}

session_log() { cat /tmp/rc_session_logdir 2>/dev/null || echo "$LAB/logs/recording_latest"; }

want() { [ "$RUN_ONLY" = "all" ] || [ "$RUN_ONLY" = "$1" ]; }

mkdir -p "$CLIPS_DIR"
stop_all

# ---------------------------------------------------------------- clip 1 --
if want 1; then
banner "CLIP 1 (I-II): BOOT + DORMANT — record ~20s"
note "SHOW: terminal with cFS boot; dashboard :8051 ground pane (green, benign events)"
note "SAY: two COTS catalog apps load like any other - review passed, telemetry plausible"
[ "$DRYRUN" = 1 ] && exit 0
boot_cfs
note "HOLD ~15s: benign HK events, no-op commands, dashboard DORMANT phase"
sleep 15
note "clip 1 timeline done — stop recording"
stop_all
fi

# ---------------------------------------------------------------- clip 2 --
if want 2; then
banner "CLIP 2 (III): SVALBARD APPROACH — record ~20s"
note "SHOW: gnss_sim --approach terminal (walking north) + cFS log (silent)"
note "SAY: GNSS parse is local-only; the SB sees nothing at all"
[ "$DRYRUN" = 1 ] && exit 0
boot_cfs
(cd "$LAB" && (setsid python3 gnss_sim.py --approach > "$(session_log)/gnss_sim.log" 2>&1 < /dev/null &))
sleep 6
note "HOLD ~10s: satellite approaching, ground pane stays green, phase=DORMANT"
sleep 10
note "clip 2 timeline done — stop recording (leave everything running for clip 3)"
fi

# ---------------------------------------------------------------- clip 3 --
if want 3; then
banner "CLIP 3 (IV-V): THE HANDOFF — record ~15s"
note "SHOW: cFS log + dashboard phase tracker; fire trigger with kill -USR1"
note "SAY: fence entry writes one fragment byte to a hidden FIFO - not the Software Bus"
[ "$DRYRUN" = 1 ] && exit 0
GNSS_PID=$(pgrep -f 'gnss_sim.py --approach' | head -n1)
if [ -z "${GNSS_PID:-}" ]; then
  note "approach sim not running (clip 3 run standalone) - booting fresh"
  boot_cfs
  (cd "$LAB" && (setsid python3 gnss_sim.py --approach > "$(session_log)/gnss_sim.log" 2>&1 < /dev/null &))
  sleep 8
  GNSS_PID=$(pgrep -f 'gnss_sim.py --approach' | head -n1)
fi
kill -USR1 "$GNSS_PID"
note "TRIGGER FIRED - watch for: 'attitude solution converged' then 'extended calibration mode'"
sleep 8
note "clip 3 timeline done — stop recording"
fi

# ---------------------------------------------------------------- clip 4 --
if want 4; then
banner "CLIP 4 (VI): EXFIL BURST — record ~15s"
note "SHOW: dashboard split-screen: ground pane green / attacker pane filling red"
note "SAY: 32 packets in the pass window; ground telemetry never shows it"
[ "$DRYRUN" = 1 ] && exit 0
note "(runs right after clip 3 - exfil already streaming into dashboard)"
sleep 12
note "clip 4 timeline done — stop recording"
fi

# ---------------------------------------------------------------- clip 5 --
if want 5; then
banner "CLIP 5 (IX): RESET — record ~10s"
note "SHOW: cFS log line 'calibration cycle complete' + dashboard phase back to DORMANT"
[ "$DRYRUN" = 1 ] && exit 0
CLOG="$(session_log)/cfs_console.log"
note "waiting for cycle-complete event"
for i in $(seq 1 20); do
  grep -q "calibration cycle complete" "$CLOG" 2>/dev/null && break
  sleep 1
done
sleep 4
note "BONUS if you want it: USR2 (leave fence) then USR1 again = next pass re-triggers"
note "clip 5 timeline done — stop recording"
stop_all
fi

# ---------------------------------------------------------------- clip 6 --
if want 6; then
banner "CLIP 6 (DET): DETECTION — record ~30s"
note "SHOW: static scan (finds FIFO), then dynamic scan (flags sockets)"
note "SAY: SB monitoring saw nothing; OS-level artifacts tell the whole story"
[ "$DRYRUN" = 1 ] && exit 0
boot_cfs
(cd "$LAB" && (setsid python3 gnss_sim.py --attack > "$(session_log)/gnss_sim.log" 2>&1 < /dev/null &))
sleep 6
CFS_PID=$(pgrep -f core-cpu1 | head -n1)
echo
note "STATIC SCAN — run this, show the FIFO finding:"
echo "    python3 detector.py --image $EXE --static"
python3 "$LAB/detector.py" --image "$EXE" --static || true
echo
note "DYNAMIC SCAN — run this, show the socket findings:"
echo "    python3 detector.py -p $CFS_PID --exe-dir $EXE"
python3 "$LAB/detector.py" -p "$CFS_PID" --exe-dir "$EXE" || true
sleep 4
note "clip 6 timeline done — stop recording"
stop_all
fi

banner "ALL REQUESTED CLIPS DONE — recordings live in your OBS captures"
