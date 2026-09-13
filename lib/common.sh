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
BIN_DIR="/usr/local/bin"
# Directory holding lib/*.py helpers (callers set SCRIPT_DIR before sourcing)
LIB_DIR="${SCRIPT_DIR:-/usr/local/lib/sshwsxray}/lib"
CONFIG_FILE="$INSTALL_DIR/config"
XRAY_CONFIG="${SSHWSXRAY_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
XRAY_DB="$INSTALL_DIR/xray_users.db"
XRAY_TRAFFIC_DB="$INSTALL_DIR/xray_traffic.db"

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
save_config() {  # save_config KEY VALUE
    local key="$1" value="$2"
    if [[ -f "$CONFIG_FILE" ]] && grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE"
    else
        echo "${key}=\"${value}\"" >> "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE"
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
    WS_PATH="${WS_PATH:-wsxray}"
    GOST_PORT="${GOST_PORT:-80}"
    GOST_TLS_PORT="${GOST_TLS_PORT:-443}"
    XRAY_VMESS_WS_PORT="${XRAY_VMESS_WS_PORT:-10086}"
    XRAY_VMESS_GRPC_PORT="${XRAY_VMESS_GRPC_PORT:-10087}"
    XRAY_VLESS_WS_PORT="${XRAY_VLESS_WS_PORT:-10088}"
    XRAY_VLESS_GRPC_PORT="${XRAY_VLESS_GRPC_PORT:-10089}"
    XRAY_VLESS_REALITY_PORT="${XRAY_VLESS_REALITY_PORT:-10090}"
    XRAY_TROJAN_WS_PORT="${XRAY_TROJAN_WS_PORT:-10091}"
    XRAY_TROJAN_GRPC_PORT="${XRAY_TROJAN_GRPC_PORT:-10092}"
    XRAY_API_PORT="${XRAY_API_PORT:-10085}"
    REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
    REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-www.cloudflare.com}"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    IP_LIMIT="${IP_LIMIT:-2}"
    TRIAL_HOURS="${TRIAL_HOURS:-1}"
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
date_to_epoch() { date -d "$1" +%s; }

# Return 0 if given date/time is in the past (expired)
is_expired() {
    local target
    target=$(date_to_epoch "$1")
    (( target < $(date +%s) ))
}

# Days remaining until given date (negative = overdue)
days_left() {
    local target
    target=$(date_to_epoch "$1")
    echo $(( (target - $(date +%s)) / 86400 ))
}

# ---------- Random generators ----------
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

# Remove lines where ANY colon-free field equals name (field separator: |)
db_del() {  # db_del <dbfile> <name>
    # \#...# = custom sed delimiter (leading backslash is required!)
    sed -i "\\#^\\([^|]*|\\)*${2}|#d" "$1" 2>/dev/null
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
