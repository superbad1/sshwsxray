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

# Validasi config sebelum restart. Return 0 hanya bila benar-benar valid.
# (Xray keluar dengan kode 23 saat config invalid, jadi service TIDAK akan
# di-restart otomatis oleh systemd - lebih baik kita batalkan restart.)
xray_validate() {
    [[ -f "$XRAY_CONFIG" ]] || { print_error "config.json tidak ada"; return 1; }
    if ! python3 -c "import json;json.load(open('$XRAY_CONFIG'))" 2>/dev/null; then
        print_error "config.json bukan JSON valid"
        return 1
    fi
    if command -v xray &>/dev/null; then
        if ! xray run -test -c "$XRAY_CONFIG" >/dev/null 2>&1; then
            print_error "xray -test menandai config bermasalah"
            return 1
        fi
    fi
    return 0
}

xray_safe_restart() {
    if ! xray_validate; then
        print_error "Xray TIDAK di-restart karena config tidak valid"
        return 1
    fi
    xray_restart
    sleep 1
    if [[ "$(xray_status)" == "active" ]]; then
        print_success "Xray restarted"
        return 0
    fi
    print_error "Xray gagal start - cek 'journalctl -u xray'"
    return 1
}

# ---------- Path WebSocket Xray (acak, satu per protokol) ----------
# Port 80/443 dipakai bersama SSH-WebSocket dan Xray, jadi path pada request
# upgrade itulah yang menentukan tujuan (bridge lib/sshws.py yang membaca).
# Path dibuat acak supaya tidak mudah ditebak, dan disimpan di config supaya
# link akun tetap valid setelah restart/reboot.
xray_ws_paths_generate() {  # paksa path baru (dipakai menu)
    XRAY_VMESS_WS_PATH="$(gen_token)"
    XRAY_VLESS_WS_PATH="$(gen_token)"
    XRAY_TROJAN_WS_PATH="$(gen_token)"
    save_config XRAY_VMESS_WS_PATH "$XRAY_VMESS_WS_PATH"
    save_config XRAY_VLESS_WS_PATH "$XRAY_VLESS_WS_PATH"
    save_config XRAY_TROJAN_WS_PATH "$XRAY_TROJAN_WS_PATH"
    return 0
}

xray_ws_paths_ensure() {  # hanya isi yang masih kosong
    [[ -n "${XRAY_VMESS_WS_PATH:-}"  ]] || { XRAY_VMESS_WS_PATH="$(gen_token)";  save_config XRAY_VMESS_WS_PATH "$XRAY_VMESS_WS_PATH"; }
    [[ -n "${XRAY_VLESS_WS_PATH:-}"  ]] || { XRAY_VLESS_WS_PATH="$(gen_token)";  save_config XRAY_VLESS_WS_PATH "$XRAY_VLESS_WS_PATH"; }
    [[ -n "${XRAY_TROJAN_WS_PATH:-}" ]] || { XRAY_TROJAN_WS_PATH="$(gen_token)"; save_config XRAY_TROJAN_WS_PATH "$XRAY_TROJAN_WS_PATH"; }
    return 0
}

# Path yang dipakai klien untuk sebuah protokol (kosong bila belum ada)
xray_ws_path() {  # xray_ws_path <vmess|vless|trojan>
    case "$1" in
        vmess)  echo "$XRAY_VMESS_WS_PATH" ;;
        vless)  echo "$XRAY_VLESS_WS_PATH" ;;
        trojan) echo "$XRAY_TROJAN_WS_PATH" ;;
        *) return 1 ;;
    esac
}

# Port tempat klien menyambung: 443 (TLS, lewat bridge) bila cert tersedia,
# kalau tidak 80 (polos). Port lama (10086/10088/10091) tetap terbuka juga.
xray_client_port() {
    load_config
    apply_config_defaults
    if cert_paths >/dev/null 2>&1; then
        echo "${WSS_PORT:-443}"
    else
        echo "${WS_PORT:-80}"
    fi
}

