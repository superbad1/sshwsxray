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
echo "REALITY:fake-priv-key:fake-pub-key" > "$INSTALL_DIR/reality.keys"
: > "$XRAY_DB"

# shellcheck source=../lib/xray.sh
source "$PROJECT_ROOT/lib/xray.sh"

# add fake clients to db (pipe-separated)
echo "vmess|11111111-2222-3333-4444-555555555555|budi|2026-09-13|2026-10-13|2" >> "$XRAY_DB"
echo "vless|aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee|ani|2026-09-13|2026-10-13|2" >> "$XRAY_DB"
echo "trojan|trojanpass|cici|2026-09-13|2026-10-13|1" >> "$XRAY_DB"

echo "=== Skenario 1: tanpa cert SSL ==="
xray_render_config

python3 - "$XRAY_CONFIG" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
tags = [i["tag"] for i in cfg["inbounds"]]
for t in ("api", "vless-reality-in", "vmess-ws-in", "vless-ws-in", "vmess-grpc-in", "vless-grpc-in"):
    assert t in tags, (t, tags)
assert "trojan-ws-in" not in tags, tags
vm = next(i for i in cfg["inbounds"] if i["tag"] == "vmess-ws-in")
assert vm["settings"]["clients"] == [{"id": "11111111-2222-3333-4444-555555555555", "email": "11111111-2222-3333-4444-555555555555@vmess-ws-in"}]
rl = next(i for i in cfg["inbounds"] if i["tag"] == "vless-reality-in")
assert rl["streamSettings"]["realitySettings"]["privateKey"] == "fake-priv-key"
assert rl["streamSettings"]["realitySettings"]["shortIds"], "shortId kosong"
gr = next(i for i in cfg["inbounds"] if i["tag"] == "vless-grpc-in")
assert gr["listen"] == "0.0.0.0", gr["listen"]
print("RENDER (no cert) OK:", ", ".join(tags))
EOF

echo "=== Skenario 2: dengan cert SSL ==="
mkdir -p "$INSTALL_DIR/cert"
echo "FAKE CERT" > "$INSTALL_DIR/cert/fullchain.pem"
echo "FAKE KEY"  > "$INSTALL_DIR/cert/privkey.pem"
save_config CERT_DIR "$INSTALL_DIR/cert"

xray_render_config

python3 - "$XRAY_CONFIG" <<'EOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
tags = [i["tag"] for i in cfg["inbounds"]]
for t in ("trojan-ws-in", "trojan-grpc-in"):
    assert t in tags, (t, tags)
tr = next(i for i in cfg["inbounds"] if i["tag"] == "trojan-ws-in")
assert tr["settings"]["clients"][0]["password"] == "trojanpass"
assert tr["settings"]["clients"][0]["email"] == "trojanpass@trojan-ws-in"
assert tr["streamSettings"]["security"] == "tls"
print("RENDER (with cert) OK:", ", ".join(tags))
EOF

# traffic db helpers smoke
echo "11111111-2222-3333-4444-555555555555|1048576" > "$XRAY_TRAFFIC_DB"
bytes=$(xray_user_traffic "11111111-2222-3333-4444-555555555555")
[[ "$bytes" == "1048576" ]] && echo "TRAFFIC LOOKUP OK" || { echo "TRAFFIC LOOKUP FAIL: $bytes"; exit 1; }

# validate must pass JSON check even without xray binary
xray_validate && echo "VALIDATE OK"
