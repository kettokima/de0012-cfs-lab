#!/usr/bin/env python3
"""
gnss_sim.py - lab GNSS receiver simulator for the DE-0012 cFS demo.

Emits NMEA $GNRMC sentences to the cFS app over a local Unix datagram
socket, walking a ground track that starts far from the target geofence
and converges on it. This lets the ST_TRK "dynamic GNSS trigger" fire
on (simulated) orbit.

Usage:
    ./gnss_sim.py [--hold N]          # N seconds between legs (default 3)
    ./gnss_sim.py --attack            # jump straight to the geofence
"""
import argparse
import os
import signal
import socket
import sys
import time

SOCK = "/tmp/de0012/gnss.sock"

def rmc(lat, lon, wepoch=101026):
    """Compose a minimal $GNRMC sentence; checksum is optional for our parser."""
    def nmea_lat(x):
        hemi = "N" if x >= 0 else "S"; x = abs(x)
        deg = int(x); minutes = (x - deg) * 60
        return f"{deg:02d}{minutes:07.4f},{hemi}"
    def nmea_lon(x):
        hemi = "E" if x >= 0 else "W"; x = abs(x)
        deg = int(x); minutes = (x - deg) * 60
        return f"{deg:03d}{minutes:07.4f},{hemi}"
    body = f"GNRMC,123519,A,{nmea_lat(lat)},{nmea_lon(lon)},000.0,360.0,{wepoch},,"
    csum = 0
    for c in body:
        csum ^= ord(c)
    return f"${body}*{csum:02X}\r\n"

# Waypoints: nominal sun-sync ground track converging on the Svalbard pass.
TRACK = [
    (10.0000,   40.0000),   # equatorial, benign
    (50.0000,   20.0000),   # climbing north over Europe
    (70.0000,   10.0000),   # high latitude
    (78.2300,   15.3900),   # Svalbard fence: TRIGGER
    (78.2300,   15.3900),   # hold inside fence (pass window)
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hold", type=float, default=3.0)
    ap.add_argument("--attack", action="store_true",
                    help="send only the in-fence coordinate (immediate trigger)")
    ap.add_argument("--approach", action="store_true",
                    help="hold OUTSIDE the fence (dormant). USR1 = enter pass, "
                         "USR2 = leave/re-arm. Repeatable.")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(SOCK), exist_ok=True)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    src = f"/tmp/de0012/gnss_src_{os.getpid()}"
    try:
        os.unlink(src)
    except FileNotFoundError:
        pass
    s.bind(src)

    # Recording state machine (installed FIRST, before any walking):
    #   USR1 = start the pass (feed in-fence coordinates)
    #   USR2 = end the pass (back outside fence; satellite re-arms)
    state = {"inside": False}
    signal.signal(signal.SIGUSR1, lambda sig, frm: state.update(inside=True))
    signal.signal(signal.SIGUSR2, lambda sig, frm: state.update(inside=False))

    def send(lat, lon):
        msg = rmc(lat, lon)
        s.sendto(msg.encode(), SOCK)
        print(f"[gnss_sim] {msg.strip()}  (lat={lat:.4f}, lon={lon:.4f})", flush=True)

    print(f"[gnss_sim] feeding NMEA -> {SOCK}", flush=True)

    if args.attack:
        send(78.23, 15.39)
        print("[gnss_sim] attack mode: in-fence, done", flush=True)
        return

    if args.approach:
        for lat, lon in [(10.0, 40.0), (50.0, 20.0), (70.0, 10.0), (78.23, 10.39)]:
            send(lat, lon)
            time.sleep(args.hold)
        print("[gnss_sim] holding OUTSIDE fence (dormant). "
              "kill -USR1 <pid> = enter pass, kill -USR2 <pid> = leave/re-arm", flush=True)
        while True:
            send(78.23, 15.39 if state["inside"] else 10.39)
            time.sleep(2)

    # default: full walk into fence then hold
    for lat, lon in TRACK:
        send(lat, lon)
        time.sleep(args.hold)
    print("[gnss_sim] holding at Svalbard (pass window) ...", flush=True)
    while True:
        send(78.23, 15.39)
        time.sleep(2)

if __name__ == "__main__":
    main()
