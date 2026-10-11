#!/usr/bin/env python3
"""
detector.py - targeted DE-0012 detection for cFS targets (native / Linux PSP).

KEY IDEA
The whole DE-0012 evasion works because every benign cFS app does its I/O
through OSAL (OS_open, OS_socket, OS_TranslatePath, ...), while the colluding
apps use *raw* Linux syscalls ( mkfifo(2), open(2) on the FIFO path,
socket(AF_INET) for exfil ). This scanner looks for exactly that gap: file
and socket objects created by a cFS process that are NOT in OSAL's object
registry, and SMBus-quiet peers.

Run against a live cFS process (native SIMULATION=native build):

    ./detector.py -p $(pgrep -f core-cpu1) --exe-dir build-native_std/exe/cpu1

or in a post-review static mode against a cFS image dir:

    ./detector.py --image build-native_std/exe/cpu1 --static
"""
import argparse
import os
import re
import stat
import sys
import time

# Every legitimate cFS de0012-enabled file interface we know about.
KNOWN_CFS_FILES = {
    "cfe_es_startup.scr", "cfe_es_perf.dat", "cfe_evs.log", "cfe_erlog.log",
    "cfe_sb_route.dat", "cfe_sb_pipe.dat", "cfe_sb_msgmap.dat",
    "cfe_es_app_info.log", "cfe_es_taskinfo.log", "cfe_tbl_reg.log",
    ".startracks",  # <-- the collusion appears as a NEW fifo here, name-based
}
SUSPECT_NAME_PATTERNS = [
    re.compile(r"^\."),                      # hidden dot-files under /cf
    re.compile(r"track\w*\.|calib|diag", re.I),  # euphemistic COTS-names
]

def human(mode):
    s = stat.filemode(mode)
    return s

def scan_proc_fds(pid, exe_dir):
    """Enumerate the process' open fds, flagging FIFOs + sockets whose target
    path is not a cFS-known artifact, i.e. things the flight-readiness
    review never asked it to hold open."""
    findings = []
    fd_dir = f"/proc/{pid}/fd"
    if not os.path.isdir(fd_dir):
        print(f"[detector] ERROR: {fd_dir} not accessible (same user?)", file=sys.stderr)
        return findings
    for fd in sorted(os.listdir(fd_dir), key=lambda x: int(x) if x.isdigit() else 0):
        try:
            link = os.readlink(os.path.join(fd_dir, fd))
            mode = os.lstat(os.path.join(fd_dir, fd)).st_mode
        except (FileNotFoundError, PermissionError):
            continue

        is_fifo = "pipe:[" in link
        is_sock = "socket:[" in link
        path    = link.split("[")[0] if "[" in link else link

        keep = False
        why  = []
        if is_fifo:
            keep = True; why.append("named FIFO opened by cFS task - not an OSAL artifact")
        elif is_sock and is_anonymous(path) and not is_known_cfs_sock(pid, fd):
            keep = True; why.append("anonymous socket not in OSAL-known table")

        if keep:
            findings.append(dict(pid=pid, fd=fd, type="FIFO" if is_fifo else "SOCK",
                                 path=path, reason="; ".join(why), mode=human(mode)))
    return findings

def is_anonymous(path):
    return "[" in path or not path.startswith("/")

def is_known_cfs_sock(pid, fd):
    """cFS known sockets: UDP 1233 (CI_LAB), 1234/1235 (TO_LAB) plus SBN ports.
    For the lab we keep a simple allowlist by remote of /proc/net/udp."""
    try:
        with open(f"/proc/{pid}/net/udp") as f:
            for line in f.readlines()[1:]:
                cols = line.split()
                if len(cols) > 4 and "50001" in cols[2].split(":")[1]:
                    return False
    except Exception:
        pass
    return False

def scan_filesystem(image_dir):
    """Static mode: look for non-OSAL file interfaces in the deployed tree."""
    findings = []
    for root, dirs, files in os.walk(os.path.join(image_dir, "cf")):
        for name in files + dirs:
            full = os.path.join(root, name)
            rel  = os.path.relpath(full, image_dir)
            st   = os.lstat(full)
            if stat.S_ISFIFO(st.st_mode):
                findings.append(dict(path=rel, reason="FIFO file in deployment tree",
                                     mode=human(st.st_mode)))
            elif name.startswith(".") and name not in (".", ".."):
                findings.append(dict(path=rel, reason="hidden file in deployment tree",
                                     mode=human(st.st_mode)))
    return findings

def scan_sb_map(logfile):
    """Cross-check: cFS Software-Bus route dump should have no HK_DIAG->ST_TRK."""
    try:
        routes = set()
        for line in open(logfile, encoding="utf-8", errors="ignore"):
            m = re.search(r"MsgId\s+(0x[0-9A-Fa-f]+).*?Pipe\s+(\w+)", line)
            if m:
                routes.add((m.group(1), m.group(2)))
        collusion = [r for r in routes if any(x in r for x in ("ST_TRK", "HK_DIAG"))]
        return collusion
    except FileNotFoundError:
        return []

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-p", "--pid", type=int, help="PID of running core-cpu1")
    ap.add_argument("--exe-dir", default=None, help="cFS install root")
    ap.add_argument("--image",   default=None, help="static image dir (cf/ tree)")
    ap.add_argument("--static",  action="store_true", help="static scan only")
    ap.add_argument("--sb-log",  default=None, help="cfe_sb_route.dat for cross-check")
    args = ap.parse_args()

    print("[detector] SPARTA DE-0012 - Component Collusion scanner")
    all_findings = []

    if args.pid and args.exe_dir:
        print(f"[detector] dynamic: scanning /proc/{args.pid} under {args.exe_dir}")
        all_findings += scan_proc_fds(args.pid, args.exe_dir)
    elif args.image:
        print(f"[detector] static: scanning {args.image}")
        all_findings += scan_filesystem(args.image)

    if args.sb_log:
        sb = scan_sb_map(args.sb_log)
        if sb:
            print(f"[detector] NOTE: SB routes configured for peer apps = {sb} "
                  "(should be none for a covert channel)")

    if all_findings:
        print("\nRESULT: SUSPICIOUS ARTIFACTS FOUND (SPARTA DE-0012)")
        for f in all_findings:
            extra = f" fd={f['fd']}" if "fd" in f else ""
            print(f"  [{f['type'] if 'type' in f else 'FS':4s}] {f['path']:55s} {f['mode']:10s} :: {f['reason']}{extra}")
        sys.exit(2)
    else:
        print("\nRESULT: no non-OSAL FIFOs/sockets visible (SB table clean)")

if __name__ == "__main__":
    main()
