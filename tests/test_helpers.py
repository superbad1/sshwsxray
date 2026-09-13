#!/usr/bin/env python3
"""Sandbox tests for lib/xray_proto.py and lib/xray_render.py (run locally, no root)."""
import base64
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib")
sys.path.insert(0, LIB)

import xray_proto  # noqa: E402
import xray_render  # noqa: E402

failures = 0


def check(name, cond):
    global failures
    print(("PASS  " if cond else "FAIL  ") + name)
    if not cond:
        failures += 1


# ---------- xray_proto ----------
# Build a fake QueryStatsResponse: stat{ name: "user>>>uuid@vmess-ws-in>>>traffic>>>uplink", value: 12345 }
def lp_field(num, data):
    return bytes([num << 3 | 2]) + xray_proto._varint(len(data)) + data


name = b"user>>>uuid-1@vmess-ws-in>>>traffic>>>uplink"
stat = lp_field(1, name) + b"\x10\xb9\x60"  # field2 varint 12345
msg = lp_field(1, stat)
frame = b"\x00" + struct.pack(">I", len(msg)) + msg

names = list(xray_proto.decode_response(frame))
check("decode single stat", names == [(name.decode(), 12345)])

enc = xray_proto.encode_query("", reset=True)
check("encode magic byte", enc[0] == 0)
check("encode length prefix", struct.unpack(">I", enc[1:5])[0] == len(enc) - 5)
check("encode roundtrip service", b"QueryStats" in enc)

# CLI mode
out = subprocess.run(
    [sys.executable, os.path.join(LIB, "xray_proto.py"), "decode", base64.b64encode(frame).decode()],
    capture_output=True, text=True)
check("CLI decode", "user>>>uuid-1@vmess-ws-in>>>traffic>>>uplink###value### 12345" in out.stdout)

# ---------- xray_render ----------
cfg = {
    "inbounds": [
        {"tag": "vmess-ws-in", "protocol": "vmess", "settings": {"clients": []}},
        {"tag": "trojan-ws-in", "protocol": "trojan", "settings": {"clients": []}},
    ]
}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(cfg, f)
    path = f.name

xray_render.inject("vmess-ws-in", json.dumps(["uuid-a", "uuid-b"]), path)
xray_render.inject("trojan-ws-in", json.dumps([{"password": "pass-1"}]), path)
with open(path) as f:
    got = json.load(f)
os.unlink(path)

vmess_clients = got["inbounds"][0]["settings"]["clients"]
trojan_clients = got["inbounds"][1]["settings"]["clients"]
check("vmess clients injected with email",
      vmess_clients == [{"id": "uuid-a", "email": "uuid-a@vmess-ws-in"},
                        {"id": "uuid-b", "email": "uuid-b@vmess-ws-in"}])
check("trojan clients injected with email",
      trojan_clients == [{"password": "pass-1", "email": "pass-1@trojan-ws-in"}])

print()
print("FAILED: %d" % failures if failures else "ALL TESTS PASSED")
sys.exit(1 if failures else 0)
