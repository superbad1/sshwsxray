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


def start_backend_server(marker=b"X-Backend: XRAY"):
    """Backend tiruan yang menjawab 101 SENDIRI (meniru inbound Xray).

    `seen` menyimpan request mentah yang diterima backend, supaya test bisa
    memastikan bridge meneruskan handshake asli (bukan membuat 101 sendiri).
    """
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    port = srv.getsockname()[1]
    stop = threading.Event()
    seen = []

    def handle(conn):
        with conn:
            req = b""
            while b"\r\n\r\n" not in req:
                try:
                    chunk = conn.recv(4096)
                except OSError:
                    return
                if not chunk:
                    return
                req += chunk
            seen.append(req)
            conn.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                + marker
                + b"\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            )
            while True:
                try:
                    data = conn.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                conn.sendall(b"BACKEND:" + data)

    def serve():
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=handle, args=(conn,), daemon=True).start()

    threading.Thread(target=serve, daemon=True).start()
    return port, srv, stop, seen


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


def start_bridge(port, path, target_port, tls=False, cert=None, key=None, max_per_ip=0, routes=None, peer_map=None):
    """path=None -> mode standar '/' (tanpa path khusus).

    max_per_ip=0 -> tanpa batas per-IP (dipakai mayoritas test agar saling
    tidak mengganggu karena semuanya datang dari 127.0.0.1).
    """
    cmd = [
        sys.executable, BRIDGE,
        "--listen", "127.0.0.1",
        "--port", str(port),
        "--target", "127.0.0.1:%d" % target_port,
        "--max-per-ip", str(max_per_ip),
    ]
    if path is not None:
        cmd += ["--path", path]
    for route in routes or []:
        cmd += ["--route", route]
    if peer_map:
        cmd += ["--peer-map", peer_map]
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
    # bridge dengan batas per-IP kecil untuk menguji proteksi abuse
    limited_port = free_port()
    bridge_limited = start_bridge(limited_port, None, echo_port, max_per_ip=2)

    # bridge mode router: /rahasia -> backend Xray tiruan, sisanya -> echo (SSH)
    backend_port, backend_srv, backend_stop, backend_seen = start_backend_server()
    router_port = free_port()
    bridge_router = start_bridge(
        router_port, None, echo_port,
        routes=["/rahasia=127.0.0.1:%d" % backend_port],
    )

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

        # 12. batas koneksi per-IP (max-per-ip=2): koneksi ke-3 ditolak
        ok1 = RawClient(limited_port)
        ok1.handshake(path="/")
        ok1.send(b"one")
        ok2 = RawClient(limited_port)
        ok2.handshake(path="/")
        ok2.send(b"two")
        check("per-IP: 2 koneksi pertama diterima",
              ok1.recv_exact(3) == b"one" and ok2.recv_exact(3) == b"two")
        blocked = False
        try:
            over = RawClient(limited_port, timeout=3.0)
            over.handshake(path="/")
            blocked = over.status != 101
            over.close()
        except (ConnectionError, OSError):
            blocked = True
        check("per-IP: koneksi ke-3 ditolak", blocked)
        ok1.close(); ok2.close()
        time.sleep(0.5)
        # setelah slot bebas, koneksi baru diterima lagi
        again = RawClient(limited_port, timeout=3.0)
        try:
            again.handshake(path="/")
            again.send(b"again")
            check("per-IP: slot bebas dipakai lagi", again.recv_exact(5) == b"again")
        except (ConnectionError, OSError):
            check("per-IP: slot bebas dipakai lagi", False, "koneksi ditolak")
        again.close()

        # 13. mode router: path yang terdaftar diteruskan ke backend Xray,
        #     dan backend (bukan bridge) yang menjawab 101.
        r1 = RawClient(router_port)
        r1.handshake(path="/rahasia")
        check("router: path terdaftar dapat 101", r1.status == 101, r1.status)
        check("router: 101 datang dari backend, bukan bridge",
              r1.headers.get("x-backend") == "XRAY", r1.headers)
        check("router: handshake diteruskan apa adanya",
              any(b"Sec-WebSocket-Key" in req and b"GET /rahasia" in req
                  for req in backend_seen), backend_seen)
        r1.send(b"vmess-payload")
        check("router: byte diteruskan dua arah",
              r1.recv_exact(21) == b"BACKEND:vmess-payload")
        r1.close()

        # 14. query string diabaikan saat mencocokkan route
        r2 = RawClient(router_port)
        r2.handshake(path="/rahasia?ed=2048")
        check("router: query string diabaikan",
              r2.status == 101 and r2.headers.get("x-backend") == "XRAY", r2.status)
        r2.close()

        # 15. path yang tidak terdaftar tetap jalur SSH (bridge yang jawab 101)
        r3 = RawClient(router_port)
        r3.handshake(path="/apapun")
        check("router: path lain tetap jalur SSH",
              r3.status == 101 and r3.headers.get("x-backend") is None, r3.headers)
        r3.send(b"ssh-payload")
        check("router: jalur SSH tetap pipe ke sshd",
              r3.recv_exact(11) == b"ssh-payload")
        r3.close()

        # 16. route di port TLS juga berfungsi (bridge yang menerima TLS)
        tls_router_port = free_port()
        bridge_router_tls = start_bridge(
            tls_router_port, None, echo_port, tls=True, cert=cert, key=key,
            routes=["/rahasia=127.0.0.1:%d" % backend_port],
        )
        try:
            r4 = RawClient(tls_router_port, tls=True)
            r4.handshake(path="/rahasia")
            check("router TLS: path terdaftar diteruskan",
                  r4.status == 101 and r4.headers.get("x-backend") == "XRAY",
                  r4.status)
            r4.send(b"wss-payload")
            check("router TLS: byte diteruskan dua arah",
                  r4.recv_exact(19) == b"BACKEND:wss-payload")
            r4.close()
        finally:
            bridge_router_tls.terminate()

        # 17. --peer-map: bridge mencatat IP asli klien selama koneksi hidup.
        # Di sisi sshd semua klien WS tampak dari 127.0.0.1, jadi tanpa peta
        # ini limit IP per akun tidak pernah tercapai.
        peer_map_path = os.path.join(inst, "ws_peers.db")
        peer_port = free_port()
        peer_bridge = start_bridge(peer_port, None, echo_port, peer_map=peer_map_path)
        try:
            pclient = RawClient(peer_port)
            pclient.handshake()
            check("peer-map: handshake bridge", pclient.status == 101, pclient.status)
            pclient.send(b"x")
            check("peer-map: byte mengalir lewat bridge", pclient.recv_exact(1) == b"x")

            lines = []
            if os.path.exists(peer_map_path):
                with open(peer_map_path) as fh:
                    lines = [ln.strip() for ln in fh if ln.strip()]
            entry_ok = len(lines) == 1 and lines[0].split("|")[-1] == "127.0.0.1"
            check("peer-map: IP klien dicatat", entry_ok, lines)

            pclient.close()
            emptied = False
            for _ in range(50):
                try:
                    with open(peer_map_path) as fh:
                        emptied = fh.read().strip() == ""
                except OSError:
                    emptied = True
                if emptied:
                    break
                time.sleep(0.1)
            check("peer-map: entri dibersihkan setelah koneksi tutup", emptied)
        finally:
            peer_bridge.terminate()
    finally:
        bridge.terminate()
        bridge_tls.terminate()
        bridge_strict.terminate()
        bridge_limited.terminate()
        bridge_router.terminate()
        echo_stop.set()
        echo_srv.close()
        backend_stop.set()
        backend_srv.close()

    print()
    if failures == 0:
        print("ALL SSHWS TESTS PASSED")
        return 0
    print("FAILED: %d" % failures)
    return 1


if __name__ == "__main__":
    sys.exit(main())
