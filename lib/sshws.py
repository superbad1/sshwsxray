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

Usage:
    sshws.py --port 80  --target 127.0.0.1:22
    sshws.py --port 443 --target 127.0.0.1:22 \
             --tls --cert /etc/sshwsxray/cert/fullchain.pem \
                  --key  /etc/sshwsxray/cert/privkey.pem

Notes:
    * Auth is NOT handled here: sshd authenticates the SSH session, so the
      Linux user/expiry/IP-limit rules apply exactly like plain SSH.
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
            try:
                dst.write_eof()
            except (OSError, RuntimeError):
                pass
            return
        dst.write(data)
        await dst.drain()


# --------------------------------------------------------------------------
# Per-connection handling
# --------------------------------------------------------------------------
async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    args: argparse.Namespace,
) -> None:
    peer = writer.get_extra_info("peername")
    tune(writer.get_extra_info("socket"))
    target_writer: Optional[asyncio.StreamWriter] = None
    try:
        raw = await read_request(reader, args.handshake_timeout)
        if raw is None:
            log.warning("handshake gagal/timeout dari %s", peer)
            return

        method, path, headers = parse_request(raw)
        want = normalize_path(args.path)
        upgrade = headers.get("upgrade", "").lower()
        connection = headers.get("connection", "").lower()

        # Standar '/': tanpa path khusus, semua path diterima.
        if want != "/" and normalize_path(path) != want:
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

        # Balas 101 Switching Protocols. Sec-WebSocket-Accept hanya dikirim
        # bila klien menyertakan key (sebagian injector tidak menyertakannya).
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

        try:
            target_reader, target_writer = await asyncio.wait_for(
                asyncio.open_connection(args.target_host, args.target_port),
                args.connect_timeout,
            )
        except (OSError, asyncio.TimeoutError) as exc:
            log.error("gagal konek ke %s:%s (%s)", args.target_host, args.target_port, exc)
            return

        tune(target_writer.get_extra_info("socket"))
        log.info(
            "bridge aktif: %s -> %s:%s (request %s)",
            peer,
            args.target_host,
            args.target_port,
            path or "/",
        )

        # Data yang sudah ikut terkirim setelah header tetap ada di buffer
        # `reader` dan akan terbaca oleh pump di bawah (tanpa kehilangan byte).
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
    except (ConnectionResetError, ConnectionAbortedError, asyncio.IncompleteReadError):
        pass
    except Exception as exc:  # noqa: BLE001 - satu klien tidak boleh menjatuhkan service
        log.warning("error menangani %s: %r", peer, exc)
    finally:
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


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="SSH over WebSocket bridge (handshake-only)")
    p.add_argument("--listen", default="0.0.0.0", help="alamat bind (default 0.0.0.0)")
    p.add_argument("--port", type=int, required=True, help="port listen")
    p.add_argument(
        "--path",
        default="/",
        help="path websocket; '/' (default) = terima semua path",
    )
    p.add_argument("--target", default="127.0.0.1:22", help="target TCP (default 127.0.0.1:22)")
    p.add_argument("--tls", action="store_true", help="aktifkan TLS (wss)")
    p.add_argument("--cert", help="path fullchain.pem")
    p.add_argument("--key", help="path privkey.pem")
    p.add_argument("--handshake-timeout", type=float, default=10.0)
    p.add_argument("--connect-timeout", type=float, default=10.0)
    p.add_argument("--max-connections", type=int, default=1024)
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

    async def wrapped(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        async with sem:
            await handle_client(reader, writer, args)

    server = await asyncio.start_server(
        wrapped, host=args.listen, port=args.port, ssl=ssl_ctx, limit=MAX_HEADER
    )
    scheme = "wss" if args.tls else "ws"
    addr = ", ".join(str(sock.getsockname()[:2]) for sock in (server.sockets or []))
    log.info(
        "listen %s://%s%s -> %s:%s (pid=%d)",
        scheme,
        addr,
        normalize_path(args.path),
        args.target_host,
        args.target_port,
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
