#!/usr/bin/env python3
"""Minimal scripted ACP client for probes.
usage: drive.py OUT.jsonl CWD SCENARIO -- agent-cmd [args...]
SCENARIO is a comma list of steps: prompt:<text> | config:<id>=<value> | cancel:<text>@<seconds> | load | resume
Spawns the agent through record.py (so every line is logged) and serves
fs/read_text_file, fs/write_text_file and session/request_permission (first allow option)."""
import json, os, subprocess, sys, threading, time, queue

here = os.path.dirname(os.path.abspath(__file__))
out, cwd, scenario = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = sys.argv[sys.argv.index("--") + 1:]
p = subprocess.Popen([sys.executable, os.path.join(here, "record.py"), out, "--"] + cmd,
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=cwd)
responses, updates, nid, lock = {}, queue.Queue(), [0], threading.Lock()
cv = threading.Condition()

def send(obj):
    with lock:
        p.stdin.write((json.dumps(obj) + "\n").encode()); p.stdin.flush()

def reader():
    for raw in iter(p.stdout.readline, b""):
        try: m = json.loads(raw)
        except Exception: continue
        if "method" in m and "id" in m:
            handle_request(m)
        elif "method" in m:
            updates.put(m)
        else:
            with cv: responses[m["id"]] = m; cv.notify_all()

def handle_request(m):
    meth, par, rid = m["method"], m.get("params", {}), m["id"]
    if meth == "fs/read_text_file":
        try:
            t = open(par["path"]).read()
            ls = t.split("\n"); s = (par.get("line") or 1) - 1
            if par.get("limit"): ls = ls[s:s + par["limit"]]
            elif s: ls = ls[s:]
            send({"jsonrpc": "2.0", "id": rid, "result": {"content": "\n".join(ls)}})
        except Exception as e:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32002, "message": str(e)}})
    elif meth == "fs/write_text_file":
        os.makedirs(os.path.dirname(par["path"]), exist_ok=True)
        open(par["path"], "w").write(par["content"])
        send({"jsonrpc": "2.0", "id": rid, "result": None})
    elif meth == "session/request_permission":
        opts = par.get("options", [])
        pick = next((o for o in opts if o.get("kind", "").startswith("allow")), opts[0] if opts else None)
        res = {"outcome": {"outcome": "selected", "optionId": pick["optionId"]}} if pick else {"outcome": {"outcome": "cancelled"}}
        send({"jsonrpc": "2.0", "id": rid, "result": res})
    else:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unsupported"}})

threading.Thread(target=reader, daemon=True).start()

def call(method, params, timeout=180):
    nid[0] += 1; i = nid[0]
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
    return i

def wait(i, timeout=180):
    end = time.time() + timeout
    with cv:
        while i not in responses:
            if time.time() > end or p.poll() is not None: return None
            cv.wait(0.5)
    return responses[i]

caps = {"fs": {"readTextFile": True, "writeTextFile": True}}
r = wait(call("initialize", {"protocolVersion": 1, "clientCapabilities": caps,
                             "clientInfo": {"name": "alloy-probe", "version": "0"}}))
init = (r or {}).get("result", {})
sid = None
def new():
    r = wait(call("session/new", {"cwd": cwd, "mcpServers": []}))
    return (r or {}).get("result", {}).get("sessionId")
sid = new()
for step in [s for s in scenario.split(",") if s]:
    kind, _, arg = step.partition(":")
    if kind == "prompt":
        wait(call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": arg}]}))
    elif kind == "cancel":
        text, _, secs = arg.rpartition("@")
        i = call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
        time.sleep(float(secs))
        send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": sid}})
        wait(i, 60)
    elif kind == "config":
        cid, _, val = arg.partition("=")
        wait(call("session/set_config_option", {"sessionId": sid, "configId": cid, "value": val}), 30)
    elif kind in ("load", "resume"):
        wait(call("session/" + kind, {"sessionId": sid, "cwd": cwd, "mcpServers": []}), 60)
try: p.stdin.close()
except Exception: pass
try: p.wait(10)
except Exception: p.terminate()
