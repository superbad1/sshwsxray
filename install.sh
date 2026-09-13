#!/bin/bash
# ============================================================
#  install.sh - Satu berkas untuk memasang sshwsxray
#
#  Instalasi satu baris (VPS Debian/Ubuntu, sebagai root):
#
#     curl -fsSL https://raw.githubusercontent.com/superbad1/sshwsxray/main/install.sh | sudo bash
#
#  Tanpa git, tanpa arsip, tanpa ekstrak, tanpa argumen.
#
#  Berkas ini memegang dua peran sekaligus:
#    1. Bootstrap  - saat dibaca dari pipe, ia mengunduh berkas aplikasi
#                    (menu.sh, uninstall.sh, lib/*) ke direktori sementara
#                    lalu menjalankan salinan dirinya dari sana.
#    2. Installer  - memasang OpenSSH, bridge WebSocket, Xray-core, cron,
#                    SSL, dan menyalin aplikasi ke /usr/local/lib/sshwsxray.
#
#  Salinan installer juga dipasang di /usr/local/lib/sshwsxray supaya menu
#  "Install / perbarui SSL" bisa memanggilnya:
#     SSL_ONLY=1 /usr/local/lib/sshwsxray/install.sh
# ============================================================

RAW_BASE="https://raw.githubusercontent.com/superbad1/sshwsxray/main"

# Seluruh berkas aplikasi (install.sh sendiri ikut supaya salinan di
# /usr/local/lib/sshwsxray selalu ada). tests/test_install.sh membandingkan
# daftar ini dengan isi repo, jadi berkas baru di lib/ yang lupa didaftarkan
# akan langsung ketahuan.
MANIFEST="
install.sh
menu.sh
uninstall.sh
lib/backup.sh
lib/common.sh
lib/expire.sh
lib/monitor.sh
lib/ssh.sh
lib/telegram.sh
lib/xray.sh
lib/xray_users.sh
lib/sshws.py
lib/xray_proto.py
lib/xray_render.py
"

INSTALL_DIR="${SSHWSXRAY_INSTALL_DIR:-/etc/sshwsxray}"
APP_DIR="${SSHWSXRAY_APP_DIR:-/usr/local/lib/sshwsxray}"
BIN_DIR="/usr/local/bin"
TMP_DIR=""

