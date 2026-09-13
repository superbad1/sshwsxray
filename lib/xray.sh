#!/bin/bash
# ============================================================
#  lib/xray.sh - Xray-core service, config render, traffic API
# ============================================================

XRAY_DB="$INSTALL_DIR/xray_users.db"
XRAY_TRAFFIC_DB="$INSTALL_DIR/xray_traffic.db"

# ---------- systemd control ----------
xray_start()    { systemctl start xray; }
xray_stop()     { systemctl stop xray; }
xray_restart()  { systemctl restart xray; }
xray_status()   { systemctl is-active xray &>/dev/null && echo active || echo inactive; }

# Validate current config before restart. Returns 0 when valid.
xray_validate() {
    [[ -f "$XRAY_CONFIG" ]] || { print_error "config.json tidak ada"; return 1; }
    if ! python3 -c "import json;json.load(open('$XRAY_CONFIG'))" 2>/dev/null; then
        print_error "config.json bukan JSON valid"
        return 1
    fi
    if command -v xray &>/dev/null; then
        if ! xray run -test -c "$XRAY_CONFIG" &>/dev/null; then
            print_warning "xray -test menandai config bermasalah (lanjut dengan hati-hati)"
        fi
    fi
    return 0
}

xray_safe_restart() {
    if xray_validate; then
        xray_restart
        sleep 1
        if [[ "$(xray_status)" == "active" ]]; then
            print_success "Xray restarted"
            return 0
        fi
        print_error "Xray gagal start - cek 'journalctl -u xray'"
    fi
    return 1
}

