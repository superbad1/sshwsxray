#!/bin/bash
# ============================================================
#  setup.sh - SSH Websocket + Xray-core autoscript installer
#  Target : Debian 10/11/12 & Ubuntu 20.04/22.04/24.04
#  Usage  : sudo bash setup.sh [--ssl-only]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
require_root
# sandbox override for testing
INSTALL_DIR="${SSHWSXRAY_INSTALL_DIR:-$INSTALL_DIR}"

# ---------- Flags ----------
SSL_ONLY=0
[[ "${1:-}" == "--ssl-only" ]] && SSL_ONLY=1

APP_DIR="${SSHWSXRAY_APP_DIR:-/usr/local/lib/sshwsxray}"

log_step() { echo -e "\n${CYAN}==> ${1}${NC}"; }

# ---------- Arch detection ----------
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) print_error "Arsitektur $(uname -m) tidak didukung"; exit 1 ;;
    esac
}

# ---------- Port conflict check ----------
check_port_free() {  # <port> <svcname>
    if ss -tlnp 2>/dev/null | grep -q ":$1 "; then
        print_warning "Port $1 sudah dipakai ($2). Instalasi tetap lanjut - periksa konflik!"
    fi
}

# ---------- Install packages ----------
# Catatan: tidak ada lagi download script pihak ketiga. Limit IP dihitung
# sendiri dari koneksi sshd (lihat ssh_user_ip_count di lib/monitor.sh).
install_packages() {
    log_step "Update sistem & install dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl wget tar jq python3 openssl cron ca-certificates \
        openssh-server speedtest-cli >/dev/null
}

