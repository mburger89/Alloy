import http.server, json, sys
LOG=sys.argv[1]; MODE=sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        b=s.rfile.read(int(s.headers.get("content-length",0)))
        open(LOG,"a").write(json.dumps({"path":s.path,"headers":dict(s.headers),"body":json.loads(b or "{}")})+"\n")
        out={}
        if s.path=="/pre" and MODE=="ctx":
            out={"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"NOTE: session 'auth refactor' changed lines 1-3 of login.swift 2 minutes ago"}}
        r=json.dumps(out).encode()
        s.send_response(200); s.send_header("content-type","application/json"); s.send_header("content-length",str(len(r))); s.end_headers(); s.wfile.write(r)
    def log_message(*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[3])),H).serve_forever()
