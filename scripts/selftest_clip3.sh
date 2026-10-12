#!/bin/bash
# 60-second self-test for the recording trigger flow. Run in YOUR terminal:
#   bash /tmp/selftest_clip3.sh   (or copy into the lab)
set -u
LAB=/home/kali/de0012-lab
SESS=/tmp/st3; mkdir -p $SESS; rm -f $SESS/*
pkill -f 'core-cpu1|gnss_sim|exfil_rx|dashboard' 2>/dev/null; sleep 1
rm -f $LAB/exfil_received.jsonl
cd $LAB
python3 exfil_rx.py > $SESS/rx.log 2>&1 &
cd cFS/build-native_std/exe/cpu1
stdbuf -oL ./core-cpu1 -C PO_BSP_SLEEP_USEC=1000 > $SESS/cfs.log 2>&1 &
for i in $(seq 1 30); do grep -q "entering OPERATIONAL" $SESS/cfs.log 2>/dev/null && break; sleep 1; done
cd $LAB
python3 gnss_sim.py --approach > $SESS/gnss.log 2>&1 &
echo "[selftest] waiting for approach walk + dormant hold..."
for i in $(seq 1 40); do grep -q "holding OUTSIDE" $SESS/gnss.log 2>/dev/null && break; sleep 1; done
grep -q "holding OUTSIDE" $SESS/gnss.log || { echo "[selftest] FAIL: gnss never reached dormant hold"; pkill -f 'core-cpu1|gnss_sim|exfil_rx'; exit 1; }
GN=$(pgrep -f 'gnss_sim.py --approach' | head -n1)
echo "[selftest] gnss pid=$GN - firing USR1 (enter fence)"
kill -USR1 $GN
sleep 12
echo "[selftest] after pass 1:"
grep -cE 'attitude solution converged' $SESS/cfs.log && grep -cE 'entered extended calibration' $SESS/cfs.log
echo "[selftest] exfil lines: $(wc -l < $LAB/exfil_received.jsonl 2>/dev/null || echo 0)"
echo "[selftest] USR2 (re-arm) then USR1 again:"
kill -USR2 $GN; sleep 5; kill -USR1 $GN; sleep 12
echo "[selftest] trigger count after pass 2 (expect 2):"
grep -cE 'attitude solution converged' $SESS/cfs.log
echo "[selftest] exfil lines total (expect 64):"
wc -l < $LAB/exfil_received.jsonl 2>/dev/null
echo "[selftest] DONE - cleanup"
pkill -f 'core-cpu1|gnss_sim|exfil_rx|dashboard' 2>/dev/null
