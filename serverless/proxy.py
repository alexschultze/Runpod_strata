"""Kleiner Reverse-Proxy für RunPod Load-Balancing-Endpoints.
/ping -> 204 solange Strata lädt, 200 sobald /health loaded=true meldet.
Alles andere wird (gestreamt) an Strata weitergereicht. Nur stdlib."""
import http.client, json, os, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = ("127.0.0.1", int(os.environ.get("STRATA_PORT", "8080")))
LISTEN = int(os.environ.get("PORT", "8000"))
HEALTH = int(os.environ.get("PORT_HEALTH", str(LISTEN)))
HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization", "host"}


def ready():
    try:
        c = http.client.HTTPConnection(*UP, timeout=3)
        c.request("GET", "/health")
        r = c.getresponse()
        return r.status == 200 and json.loads(r.read() or b"{}").get("loaded") is not False
    except Exception:
        return False


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a): pass

    def _ping(self):
        self.send_response(200 if ready() else 204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _proxy(self):
        if self.path.split("?")[0] == "/ping":
            return self._ping()
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        hdr = {k: v for k, v in self.headers.items() if k.lower() not in HOP | {"content-length"}}
        hdr["Host"] = "%s:%d" % UP  # Strata prüft den Host-Header (DNS-Rebinding-Schutz)
        try:
            c = http.client.HTTPConnection(*UP, timeout=3600)
            c.request(self.command, self.path, body, hdr)
            r = c.getresponse()
        except (OSError, http.client.HTTPException):
            self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in HOP | {"content-length"}:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                chunk = r.read1(8192)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True
        finally:
            c.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_OPTIONS = do_HEAD = _proxy


class S(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64


if __name__ == "__main__":
    if HEALTH != LISTEN:  # eigener Health-Port: nur /ping
        import threading
        threading.Thread(target=S(("0.0.0.0", HEALTH), H).serve_forever, daemon=True).start()
    S(("0.0.0.0", LISTEN), H).serve_forever()
