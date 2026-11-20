#!/usr/bin/env python3
"""Stdio proxy for ACP agents: record.py OUT.jsonl -- agent-cmd [args...]
Forwards stdin/stdout between the caller and the agent, logging each line as
{"t": seconds, "dir": "c2a"|"a2c"|"err", "line": "..."} to OUT.jsonl.
Run the output through scrub.sh before committing."""
import json, subprocess, sys, threading, time

def main():
    if "--" not in sys.argv or len(sys.argv) < 4:
        sys.exit("usage: record.py OUT.jsonl -- agent-cmd [args...]")
    out_path = sys.argv[1]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    t0 = time.monotonic()
    lock = threading.Lock()
    log = open(out_path, "w")
    def rec(d, line):
        with lock:
            log.write(json.dumps({"t": round(time.monotonic() - t0, 3), "dir": d, "line": line}) + "\n")
            log.flush()
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def pump(src, dst, d):
        for raw in iter(src.readline, b""):
            rec(d, raw.decode("utf-8", "replace").rstrip("\n"))
            if dst:
                try: dst.write(raw); dst.flush()
                except OSError: break
        if dst and d == "c2a":
            try: dst.close()
            except OSError: pass
    ths = [threading.Thread(target=pump, args=(sys.stdin.buffer, p.stdin, "c2a"), daemon=True),
           threading.Thread(target=pump, args=(p.stdout, sys.stdout.buffer, "a2c")),
           threading.Thread(target=pump, args=(p.stderr, None, "err"))]
    for t in ths: t.start()
    try: p.wait()
    except KeyboardInterrupt: p.terminate()
    for t in ths[1:]: t.join(timeout=2)
    log.close()
    sys.exit(p.returncode or 0)

main()
