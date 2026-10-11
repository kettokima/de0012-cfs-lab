#!/usr/bin/env python3
"""
exfil_rx.py - simulated RF ground station / attacker receiver.

Listens on UDP 50001 for the one-JSON-line datagrams that HK_DIAG starts
emitting only after the covert FIFO trigger. In a real deployment this
would be an SDR capture or a ground data system; the point is that the
cFS telemetry log never sees it.

Usage:
    ./exfil_rx.py [--port 50001] [--log received.jsonl]
"""
import argparse
import json
import socket
import sys
import time

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=50001)
    ap.add_argument("--log", default="exfil_received.jsonl")
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", args.port))
    s.settimeout(0.5)

    print(f"[exfil_rx] attacker ground station on 127.0.0.1:{args.port}", flush=True)
    print(f"[exfil_rx] writing captures -> {args.log}", flush=True)
    t0 = time.time()
    n = 0
    with open(args.log, "a") as f:
        while True:
            try:
                data, _ = s.recvfrom(4096)
            except socket.timeout:
                continue
            n += 1
            txt = data.decode(errors="replace").strip()
            stamp = time.strftime("%H:%M:%S")
            print(f"[exfil_rx] {stamp} +{time.time()-t0:6.1f}s  #{n:03d}  {txt}", flush=True)
            f.write(txt + "\n")
            f.flush()

if __name__ == "__main__":
    main()
