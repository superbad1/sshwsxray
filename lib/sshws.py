#!/usr/bin/env python3
"""SSH-over-WebSocket bridge (handshake-only, pure Python stdlib).

Hanya melakukan handshake HTTP/WebSocket:

    1. klien kirim GET / dengan header Upgrade: websocket
    2. server balas 101 Switching Protocols
    3. setelah itu stream TCP diteruskan apa adanya (raw byte) ke target,
       normalnya sshd di 127.0.0.1:22

Tidak ada framing RFC 6455 (masking, fragmentasi, ping/pong, close frame):
setelah upgrade, isi koneksi adalah byte SSH mentah dua arah. Ini cocok
untuk klien tunnel berbasis HTTP Upgrade (injector/HTTP custom) dan payload
tidak lagi dibungkus, sehingga overhead nol dan payload bisa besar.

Path: standar `/` — TIDAK ada path khusus untuk SSH-WS, jadi berapa pun
path yang diminta klien tetap diterima (maksimal kompatibel dengan injector).
Bila `--path` diisi selain `/`, pencocokan path ditegakkan lagi (404 bila beda).

Router Xray: port 80/443 dipakai bersama SSH-WebSocket dan Xray, jadi bridge
ini juga bisa menjadi router berbasis path (seperti nginx). Setiap `--route
/path=host:port` mengarahkan path tertentu ke inbound Xray; request upgrade
diteruskan APA ADANYA sehingga Xray sendiri yang menjawab 101. Path yang tidak
cocok dengan route mana pun tetap dilayani sebagai SSH.

Usage:
    sshws.py --port 80  --target 127.0.0.1:22
    sshws.py --port 443 --target 127.0.0.1:22 \
             --route /vmTOKEN=127.0.0.1:10086 \
             --route /vlTOKEN=127.0.0.1:10088 \
             --tls --cert /etc/sshwsxray/cert/fullchain.pem \
                  --key  /etc/sshwsxray/cert/privkey.pem

Notes:
    * Auth is NOT handled here: sshd authenticates the SSH session, so the
      Linux user/expiry/IP-limit rules apply exactly like plain SSH.
    * Path standar `/`: semua path diterima (lihat --path untuk mode ketat).
    * Ada batas koneksi global (--max-connections) dan per-IP (--max-per-ip)
      supaya satu sumber tidak menghabiskan kuota koneksi.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import logging
import os
import signal
import socket
import ssl
import sys
from typing import Optional, Tuple

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

CHUNK = 32 * 1024
MAX_HEADER = 16 * 1024

log = logging.getLogger("sshws")


# --------------------------------------------------------------------------
# HTTP upgrade handshake
# --------------------------------------------------------------------------
def normalize_path(path: str) -> str:
    """'/wsxray/', 'wsxray', '/wsxray?x=1' -> '/wsxray'; '/' -> '/'."""
    clean = path.split("?", 1)[0].strip().strip("/")
    return "/" + clean if clean else "/"


def make_accept(key: str) -> str:
    digest = hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def parse_request(raw: bytes) -> Tuple[str, str, dict]:
    head = raw.split(b"\r\n\r\n", 1)[0]
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split()
    method = parts[0] if parts else ""
    path = parts[1] if len(parts) > 1 else ""
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
    return method, path, headers


async def read_request(reader: asyncio.StreamReader, timeout: float) -> Optional[bytes]:
    try:
        return await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
        return None


def http_error(writer: asyncio.StreamWriter, code: int, text: str) -> None:
    body = text.encode()
    writer.write(
        (
            "HTTP/1.1 {code} {text}\r\n"
            "Content-Type: text/plain\r\n"
            "Content-Length: {length}\r\n"
            "Connection: close\r\n\r\n{text}"
        )
        .format(code=code, text=text, length=len(body))
        .encode()
    )


def peer_ip(peer) -> str:
    """Ambil alamat IP dari hasil get_extra_info('peername')."""
    if isinstance(peer, (tuple, list)) and peer:
        return str(peer[0])
    return "unknown"


class PeerMap:
    """Peta `port loopback bridge -> IP klien asli`, satu baris `port|ip`.

    Bridge menyambung ke sshd dari 127.0.0.1, jadi sshd - dan `ss` yang dipakai
    cron/monitor - melihat SEMUA klien WebSocket seolah datang dari loopback.
    Akibatnya limit IP per akun (yang dihitung dari IP unik di port 22) tidak
    pernah tercapai untuk pengguna WS, padahal itulah jalur utamanya. File ini
    membuat cron bisa mengembalikan IP asli klien.

    Sejak Python 3.3, open() memakai O_CLOEXEC; asyncio loop tunggal, jadi
    penulisan ulang file ini tidak butuh penguncian.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.entries: dict[int, str] = {}
        self.enabled = True
        # mulai dari bersih: sisakan entri basi dari proses sebelumnya
        self._flush()

    def register(self, writer: asyncio.StreamWriter, ip: str) -> Optional[int]:
        if not self.enabled:
            return None
        sockname = writer.get_extra_info("sockname")
        if not sockname or len(sockname) < 2:
            return None
        port = int(sockname[1])
        self.entries[port] = ip
        self._flush()
        return port

    def unregister(self, port: int) -> None:
        if self.entries.pop(port, None) is not None:
            self._flush()

    def _flush(self) -> None:
        tmp = "%s.tmp.%d" % (self.path, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                for port, ip in sorted(self.entries.items()):
                    fh.write("%d|%s\n" % (port, ip))
            os.replace(tmp, self.path)
            os.chmod(self.path, 0o600)
        except OSError as exc:
            log.warning(
                "tidak bisa menulis peer map %s (%s) - limit IP jalur WS dimatikan",
                self.path,
                exc,
            )
            self.enabled = False
            try:
                os.unlink(tmp)
            except OSError:
                pass


def tune(sock: Optional[socket.socket]) -> None:
    """Low latency matters for interactive SSH."""
    if sock is None:
        return
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except OSError:
        pass


# --------------------------------------------------------------------------
# Raw pipes (no WebSocket framing after the upgrade)
# --------------------------------------------------------------------------
async def pump(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    while True:
        data = await src.read(CHUNK)
        if not data:
            # Half-close: write_eof() TIDAK didukung transport TLS
            # (raise NotImplementedError), jadi kegagalannya diabaikan.
            try:
                dst.write_eof()
            except (OSError, RuntimeError, NotImplementedError):
                pass
            return
        dst.write(data)
        await dst.drain()


# --------------------------------------------------------------------------
# Per-connection handling
# --------------------------------------------------------------------------
async def connect_backend(
    host: str, port: int, timeout: float
) -> Tuple[Optional[asyncio.StreamReader], Optional[asyncio.StreamWriter]]:
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout
        )
    except (OSError, asyncio.TimeoutError) as exc:
        log.error("gagal konek ke %s:%s (%s)", host, port, exc)
        return None, None
    tune(writer.get_extra_info("socket"))
    return reader, writer


async def relay(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    target_reader: asyncio.StreamReader,
    target_writer: asyncio.StreamWriter,
) -> None:
    """Salurkan byte dua arah apa adanya sampai salah satu sisi selesai."""
    upstream = asyncio.create_task(pump(reader, target_writer))
    downstream = asyncio.create_task(pump(target_reader, writer))
    done, pending = await asyncio.wait(
        {upstream, downstream}, return_when=asyncio.FIRST_COMPLETED
    )
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)
    for task in done:
        exc = task.exception()
        if exc and not isinstance(
            exc,
            (
                ConnectionResetError,
                ConnectionAbortedError,
                BrokenPipeError,
                asyncio.IncompleteReadError,
            ),
        ):
            log.debug("task berhenti dengan error: %r", exc)