# ---------- Config render ----------
# Renders /usr/local/etc/xray/config.json from $XRAY_DB.
# Inbound ports read from saved config so edits persist.
xray_render_config() {
    # pull latest settings (domain, cert dir, ports)
    load_config
    apply_config_defaults
    # path acak wajib ada sebelum inbound dirender
    xray_ws_paths_ensure
    # simpan config lama: dipakai untuk rollback bila hasil render tidak valid
    local prev_config=""
    if [[ -f "$XRAY_CONFIG" ]]; then
        prev_config=$(mktemp)
        cp "$XRAY_CONFIG" "$prev_config"
    fi
    local domain
    domain=$(get_domain)
    local cert=""
    if cert_paths >/dev/null 2>&1; then
        read -r CERT_FILE KEY_FILE < <(cert_paths)
        cert="ok"
    fi

    # --- WS inbounds (transport satu-satunya; TLS hanya untuk Trojan) ---
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

    # Setiap protokol punya path acak sendiri: port 80/443 dipakai bersama
    # SSH-WebSocket, dan path itulah yang menentukan request upgrade menuju
    # inbound yang mana (dibaca oleh bridge lib/sshws.py).
    make_ws_inbound() {
        local tag="$1" listen="$2" port="$3" proto="$4" ws_path="$5"
        local security="${6:-none}" tls_json=""
        [[ "$security" == "tls" ]] && tls_json="$tls_block"
        cat <<EOF
        {
            "tag": "${tag}",
            "listen": "${listen}",
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
                "wsSettings": {"path": "/${ws_path}"}
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
        }
EOF
    }

    # Cert may be absent: Trojan requires TLS, so without cert we skip its
    # inbound instead of emitting invalid JSON ("tlsSettings": ,).
    # hanya tampilkan saat interaktif: fungsi ini juga jalan dari cron tiap
    # menit dan peringatan berulang cuma membuat spam log
    if [[ -z "$cert" && -t 1 ]]; then
        print_warning "Cert SSL tidak ada - inbound Trojan dilewati (butuh TLS)"
    fi
    local trojan_ws_json=""
    if [[ -n "$cert" ]]; then
        # leading comma: inbound sebelumnya (vless-ws) belum punya koma
        # inbound publik: TLS sendiri (fungsinya sebagai Trojan tetap utuh)
        trojan_ws_json=", $(make_ws_inbound "trojan-ws-in" "0.0.0.0" "$XRAY_TROJAN_WS_PORT" "trojan" "$XRAY_TROJAN_WS_PATH" "tls")"
        # inbound kedua tanpa TLS, hanya loopback: dipakai bridge di port 443,
        # yang sudah menerima TLS dari klien (TLS tidak bisa ditumpuk dua kali)
        trojan_ws_json+=", $(make_ws_inbound "trojan-mux-in" "127.0.0.1" "$XRAY_TROJAN_MUX_PORT" "trojan" "$XRAY_TROJAN_WS_PATH" "none")"
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
$(make_ws_inbound "vmess-ws-in" "0.0.0.0" "$XRAY_VMESS_WS_PORT" "vmess" "$XRAY_VMESS_WS_PATH"),
$(make_ws_inbound "vless-ws-in" "0.0.0.0" "$XRAY_VLESS_WS_PORT" "vless" "$XRAY_VLESS_WS_PATH")${trojan_ws_json}
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

    inject_clients "vmess-ws-in"  "[${vmess_clients}]"
    inject_clients "vless-ws-in"  "[${vless_clients}]"
    [[ -n "$trojan_clients_obj" ]] || trojan_clients_obj=''
    if [[ -n "$cert" ]]; then
        inject_clients "trojan-ws-in"  "[${trojan_clients_obj}]"
        # inbound mux harus punya daftar klien yang sama
        [[ -n "$trojan_clients_obj" ]] && inject_clients "trojan-mux-in" "[${trojan_clients_obj}]"
    fi

    # Validasi hasil render; kalau rusak, kembalikan config sebelumnya supaya
    # service yang sedang jalan tidak ikut mati.
    if ! xray_validate; then
        if [[ -n "$prev_config" ]]; then
            cp "$prev_config" "$XRAY_CONFIG"
            print_warning "Config Xray baru tidak valid - dikembalikan ke config sebelumnya"
        fi
        [[ -n "$prev_config" ]] && rm -f "$prev_config"
        return 1
    fi
    [[ -n "$prev_config" ]] && rm -f "$prev_config"
    return 0
}

# ---------- gRPC stats query ----------
# Memakai python (lib/xray_proto.py query) supaya tidak butuh binary `nc`
# yang tidak terpasang bawaan di Debian/Ubuntu minimal.
xray_stats_query() {  # xray_stats_query "<pattern>" -> "name<TAB>value" per baris
    local pattern="$1"
    command -v python3 &>/dev/null || return 0
    python3 "${LIB_DIR}/xray_proto.py" query "$XRAY_API_PORT" "$pattern" 2>/dev/null
}

# ---------- Traffic per user (cached snapshot) ----------
# Nama statistik Xray: user>>><uuid>@<tag>>>>traffic>>>{uplink,downlink}
# Query memakai reset=true, jadi nilai yang dikembalikan = selisih sejak
# pengambilan terakhir - aman untuk diakumulasi.
xray_traffic_update() {  # fetch stats and merge into traffic db (uuid|total_bytes)
    local out
    out=$(xray_stats_query "")
    [[ -z "$out" ]] && return 0
    local name value key old total tmp
    while IFS=$'\t' read -r name value; do
        [[ -z "$name" || -z "$value" ]] && continue
        [[ "$name" != user* ]] && continue
        key="${name#user>>>}"      # buang prefix "user>>>"
        key="${key%%@*}"           # ambil uuid sebelum '@'
        [[ -z "$key" ]] && continue
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        old=0
        if [[ -f "$XRAY_TRAFFIC_DB" ]]; then
            old=$(awk -F'|' -v k="$key" '$1==k {print $2}' "$XRAY_TRAFFIC_DB" | head -n1)
        fi
        [[ "$old" =~ ^[0-9]+$ ]] || old=0
        total=$(( old + value ))
        tmp=$(mktemp)
        if [[ -f "$XRAY_TRAFFIC_DB" ]]; then
            awk -F'|' -v k="$key" '$1!=k' "$XRAY_TRAFFIC_DB" > "$tmp"
        fi
        echo "${key}|${total}" >> "$tmp"
        mv "$tmp" "$XRAY_TRAFFIC_DB"
        chmod 600 "$XRAY_TRAFFIC_DB" 2>/dev/null
    done <<< "$out"
}

xray_user_traffic() {  # xray_user_traffic <uuid> -> bytes total
    local key="$1"
    [[ -f "$XRAY_TRAFFIC_DB" ]] || { echo 0; return; }
    awk -F'|' -v k="$key" '$1==k {print $2; exit}' "$XRAY_TRAFFIC_DB" 2>/dev/null | head -n1
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
    for p in "$XRAY_VMESS_WS_PORT" "$XRAY_VLESS_WS_PORT" "$XRAY_TROJAN_WS_PORT"; do
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

# Render ulang config.json dari database lalu restart. Dipakai untuk
# menerapkan perubahan skema/port tanpa perlu mengubah daftar akun.
xray_rebuild_menu() {
    print_header
    echo -e "${CYAN}>>> REBUILD CONFIG XRAY${NC}"
    echo ""
    xray_render_config && xray_safe_restart
    pause_menu
}
