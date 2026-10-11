#!/usr/bin/env bash
# run_demo.sh - one-shot DE-0012 demo: boot cFS, run GNSS sim, capture exfil.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"   # portable lab root
EXE="$LAB_ROOT/cFS/build-native_std/exe/cpu1"
LOGDIR="$LAB_ROOT/logs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR"

echo "[run_demo] lab rooted at $LAB_ROOT"
echo "[run_demo] logs    -> $LOGDIR"

# --- 0) Cleanup old state --------------------------------------------------
pkill -f core-cpu1     2>/dev/null || true
pkill -f gnss_sim.py  2>/dev/null || true
pkill -f exfil_rx.py  2>/dev/null || true
rm -f "$EXE/cf/de0012/.startracks" 2>/dev/null || true
rm -f /tmp/de0012/gnss.sock       2>/dev/null || true
rm -f "$LAB_ROOT/exfil_received.jsonl"        2>/dev/null || true
sleep 1

mkdir -p "$EXE/cf/de0012"

# --- 1) Simulated RF ground station (attacker receiver) --------------------
echo "[run_demo] starting exfil_receiver (ground station)..."
cd "$LAB_ROOT"
nohup python3 exfil_rx.py > "$LOGDIR/exfil_rx.log" 2>&1 &
RX_PID=$!
cd - > /dev/null
sleep 0.5

# --- 1b) Visual console (browser dashboard on 127.0.0.1:8051) --------------
echo "[run_demo] starting dashboard -> http://127.0.0.1:8051"
nohup "$LAB_ROOT/.venv/bin/python" "$LAB_ROOT/dashboard.py" --logdir "$LOGDIR" \
    > "$LOGDIR/dashboard.log" 2>&1 &
DASH_PID=$!

# --- 2) Boot cFS ------------------------------------------------------------
echo "[run_demo] booting cFS cpu1..."
cd "$EXE"
nohup stdbuf -oL ./core-cpu1 -C PO_BSP_SLEEP_USEC=1000 > "$LOGDIR/cfs_console.log" 2>&1 &
CFS_BG_PID=$!
cd - > /dev/null
echo "[run_demo] cFS pid=$CFS_BG_PID"
sleep 8   # let startup script finish and apps settle

# --- 3) Drive the GNSS simulator -------------------------------------------
echo "[run_demo] starting GNSS simulator..."
cd "$LAB_ROOT"
nohup python3 gnss_sim.py > "$LOGDIR/gnss_sim.log" 2>&1 &
GNSS_PID=$!
cd - > /dev/null

echo "[run_demo] let the trigger fire..."; sleep 6

# --- 3b) SB-route hygiene report: extract every SB route line from the console
SB_ROUTE_TXT="$LOGDIR/sb_routes.txt"
grep -E 'MsgId|Pipe|ST_TRK|HK_DIAG|Subscribe' "$LOGDIR/cfs_console.log" > "$SB_ROUTE_TXT" || true
echo "[run_demo] SB route context -> $SB_ROUTE_TXT"
if grep -qE 'ST_TRK.*HK_DIAG|HK_DIAG.*ST_TRK' "$SB_ROUTE_TXT"; then
    echo "[run_demo] WARNING: cross-app SB route detected (should NOT happen)"
else
    echo "[run_demo] GOOD: no ST_TRK<->HK_DIAG routes exist on the Software Bus"
fi

# --- 3c) Run the dynamic detector while collusion is live --------------------
python3 "$LAB_ROOT/detector.py" -p "$CFS_BG_PID" --exe-dir "$EXE" --sb-log "$SB_ROUTE_TXT" \
    > "$LOGDIR/detector.out" 2>&1 && echo "[run_demo] detector green" || echo "[run_demo] detector flagged covert artifacts -> $LOGDIR/detector.out"

sleep 12

# --- 4) Stop everything -----------------------------------------------------
echo "[run_demo] shutting down..."
kill "$GNSS_PID"  2>/dev/null || true
kill "$CFS_BG_PID" 2>/dev/null || true
kill "$DASH_PID"   2>/dev/null || true
pkill -f exfil_rx.py 2>/dev/null || true
pkill -f core-cpu1  2>/dev/null || true
pkill -f dashboard.py 2>/dev/null || true
sleep 2

# --- 5) Show evidence ----------------------------------------------------------
echo
echo "================  GNSS SIMULATOR  ================"; tail -n 6  "$LOGDIR/gnss_sim.log"
echo
echo "================  ATTACKER RX      ================"; tail -n 20 "$LOGDIR/exfil_rx.log"
echo
echo "============  cFS EVENT LOG (look benign) ========="
grep -E 'ST_TRK|HK_DIAG|CFE_SB' "$LOGDIR/cfs_console.log" | tail -n 25 || \
    tail -n 25 "$LOGDIR/cfs_console.log"

echo
echo "[run_demo] artifacts (FIFO, received exfil):"
ls -la "$EXE/cf/de0012/" || true
[ -f "$LAB_ROOT/exfil_received.jsonl" ] && cat "$LAB_ROOT/exfil_received.jsonl" | tail -n 5

echo
echo
echo "================  DETECTOR  ==================="; cat "$LOGDIR/detector.out"

echo "[run_demo] Done. Logs in $LOGDIR"