async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    args: argparse.Namespace,
) -> None:
    peer = writer.get_extra_info("peername")
    tune(writer.get_extra_info("socket"))
    target_writer: Optional[asyncio.StreamWriter] = None
    registered_port: Optional[int] = None
    try:
        raw = await read_request(reader, args.handshake_timeout)
        if raw is None:
            log.warning("handshake gagal/timeout dari %s", peer)
            return

        method, path, headers = parse_request(raw)
        req_path = normalize_path(path)

        # ---- Mode router: path cocok dengan --route -> teruskan ke backend ----
        # Dipakai Xray: request diteruskan APA ADANYA (tanpa satu byte pun
        # dibuang) sehingga backend itu sendiri yang menjawab 101, dan byte
        # yang sudah dipipelkan klien tetap utuh.
        route = args.routes.get(req_path)
        if route is not None:
            target_reader, target_writer = await connect_backend(
                route[0], route[1], args.connect_timeout
            )
            if target_writer is None:
                http_error(writer, 502, "Bad Gateway")
                await writer.drain()
                return
            target_writer.write(raw)
            await target_writer.drain()
            log.info("route %s -> %s:%s dari %s", req_path, route[0], route[1], peer)
            await relay(reader, writer, target_reader, target_writer)
            return

        # ---- Mode SSH: bridge balas 101 sendiri lalu pipe ke sshd ----
        want = normalize_path(args.path)
        upgrade = headers.get("upgrade", "").lower()
        connection = headers.get("connection", "").lower()

        # Standar '/': tanpa path khusus, semua path diterima.
        if want != "/" and req_path != want:
            log.info("path tidak cocok (%s) dari %s", path, peer)
            http_error(writer, 404, "Not Found")
            await writer.drain()
            return

        if (
            method != "GET"
            or "websocket" not in upgrade
            or "upgrade" not in connection
        ):
            log.info("request bukan upgrade websocket dari %s", peer)
            http_error(writer, 400, "Bad Request")
            await writer.drain()
            return

        # Batas per-IP hanya untuk jalur SSH: satu klien Xray bisa membuka
        # puluhan koneksi sah, jadi tidak boleh dihitung dengan limit akun SSH.
        ip = peer_ip(peer)
        limited = args.max_per_ip > 0
        if limited:
            if args.per_ip.get(ip, 0) >= args.max_per_ip:
                log.warning("batas %d koneksi per IP tercapai (%s)", args.max_per_ip, ip)
                writer.close()
                return
            args.per_ip[ip] = args.per_ip.get(ip, 0) + 1

        try:
            # Balas 101 Switching Protocols. Sec-WebSocket-Accept hanya
            # dikirim bila klien menyertakan key (sebagian injector tidak).
            response = [
                "HTTP/1.1 101 Switching Protocols",
                "Upgrade: websocket",
                "Connection: Upgrade",
            ]
            key = headers.get("sec-websocket-key")
            if key:
                response.append("Sec-WebSocket-Accept: %s" % make_accept(key))
            writer.write(("\r\n".join(response) + "\r\n\r\n").encode())
            await writer.drain()

            target_reader, target_writer = await connect_backend(
                args.target_host, args.target_port, args.connect_timeout
            )
            if target_writer is None:
                return

            # catat IP asli klien untuk port loopback ini, supaya cron bisa
            # menghitung jumlah IP unik per akun (limit IP) walau lewat WS
            if args.peer_map_state is not None:
                registered_port = args.peer_map_state.register(target_writer, ip)

            log.info(
                "bridge aktif: %s -> %s:%s (request %s)",
                peer,
                args.target_host,
                args.target_port,
                path or "/",
            )

            # Data yang sudah ikut terkirim setelah header tetap ada di buffer
            # `reader` dan akan terbaca oleh pump (tanpa kehilangan byte).
            await relay(reader, writer, target_reader, target_writer)
        finally:
            if limited:
                remaining = args.per_ip.get(ip, 1) - 1
                if remaining > 0:
                    args.per_ip[ip] = remaining
                else:
                    args.per_ip.pop(ip, None)
    except (ConnectionResetError, ConnectionAbortedError, asyncio.IncompleteReadError):
        pass
    except Exception as exc:  # noqa: BLE001 - satu klien tidak boleh menjatuhkan service
        log.warning("error menangani %s: %r", peer, exc)
    finally:
        if registered_port is not None and args.peer_map_state is not None:
            args.peer_map_state.unregister(registered_port)
        for closer in (target_writer, writer):
            if closer is None:
                continue
            try:
                closer.close()
            except OSError:
                pass