# ---------- SSH config ----------
configure_ssh() {
    log_step "Konfigurasi OpenSSH"
    mkdir -p /etc/ssh
    local backup="/etc/ssh/sshd_config.bak.$(date +%s)"
    [[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "$backup" 2>/dev/null
    cat > /etc/ssh/sshd_config <<EOF
Port 22
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
MaxSessions 10
MaxStartups 10:30:60
ClientAliveInterval 60
ClientAliveCountMax 3
UseDNS no
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
    # Validasi dulu: config sshd yang rusak = tidak bisa login sama sekali.
    if ! sshd -t -f /etc/ssh/sshd_config 2>/dev/null; then
        print_error "sshd_config hasil instalasi tidak valid - dikembalikan ke config lama"
        if [[ -f "$backup" ]]; then
            cp "$backup" /etc/ssh/sshd_config
        else
            rm -f /etc/ssh/sshd_config
        fi
        return 1
    fi
    # simpan maksimal 5 backup sshd_config
    ls -1t /etc/ssh/sshd_config.bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    return 0
}

# ---------- Bridge WebSocket kustom (pure Python, pengganti gost) ----------
install_sshws() {
    log_step "Install bridge SSH-WebSocket (lib/sshws.py)"
    load_config
    # SSH-WS memakai path standar '/' (tanpa path khusus); WS_PATH hanya untuk Xray
    local ws_port="${WS_PORT:-80}"
    local wss_port="${WSS_PORT:-443}"
    local max_per_ip="${WS_MAX_PER_IP:-16}"

    # pastikan script bridge ada sebelum unit systemd dibuat
    mkdir -p "$APP_DIR"
    if [[ "${SCRIPT_DIR}/lib/sshws.py" != "${APP_DIR}/sshws.py" ]]; then
        install -m 644 "${SCRIPT_DIR}/lib/sshws.py" "${APP_DIR}/sshws.py"
    fi
    [[ -f "${APP_DIR}/sshws.py" ]] || { print_error "${APP_DIR}/sshws.py tidak ditemukan"; return 1; }

    # ---- websocket biasa (port 80) -> sshd ----
    cat > /etc/systemd/system/sshws.service <<EOF
[Unit]
Description=SSH over WebSocket (custom python bridge)
After=network.target ssh.service

[Service]
Type=simple
ExecStart=$(command -v python3) ${APP_DIR}/sshws.py --port ${ws_port} --target 127.0.0.1:22 --max-per-ip ${max_per_ip}
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    # ---- websocket secure (port 443, butuh cert) -> sshd ----
    if [[ -f "${INSTALL_DIR}/cert/fullchain.pem" ]]; then
        cat > /etc/systemd/system/sshws-tls.service <<EOF
[Unit]
Description=SSH over WSS (custom python bridge, TLS)
After=network.target ssh.service

[Service]
Type=simple
ExecStart=$(command -v python3) ${APP_DIR}/sshws.py --port ${wss_port} --target 127.0.0.1:22 --max-per-ip ${max_per_ip} --tls --cert ${INSTALL_DIR}/cert/fullchain.pem --key ${INSTALL_DIR}/cert/privkey.pem
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    if [[ -f /etc/systemd/system/sshws-tls.service ]]; then
        systemctl enable sshws sshws-tls
        systemctl restart sshws-tls 2>/dev/null || true
    else
        systemctl enable sshws
    fi
    systemctl restart sshws 2>/dev/null || true
    return 0
}

# ---------- Firewall ----------
# Tidak memaksa firewall apa pun; kalau ufw terpasang & aktif, port yang
# dibutuhkan dibuka otomatis supaya tidak "sudah terpasang tapi ditolak".
configure_firewall() {
    log_step "Firewall"
    local ports=("22" "80" "443" "${XRAY_VMESS_WS_PORT}" "${XRAY_VLESS_WS_PORT}" "${XRAY_TROJAN_WS_PORT}")
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
        local p
        for p in "${ports[@]}"; do
            [[ -z "$p" ]] && continue
            ufw allow "$p"/tcp >/dev/null 2>&1
        done
        print_success "Port dibuka di ufw: ${ports[*]} (tcp)"
        return 0
    fi
    print_warning "ufw tidak aktif - pastikan port berikut terbuka di firewall/security group VPS:"
    print_warning "  ${ports[*]} (tcp)"
    return 0
}

# ---------- xray-core ----------
install_xray() {
    log_step "Install Xray-core (installer resmi XTLS/Xray-install)"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray
}

# ---------- SSL ----------
issue_ssl() {
    log_step "Sertifikat SSL (Let's Encrypt)"
    load_config
    local domain
    domain=$(get_domain)
    if [[ -z "$domain" ]]; then
        print_warning "Domain belum diset - SSL dilewati (wss & Trojan TLS tidak aktif)"
        return 1
    fi
    apt-get install -y certbot >/dev/null 2>&1
    if certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$domain"; then
        mkdir -p "$INSTALL_DIR/cert"
        cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$INSTALL_DIR/cert/"
        cp "/etc/letsencrypt/live/$domain/privkey.pem"  "$INSTALL_DIR/cert/"
        chmod 600 "$INSTALL_DIR/cert/"*.pem
        save_config CERT_DIR "$INSTALL_DIR/cert"
        print_success "SSL terpasang untuk $domain"
        # renew hook: copy + restart services
        cat > /etc/letsencrypt/renewal-hooks/deploy/sshwsxray.sh <<EOF
#!/bin/bash
cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$INSTALL_DIR/cert/"
cp "/etc/letsencrypt/live/$domain/privkey.pem"  "$INSTALL_DIR/cert/"
systemctl restart sshws-tls xray 2>/dev/null
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/sshwsxray.sh
        return 0
    fi
    print_error "Issuance SSL gagal - pastikan domain mengarah ke IP ini & port 80 bebas"
    return 1
}

# ---------- Init data dir ----------
# ensure_db_files() (lib/common.sh) hanya MEMBUAT file yang belum ada.
# Versi lama memakai ': > file' sehingga menjalankan ulang installer - atau
# "Install/perbarui sertifikat SSL" dari menu - menghapus semua akun.
init_data() {
    log_step "Inisialisasi direktori data"
    ensure_db_files
}

# ---------- Cron jobs ----------
install_cron() {
    log_step "Pasang cron jobs"
    cat > /etc/cron.d/sshwsxray <<EOF
# SSHWSXRAY SSH/Xray manager
* * * * * root ${BIN_DIR}/sshwsxray-cron
EOF
    chmod 644 /etc/cron.d/sshwsxray
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
}

# ---------- App files install (so runtime does not depend on repo dir) ----------
install_app_files() {
    log_step "Install aplikasi ke ${APP_DIR}"
    mkdir -p "$APP_DIR/lib"
    if [[ "$SCRIPT_DIR" != "$APP_DIR" ]]; then
        # setup.sh & uninstall.sh ikut disalin: menu "Install/perbarui SSL"
        # menjalankan ${APP_DIR}/setup.sh, jadi file itu harus ada di sana.
        cp -f "${SCRIPT_DIR}/menu.sh" "$APP_DIR/menu.sh"
        cp -f "${SCRIPT_DIR}/setup.sh" "$APP_DIR/setup.sh"
        cp -f "${SCRIPT_DIR}/uninstall.sh" "$APP_DIR/uninstall.sh" 2>/dev/null || true
        cp -f "${SCRIPT_DIR}/lib/"*.sh "$APP_DIR/lib/"
        cp -f "${SCRIPT_DIR}/lib/"*.py "$APP_DIR/lib/"
    fi
    chmod 755 "$APP_DIR/menu.sh" "$APP_DIR/lib/"*.sh
    [[ -f "$APP_DIR/setup.sh" ]] && chmod 755 "$APP_DIR/setup.sh"
    [[ -f "$APP_DIR/uninstall.sh" ]] && chmod 755 "$APP_DIR/uninstall.sh"
    chmod 644 "$APP_DIR/lib/"*.py 2>/dev/null || true
    return 0
}

# ---------- Cron payload (separate file, no menu deps) ----------
write_cron_script() {
    cat > "${BIN_DIR}/sshwsxray-cron" <<CRONEOF
#!/bin/bash
# sshwsxray cron: expire check, IP limit, multi-login alert, traffic snapshot
export SCRIPT_DIR="${APP_DIR}"
source "${APP_DIR}/lib/common.sh"
load_config
apply_config_defaults
source "${APP_DIR}/lib/telegram.sh"
source "${APP_DIR}/lib/ssh.sh"
source "${APP_DIR}/lib/xray.sh"
source "${APP_DIR}/lib/monitor.sh"
monitor_enforce
CRONEOF
    chmod 755 "${BIN_DIR}/sshwsxray-cron"
}

# ---------- Symlink menu ----------
install_symlink() {
    ln -sf "${APP_DIR}/menu.sh" "${BIN_DIR}/sshwsxray"
    chmod +x "${APP_DIR}/menu.sh"
}

# ============================================================
# Main
# ============================================================
main() {
if [[ $SSL_ONLY -eq 1 ]]; then
    init_data
    load_config
    apply_config_defaults
    # SSL bisa ditambahkan belakangan SETELAH instalasi awal: unit WSS dan
    # inbound Trojan belum ada, jadi keduanya harus dipasang/di-render di sini.
    if ! issue_ssl; then
        print_error "SSL gagal - tidak ada perubahan yang diterapkan"
        return 1
    fi
    install_sshws
    install_app_files
    source "${SCRIPT_DIR}/lib/xray.sh"
    if xray_render_config; then
        xray_safe_restart
    fi
    print_success "SSL terpasang: wss://${WSS_PORT} (SSH) dan inbound Trojan WS aktif"
    return 0
fi

echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}   SSH WEBSOCKET + XRAY AUTOSCRIPT INSTALLER${NC}"
echo -e "${CYAN}   SSH WebSocket + Xray-core (VMESS/VLESS)${NC}"
echo -e "${CYAN}==============================================${NC}"

if ! detect_os; then
    print_error "OS tidak didukung (butuh Debian atau Ubuntu)."
    return 1
fi
print_info "OS terdeteksi: ${OS_ID} ${OS_VERSION}"
print_info "Arsitektur   : $(uname -m) ($(detect_arch))"

# Gather domain early (needed for cert & links)
read -rp "Domain untuk SSL (kosongkan jika tanpa domain): " DOMAIN_INPUT
DOMAIN_INPUT="${DOMAIN_INPUT:-}"
if [[ -n "$DOMAIN_INPUT" ]]; then
    if ! [[ "$DOMAIN_INPUT" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Format domain tidak valid"; return 1
    fi
fi

install_packages
init_data

# Save domain & defaults before services are configured
if [[ -n "$DOMAIN_INPUT" ]]; then
    save_config DOMAIN "$DOMAIN_INPUT"
    echo "$DOMAIN_INPUT" > "$INSTALL_DIR/domain"
fi
apply_config_defaults
for key in WS_PATH WS_PORT WSS_PORT WS_MAX_PER_IP XRAY_VMESS_WS_PORT \
           XRAY_VLESS_WS_PORT XRAY_TROJAN_WS_PORT XRAY_API_PORT \
           IP_LIMIT TRIAL_HOURS; do
    save_config "$key" "${!key}"
done

# Port yang dibutuhkan harus bebas (peringatan, bukan penghenti)
check_port_free "$WS_PORT" "sshws"
check_port_free "$WSS_PORT" "sshws-tls"
check_port_free "$XRAY_VMESS_WS_PORT" "vmess ws"
check_port_free "$XRAY_VLESS_WS_PORT" "vless ws"
check_port_free "$XRAY_TROJAN_WS_PORT" "trojan ws"
check_port_free "$XRAY_API_PORT" "xray api"

configure_ssh || print_warning "Konfigurasi sshd dilewati - config lama tetap dipakai"
issue_ssl || true   # SSL dulu: unit sshws-tls butuh cert
install_sshws
install_xray

# sync cert into sshwsxray data dir if issued via letsencrypt path
if [[ -n "$DOMAIN_INPUT" && -d "$INSTALL_DIR/cert" ]]; then
    :
elif [[ -n "$DOMAIN_INPUT" && -f "/etc/letsencrypt/live/$DOMAIN_INPUT/fullchain.pem" ]]; then
    mkdir -p "$INSTALL_DIR/cert"
    cp "/etc/letsencrypt/live/$DOMAIN_INPUT/fullchain.pem" "$INSTALL_DIR/cert/"
    cp "/etc/letsencrypt/live/$DOMAIN_INPUT/privkey.pem" "$INSTALL_DIR/cert/"
    chmod 600 "$INSTALL_DIR/cert/"*.pem
    save_config CERT_DIR "$INSTALL_DIR/cert"
fi
init_data

# Render initial xray config (inbounds only; clients added via menu)
source "${SCRIPT_DIR}/lib/xray.sh"
if xray_render_config && xray_validate; then
    systemctl restart xray
else
    print_error "Config Xray tidak valid - service xray tidak di-restart"
fi
systemctl restart sshws 2>/dev/null
systemctl restart sshws-tls 2>/dev/null || true

configure_firewall

install_app_files
install_cron
write_cron_script
install_symlink

# persist domain file permissions
[[ -f "$INSTALL_DIR/domain" ]] && chmod 600 "$INSTALL_DIR/domain"

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}      INSTALASI SELESAI${NC}"
echo -e "${GREEN}==============================================${NC}"
load_config
apply_config_defaults
local_domain=$(get_domain)
echo -e " Domain    : ${local_domain:-(tanpa domain)}"
echo -e " IP        : $(pubip)"
echo -e ""
echo -e " SSH       : port 22"
echo -e " SSH WS    : ws://$(get_domain):${WS_PORT}/ (path standar /)"
if [[ -f "$INSTALL_DIR/cert/fullchain.pem" ]]; then
echo -e " SSH WSS   : wss://$(get_domain):${WSS_PORT}/ (path standar /)"
fi
echo -e " VMess WS  : port ${XRAY_VMESS_WS_PORT} (path /${WS_PATH})"
echo -e " VLESS WS  : port ${XRAY_VLESS_WS_PORT} (path /${WS_PATH})"
echo -e " Trojan WS : port ${XRAY_TROJAN_WS_PORT} (path /${WS_PATH}, TLS)"
echo -e ""
echo -e " Jalankan menu : ${BOLD}sshwsxray${NC}"
echo -e "${GREEN}==============================================${NC}"
return 0
}

# Jalankan main hanya bila dieksekusi langsung; saat di-source (mis. oleh test)
# fungsi-fungsi installer bisa dipanggil tanpa menjalankan instalasi.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
