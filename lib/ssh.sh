#!/bin/bash
# ============================================================
#  lib/ssh.sh - SSH & SSH-over-WebSocket user management
#  DB format (separator |): user|pass|created|expired|iplimit
# ============================================================

SSH_DB="$INSTALL_DIR/ssh_users.db"
TRIAL_DB="$INSTALL_DIR/trial_users.db"

# ---------- Low-level system user ops ----------
_sys_user_add() {  # _sys_user_add <user> <pass> <expire_date> [shell] [iplimit]
    local user="$1" pass="$2" expire="$3" shell="${4:-/bin/false}"
    local iplimit="${5:-${IP_LIMIT:-2}}"
    # expire for chage: YYYY-MM-DD (drop time part if present)
    local edate="${expire%% *}"
    id "$user" &>/dev/null && { print_error "User $user sudah ada"; return 1; }
    useradd -e "$edate" -s "$shell" -M "$user" 2>/dev/null
    echo "$user:$pass" | chpasswd
    db_add "$SSH_DB" "${user}|${pass}|$(date +%F)|${expire}|${iplimit}"
}

_sys_user_del() {  # _sys_user_del <user>
    local user="$1"
    if id "$user" &>/dev/null; then
        # kill sessions
        pkill -u "$user" 2>/dev/null
        userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null
    fi
    sed -i "/^${user}|/d" "$SSH_DB" 2>/dev/null
    sed -i "/^[^|]*|${user}|/d" "$TRIAL_DB" 2>/dev/null
    netsense_del_user "$user" 2>/dev/null
}