# Dari mana berkas ini dijalankan:
#   sebagai berkas (salinan hasil unduhan / di APP_DIR) -> SCRIPT_DIR terisi
#   dibaca dari pipe ('curl ... | bash')                -> BASH_SOURCE kosong
# Mode kerja ditentukan dari ada/tidaknya lib/ di sebelah SCRIPT_DIR.
SELF="${BASH_SOURCE[0]}"
if [[ -f "$SELF" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
else
    SCRIPT_DIR=""
fi

# ============================================================
#  Helper dasar (dipakai sebelum lib/common.sh di-source)
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step() { echo -e "\n${CYAN}==> ${1}${NC}"; }
log()  { echo -e "${BLUE}==>${NC} $1"; }
ok()   { echo -e "${GREEN}[ OK  ]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN ]${NC} $1"; }
die()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Apakah /dev/tty benar-benar bisa dipakai?
# Tes '-c /dev/tty' dan '-r /dev/tty' TIDAK cukup: keduanya lolos walaupun
# proses tidak punya controlling terminal, dan kegagalannya baru muncul saat
# dibuka ("No such device or address"). Jadi dicoba dibuka sungguhan.
tty_usable() { ( true </dev/tty ) 2>/dev/null; }

fetch() {  # fetch <url> <dest>
    if have curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
    else
        wget -q --tries=3 --timeout=15 -O "$2" "$1"
    fi
}

# ============================================================
#  Bootstrap
# ============================================================
check_downloader() {
    if have curl || have wget; then return 0; fi
    log "curl/wget belum ada - memasang curl"
    have apt-get || die "Butuh curl atau wget (apt-get juga tidak ada)"
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null 2>&1 \
        || die "Gagal memasang curl"
    have mktemp || die "Butuh mktemp (paket coreutils)"
}

download_app_files() {
    local total="$1" f
    log "Mengunduh ${total} berkas aplikasi"
    for f in $MANIFEST; do
        mkdir -p "$TMP_DIR/$(dirname "$f")"
        fetch "${RAW_BASE}/${f}" "$TMP_DIR/${f}" \
            || die "Gagal mengunduh berkas '${f}'
      Periksa koneksi internet VPS, lalu jalankan ulang perintah instalasi."
    done
    ok "${total} berkas terunduh"
    [[ -s "$TMP_DIR/install.sh" ]] \
        || die "install.sh tidak terunduh dengan benar (berkas kosong)"
}

cleanup_tmp() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }

# Jalankan salinan installer hasil unduhan (yang sudah punya lib/ di sebelahnya)
run_downloaded_copy() {
    local rc=0
    if [[ -t 0 ]]; then
        bash "$SCRIPT_DIR/install.sh" || rc=$?
    elif tty_usable; then
        # Pada 'curl ... | sudo bash' stdin berisi script installer ini, bukan
        # keyboard. Tanpa dialihkan ke /dev/tty, pertanyaan domain di tahap
        # instalasi langsung mendapat EOF dan instalasi selesai tanpa SSL
        # tanpa disadari.
        bash "$SCRIPT_DIR/install.sh" < /dev/tty || rc=$?
    else
        warn "Tidak ada terminal untuk menjawab pertanyaan - instalasi lanjut
      dengan jawaban kosong (tanpa domain/SSL). SSL bisa ditambahkan nanti
      lewat menu: sudo sshwsxray -> 5 -> 8"
        bash "$SCRIPT_DIR/install.sh" || rc=$?
    fi
    return "$rc"
}

# ============================================================
#  Fungsi installer
# ============================================================
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

check_port_free() {  # <port> <svcname>
    if ss -tlnp 2>/dev/null | grep -q ":$1 "; then
        print_warning "Port $1 sudah dipakai ($2). Instalasi tetap lanjut - periksa konflik!"
    fi
}

install_packages() {
    log_step "Update sistem & install dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl wget tar jq python3 openssl cron ca-certificates \
        openssh-server speedtest-cli >/dev/null
}

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

# Bridge WebSocket kustom (pure Python, pengganti gost)
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

install_xray() {
    log_step "Install Xray-core (installer resmi XTLS/Xray-install)"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray
}

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

# ensure_db_files() (lib/common.sh) hanya MEMBUAT berkas yang belum ada.
# Versi lama memakai ': > file' sehingga menjalankan ulang installer - atau
# "Install/perbarui sertifikat SSL" dari menu - menghapus semua akun.
init_data() {
    log_step "Inisialisasi direktori data"
    ensure_db_files
}

install_cron() {
    log_step "Pasang cron jobs"
    cat > /etc/cron.d/sshwsxray <<EOF
# SSHWSXRAY SSH/Xray manager
* * * * * root ${BIN_DIR}/sshwsxray-cron
EOF
    chmod 644 /etc/cron.d/sshwsxray
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
}

# Salin aplikasi ke APP_DIR supaya runtime tidak bergantung pada direktori
# sementara hasil unduhan.
install_app_files() {
    log_step "Install aplikasi ke ${APP_DIR}"
    mkdir -p "$APP_DIR/lib"
    if [[ "$SCRIPT_DIR" != "$APP_DIR" ]]; then
        # install.sh ikut disalin: menu "Install/perbarui SSL" menjalankan
        # ${APP_DIR}/install.sh, jadi berkas itu harus ada di sana.
        cp -f "${SCRIPT_DIR}/menu.sh" "$APP_DIR/menu.sh"
        cp -f "${SCRIPT_DIR}/install.sh" "$APP_DIR/install.sh"
        cp -f "${SCRIPT_DIR}/uninstall.sh" "$APP_DIR/uninstall.sh" 2>/dev/null || true
        cp -f "${SCRIPT_DIR}/lib/"*.sh "$APP_DIR/lib/"
        cp -f "${SCRIPT_DIR}/lib/"*.py "$APP_DIR/lib/"
    fi
    chmod 755 "$APP_DIR/menu.sh" "$APP_DIR/lib/"*.sh
    [[ -f "$APP_DIR/install.sh" ]] && chmod 755 "$APP_DIR/install.sh"
    [[ -f "$APP_DIR/uninstall.sh" ]] && chmod 755 "$APP_DIR/uninstall.sh"
    chmod 644 "$APP_DIR/lib/"*.py 2>/dev/null || true
    return 0
}

# Cron payload (berkas terpisah, tanpa dependensi menu)
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

install_symlink() {
    ln -sf "${APP_DIR}/menu.sh" "${BIN_DIR}/sshwsxray"
    chmod +x "${APP_DIR}/menu.sh"
}

# ============================================================
#  Alur: instalasi lengkap
# ============================================================
install_all() {
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}   SSH WEBSOCKET + XRAY AUTOSCRIPT INSTALLER${NC}"
    echo -e "${CYAN}   SSH WebSocket + Xray-core (VMESS/VLESS)${NC}"
    echo -e "${CYAN}==============================================${NC}"

    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/lib/common.sh"
    load_config
    apply_config_defaults

    if ! detect_os; then
        print_error "OS tidak didukung (butuh Debian atau Ubuntu)."
        return 1
    fi
    print_info "OS terdeteksi: ${OS_ID} ${OS_VERSION}"
    print_info "Arsitektur   : $(uname -m) ($(detect_arch))"

    # Tanya domain lebih awal (dipakai untuk cert & link)
    read -rp "Domain untuk SSL (kosongkan jika tanpa domain): " DOMAIN_INPUT
    DOMAIN_INPUT="${DOMAIN_INPUT:-}"
    if [[ -n "$DOMAIN_INPUT" ]]; then
        if ! [[ "$DOMAIN_INPUT" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            print_error "Format domain tidak valid"; return 1
        fi
    fi

    install_packages
    init_data

    # Simpan domain & default sebelum service dikonfigurasi
    if [[ -n "$DOMAIN_INPUT" ]]; then
        save_config DOMAIN "$DOMAIN_INPUT"
        echo "$DOMAIN_INPUT" > "$INSTALL_DIR/domain"
    fi
    apply_config_defaults
    local key
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

    # salin cert dari letsencrypt kalau belum ada di direktori data
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

    # Render config Xray awal (hanya inbound; akun ditambah lewat menu)
    # shellcheck source=lib/xray.sh
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

    [[ -f "$INSTALL_DIR/domain" ]] && chmod 600 "$INSTALL_DIR/domain"

    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}      INSTALASI SELESAI${NC}"
    echo -e "${GREEN}==============================================${NC}"
    load_config
    apply_config_defaults
    local local_domain
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

# ============================================================
#  Alur: hanya SSL (dipanggil menu Pengaturan -> 8)
# ============================================================
ssl_only() {
    # shellcheck source=lib/common.sh
    source "${SCRIPT_DIR}/lib/common.sh"
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
    # shellcheck source=lib/xray.sh
    source "${SCRIPT_DIR}/lib/xray.sh"
    if xray_render_config; then
        xray_safe_restart
    fi
    print_success "SSL terpasang: wss://${WSS_PORT} (SSH) dan inbound Trojan WS aktif"
    return 0
}

# ============================================================# Gagal cepat bila OS tidak didukung, SEBELUM mengunduh apa pun.
# Tidak mencetak apa-apa saat OS didukung: tahap instalasi yang mencetak
# ringkasan OS/arsitektur (supaya saat bootstrap tidak tercetak dua kali).
check_os() {
    local id=""
    if [[ -r /etc/os-release ]]; then
        id="$(. /etc/os-release; echo "${ID:-}")"
    fi
    case "$id" in
        debian|ubuntu) return 0 ;;
        *) die "OS tidak didukung (butuh Debian 10/11/12 atau Ubuntu 20.04/22.04/24.04). Terdeteksi: ${id:-tidak diketahui}" ;;
    esac
}

