#!/bin/bash
# Sandbox smoke test for xray_render_config (no root, no real services needed)
set -e
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SCRIPT_DIR="$PROJECT_ROOT"
export SSHWSXRAY_INSTALL_DIR="$SANDBOX/sshwsxray"
# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"

# minimal config: no domain, defaults
apply_config_defaults
mkdir -p "$INSTALL_DIR"
: > "$XRAY_DB"

# shellcheck source=../lib/xray.sh
source "$PROJECT_ROOT/lib/xray.sh"

# transport yang TIDAK boleh ada lagi
FORBIDDEN='("vless-reality-in", "vmess-grpc-in", "vless-grpc-in", "trojan-grpc-in")'

# add fake clients to db (pipe-separated)
echo "vmess|11111111-2222-3333-4444-555555555555|budi|2026-09-13|2026-10-13|2" >> "$XRAY_DB"
echo "vless|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|ani|2026-09-13|2026-10-13|2" >> "$XRAY_DB"
echo "trojan|trojanpass|cici|2026-09-13|2026-10-13|1" >> "$XRAY_DB"

echo "=== Skenario 1: tanpa cert SSL ==="
xray_render_config

python3 - "$XRAY_CONFIG" <<EOF
import json, sys
cfg = json.load(open(sys.argv[1]))
tags = [i["tag"] for i in cfg["inbounds"]]
for t in ("api", "vmess-ws-in", "vless-ws-in"):
    assert t in tags, (t, tags)
assert "trojan-ws-in" not in tags, tags
for t in $FORBIDDEN:
    assert t not in tags, (t, tags)
# transport WS harus bisa diakses dari luar (bukan loopback)
for tag in ("vmess-ws-in", "vless-ws-in"):
    ib = next(i for i in cfg["inbounds"] if i["tag"] == tag)
    assert ib["listen"] == "0.0.0.0", (tag, ib["listen"])
    assert ib["streamSettings"]["network"] == "ws", (tag, ib["streamSettings"]["network"])
    assert ib["streamSettings"]["wsSettings"]["path"].startswith("/"), tag
    assert "grpcSettings" not in ib["streamSettings"], tag
# tidak ada sisa transport grpc/reality di config
raw = open(sys.argv[1]).read()
assert '"grpc"' not in raw, "masih ada transport grpc"
assert "reality" not in raw, "masih ada reality"
# API stats tetap localhost saja
api = next(i for i in cfg["inbounds"] if i["tag"] == "api")
assert api["listen"] == "127.0.0.1", api["listen"]
vm = next(i for i in cfg["inbounds"] if i["tag"] == "vmess-ws-in")
assert vm["settings"]["clients"] == [{"id": "11111111-2222-3333-4444-555555555555", "email": "11111111-2222-3333-4444-555555555555@vmess-ws-in"}]
print("RENDER (no cert) OK:", ", ".join(tags))
EOF

echo "=== Skenario 2: dengan cert SSL ==="
mkdir -p "$INSTALL_DIR/cert"
echo "FAKE CERT" > "$INSTALL_DIR/cert/fullchain.pem"
echo "FAKE KEY"  > "$INSTALL_DIR/cert/privkey.pem"
save_config CERT_DIR "$INSTALL_DIR/cert"

xray_render_config

python3 - "$XRAY_CONFIG" <<EOF
import json, sys
cfg = json.load(open(sys.argv[1]))
tags = [i["tag"] for i in cfg["inbounds"]]
assert "trojan-ws-in" in tags, tags
for t in $FORBIDDEN:
    assert t not in tags, (t, tags)
tr = next(i for i in cfg["inbounds"] if i["tag"] == "trojan-ws-in")
assert tr["settings"]["clients"][0]["password"] == "trojanpass"
assert tr["settings"]["clients"][0]["email"] == "trojanpass@trojan-ws-in"
assert tr["streamSettings"]["security"] == "tls"
assert tr["listen"] == "0.0.0.0", tr["listen"]
assert tr["streamSettings"]["network"] == "ws", tr["streamSettings"]["network"]
print("RENDER (with cert) OK:", ", ".join(tags))
EOF

# traffic db helpers smoke
echo "11111111-2222-3333-4444-555555555555|1048576" > "$XRAY_TRAFFIC_DB"
bytes=$(xray_user_traffic "11111111-2222-3333-4444-555555555555")
[[ "$bytes" == "1048576" ]] && echo "TRAFFIC LOOKUP OK" || { echo "TRAFFIC LOOKUP FAIL: $bytes"; exit 1; }

# validate must pass JSON check even without xray binary
xray_validate && echo "VALIDATE OK"

echo "=== Skenario 3: akumulasi traffic per-user (regression prefix user>>>) ==="
UUID="11111111-2222-3333-4444-555555555555"
: > "$XRAY_TRAFFIC_DB"
# tiru output xray_stats_query (format: name<TAB>value)
xray_stats_query() {
    printf 'user>>>%s@vmess-ws-in>>>traffic>>>uplink\t4096\n' "$UUID"
    printf 'user>>>%s@vmess-ws-in>>>traffic>>>downlink\t2048\n' "$UUID"
    printf 'inbound>>>vmess-ws-in>>>traffic>>>uplink\t999999\n'
}
xray_traffic_update
got=$(xray_user_traffic "$UUID")
[[ "$got" == "6144" ]] && echo "TRAFFIC AKUMULASI OK ($got)" || { echo "TRAFFIC AKUMULASI FAIL: '$got' (harus 6144)"; exit 1; }
# delta berikutnya harus DITAMBAHKAN, bukan menimpa
xray_stats_query() { printf 'user>>>%s@vmess-ws-in>>>traffic>>>uplink\t1000\n' "$UUID"; }
xray_traffic_update
got=$(xray_user_traffic "$UUID")
[[ "$got" == "7144" ]] && echo "TRAFFIC DELTA OK ($got)" || { echo "TRAFFIC DELTA FAIL: '$got' (harus 7144)"; exit 1; }

echo "=== Skenario 4: query stats tanpa netcat ==="
if python3 "$PROJECT_ROOT/lib/xray_proto.py" query 1 >/dev/null 2>&1; then
    echo "QUERY OFFLINE FAIL (seharusnya exit 1 saat port tertutup)"; exit 1
fi
echo "QUERY OFFLINE OK (exit 1, tidak menggantung)"

echo "=== Skenario 5: rollback config bila hasil render tidak valid ==="
cp "$XRAY_CONFIG" "$SANDBOX/prev.json"
xray_validate() { return 1; }   # paksa validasi gagal
if xray_render_config; then
    echo "ROLLBACK FAIL (render seharusnya ditolak)"; exit 1
fi
if cmp -s "$XRAY_CONFIG" "$SANDBOX/prev.json"; then
    echo "ROLLBACK OK (config lama dipertahankan)"
else
    echo "ROLLBACK FAIL (config lama tertimpa)"; exit 1
fi