# --------------------------------------------------------------------------
# Server bootstrap
# --------------------------------------------------------------------------
def parse_target(value: str) -> Tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host or not port.isdigit():
        raise argparse.ArgumentTypeError("format target harus host:port")
    return host, int(port)


def parse_route(value: str) -> Tuple[str, str, int]:
    """'/path=host:port' -> ('/path', 'host', port)."""
    path, sep, target = value.partition("=")
    if not sep or not path.strip() or not target.strip():
        raise argparse.ArgumentTypeError("format route harus /path=host:port")
    host, port = parse_target(target.strip())
    return normalize_path(path.strip()), host, port


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="SSH over WebSocket bridge + router Xray")
    p.add_argument("--listen", default="0.0.0.0", help="alamat bind (default 0.0.0.0)")
    p.add_argument("--port", type=int, required=True, help="port listen")
    p.add_argument(
        "--path",
        default="/",
        help="path websocket; '/' (default) = terima semua path",
    )
    p.add_argument("--target", default="127.0.0.1:22", help="target TCP SSH (default 127.0.0.1:22)")
    p.add_argument(
        "--route",
        action="append",
        type=parse_route,
        default=[],
        metavar="/PATH=HOST:PORT",
        help="teruskan path ini ke backend lain (mis. inbound Xray); bisa diulang",
    )
    p.add_argument("--tls", action="store_true", help="aktifkan TLS (wss)")
    p.add_argument("--cert", help="path fullchain.pem")
    p.add_argument("--key", help="path privkey.pem")
    p.add_argument(
        "--peer-map",
        default="",
        help="file 'port|ip' berisi IP asli klien (dipakai penegakan limit IP)",
    )
    p.add_argument("--handshake-timeout", type=float, default=10.0)
    p.add_argument("--connect-timeout", type=float, default=10.0)
    p.add_argument("--max-connections", type=int, default=1024)
    p.add_argument(
        "--max-per-ip",
        type=int,
        default=16,
        help="batas koneksi bersamaan per alamat IP (0 = tanpa batas)",
    )
    p.add_argument("--verbose", "-v", action="store_true")
    return p


