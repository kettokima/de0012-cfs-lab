#!/bin/bash
# setup.sh - one-shot attendee setup for the DE-0012 lab.
# Clones NASA cFS (pinned commit), overlays the lab's apps/configs,
# builds native_std, and runs the healthcheck.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "== [1/6] prerequisites =="
for c in git gcc make python3; do
  command -v "$c" >/dev/null || { echo "MISSING: $c - install it first (e.g. 'sudo apt install $c')"; exit 1; }
done
python3 -c "import venv" 2>/dev/null || { echo "MISSING: python3-venv (sudo apt install python3-venv)"; exit 1; }
echo "  ok: git gcc make python3 venv"

echo "== [2/6] cFS source =="
if [ ! -d cFS/.git ]; then
  git clone https://github.com/nasa/cFS.git cFS
  # Pin the exact commit the lab was developed against:
  (cd cFS && git checkout ca14a5c -- 2>/dev/null || true) # best-effort pin; main works too
fi
(cd cFS && git submodule update --init --recursive apps/cf apps/ci_lab apps/to_lab apps/sch_lab apps/sample_app apps/sample_lib apps/hk apps/hs apps/md apps/cs apps/fm apps/lc apps/sc apps/ds tools/elf2cfetbl tools/tblCRCTool tools/cfs-cosmos-plugin tools/commandline-tools 2>/dev/null || git submodule update --init --recursive)
echo "  ok: cFS + submodules"

echo "== [3/6] python venv (cmake fallback included) =="
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
if ! command -v cmake >/dev/null && [ ! -x .venv/bin/cmake ]; then
  ./.venv/bin/pip install --quiet cmake ninja
elif ! command -v cmake >/dev/null; then
  echo "  (system cmake absent, using venv cmake)"
fi
./.venv/bin/pip install --quiet flask
echo "  ok: venv (cmake: $(./.venv/bin/cmake --version 2>/dev/null | head -n1 || cmake --version | head -n1), flask: yes)"

echo "== [4/6] overlay lab apps + mission config =="
cp -r lab-apps/st_app     cFS/apps/
cp -r lab-apps/hk_diag    cFS/apps/
# cfs_defs = full copy of the superproject sample_defs (mission defaults),
# then overlay our edited files on top.
rm -rf cFS/cfs_defs
cp -r cFS/sample_defs cFS/cfs_defs
cp mission/cfs_defs/targets.cmake          cFS/cfs_defs/
cp mission/cfs_defs/generate_startup.cmake cFS/cfs_defs/
cp mission/target-configs.mk               cFS/target-configs.mk
echo "  ok: st_app, hk_diag, cfs_defs (full sample_defs + overlays), target-configs.mk"

echo "== [5/6] build native_std (~5-10 min first time) =="
cd cFS
if command -v cmake >/dev/null; then
  make native_std.prep && make native_std.compile native_std.install
else
  source ../.venv/bin/activate
  make native_std.prep && make native_std.compile native_std.install
fi
cd "$HERE"
echo "  ok: build complete"

echo "== [6/6] install runtime scripts + docs =="
cp scripts/run_demo.sh scripts/record_clips.sh scripts/healthcheck.sh scripts/lab_launch.sh ./
cp scripts/gnss_sim.py scripts/exfil_rx.py scripts/detector.py scripts/dashboard.py ./
chmod +x run_demo.sh record_clips.sh healthcheck.sh lab_launch.sh
cp docs/KILLCHAIN.md docs/DETECTION.md docs/README.md ./
echo "  ok: scripts + docs installed"

echo
echo "Setup complete. Verify with:"
echo "  ./healthcheck.sh"
echo "Then run the demo:"
echo "  (setsid ./lab_launch.sh > /dev/null 2>&1 < /dev/null &)"
echo "  # browser: http://127.0.0.1:8051"