# ---------- Create SSH account ----------
ssh_create() {
    print_header
    echo -e "${CYAN}>>> BUAT AKUN SSH / SSH WEBSOCKET${NC}"
    echo ""
    read -rp "Username: " user
    [[ -z "$user" ]] && { print_error "Username kosong"; pause_menu; return 1; }
    if ! [[ "$user" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        print_error "Username 3-32 karakter, alfanumerik/-/_"
        pause_menu; return 1
    fi
    id "$user" &>/dev/null && { print_error "User sudah ada"; pause_menu; return 1; }
    read -rp "Password [kosong=auto]: " pass
    [[ -z "$pass" ]] && pass=$(gen_passwd 12)
    read -rp "Masa aktif (hari) [30]: " days
    [[ -z "$days" ]] && days=30
    read -rp "Batas IP [${IP_LIMIT}]: " iplimit
    [[ -z "$iplimit" ]] && iplimit=$IP_LIMIT

    local expire
    expire=$(add_days "$days")

    if _sys_user_add "$user" "$pass" "$expire" /bin/false "$iplimit"; then
        echo ""
        print_success "Akun SSH berhasil dibuat"
        echo -e "${CYAN}----------------------------------------------${NC}"
        echo -e " Hostname : $(get_domain) ($(pubip))"
        echo -e " Port SSH : 22"
        echo -e " Port WS  : ${GOST_PORT} (ws) / ${GOST_TLS_PORT} (wss)"
        echo -e " Path WS  : ${WS_PATH}"
        echo -e " Username : ${user}"
        echo -e " Password : ${pass}"
        echo -e " Expired  : ${expire}"
        echo -e " Limit IP : ${iplimit}"
        echo -e "${CYAN}----------------------------------------------${NC}"
        # websocket account info file for user
        local domain
        domain=$(get_domain)
        cat > "/root/${user}-ssh-ws.txt" <<EOF
=== AKUN SSH WEBSOCKET (${user}) ===
Host      : ${domain:-$(pubip)}
Port SSH  : 22
Port WS   : ${GOST_PORT} (websocket) / ${GOST_TLS_PORT} (websocket secure)
Path      : ${WS_PATH}
User      : ${user}
Password  : ${pass}
Expired   : ${expire}
Limit IP  : ${iplimit}
EOF
        tg_send "✅ <b>AKUN SSH BARU</b>%0AUser: ${user}%0AExpired: ${expire}%0ALimit IP: ${iplimit}"
    fi
    pause_menu
}

# ---------- Trial account ----------
ssh_trial() {
    print_header
    echo -e "${CYAN}>>> AKUN TRIAL SSH (${TRIAL_HOURS} JAM)${NC}"
    echo ""
    read -rp "Prefix username [trial]: " prefix
    [[ -z "$prefix" ]] && prefix="trial"
    local user
    user="${prefix}$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
    local expire
    expire=$(add_hours "$TRIAL_HOURS")

    useradd -e "${expire%% *}" -s /bin/false -M "$user" 2>/dev/null
    local pass
    pass=$(gen_passwd 10)
    echo "$user:$pass" | chpasswd
    db_add "$SSH_DB" "${user}|${pass}|$(date +%F)|${expire}|1"
    db_add "$TRIAL_DB" "ssh|${user}|${expire}"
    echo ""
    print_success "Trial dibuat: ${user} (berlaku ${TRIAL_HOURS} jam, 1 IP)"
    echo -e " Password : ${pass}"
    echo -e " Expired  : ${expire}"
    tg_send "🧪 <b>TRIAL SSH</b>%0AUser: ${user}%0AExpired: ${expire}"
    pause_menu
}

# ---------- Renew ----------
ssh_renew() {
    print_header
    echo -e "${CYAN}>>> RENEW AKUN SSH${NC}"
    echo ""
    list_ssh_users brief
    read -rp "Username yang di-renew: " user
    if ! id "$user" &>/dev/null; then
        print_error "User tidak ditemukan"; pause_menu; return 1
    fi
    read -rp "Tambah masa aktif (hari) [30]: " days
    [[ -z "$days" ]] && days=30
    local current expire
    current=$(awk -F'|' -v u="$user" '$1==u {print $4}' "$SSH_DB" 2>/dev/null | head -n1)
    if [[ -n "$current" ]] && is_expired "$current"; then
        expire=$(add_days "$days")
    else
        expire=$(date -d "${current:-$(date +%F)} +$days days" +"%Y-%m-%d %H:%M")
    fi
    chage -E "${expire%% *}" "$user"
    # rewrite field 4 (expired) for this user via awk (pipe-safe)
    awk -F'|' -v u="$user" -v e="$expire" 'BEGIN{OFS="|"} $1==u {$4=e} {print}' \
        "$SSH_DB" > "${SSH_DB}.tmp" && mv "${SSH_DB}.tmp" "$SSH_DB"
    print_success "User ${user} diperpanjang sampai ${expire}"
    tg_send "🔄 <b>RENEW SSH</b>%0AUser: ${user}%0AExpired baru: ${expire}"
    pause_menu
}

# ---------- Delete ----------
ssh_delete() {
    print_header
    echo -e "${CYAN}>>> HAPUS AKUN SSH${NC}"
    echo ""
    list_ssh_users brief
    read -rp "Username yang dihapus: " user
    if ! id "$user" &>/dev/null; then
        print_error "User tidak ditemukan"; pause_menu; return 1
    fi
    confirm "Yakin hapus user '${user}'?"
    if [[ $? -eq 0 ]]; then
        _sys_user_del "$user"
        rm -f "/root/${user}-ssh-ws.txt"
        print_success "User ${user} dihapus"
        tg_send "🗑 <b>AKUN SSH DIHAPUS</b>%0AUser: ${user}"
    fi
    pause_menu
}

# ---------- List ----------
list_ssh_users() {  # list_ssh_users [brief|full]
    local mode="${1:-full}"
    if [[ ! -s "$SSH_DB" ]]; then
        echo -e "${YELLOW}Belum ada user SSH.${NC}"
        return 0
    fi
    if [[ "$mode" == "brief" ]]; then
        awk -F'|' '{printf "  %-16s expired: %s\n", $1, $4}' "$SSH_DB"
        return 0
    fi
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    printf "${WHITE} %-16s %-10s %-20s %-5s %-5s${NC}\n" "USERNAME" "STATUS" "EXPIRED" "IPLIM" "IPNOW"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    while IFS='|' read -r user _pass _created expired iplimit; do
        [[ -z "$user" ]] && continue
        local status ipnow
        if is_expired "$expired"; then
            status="${RED}EXPIRED${NC}"
        else
            status="${GREEN}ACTIVE${NC}"
        fi
        ipnow=$(netsense_count_ips "$user" 2>/dev/null || echo "0")
        printf " %-16s %-16b %-20s %-5s %-5s\n" "$user" "$status" "$expired" "${iplimit:-$IP_LIMIT}" "$ipnow"
    done < "$SSH_DB"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

ssh_list() {
    print_header
    echo -e "${CYAN}>>> DAFTAR AKUN SSH${NC}"
    echo ""
    list_ssh_users full
    pause_menu
}

# ---------- Change password ----------
ssh_chpass() {
    print_header
    echo -e "${CYAN}>>> GANTI PASSWORD SSH${NC}"
    echo ""
    read -rp "Username: " user
    id "$user" &>/dev/null || { print_error "User tidak ditemukan"; pause_menu; return 1; }
    read -rp "Password baru [kosong=auto]: " pass
    [[ -z "$pass" ]] && pass=$(gen_passwd 12)
    echo "$user:$pass" | chpasswd
    # rewrite field 2 (password) for this user via awk (pipe-safe)
    awk -F'|' -v u="$user" -v p="$pass" 'BEGIN{OFS="|"} $1==u {$2=p} {print}' \
        "$SSH_DB" > "${SSH_DB}.tmp" && mv "${SSH_DB}.tmp" "$SSH_DB"
    print_success "Password ${user} diganti menjadi: ${pass}"
    pause_menu
}

# ---------- Check login (who + multi-login detect) ----------
ssh_online() {
    print_header
    echo -e "${CYAN}>>> USER SSH ONLINE${NC}"
    echo ""
    who -u 2>/dev/null | awk '{printf " %-10s %-12s %-16s %-8s %s %s %s\n", $1, $2, $3, "ssh", $4, $5, $6}' | sort
    echo ""
    echo -e "${CYAN}--- Deteksi multi-login (lebih dari 1 sesi / user) ---${NC}"
    who 2>/dev/null | awk '{print $1}' | sort | uniq -c | awk '$1 > 1 {print " ⚠ " $1 " sesi: " $2}'
    pause_menu
}
