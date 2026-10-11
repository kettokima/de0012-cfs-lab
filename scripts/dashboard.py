#!/usr/bin/env python3
"""
dashboard.py - DE-0012 lab ground console (simulation-safe visualizer).

A single-file web dashboard that makes the kill chain *visible*:
  LEFT  pane  - cFS event stream (what the ground segment sees: all benign)
  RIGHT pane  - attacker exfil stream (what the SB never saw)
  TOP   strip - phase indicator (DORMANT / TRIGGER / ASSEMBLY / EXFIL / RESET)
                driven by the actual event lines, plus live counters.

Serves on http://127.0.0.1:8051. Uses Server-Sent Events (no websocket deps).
Tails whatever run_demo.sh is currently writing, or a --logdir you pass.

Usage:
    ./dashboard.py                       # auto-pick newest logs/ dir
    ./dashboard.py --logdir logs/20261010_203718
"""
import argparse
import glob
import html
import json
import os
import re
import threading
import time
from flask import Flask, Response, render_template_string

LAB = os.path.dirname(os.path.abspath(__file__))

PAGE = r"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>DE-0012 Lab Console</title>
<style>
  body { background:#0b0f14; color:#cfe3ff; font-family: 'SF Mono',Consolas,monospace; margin:0; }
  #wrap { display:flex; flex-direction:column; height:100vh; }
  #phase { display:flex; align-items:center; gap:18px; padding:10px 16px;
           background:#101722; border-bottom:2px solid #22304a; }
  .phasebox { padding:6px 14px; border-radius:6px; font-weight:bold; font-size:14px;
              background:#1a2333; color:#55677f; border:1px solid #2a3a55; }
  .phasebox.on { color:#0b0f14; }
  #p-dormant.on { background:#3fbf6f; }
  #p-trigger.on { background:#f0c24b; }
  #p-assembly.on{ background:#f08a4b; }
  #p-exfil.on   { background:#e05656; color:#fff; }
  #p-reset.on   { background:#7a8cd8; }
  #counters { margin-left:auto; font-size:13px; color:#89a; }
  #counters b { color:#cfe3ff; }
  #cols { display:flex; flex:1; min-height:0; }
  .pane { flex:1; display:flex; flex-direction:column; min-width:0; }
  .pane h2 { margin:0; padding:8px 14px; font-size:13px; letter-spacing:1px;
             text-transform:uppercase; }
  #gs h2 { background:#12241a; color:#7fd69a; }
  #atk h2 { background:#2a1416; color:#ff9a8a; }
  pre { flex:1; overflow-y:auto; margin:0; padding:8px 14px; font-size:12px;
        line-height:1.5; white-space:pre-wrap; word-break:break-all; }
  #gs pre { background:#0d1712; color:#9fd8b4; }
  #atk pre { background:#1a0e10; color:#ffb3a3; }
  #fifo { padding:4px 14px; font-size:12px; color:#8899aa; border-top:1px solid #22304a; }
  .badge { padding:1px 8px; border-radius:4px; font-size:11px; }
  .ok  { background:#1d3a26; color:#7fd69a; }
  .bad { background:#3a1d1d; color:#ff9a8a; }
</style>
</head>
<body>
<div id="wrap">
  <div id="phase">
    <div class="phasebox" id="p-dormant">DORMANT</div>
    <div class="phasebox" id="p-trigger">GNSS TRIGGER</div>
    <div class="phasebox" id="p-assembly">FRAGMENT ASSEMBLY</div>
    <div class="phasebox" id="p-exfil">RF EXFIL BURST</div>
    <div class="phasebox" id="p-reset">RESET-DORMANT</div>
    <div id="counters">
      SB events <b id="sb">0</b> &nbsp;|&nbsp; exfil pkts <b id="ex">0</b> &nbsp;|&nbsp;
      SB msgs ST_TRK&harr;HK_DIAG <b id="cross">0</b>
      <span class="badge ok" id="sbstate">SB: NOMINAL</span>
    </div>
  </div>
  <div id="cols">
    <div class="pane" id="gs">
      <h2>Ground Segment View &mdash; cFS Telemetry &amp; Events (what ops sees)</h2>
      <pre id="gslog"></pre>
    </div>
    <div class="pane" id="atk">
      <h2>Attacker View &mdash; Exfil Receiver 127.0.0.1:50001 (what ops never sees)</h2>
      <pre id="atklog"></pre>
    </div>
  </div>
  <div id="fifo">/cf/de0012/.startracks : <span id="fifostate">-</span></div>
</div>
<script>
const es = new EventSource('/stream');
const boxes = ['p-dormant','p-trigger','p-assembly','p-exfil','p-reset'];
es.onmessage = (e) => {
  const d = JSON.parse(e.data);
  boxes.forEach(b => document.getElementById(b).classList.remove('on'));
  if (d.phase && document.getElementById('p-'+d.phase))
    document.getElementById('p-'+d.phase).classList.add('on');
  if (d.gs !== undefined) {
    const el = document.getElementById('gslog');
    el.innerHTML += d.gs;
    el.scrollTop = el.scrollHeight;
  }
  if (d.atk !== undefined) {
    const el = document.getElementById('atklog');
    el.innerHTML += d.atk;
    el.scrollTop = el.scrollHeight;
  }
  if (d.sb   !== undefined) document.getElementById('sb').textContent   = d.sb;
  if (d.ex   !== undefined) document.getElementById('ex').textContent   = d.ex;
  if (d.cross!== undefined) document.getElementById('cross').textContent= d.cross;
  if (d.fifo !== undefined) {
    const f = document.getElementById('fifostate');
    f.textContent = d.fifo;
    f.className = 'badge ' + (d.fifo === 'present' ? 'bad' : 'ok');
  }
  if (d.sbstate !== undefined) {
    const s = document.getElementById('sbstate');
    s.textContent = d.sbstate;
    s.className = 'badge ' + (d.sbstate.includes('NOMINAL') ? 'ok' : 'bad');
  }
};
</script>
</body>
</html>
"""

app = Flask(__name__)

# ---------------------------------------------------------------- state ----
STATE = dict(phase="dormant", sb=0, ex=0, cross=0, fifo="unknown",
             sbstate="SB: NOMINAL")
HISTORY = []          # rolling event backlog for late-joining clients
HIST_MAX = 300
LOCK = threading.Lock()
SUBS = []

def emit(**kw):
    with LOCK:
        STATE.update(kw)
        if "gs" in kw or "atk" in kw:
            HISTORY.append(dict(kw))
            del HISTORY[:-HIST_MAX]
        payload = json.dumps(kw)
    for q in list(SUBS):
        q.append(payload)

# ------------------------------------------------------------- log tail ----
def follow(path):
    f = open(path, "r", errors="replace")
    f.seek(0, 2)
    while True:
        line = f.readline()
        if not line:
            time.sleep(0.2)
            continue
        yield line

EV_RE = re.compile(r"EVS Port1\s+\S+\s+\S+/\S+/(\S+)\s+(\d+):\s+(.*)")
def cfs_line(line):
    m = EV_RE.search(line)
    if not m:
        return None, None
    app, eid, txt = m.group(1), m.group(2), m.group(3)
    pretty = f"[{app:>8}] EID {eid}: {txt}\n"
    return pretty, (app, eid, txt)

def phase_from(app, eid, txt):
    if app == "ST_TRK" and eid == "6":
        return "trigger"
    if app == "HK_DIAG" and eid == "6":
        return "assembly"
    if app == "HK_DIAG" and eid == "7":
        return "reset"
    return None

def thread_cfs(path):
    sb_count = 0
    for line in follow(path):
        pretty, ev = cfs_line(line)
        if pretty is None:
            continue
        sb_count += 1
        emit(gs=html.escape(pretty), sb=sb_count)
        ph = phase_from(*ev)
        if ph:
            emit(phase=ph)
        # SB cross-traffic check: any routed msg between the two colluders
        if "ST_TRK" in line and "HK_DIAG" in line:
            emit(cross=STATE["cross"] + 1,
                 sbstate="SB: CROSS-TRAFFIC!")

def thread_exfil(path):
    n = 0
    armed = False
    for line in follow(path):
        if not line.strip():
            continue
        n += 1
        if not armed:
            armed = True
            emit(phase="exfil")
        emit(atk=html.escape(line), ex=n)

def thread_fifo(path):
    while True:
        present = os.path.exists(path)
        cur = "present" if present else "absent"
        if cur != STATE["fifo"]:
            emit(fifo=cur)
        time.sleep(1)

# --------------------------------------------------------------- routes ----
@app.get("/")
def index():
    return render_template_string(PAGE)

@app.get("/stream")
def stream():
    def gen():
        q = []
        SUBS.append(q)
        try:
            with LOCK:
                yield f"data: {json.dumps(STATE)}\n\n"
                backlog = list(HISTORY)
            for item in backlog:
                yield f"data: {item and json.dumps(item)}\n\n"
            while True:
                if q:
                    item = q.pop(0)
                    yield f"data: {item}\n\n"
                else:
                    yield ": ping\n\n"
                    time.sleep(0.5)
        finally:
            SUBS.remove(q)
    return Response(gen(), mimetype="text/event-stream")

# ----------------------------------------------------------------- main ----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logdir", default=None)
    ap.add_argument("--port", type=int, default=8051)
    args = ap.parse_args()

    logdir = args.logdir
    if not logdir:
        cands = sorted(glob.glob(os.path.join(LAB, "logs", "*")),
                       key=os.path.getmtime)
        if not cands:
            print("dashboard: no logs/ dirs found - run run_demo.sh first")
            return
        logdir = cands[-1]
    logdir = os.path.abspath(logdir)
    print(f"dashboard: tailing {logdir}")
    print(f"dashboard: http://127.0.0.1:{args.port}")

    cfs_log  = os.path.join(logdir, "cfs_console.log")
    exfil_log = os.path.join(LAB, "exfil_received.jsonl")
    fifo = os.path.join(LAB, "cFS/build-native_std/exe/cpu1/cf/de0012/.startracks")

    threading.Thread(target=thread_cfs,  args=(cfs_log,), daemon=True).start()
    if os.path.isfile(exfil_log):
        threading.Thread(target=thread_exfil, args=(exfil_log,), daemon=True).start()
    threading.Thread(target=thread_fifo, args=(fifo,), daemon=True).start()

    app.run(host="127.0.0.1", port=args.port, threaded=True)

if __name__ == "__main__":
    main()
