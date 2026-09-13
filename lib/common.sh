#!/bin/bash
# ============================================================
#  lib/common.sh - Core helpers shared by all sshwsxray scripts
# ============================================================

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Constants ----------
INSTALL_DIR="${SSHWSXRAY_INSTALL_DIR:-/etc/sshwsxray}"
# BIN_DIR bisa di-override supaya test bisa memasang symlink di sandbox.
BIN_DIR="${SSHWSXRAY_BIN_DIR:-/usr/local/bin}"
# Direktori aplikasi hasil instalasi (install.sh, menu.sh, lib/, sshws.py).
# Dipakai installer, menu, dan lib/bridge.sh - jadi didefinisikan di sini.
APP_DIR="${SSHWSXRAY_APP_DIR:-/usr/local/lib/sshwsxray}"
# Directory holding lib/*.py helpers (callers set SCRIPT_DIR before sourcing)
LIB_DIR="${SCRIPT_DIR:-/usr/local/lib/sshwsxray}/lib"
CONFIG_FILE="$INSTALL_DIR/config"
XRAY_CONFIG="${SSHWSXRAY_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
XRAY_DB="$INSTALL_DIR/xray_users.db"
XRAY_TRAFFIC_DB="$INSTALL_DIR/xray_traffic.db"
# Peta 'port|ip' yang ditulis bridge (lib/sshws.py --peer-map). Dipakai monitor
# untuk mengembalikan IP asli klien WebSocket, yang di sisi sshd tampak sebagai
# 127.0.0.1 (bridge meneruskan ke sshd lewat loopback).
WS_PEER_MAP="$INSTALL_DIR/ws_peers.db"

# ---------- UI helpers ----------
print_header() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}          SSH WEBSOCKET + XRAY MANAGER         ${NC}"
    echo -e "${CYAN}   SSH Websocket + Xray-core (VMESS/VLESS)    ${NC}"
    echo -e "${CYAN}==============================================${NC}"
}

print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[ OK  ]${NC} $1"; }
print_info()    { echo -e "${BLUE}[INFO ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN ]${NC} $1"; }

# ---------- Root check ----------
require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        print_error "Script ini harus dijalankan sebagai root (sudo bash $0)"
        exit 1
    fi
}

# ---------- OS detection ----------
detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi
    case "${OS_ID}" in
        debian|ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- Config load/save ----------
# Config format: KEY="value" (one per line)
#
# Nilai di-escape sebelum ditulis karena file ini di-source oleh script lain:
#   * backslash & kutip ganda -> supaya isi file tetap valid sebagai string shell
#   * & dan #                 -> supaya tidak merusak penggantian sed
# Newline dibuang agar tetap satu baris per key.
save_config() {  # save_config KEY VALUE
    local key="$1" value="$2"
    value="${value//$'\n'/ }"
    # hanya backslash & kutip ganda yang perlu di-escape agar file tetap
    # valid sebagai shell; penggantian baris dilakukan dengan awk (bukan sed)
    # supaya karakter & # | " tidak merusak hasilnya.
    local esc tmp
    esc=$(printf '%s' "$value" | sed -e 's/[\\"]/\\&/g')
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
    tmp=$(mktemp)
    if [[ -f "$CONFIG_FILE" ]]; then
        awk -F= -v k="$key" '$1 != k' "$CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s="%s"\n' "$key" "$esc" >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$CONFIG_FILE" || return 1
    chmod 600 "$CONFIG_FILE" 2>/dev/null
    # keep current shell in sync so callers see the new value immediately
    printf -v "$key" '%s' "$value"
}

load_config() {
    # always return 0 so callers under "set -e" are not killed when
    # the config file does not exist yet (e.g. first install / sandbox)
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
    return 0
}

