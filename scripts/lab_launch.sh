#!/bin/bash
# lab_launch.sh - detached lab launcher (survives terminal/tool death).
# Usage: (setsid /home/kali/de0012-lab/lab_launch.sh [target] > /dev/null 2>&1 < /dev/null &)
#   target: demo     (default) - full run_demo.sh orchestration
#           dash LOGDIR         - dashboard only against existing logdir
TARGET="${1:-demo}"
LAB="$(cd "$(dirname "$0")" && pwd)"
case "$TARGET" in
  demo) exec "$LAB/run_demo.sh" ;;
  dash) exec "$LAB/.venv/bin/python" "$LAB/dashboard.py" --logdir "$2" ;;
  *)    echo "usage: lab_launch.sh [demo|dash LOGDIR]" >&2; exit 1 ;;
esac
