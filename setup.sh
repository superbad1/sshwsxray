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

APP_DIR="/usr/local/lib/sshwsxray"

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
install_packages() {
    log_step "Update sistem & install dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl wget tar jq python3 openssl cron \
        openssh-server netfilter-persistent iptables-persistent \
        speedtest-cli >/dev/null

    log_step "Menginstall netsense (limit IP)"
    if ! command -v netsense &>/dev/null; then
        curl -sL "https://raw.githubusercontent.com/awaluff/netsense/main/netsense" \
            -o /usr/local/bin/netsense && chmod +x /usr/local/bin/netsense \
            && print_success "netsense terinstall" \
            || print_warning "netsense gagal diinstall - limit IP via cron yang akan menutup sesi"
    fi
}

# ---------- SSH config ----------
configure_ssh() {
    log_step "Konfigurasi OpenSSH"
    mkdir -p /etc/ssh
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)" 2>/dev/null
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
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
}

# ---------- Bridge WebSocket kustom (pure Python, pengganti gost) ----------
install_sshws() {
    log_step "Install bridge SSH-WebSocket (lib/sshws.py)"
    load_config
    # SSH-WS memakai path standar '/' (tanpa path khusus); WS_PATH hanya untuk Xray
    local ws_port="${WS_PORT:-80}"
    local wss_port="${WSS_PORT:-443}"

    # pastikan script bridge ada sebelum unit systemd dibuat
    mkdir -p "$APP_DIR"
    install -m 644 "${SCRIPT_DIR}/lib/sshws.py" "${APP_DIR}/sshws.py"

    # ---- websocket biasa (port 80) -> sshd ----
    cat > /etc/systemd/system/sshws.service <<EOF
[Unit]
Description=SSH over WebSocket (custom python bridge)
After=network.target ssh.service

[Service]
Type=simple
ExecStart=$(command -v python3) ${APP_DIR}/sshws.py --port ${ws_port} --target 127.0.0.1:22
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
ExecStart=$(command -v python3) ${APP_DIR}/sshws.py --port ${wss_port} --target 127.0.0.1:22 --tls --cert ${INSTALL_DIR}/cert/fullchain.pem --key ${INSTALL_DIR}/cert/privkey.pem
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
    else
        systemctl enable sshws
    fi
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
init_data() {
    log_step "Inisialisasi direktori data"
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"
    : > "$INSTALL_DIR/ssh_users.db"
    : > "$INSTALL_DIR/xray_users.db"
    : > "$INSTALL_DIR/xray_traffic.db"
    : > "$INSTALL_DIR/trial_users.db"
    chmod 600 "$INSTALL_DIR/"*.db
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
    cp "${SCRIPT_DIR}/menu.sh" "$APP_DIR/menu.sh"
    cp "${SCRIPT_DIR}/lib/"*.sh "$APP_DIR/lib/"
    cp "${SCRIPT_DIR}/lib/"*.py "$APP_DIR/lib/"
    chmod 755 "$APP_DIR/menu.sh" "$APP_DIR/lib/"*.sh
    chmod 644 "$APP_DIR/lib/"*.py
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
if [[ $SSL_ONLY -eq 1 ]]; then
    init_data
    load_config
    apply_config_defaults
    issue_ssl
    exit $?
fi

echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}   SSH WEBSOCKET + XRAY AUTOSCRIPT INSTALLER${NC}"
echo -e "${CYAN}   SSH WebSocket + Xray-core (VMESS/VLESS)${NC}"
echo -e "${CYAN}==============================================${NC}"

if ! detect_os; then
    print_error "OS tidak didukung (butuh Debian atau Ubuntu)."
    exit 1
fi
print_info "OS terdeteksi: ${OS_ID} ${OS_VERSION}"
print_info "Arsitektur   : $(uname -m) ($(detect_arch))"

# Gather domain early (needed for cert & links)
read -rp "Domain untuk SSL (kosongkan jika tanpa domain): " DOMAIN_INPUT
DOMAIN_INPUT="${DOMAIN_INPUT:-}"
if [[ -n "$DOMAIN_INPUT" ]]; then
    if ! [[ "$DOMAIN_INPUT" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Format domain tidak valid"; exit 1
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
for key in WS_PATH WS_PORT WSS_PORT XRAY_VMESS_WS_PORT XRAY_VLESS_WS_PORT \
           XRAY_TROJAN_WS_PORT XRAY_API_PORT IP_LIMIT TRIAL_HOURS; do
    save_config "$key" "${!key}"
done

configure_ssh
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

# Render initial xray config (inbounds only; clients added via menu)
source "${SCRIPT_DIR}/lib/xray.sh"
xray_render_config
xray_validate && systemctl restart xray
systemctl restart sshws 2>/dev/null
systemctl restart sshws-tls 2>/dev/null || true

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