# Defaults if unset after loading
apply_config_defaults() {
    DOMAIN="${DOMAIN:-}"
    CERT_DIR="${CERT_DIR:-}"
    WS_PORT="${WS_PORT:-80}"
    WSS_PORT="${WSS_PORT:-443}"
    # batas koneksi bersamaan per-IP untuk bridge SSH-WebSocket
    WS_MAX_PER_IP="${WS_MAX_PER_IP:-16}"
    # Path Xray per protokol. Diisi token acak oleh xray_ws_paths_ensure()
    # (lib/xray.sh) supaya VMess/VLESS/Trojan bisa dibedakan saat semuanya
    # lewat port 80/443 yang sama dengan SSH-WebSocket.
    XRAY_VMESS_WS_PATH="${XRAY_VMESS_WS_PATH:-}"
    XRAY_VLESS_WS_PATH="${XRAY_VLESS_WS_PATH:-}"
    XRAY_TROJAN_WS_PATH="${XRAY_TROJAN_WS_PATH:-}"
    # inbound Trojan tambahan khusus untuk bridge 443: bridge yang menerima
    # TLS, jadi inbound ini polos (security none) dan hanya listen di loopback
    XRAY_TROJAN_MUX_PORT="${XRAY_TROJAN_MUX_PORT:-10093}"
    is_int "$XRAY_TROJAN_MUX_PORT" || XRAY_TROJAN_MUX_PORT=10093
    # Hanya transport WebSocket yang dipakai (gRPC & Reality dihapus)
    XRAY_VMESS_WS_PORT="${XRAY_VMESS_WS_PORT:-10086}"
    XRAY_VLESS_WS_PORT="${XRAY_VLESS_WS_PORT:-10088}"
    XRAY_TROJAN_WS_PORT="${XRAY_TROJAN_WS_PORT:-10091}"
    XRAY_API_PORT="${XRAY_API_PORT:-10085}"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    IP_LIMIT="${IP_LIMIT:-2}"
    TRIAL_HOURS="${TRIAL_HOURS:-1}"
    # nilai dari config bisa saja diedit manual -> paksa numerik
    is_int "$IP_LIMIT" || IP_LIMIT=2
    is_int "$TRIAL_HOURS" || TRIAL_HOURS=1
    is_int "$WS_PORT" || WS_PORT=80
    is_int "$WSS_PORT" || WSS_PORT=443
    is_int "$WS_MAX_PER_IP" || WS_MAX_PER_IP=16
    AUTO_REBOOT="${AUTO_REBOOT:-0}"
    BACKUP_ENABLED="${BACKUP_ENABLED:-1}"
}

# ---------- Network helpers ----------
pubip() {
    local ip=""
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
    echo "$ip"
}

# Domain must be stored at install time in $INSTALL_DIR/domain
get_domain() {
    if [[ -n "$DOMAIN" ]]; then
        echo "$DOMAIN"
    elif [[ -f "$INSTALL_DIR/domain" ]]; then
        cat "$INSTALL_DIR/domain"
    else
        echo ""
    fi
}