# ---------- Config render ----------
# Renders /usr/local/etc/xray/config.json from $XRAY_DB.
# Inbound ports read from saved config so edits persist.
xray_render_config() {
    # pull latest settings (domain, cert dir, ports, reality short id)
    load_config
    apply_config_defaults
    local domain
    domain=$(get_domain)
    local cert=""
    if cert_paths >/dev/null 2>&1; then
        read -r CERT_FILE KEY_FILE < <(cert_paths)
        cert="ok"
    fi

    local vless_reality_inbound=""
    local ws_grpc_inbounds=""

    # --- VLESS Reality (no cert needed) ---
    # reality.keys format: REALITY:<private_key>:<public_key>
    local rkey rshort rpub
    rkey=$(grep "^REALITY:" "$INSTALL_DIR/reality.keys" 2>/dev/null | cut -d: -f2)
    rpub=$(grep "^REALITY:" "$INSTALL_DIR/reality.keys" 2>/dev/null | cut -d: -f3)
    if [[ -n "$rkey" ]]; then
        # reuse persisted shortId so existing client links stay valid
        load_config
        if [[ -n "${REALITY_SHORT_ID:-}" ]]; then
            rshort="$REALITY_SHORT_ID"
        else
            rshort=$(head -c 16 /dev/urandom | base64 | tr -d '=+/' | head -c 8)
        fi
        [[ -n "$rpub" ]] && save_config REALITY_PUBLIC_KEY "$rpub"
        vless_reality_inbound=$(cat <<EOF
        {
            "tag": "vless-reality-in",
            "listen": "0.0.0.0",
            "port": ${XRAY_VLESS_REALITY_PORT},
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${REALITY_DEST}",
                    "xver": 0,
                    "serverNames": ["${REALITY_SERVER_NAMES}"],
                    "privateKey": "${rkey}",
                    "shortIds": ["${rshort}", ""]
                }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
        }
EOF
)
    fi

    # --- WS / gRPC inbounds (need TLS cert for wss via direct TLS) ---
    local tls_block=""
    if [[ -n "$cert" ]]; then
        tls_block=$(cat <<EOF
{
                    "certificates": [{
                        "certificateFile": "${CERT_FILE}",
                        "keyFile": "${KEY_FILE}"
                    }]
                }
EOF
)
    fi

    make_ws_inbound() {
        local tag="$1" port="$2" proto="$3"
        local security="none" tls_json=""
        # ws is plain (behind gost wss in production) or direct TLS if cert exists
        [[ "$proto" == "trojan" ]] && security="tls" && tls_json="$tls_block"
        cat <<EOF
        {
            "tag": "${tag}",
            "listen": "127.0.0.1",
            "port": ${port},
            "protocol": "${proto}",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "ws",
                "security": "${security}",
                "tlsSettings": ${tls_json:-"{}"},
                "wsSettings": {"path": "/${WS_PATH}"}
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
        }
EOF
    }

    make_grpc_inbound() {
        local tag="$1" port="$2" proto="$3"
        local security="none" tls_json="{}"
        [[ "$proto" == "trojan" ]] && security="tls" && tls_json="$tls_block"
        cat <<EOF
        {
            "tag": "${tag}",
            "listen": "0.0.0.0",
            "port": ${port},
            "protocol": "${proto}",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "grpc",
                "security": "${security}",
                "tlsSettings": ${tls_json},
                "grpcSettings": {"serviceName": "${WS_PATH}-grpc"}
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
        }
EOF
    }

    # Cert may be absent: Trojan requires TLS, so without cert we skip its
    # inbound instead of emitting invalid JSON ("tlsSettings": ,).
    if [[ -z "$cert" ]]; then
        print_warning "Cert SSL tidak ada - inbound Trojan dilewati (butuh TLS)"
    fi
    local trojan_ws_json="" trojan_grpc_json=""
    if [[ -n "$cert" ]]; then
        # leading comma because the previous inbound (vless-grpc) has none
        trojan_ws_json=", $(make_ws_inbound "trojan-ws-in" "$XRAY_TROJAN_WS_PORT" "trojan"),"
        trojan_grpc_json="$(make_grpc_inbound "trojan-grpc-in" "$XRAY_TROJAN_GRPC_PORT" "trojan")"
    fi

    # --- Collect clients per protocol ---
    local vmess_clients="" vless_clients="" trojan_clients_obj=""
    while IFS='|' read -r proto uuid user _created _expired _iplimit; do
        [[ -z "$proto" ]] && continue
        case "$proto" in
            vmess)  vmess_clients+="${vmess_clients:+,}\"${uuid}\"" ;;
            vless)  vless_clients+="${vless_clients:+,}\"${uuid}\"" ;;
            trojan) trojan_clients_obj+="${trojan_clients_obj:+,}{\"password\": \"${uuid}\"}" ;;
        esac
    done < "$XRAY_DB"

    mkdir -p "$(dirname "$XRAY_CONFIG")"
    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {"loglevel": "warning"},
    "api": {
        "tag": "api",
        "services": ["HandlerService", "StatsService"]
    },
    "stats": {},
    "policy": {
        "levels": {
            "0": {
                "statsUserUplink": true,
                "statsUserDownlink": true,
                "handshake": 4,
                "connIdle": 300,
                "uplinkOnly": 2,
                "downlinkOnly": 5
            }
        },
        "system": {
            "statsInboundUplink": true,
            "statsInboundDownlink": true,
            "statsOutboundUplink": true,
            "statsOutboundDownlink": true
        }
    },
    "inbounds": [
        {
            "tag": "api",
            "listen": "127.0.0.1",
            "port": ${XRAY_API_PORT},
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"}
        },
${vless_reality_inbound:+$vless_reality_inbound,}
$(make_ws_inbound "vmess-ws-in" "$XRAY_VMESS_WS_PORT" "vmess"),
$(make_ws_inbound "vless-ws-in" "$XRAY_VLESS_WS_PORT" "vless"),
$(make_grpc_inbound "vmess-grpc-in" "$XRAY_VMESS_GRPC_PORT" "vmess"),
$(make_grpc_inbound "vless-grpc-in" "$XRAY_VLESS_GRPC_PORT" "vless")
${trojan_ws_json}${trojan_grpc_json}
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}
        ]
    }
}
EOF

    # --- Inject client lists into rendered config ---
    inject_clients() {  # inject_clients <tag> <clients_json_array>
        local tag="$1" clients="$2"
        [[ -z "$clients" ]] && return 0
        python3 "${LIB_DIR}/xray_render.py" "$tag" "$clients" "$XRAY_CONFIG"
    }

    inject_clients "vmess-ws-in"   "[${vmess_clients}]"
    inject_clients "vmess-grpc-in" "[${vmess_clients}]"
    inject_clients "vless-ws-in"   "[${vless_clients}]"
    inject_clients "vless-grpc-in" "[${vless_clients}]"
    inject_clients "vless-reality-in" "[${vless_clients}]"
    [[ -n "$trojan_clients_obj" ]] || trojan_clients_obj=''
    inject_clients "trojan-ws-in"  "[${trojan_clients_obj}]"
    inject_clients "trojan-grpc-in" "[${trojan_clients_obj}]"

    # Reality shortId is per-render random; persist so links stay valid
    if [[ -n "$rkey" ]]; then
        local sid
        sid=$(python3 -c "
import json
cfg = json.load(open('$XRAY_CONFIG'))
for i in cfg['inbounds']:
    if i.get('tag') == 'vless-reality-in':
        print(i['streamSettings']['realitySettings']['shortIds'][0])
        break
")
        [[ -n "$sid" ]] && save_config REALITY_SHORT_ID "$sid"
    fi
    return 0
}

