#!/usr/bin/env python3
"""End-to-end tests for lib/sshws.py (handshake-only SSH-over-WebSocket bridge).

Runs the bridge against a local TCP echo server and speaks the HTTP upgrade
handshake to it — no external dependencies, no root, no sshd needed. After the
101 response the connection is a raw TCP pipe, so the tests assert raw bytes
flow both ways instead of WebSocket frames.
"""
import base64
import hashlib
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "lib", "sshws.py")

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

failures = 0


def check(name, cond, detail=""):
    global failures
    if cond:
        print("PASS  " + name)
    else:
        print("FAIL  " + name + ((" :: " + str(detail)) if detail else ""))
        failures += 1


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def start_echo_server():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    port = srv.getsockname()[1]
    stop = threading.Event()

    def handle(conn):
        with conn:
            while True:
                try:
                    data = conn.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                conn.sendall(data)

    def serve():
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=handle, args=(conn,), daemon=True).start()

    threading.Thread(target=serve, daemon=True).start()
    return port, srv, stop


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_port(port, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


class RawClient:
    """Minimal HTTP-upgrade client: handshake, then raw byte stream."""

    def __init__(self, port, host="127.0.0.1", tls=False, timeout=5.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        if tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self.sock = ctx.wrap_socket(self.sock, server_hostname=host)
        self.key = base64.b64encode(os.urandom(16)).decode()
        self.status = None
        self.headers = {}
        self.extra = b""

    def handshake(self, path="/", upgrade=True, include_key=True, extra=b""):
        req = ["GET %s HTTP/1.1" % path, "Host: 127.0.0.1"]
        if upgrade:
            req.append("Upgrade: websocket")
            req.append("Connection: Upgrade")
            req.append("Sec-WebSocket-Version: 13")
            if include_key:
                req.append("Sec-WebSocket-Key: " + self.key)
        req += ["", ""]
        self.sock.sendall("\r\n".join(req).encode() + extra)

        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            raw += chunk
        head, _, rest = raw.partition(b"\r\n\r\n")
        self.extra = rest
        first = head.split(b"\r\n", 1)[0].decode("latin-1")
        parts = first.split(" ", 2)
        self.status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        for line in head.split(b"\r\n")[1:]:
            if b":" in line:
                k, _, v = line.partition(b":")
                self.headers[k.strip().decode().lower()] = v.strip().decode()
        self.accept = self.headers.get("sec-websocket-accept")
        return head

    def send(self, data):
        self.sock.sendall(data)

    def recv_exact(self, n, timeout=None):
        if timeout is not None:
            self.sock.settimeout(timeout)
        buf = self.extra
        self.extra = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("socket closed")
            buf += chunk
        if len(buf) > n:
            self.extra = buf[n:]
            buf = buf[:n]
        return buf

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def start_bridge(port, path, target_port, tls=False, cert=None, key=None):
    """path=None -> mode standar '/' (tanpa path khusus)."""
    cmd = [
        sys.executable, BRIDGE,
        "--listen", "127.0.0.1",
        "--port", str(port),
        "--target", "127.0.0.1:%d" % target_port,
    ]
    if path is not None:
        cmd += ["--path", path]
    if tls:
        cmd += ["--tls", "--cert", cert, "--key", key]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    if not wait_port(port):
        proc.kill()
        raise RuntimeError("bridge tidak start di port %d" % port)
    return proc


# --------------------------------------------------------------------------
# tests
# --------------------------------------------------------------------------
def main():
    echo_port, echo_srv, echo_stop = start_echo_server()
    inst = tempfile.mkdtemp(prefix="sshws-test-")
    cert = os.path.join(inst, "fullchain.pem")
    key = os.path.join(inst, "privkey.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost"],
        check=True, capture_output=True,
    )

    # bridge utama: TANPA --path  (path standar '/', semua path diterima)
    ws_port = free_port()
    bridge = start_bridge(ws_port, None, echo_port)
    tls_port = free_port()
    bridge_tls = start_bridge(tls_port, None, echo_port, tls=True, cert=cert, key=key)
    # bridge mode ketat: --path test (pencocokan path ditegakkan)
    strict_port = free_port()
    bridge_strict = start_bridge(strict_port, "test", echo_port)

    try:
        # 1. handshake upgrade di path standar '/'
        c = RawClient(ws_port)
        c.handshake(path="/")
        expected = base64.b64encode(
            hashlib.sha1((c.key + GUID).encode()).digest()
        ).decode()
        check("handshake 101 di '/'", c.status == 101, c.status)
        check("Sec-WebSocket-Accept benar", c.accept == expected, c.accept)
        check("Upgrade header ada", c.headers.get("upgrade", "").lower() == "websocket")
        check("Connection: Upgrade ada", "upgrade" in c.headers.get("connection", "").lower())

        # 2. byte mentah lewat bridge (tanpa framing)
        c.send(b"SSH-2.0-test\r\n")
        check("echo byte mentah", c.recv_exact(14) == b"SSH-2.0-test\r\n")
        c.close()

        # 3. tanpa path khusus: path apa pun tetap diterima
        for p in ("/wsxray", "/anything", "/a/b/c", "/"):
            cx = RawClient(ws_port)
            cx.handshake(path=p)
            cx.send(b"raw")
            ok = cx.status == 101 and cx.recv_exact(3) == b"raw"
            check("path bebas diterima: %s" % p, ok, cx.status)
            cx.close()

        # 4. mode ketat (--path test): path cocok diterima, beda 404
        c3 = RawClient(strict_port)
        c3.handshake(path="/test")
        check("mode ketat: path cocok => 101", c3.status == 101, c3.status)
        c3.close()
        c3b = RawClient(strict_port)
        c3b.handshake(path="/salah")
        check("mode ketat: path salah => 404", c3b.status == 404, c3b.status)
        c3b.close()

        # 5. bukan upgrade -> 400
        c4 = RawClient(ws_port)
        c4.handshake(path="/", upgrade=False)
        check("bukan upgrade => 400", c4.status == 400, c4.status)
        c4.close()

        # 6. tanpa Sec-WebSocket-Key tetap di-upgrade (kompatibel injector)
        c5 = RawClient(ws_port)
        c5.handshake(path="/", include_key=False)
        check("tanpa key tetap 101", c5.status == 101, c5.status)
        check("tanpa key tidak ada accept header", c5.accept is None, c5.accept)
        c5.send(b"nokey")
        check("tanpa key tetap echo", c5.recv_exact(5) == b"nokey")
        c5.close()

        # 7. data yang dipipelkan bersama handshake tidak boleh hilang
        c6 = RawClient(ws_port)
        c6.handshake(path="/", extra=b"pipelined-payload")
        check("data pipelined utuh", c6.recv_exact(17) == b"pipelined-payload")
        c6.close()

        # 8. payload besar 1 MB bolak-balik utuh
        c7 = RawClient(ws_port, timeout=30.0)
        c7.handshake(path="/")
        blob = os.urandom(1_000_000)
        c7.send(blob)
        got = c7.recv_exact(len(blob), timeout=30.0)
        check("payload 1MB utuh", got == blob, "%d/%d bytes" % (len(got), len(blob)))
        c7.close()

        # 9. TLS (wss) + echo mentah
        c8 = RawClient(tls_port, tls=True)
        c8.handshake(path="/")
        check("handshake TLS 101", c8.status == 101, c8.status)
        c8.send(b"tls-hello")
        check("echo via TLS", c8.recv_exact(9) == b"tls-hello")
        c8.close()

        # 10. koneksi serentak (8 klien)
        clients = []
        try:
            for i in range(8):
                cc = RawClient(ws_port)
                cc.handshake(path="/")
                cc.send(b"client-%d" % i)
                clients.append((cc, i))
            ok = True
            for cc, i in clients:
                if cc.recv_exact(8) != b"client-%d" % i:
                    ok = False
            check("8 koneksi serentak", ok and all(cc.status == 101 for cc, _ in clients))
        finally:
            for cc, _ in clients:
                cc.close()

        # 11. klien putus di tengah jalan tidak menjatuhkan service
        c9 = RawClient(ws_port)
        c9.handshake(path="/")
        c9.send(b"bye")
        c9.close()
        c10 = RawClient(ws_port)
        c10.handshake(path="/")
        c10.send(b"still-alive")
        check("service tetap hidup setelah klien putus",
              c10.recv_exact(11) == b"still-alive")
        c10.close()
    finally:
        bridge.terminate()
        bridge_tls.terminate()
        bridge_strict.terminate()
        echo_stop.set()
        echo_srv.close()

    print()
    if failures == 0:
        print("ALL SSHWS TESTS PASSED")
        return 0
    print("FAILED: %d" % failures)
    return 1


if __name__ == "__main__":
    sys.exit(main())
