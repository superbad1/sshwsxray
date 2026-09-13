#!/bin/bash
# ============================================================
#  lib/bridge.sh - Unit systemd untuk bridge WebSocket (lib/sshws.py)
#
#  Bridge ini dipakai bersama oleh SSH-WebSocket dan Xray di port yang sama
#  (80 polos, 443 TLS). Pembagiannya berbasis path pada request upgrade:
#  path yang terdaftar sebagai --route diteruskan apa adanya ke inbound Xray
#  (Xray sendiri yang menjawab 101), path lain dilayani sebagai SSH.
# ============================================================

# Direktori unit systemd. Bisa di-override supaya test bisa menulis unit ke
# sandbox tanpa menyentuh /etc.
SYSTEMD_DIR="${SSHWSXRAY_SYSTEMD_DIR:-/etc/systemd/system}"

# Pastikan xray_ws_paths_ensure() tersedia (didefinisikan di lib/xray.sh).
_bridge_ensure_paths_fn() {
    declare -F xray_ws_paths_ensure >/dev/null && return 0
    # shellcheck source=lib/xray.sh
    source "${SCRIPT_DIR}/lib/xray.sh"
}

# Tulis (ulang) unit sshws + sshws-tls dan restart.
# Dipanggil installer saat instalasi, dan oleh menu saat path Xray diganti.
bridge_write_units() {
    local -a r_plain=() r_tls=()
    load_config
    apply_config_defaults

    _bridge_ensure_paths_fn
    # path acak per protokol harus ada sebelum didaftarkan sebagai route
    xray_ws_paths_ensure

    local ws_port="${WS_PORT:-80}"
    local wss_port="${WSS_PORT:-443}"
    local max_per_ip="${WS_MAX_PER_IP:-16}"
    local python
    python=$(command -v python3)
    [[ -n "$python" ]] || { print_error "python3 tidak ditemukan"; return 1; }

    # Sertifikat: pakai cert_paths() (sumber yang sama dengan xray_render_config
    # dan xray_user_show). Sebelumnya di sini dipatok $INSTALL_DIR/cert saja,
    # sehingga bila cert hanya ada di /etc/letsencrypt/live Xray merender
    # inbound Trojan TLS dan link akun menunjuk ke 443, padahal tidak ada unit
    # WSS yang mendengarkan di sana.
    local cert_file="" key_file=""
    if cert_paths >/dev/null 2>&1; then
        read -r cert_file key_file < <(cert_paths)
    fi

    mkdir -p "$APP_DIR"
    if [[ "${SCRIPT_DIR}/lib/sshws.py" != "${APP_DIR}/sshws.py" ]]; then
        install -m 644 "${SCRIPT_DIR}/lib/sshws.py" "${APP_DIR}/sshws.py"
    fi
    [[ -f "${APP_DIR}/sshws.py" ]] || { print_error "${APP_DIR}/sshws.py tidak ditemukan"; return 1; }

    # VMess & VLESS dilayani di port 80 dan 443 (keduanya inbound polos).
    # Trojan butuh TLS: di 443 diteruskan ke inbound mux polos di loopback
    # karena TLS-nya sudah diterima bridge (TLS tidak boleh ditumpuk).
    local path
    for path in "$XRAY_VMESS_WS_PATH:$XRAY_VMESS_WS_PORT" \
                "$XRAY_VLESS_WS_PATH:$XRAY_VLESS_WS_PORT"; do
        [[ -z "${path%%:*}" ]] && continue
        r_plain+=("/${path%%:*}=127.0.0.1:${path##*:}")
        r_tls+=("/${path%%:*}=127.0.0.1:${path##*:}")
    done
    if [[ -n "${XRAY_TROJAN_WS_PATH:-}" && -n "$cert_file" ]]; then
        r_tls+=("/${XRAY_TROJAN_WS_PATH}=127.0.0.1:${XRAY_TROJAN_MUX_PORT}")
    fi

    local arg_plain="" arg_tls="" r
    for r in "${r_plain[@]}"; do arg_plain+=" --route \"${r}\""; done
    for r in "${r_tls[@]}"; do arg_tls+=" --route \"${r}\""; done
    local wrote_tls=0

    print_info "Route port ${ws_port} : SSH + $([[ ${#r_plain[@]} -gt 0 ]] && printf '%s' "${r_plain[*]}" || echo "(tanpa Xray)")"
    print_info "Route port ${wss_port} : SSH + $([[ ${#r_tls[@]} -gt 0 ]] && printf '%s' "${r_tls[*]}" || echo "(tanpa Xray)")"

    # ---- websocket biasa (port 80) -> SSH, plus route Xray ----
    cat > "${SYSTEMD_DIR}/sshws.service" <<EOF
[Unit]
Description=SSH + Xray over WebSocket (bridge lib/sshws.py)
After=network.target ssh.service
Wants=xray.service

[Service]
Type=simple
ExecStart=${python} ${APP_DIR}/sshws.py --port ${ws_port} --target 127.0.0.1:22 --max-per-ip ${max_per_ip} --peer-map ${WS_PEER_MAP}${arg_plain}
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    # ---- websocket secure (port 443, butuh cert) -> SSH, plus route Xray ----
    if [[ -n "$cert_file" && -f "$cert_file" && -f "$key_file" ]]; then
        cat > "${SYSTEMD_DIR}/sshws-tls.service" <<EOF
[Unit]
Description=SSH + Xray over WSS (bridge lib/sshws.py, TLS)
After=network.target ssh.service
Wants=xray.service

[Service]
Type=simple
ExecStart=${python} ${APP_DIR}/sshws.py --port ${wss_port} --target 127.0.0.1:22 --max-per-ip ${max_per_ip} --peer-map ${WS_PEER_MAP} --tls --cert ${cert_file} --key ${key_file}${arg_tls}
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
        wrote_tls=1
    fi

    # Tanpa cert, unit WSS lama HARUS dibuang: kalau dibiarkan, systemd terus
    # mencoba menyalakannya dan gagal (cert sudah tidak ada / sudah dihapus).
    if (( wrote_tls == 0 )) && [[ -f "${SYSTEMD_DIR}/sshws-tls.service" ]]; then
        systemctl disable sshws-tls >/dev/null 2>&1 || true
        rm -f "${SYSTEMD_DIR}/sshws-tls.service"
    fi

    # Setiap panggilan systemctl di bawah ini WAJIB toleran gagal: bridge
    # dipasang dari installer yang berjalan dengan 'set -e', dan service yang
    # gagal start (mis. port 80 sudah dipakai nginx) tidak boleh membatalkan
    # sisa instalasi (menu, cron, symlink).
    systemctl daemon-reload 2>/dev/null || true
    if [[ -f "${SYSTEMD_DIR}/sshws-tls.service" ]]; then
        systemctl enable sshws sshws-tls >/dev/null 2>&1 || true
        systemctl restart sshws-tls 2>/dev/null || true
    else
        systemctl enable sshws >/dev/null 2>&1 || true
    fi
    systemctl restart sshws 2>/dev/null || true
    return 0
}