# ---------- gRPC stats query ----------
xray_stats_query() {  # xray_stats_query "<pattern>" -> prints "name###value### N" lines
    local pattern="$1" payload resp
    payload=$(python3 "${LIB_DIR}/xray_proto.py" encode "$pattern" | base64 -w0)
    resp=$(printf '%s' "$payload" | base64 -d \
        | timeout 5 nc 127.0.0.1 "$XRAY_API_PORT" 2>/dev/null | base64 -w0)
    [[ -z "$resp" ]] && return 0
    python3 "${LIB_DIR}/xray_proto.py" decode "$resp"
}

# ---------- Traffic per user (cached snapshot) ----------
xray_traffic_update() {  # fetch stats and merge into traffic db (uuid|total_bytes)
    local out
    out=$(xray_stats_query "")
    [[ -z "$out" ]] && return 0
    local line name value key
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(echo "$line" | awk -F'###' '{print $1}')
        value=$(echo "$line" | awk -F'###' '{print $3}' | tr -d ' ')
        [[ "$name" != user* ]] && continue
        key=$(echo "$name" | awk -F'@' '{print $1}')
        [[ -z "$key" ]] && continue
        local old=0
        [[ -f "$XRAY_TRAFFIC_DB" ]] && old=$(grep "^${key}|" "$XRAY_TRAFFIC_DB" 2>/dev/null | awk -F'|' '{print $2}')
        old=${old:-0}
        local total=$(( old + value ))
        sed -i "\|^${key}|d" "$XRAY_TRAFFIC_DB" 2>/dev/null
        echo "${key}|${total}" >> "$XRAY_TRAFFIC_DB"
    done <<< "$out"
}

xray_user_traffic() {  # xray_user_traffic <email/uuid> -> bytes total
    local key="$1"
    [[ -f "$XRAY_TRAFFIC_DB" ]] || { echo 0; return; }
    grep "^${key}|" "$XRAY_TRAFFIC_DB" 2>/dev/null | awk -F'|' '{print $2}' | head -n1
}

# ---------- Service status display ----------
xray_show_status() {
    print_header
    echo -e "${CYAN}>>> STATUS XRAY-CORE${NC}"
    echo ""
    echo -e " Service   : $(xray_status)"
    if command -v xray &>/dev/null; then
        echo -e " Version   : $(xray version | head -n1 | awk '{print $2}')"
    fi
    echo -e " Config    : $XRAY_CONFIG"
    echo ""
    echo -e "${CYAN}--- Port listener ---${NC}"
    for p in "$XRAY_VMESS_WS_PORT" "$XRAY_VMESS_GRPC_PORT" "$XRAY_VLESS_WS_PORT" \
             "$XRAY_VLESS_GRPC_PORT" "$XRAY_VLESS_REALITY_PORT" "$XRAY_TROJAN_WS_PORT" \
             "$XRAY_TROJAN_GRPC_PORT"; do
        [[ -z "$p" ]] && continue
        if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
            printf "  %-6s ${GREEN}LISTEN${NC}\n" "$p"
        else
            printf "  %-6s ${RED}CLOSED${NC}\n" "$p"
        fi
    done
    echo ""
    journalctl -u xray -n 5 --no-pager 2>/dev/null | tail -n 5
    pause_menu
}

xray_restart_menu() {
    print_header
    echo -e "${CYAN}>>> RESTART XRAY${NC}"
    xray_safe_restart
    pause_menu
}
