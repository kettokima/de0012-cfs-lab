#!/bin/bash
# healthcheck.sh - one-shot lab sanity for session start (run me first).
set -u
LAB="$(cd "$(dirname "$0")" && pwd)"
cd "$LAB"
fail=0

echo "== 1. artifacts exist =="
fail=0
for f in run_demo.sh dashboard.py detector.py gnss_sim.py exfil_rx.py \
         KILLCHAIN.md DETECTION.md README.md lab_launch.sh record_clips.sh \
         cFS/apps/st_app/fsw/src/st_app.c cFS/apps/hk_diag/fsw/src/hk_diag.c \
         cFS/build-native_std/exe/cpu1/cf/st_app.so cFS/build-native_std/exe/cpu1/cf/hk_diag.so; do
  [ -f "$f" ] && echo "  ok   $f" || { echo "  MISS $f"; fail=1; }
done
[ -f HANDOFF.md ] && echo "  ok   HANDOFF.md (dev)" || echo "  --   HANDOFF.md (dev-only, absent in attendee repo: fine)"

echo "== 2. venv (cmake+flask) =="
[ -x .venv/bin/cmake ] && echo "  ok   cmake $(.venv/bin/cmake --version | head -n1)" || { echo "  MISS venv/cmake"; fail=1; }
.venv/bin/python -c "import flask" 2>/dev/null && echo "  ok   flask" || { echo "  MISS venv/flask"; fail=1; }

echo "== 3. kill-chain semantics in source =="
grep -q 'ST_FENCE_LAT        78.23' cFS/apps/st_app/fsw/src/st_app.c \
  && echo "  ok   Svalbard fence" || { echo "  MISS Svalbard fence"; fail=1; }
grep -q 'ST_MY_FRAGMENT      0x18' cFS/apps/st_app/fsw/src/st_app.c \
  && echo "  ok   fragment 0x18 (A)" || { echo "  MISS fragment A"; fail=1; }
grep -q 'HKD_MY_FRAGMENT  0x2A' cFS/apps/hk_diag/fsw/src/hk_diag.c \
  && echo "  ok   fragment 0x2A (B)" || { echo "  MISS fragment B"; fail=1; }
grep -q 'HKD_EXFIL_FRAMES 8' cFS/apps/hk_diag/fsw/src/hk_diag.c \
  && echo "  ok   bounded burst (8 frames)" || { echo "  MISS burst bound"; fail=1; }

echo "== 4. no stray processes =="
pgrep -f 'core-cpu1|gnss_sim|exfil_rx|dashboard.py' >/dev/null \
  && { echo "  WARN stray lab processes running:"; pgrep -af 'core-cpu1|gnss_sim|exfil_rx|dashboard.py'; } \
  || echo "  ok   clean"

echo "== 5. quick static detector self-test =="
.venv/bin/python detector.py --image cFS/build-native_std/exe/cpu1 --static \
  && echo "  WARN detector found nothing (FIFO absent - run demo once)" \
  || echo "  ok   detector fires (exit 2 = findings)"

echo
[ $fail -eq 0 ] && echo "LAB HEALTHY - ready. Full verify: (setsid $LAB/lab_launch.sh > /dev/null 2>&1 < /dev/null &) then check newest logs/" \
                 || echo "ISSUES ABOVE - see HANDOFF.md gotchas before rebuilding"
exit $fail
