#!/usr/bin/env python3
"""Probe driver for `claude` stream-json. PROBE ONLY: passes --setting-sources project so the
user's allow rules do not apply (the Alloy app itself never passes that flag).

usage: drive.py LOG SCRIPT_JSON [--cwd DIR] [--model haiku] [--extra '["--flag",...]'] [--resume ID] [--no-setting-sources]
Default cwd: a fresh temp git repo containing login.swift.
Steps (JSON list): {"send": obj} | {"respond": "allow"|"deny", "extra": {response fields}} |
 {"wait": regex, "count": n, "timeout": s} | {"sleep": s} | {"auto": "allow"|"deny"|null} | {"close": true}
Lines written by the host are logged with a "#HOST->CLI " prefix; CLI stdout lines are logged verbatim.
"""
import subprocess, sys, json, time, uuid, threading, os, re, tempfile, argparse

ap = argparse.ArgumentParser()
ap.add_argument("log"); ap.add_argument("script")
ap.add_argument("--cwd"); ap.add_argument("--model", default="haiku")
ap.add_argument("--extra", default="[]"); ap.add_argument("--resume")
ap.add_argument("--no-setting-sources", action="store_true")
a = ap.parse_args()

LOGIN = 'import Foundation\n\nfunc login(user: String, password: String) -> Bool {\n    // TODO: real auth\n    return user == "admin"\n}\n'
cwd = a.cwd
if not cwd:
    cwd = tempfile.mkdtemp(prefix="ccprobe-repo-", dir=os.environ.get("CCPROBE_TMP"))
    open(os.path.join(cwd, "login.swift"), "w").write(LOGIN)
    for c in (["git", "init", "-q"], ["git", "add", "."], ["git", "-c", "user.name=p", "-c", "user.email=p@p", "commit", "-qm", "init"]):
        subprocess.run(c, cwd=cwd, check=True)
steps = json.load(open(a.script))
cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio", "--model", a.model]
if not a.no_setting_sources: cmd += ["--setting-sources", "project"]
cmd += ["--resume", a.resume] if a.resume else ["--session-id", str(uuid.uuid4())]
cmd += json.loads(a.extra)
p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(a.log + ".err", "w"), text=True)
print("pid", p.pid, "cwd", cwd, file=sys.stderr)
last = {"r": None}; lines = []; f = open(a.log, "w"); auto = {"mode": None}

def send(o):
    s = json.dumps(o); f.write("#HOST->CLI " + s + "\n"); f.flush(); p.stdin.write(s + "\n"); p.stdin.flush()

def reply(o, resp):
    send({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"], "response": resp}})

def rd():
    for l in p.stdout:
        f.write(l); f.flush(); lines.append(l)
        try: o = json.loads(l)
        except Exception: continue
        if o.get("type") == "control_request": last["r"] = o
        if o.get("type") == "control_request" and auto["mode"] and o["request"].get("subtype") == "can_use_tool":
            rq = o["request"]
            reply(o, {"behavior": "allow", "updatedInput": rq["input"]} if auto["mode"] == "allow" else {"behavior": "deny", "message": "Denied by host"})
threading.Thread(target=rd, daemon=True).start()

for st in steps:
    if "send" in st: send(st["send"])
    if "respond" in st:
        o = last["r"]; rq = o["request"]
        resp = st.get("raw") or ({"behavior": "allow", "updatedInput": rq["input"]} if st["respond"] == "allow" else {"behavior": "deny", "message": "Denied by host"})
        if not st.get("raw"): resp.update(st.get("extra", {}))
        reply(o, resp)
    if "auto" in st: auto["mode"] = st["auto"]
    if "sleep" in st: time.sleep(st["sleep"])
    if "wait" in st:
        t = time.time() + st.get("timeout", 90); n = st.get("count", 1)
        while time.time() < t and sum(1 for l in lines if re.search(st["wait"], l)) < n: time.sleep(.2)
    if "close" in st: p.stdin.close()
try: p.wait(timeout=30)
except Exception: p.kill()
