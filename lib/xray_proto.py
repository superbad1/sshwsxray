#!/usr/bin/env python3
"""Minimal protobuf encode/decode for Xray gRPC StatsService (no grpcio needed).

Used by lib/xray.sh to talk to the dokodemo-door API inbound:
  encode <pattern>          -> write gRPC-framed QueryStatsRequest to stdout
  decode <b64>              -> parse base64 gRPC frame, print "name###value### N"
  query <port> [pattern]    -> kirim request via TCP sendiri (tanpa netcat)

`query` ada supaya script tidak bergantung pada binary `nc` yang tidak
terpasang secara default di Debian/Ubuntu minimal.
"""
import base64
import socket
import struct
import sys

STATS_SERVICE = "xray.app.stats.command.QueryStats"


def _varint(n: int) -> bytes:
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            out += bytes([b])
            break
    return out


def _lp_field(num: int, data: bytes) -> bytes:
    """Length-prefixed (wire type 2) field."""
    return bytes([num << 3 | 2]) + _varint(len(data)) + data


def encode_query(pattern: str, reset: bool = True) -> bytes:
    body = _lp_field(1, pattern.encode())
    if reset:
        body += b"\x10\x01"  # field 2 (reset), varint true
    msg = _lp_field(1, STATS_SERVICE.encode()) + _lp_field(2, body)
    # gRPC framing: 1 byte compressed flag + 4 byte big-endian length
    return b"\x00" + struct.pack(">I", len(msg)) + msg


def _read_varint(d: bytes, i: int):
    shift = res = 0
    while i < len(d):
        b = d[i]
        i += 1
        res |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return res, i


def _read_lp(d: bytes, i: int):
    n, i = _read_varint(d, i)
    return d[i:i + n], i + n


def iter_grpc_frames(data: bytes):
    """Yield setiap pesan gRPC utuh (termasuk 5 byte header) dari stream."""
    i = 0
    while i + 5 <= len(data):
        length = struct.unpack(">I", data[i + 1:i + 5])[0]
        end = i + 5 + length
        if end > len(data):
            break
        yield data[i:end]
        i = end


def query(port: int, pattern: str = "", timeout: float = 5.0) -> int:
    """Hubungi StatsService via TCP, cetak "name<TAB>value" per statistik."""
    frame = encode_query(pattern)
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
            sock.sendall(frame)
            sock.settimeout(timeout)
            chunks = []
            while True:
                try:
                    data = sock.recv(65536)
                except (socket.timeout, TimeoutError):
                    break
                if not data:
                    break
                chunks.append(data)
    except OSError:
        return 1
    raw = b"".join(chunks)
    if not raw:
        return 1
    frames = list(iter_grpc_frames(raw)) or [raw]
    for msg in frames:
        for name, value in decode_response(msg):
            print("{0}\t{1}".format(name, value))
    return 0


def decode_response(data: bytes):
    """Yield (name, value) from a gRPC-framed QueryStatsResponse."""
    i = 0
    if i < len(data) and data[i] == 0:  # compressed flag byte
        i += 1
    if i + 4 <= len(data):
        i += 4  # big-endian length prefix
    while i < len(data):
        try:
            tag, i = _read_varint(data, i)
            if tag >> 3 != 1 or tag & 7 != 2:  # repeated field 1 (stat)
                break
            slen, i = _read_varint(data, i)
            end = i + slen
            name = b""
            value = 0
            j = i
            while j < end:
                ftag, j = _read_varint(data, j)
                fnum, ftyp = ftag >> 3, ftag & 7
                if fnum == 1 and ftyp == 2:
                    name, j = _read_lp(data, j)
                elif fnum == 2 and ftyp == 0:
                    value, j = _read_varint(data, j)
                elif fnum == 2 and ftyp == 5:
                    value = struct.unpack("<f", data[j:j + 4])[0]
                    j += 4
                elif fnum == 2 and ftyp == 1:
                    value = struct.unpack("<d", data[j:j + 8])[0]
                    j += 8
                else:
                    break
            if name:
                yield name.decode(errors="replace"), value
            i = end
        except Exception:
            break


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "encode":
        pattern = sys.argv[2] if len(sys.argv) > 2 else ""
        sys.stdout.buffer.write(encode_query(pattern))
        return 0
    if cmd == "decode":
        if len(sys.argv) < 3:
            return 1
        data = base64.b64decode(sys.argv[2])
        for name, value in decode_response(data):
            print(f"{name}###value### {value}")
        return 0
    if cmd == "query":
        if len(sys.argv) < 3 or not sys.argv[2].isdigit():
            print("usage: xray_proto.py query <port> [pattern]", file=sys.stderr)
            return 1
        pattern = sys.argv[3] if len(sys.argv) > 3 else ""
        return query(int(sys.argv[2]), pattern)
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
