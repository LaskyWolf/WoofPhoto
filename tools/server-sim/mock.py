#!/usr/bin/env python3
"""A mock Immich server shaped after the OpenAPI spec: bucket dates, bulk-upload-check, thumbnails, errors."""
import json, hashlib, random, sys, time, re, base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timedelta, timezone

random.seed(7)
def sha(b): return hashlib.sha1(b).hexdigest()
def uuid(i): return "%08x-0000-4000-8000-%012x" % (i, i)
base = datetime(2026, 5, 10, 10, 20, 30, 250000, tzinfo=timezone.utc)
fmts = {
  "z3": lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (d.microsecond // 1000),
  "pg6": lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.%f") + "+00:00",
  "pgspace": lambda d: d.strftime("%Y-%m-%d %H:%M:%S") + "+00",
  "nozone": lambda d: d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03d" % (d.microsecond // 1000),
}
phone, server, truth = [], [], {}   # truth: localID -> serverID or None
def add(name, content, p_date, s_date=None, on_server=True, image=True, trashed=False, fmt="z3", server_content=None):
    lid = "PH-" + name + "/L0/001"
    phone.append(dict(localID=lid, sha1=sha(content), date=fmts["z3"](p_date), isImage=image))
    if on_server:
        sid = uuid(len(server) + 1)
        server.append(dict(id=sid, sha1=sha(server_content or content), fileCreatedAt=fmts[fmt](s_date or p_date), isImage=image, isTrashed=trashed))
        truth[lid] = None if trashed else sid
    else:
        truth[lid] = None
t = lambda s: base + timedelta(seconds=s)
add("same", b"same-bytes", t(0))
add("pgfmt", b"pg-six", t(10), fmt="pg6")
add("spacefmt", b"pg-space", t(20), fmt="pgspace")
add("nozone", b"no-zone", t(30), fmt="nozone")
add("tzshift", b"tz-shifted", t(40), s_date=t(40) + timedelta(hours=2))     # server stored the wrong zone: time can't match
add("subsecond", b"sub-second", t(50), s_date=t(50) - timedelta(milliseconds=900))
add("phoneonly", b"only-phone", t(60), on_server=False)
add("trashed", b"in-trash", t(70), trashed=True)
add("edited", b"edited-original", t(80), server_content=b"edited-original")  # same original bytes
for i, n in enumerate("abc"):
    add("burst" + n, ("burst-" + n).encode(), t(100), on_server=(n != "c"))     # 3 on phone, 2 on server, same second
add("video", b"video-bytes", t(120), image=False)
add("photo-same-second-as-video", b"other-photo", t(120), on_server=False)
json.dump(dict(phone=phone, server=server, truth=truth), open("fixtures.json", "w"), indent=1)
by_sha = {s["sha1"]: s for s in server}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def auth(self):
        if self.headers.get("Authorization") != "Bearer good": self.send(401, dict(message="Invalid user token", statusCode=401)); return False
        return True
    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/api/server/ping": return self.send(200, dict(res="pong"))
        if p == "/proxy-html-404": return self.send(404, b"<html>nginx 404</html>", "text/html")
        if p == "/api/_uploads": return self.send(200, self.server.uploads)
        if p == "/api/slow": time.sleep(3); return self.send(200, {})
        if p == "/api/garbage": return self.send(200, b"not json at all", "text/plain")
        if p == "/api/boom": return self.send(500, b"<html>bad gateway</html>", "text/html")
        m = re.match(r"/api/assets/([^/]+)/thumbnail", p)
        if m:
            if not self.auth(): return
            if m.group(1).startswith("local:"): return self.send(404, dict(message="Asset media not found", error="Not Found", statusCode=404))
            if m.group(1) == uuid(999): return self.send(404, dict(message="Asset media not found", error="Not Found", statusCode=404))
            return self.send(200, b"\xff\xd8\xff", "image/jpeg")
        return self.send(404, dict(message="Cannot GET " + p, error="Not Found", statusCode=404))
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n)
        p = self.path.split("?")[0]
        if not self.auth(): return
        if p == "/api/assets/bulk-upload-check":
            out = []
            for a in json.loads(raw)["assets"]:
                s = by_sha.get(a["checksum"])
                if s: out.append(dict(id=a["id"], action="reject", reason="duplicate", assetId=s["id"], isTrashed=s["isTrashed"]))
                else: out.append(dict(id=a["id"], action="accept"))
            return self.send(200, dict(results=out))
        if p == "/api/assets":
            fields = dict(re.findall(rb'name="([^"]+)"\r\n\r\n([^\r]*)\r\n', raw))
            rec = {k.decode(): v.decode() for k, v in fields.items() if k != b"assetData"}
            boundary = self.headers["Content-Type"].split("boundary=")[1].encode()
            start = raw.index(b'name="assetData"'); start = raw.index(b"\r\n\r\n", start) + 4
            end = raw.index(b"\r\n--" + boundary + b"--")
            rec["_sha1"] = sha(raw[start:end]); rec["_size"] = end - start
            rec["_filename"] = re.search(rb'name="assetData"; filename="([^"]*)"', raw).group(1).decode()
            self.server.uploads.append(rec)
            return self.send(201, dict(id=uuid(5000 + len(self.server.uploads)), status="created"))
        return self.send(404, dict(message="Cannot POST " + p, error="Not Found", statusCode=404))

srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H); srv.uploads = []
print("ready", flush=True); srv.serve_forever()