async def run(args: argparse.Namespace) -> None:
    args.target_host, args.target_port = parse_target(args.target)

    ssl_ctx = None
    if args.tls:
        if not args.cert or not args.key:
            raise SystemExit("--tls butuh --cert dan --key")
        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(args.cert, args.key)
        ssl_ctx.minimum_version = ssl.TLSVersion.TLSv1_2

    sem = asyncio.Semaphore(args.max_connections)
    # per-IP dijaga di dalam handle_client (hanya untuk jalur SSH)
    args.per_ip = {}
    args.routes = {route_path: (host, port) for route_path, host, port in args.route}
    args.peer_map_state = PeerMap(args.peer_map) if args.peer_map else None

    async def wrapped(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        async with sem:
            await handle_client(reader, writer, args)

    server = await asyncio.start_server(
        wrapped, host=args.listen, port=args.port, ssl=ssl_ctx, limit=MAX_HEADER
    )
    scheme = "wss" if args.tls else "ws"
    addr = ", ".join(str(sock.getsockname()[:2]) for sock in (server.sockets or []))
    routes = "".join(
        f", route {p} -> {h}:{port}" for p, (h, port) in sorted(args.routes.items())
    )
    log.info(
        "listen %s://%s%s -> sshd %s:%s%s (pid=%d)",
        scheme,
        addr,
        normalize_path(args.path),
        args.target_host,
        args.target_port,
        routes,
        os.getpid(),
    )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:  # pragma: no cover
            pass

    async with server:
        await stop.wait()
    log.info("shutdown")


def main() -> int:
    args = build_parser().parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