main() {
    if [[ ${EUID} -ne 0 ]]; then
        die "Installer harus dijalankan sebagai root. Pakai:
      curl -fsSL ${RAW_BASE}/install.sh | sudo bash"
    fi

    echo -e "${BOLD}SSH Websocket + Xray-core installer${NC}"
    check_os

    # ---- Mode 1: sudah ada lib/ di sebelah script (hasil unduhan / APP_DIR) ----
    if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
        if [[ "${SSL_ONLY:-0}" == "1" ]]; then
            ssl_only
        else
            install_all
        fi
        return 0
    fi

    # ---- Mode 2: dibaca dari pipe -> unduh aplikasi dulu, lalu jalankan ----
    check_downloader
    TMP_DIR="$(mktemp -d)"
    trap cleanup_tmp EXIT INT TERM

    download_app_files "$(echo "$MANIFEST" | wc -w)"
    SCRIPT_DIR="$TMP_DIR"

    # Kode keluar salinan installer diteruskan apa adanya (trap EXIT tetap
    # membersihkan direktori sementara sebelum script berhenti).
    local rc=0
    run_downloaded_copy || rc=$?
    return "$rc"
}

# Jalankan main hanya bila dieksekusi langsung - termasuk saat dibaca dari
# pipe, yang ditandai BASH_SOURCE[0] KOSONG ('curl ... | sudo bash'). Saat
# di-source (mis. oleh test) cukup definisi fungsinya, dan option shell tidak
# ikut berubah.
if [[ -z "${BASH_SOURCE[0]}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    main
fi