# Resolve TLS cert/key paths. Prefers explicit CERT_DIR from config,
# falls back to Let's Encrypt live dir for the stored domain.
cert_paths() {
    local domain
    domain=$(get_domain)
    if [[ -n "$CERT_DIR" && -f "$CERT_DIR/fullchain.pem" ]]; then
        echo "$CERT_DIR/fullchain.pem $CERT_DIR/privkey.pem"
        return 0
    fi
    if [[ -n "$domain" && -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
        echo "/etc/letsencrypt/live/$domain/fullchain.pem /etc/letsencrypt/live/$domain/privkey.pem"
        return 0
    fi
    return 1
}

# ---------- Date helpers (GNU date, present on Debian/Ubuntu) ----------
# Add N days to now, print as "YYYY-MM-DD"
add_days() { date -d "+$1 days" +%Y-%m-%d; }

# Add N hours to now, print as "YYYY-MM-DD HH:MM"
add_hours() { date -d "+$1 hours" +"%Y-%m-%d %H:%M"; }

# Print epoch seconds for a "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" value
date_to_epoch() { date -d "$1" +%s 2>/dev/null; }

# Return 0 if given date/time is in the past (expired).
# Tanggal kosong/tidak bisa diparse dianggap BELUM expired: lebih aman
# daripada menghapus akun hanya karena field-nya rusak.
is_expired() {
    local target
    # kosong juga harus dianggap "belum expired": GNU date mengubah string
    # kosong menjadi tengah malam hari ini, yang akan terbaca sebagai expired
    # dan membuat akun terhapus sendiri.
    [[ -z "${1// /}" ]] && return 1
    target=$(date_to_epoch "$1") || true
    [[ -z "$target" ]] && return 1
    (( target < $(date +%s) ))
}

# Days remaining until given date (negative = overdue)
days_left() {
    local target
    [[ -z "${1// /}" ]] && { echo 0; return 0; }
    target=$(date_to_epoch "$1") || true
    if [[ -z "$target" ]]; then echo 0; return 0; fi
    echo $(( (target - $(date +%s)) / 86400 ))
}

# True bila argumen berupa bilangan bulat non-negatif
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# ---------- Random generators ----------
# (WS_PATH lama sudah tidak dipakai: path Xray sekarang acak per protokol,
#  lihat XRAY_*_WS_PATH di atas dan xray_ws_paths_ensure di lib/xray.sh)
# Token path acak (huruf kecil + angka), dipakai Xray sebagai path WebSocket.
gen_token() {  # gen_token [panjang]  (default 12)
    local len="${1:-12}"
    LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$len"
}

gen_uuid() {
    local uuid=""
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || uuid=$(uuidgen 2>/dev/null) || true
    if [[ -z "$uuid" ]]; then
        print_error "Tidak bisa generate UUID"
        return 1
    fi
    echo "$uuid"
}

gen_passwd() {  # gen_passwd [length]  (default 12, alphanumeric)
    local len="${1:-12}"
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# ---------- User DB line format (single source of truth) ----------
# NOTE: field separator is PIPE (|), NOT colon, because expire values
# contain "HH:MM". All consumers must use IFS='|' / awk -F'|'.
# ssh users   : /etc/sshwsxray/ssh_users.db    -> user|pass|created|expired|iplimit
# xray users  : /etc/sshwsxray/xray_users.db   -> proto|uuid|user|created|expired|iplimit
# trial users : /etc/sshwsxray/trial_users.db  -> type|name|expired
# xray traffic: /etc/sshwsxray/xray_traffic.db -> uuid|total_bytes

DB_DIR="$INSTALL_DIR"

# Append a line to a database file
db_add() {  # db_add <dbfile> <line>
    echo "$2" >> "$1"
    chmod 600 "$1"
}

# Buat file database bila belum ada. TIDAK PERNAH menimpa/mengosongkan file
# yang sudah berisi data (installer dulu memakai ': > file' yang menghapus
# seluruh akun setiap kali dijalankan).
ensure_db_files() {
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR" 2>/dev/null
    local f
    for f in ssh_users.db xray_users.db xray_traffic.db trial_users.db ws_peers.db; do
        [[ -f "$INSTALL_DIR/$f" ]] || : > "$INSTALL_DIR/$f"
        chmod 600 "$INSTALL_DIR/$f" 2>/dev/null
    done
    return 0
}

# ---------- Misc ----------
fmt_bytes() {  # human readable bytes
    local b=${1:-0}
    if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.2f GB", b/1073741824}'
    elif (( b >= 1048576    )); then awk -v b="$b" 'BEGIN{printf "%.2f MB", b/1048576}'
    elif (( b >= 1024       )); then awk -v b="$b" 'BEGIN{printf "%.2f KB", b/1024}'
    else echo "${b} B"; fi
}

confirm() {  # confirm "message" -> returns 0 if yes
    local answer
    read -rp "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause_menu() {
    echo ""
    read -rp "Tekan Enter untuk kembali ke menu..." _
}
