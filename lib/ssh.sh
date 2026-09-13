#!/bin/bash
# ============================================================
#  lib/ssh.sh - SSH & SSH-over-WebSocket user management
#  DB format (separator |): user|pass|created|expired|iplimit
#
#  Catatan: field `pass` TIDAK diisi password asli (diisi "-") supaya
#  password tidak pernah tersimpan plaintext di database maupun backup.
#  Password asli hanya ada di file info akun /root/<user>-ssh-ws.txt (0600).
# ============================================================

SSH_DB="$INSTALL_DIR/ssh_users.db"
TRIAL_DB="$INSTALL_DIR/trial_users.db"

# Password tidak boleh memuat ':' atau newline: chpasswd memisahkan user dan
# password dengan ':' dan setiap baris dianggap satu akun - karakter itu bisa
# dipakai untuk menyetel password akun lain (termasuk root).
_valid_password() {  # _valid_password <pass>
    local p="$1"
    [[ -n "$p" ]] || return 1
    [[ "$p" == *:* ]] && return 1
    [[ "$p" == *$'\n'* || "$p" == *$'\r'* ]] && return 1
    return 0
}

# Set tanggal expire akun di level sistem.
# chage hanya punya resolusi harian dan mengunci sejak awal hari itu, jadi
# dipakai +1 hari agar pemblokiran sistem tidak pernah lebih cepat daripada
# penegakan cron yang berbasis tanggal+jam di database.
_chage_expire() {  # _chage_expire <user> <expire>
    local user="$1" expire="$2" day
    day=$(date -d "${expire%% *} +1 day" +%F 2>/dev/null) || day="${expire%% *}"
    chage -E "$day" "$user" 2>/dev/null
}

# ---------- Low-level system user ops ----------
_sys_user_add() {  # _sys_user_add <user> <pass> <expire_date> [shell] [iplimit]
    local user="$1" pass="$2" expire="$3" shell="${4:-/bin/false}"
    local iplimit="${5:-${IP_LIMIT:-2}}"
    id "$user" &>/dev/null && { print_error "User $user sudah ada"; return 1; }
    if ! _valid_password "$pass"; then
        print_error "Password tidak boleh kosong atau memuat karakter ':' / baris baru"
        return 1
    fi

    # useradd WAJIB dicek: kalau gagal (nama invalid, shell tidak ada, dll)
    # jangan sampai database berisi akun hantu yang tidak ada di sistem.
    if ! useradd -s "$shell" -M "$user" 2>/dev/null; then
        print_error "useradd gagal untuk '${user}'"
        return 1
    fi
    _chage_expire "$user" "$expire"
    if ! echo "$user:$pass" | chpasswd 2>/dev/null; then
        print_error "Gagal menyetel password untuk '${user}'"
        userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null
        return 1
    fi
    db_add "$SSH_DB" "${user}|-|$(date +%F)|${expire}|${iplimit}"
}

_sys_user_del() {  # _sys_user_del <user>
    local user="$1"
    if id "$user" &>/dev/null; then
        # kill sessions
        pkill -u "$user" 2>/dev/null
        userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null
    fi
    _db_drop_where "$SSH_DB" 1 "$user"
    _db_drop_where "$TRIAL_DB" 2 "$user"
}

# Hapus baris yang field ke-<n> sama dengan <value> (aman + pakai file unik).
_db_drop_where() {  # _db_drop_where <dbfile> <field_number> <value>
    local file="$1" field="$2" value="$3" tmp
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    if awk -F'|' -v f="$field" -v v="$value" '$f!=v' "$file" > "$tmp"; then
        mv "$tmp" "$file"
        chmod 600 "$file" 2>/dev/null
    else
        rm -f "$tmp"
        return 1
    fi
}

# Buka kembali akun yang mungkin dikunci cron karena pernah expired.
_sys_user_unlock() {  # _sys_user_unlock <user>
    local user="$1"
    usermod -U "$user" 2>/dev/null || true
    passwd -u "$user" &>/dev/null || true
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
    if ! _valid_password "$pass"; then
        print_error "Password tidak boleh memuat karakter ':' / baris baru"
        pause_menu; return 1
    fi
    read -rp "Masa aktif (hari) [30]: " days
    [[ -z "$days" ]] && days=30
    if ! is_int "$days"; then
        print_error "Masa aktif harus berupa angka (hari)"
        pause_menu; return 1
    fi
    read -rp "Batas IP [${IP_LIMIT}]: " iplimit
    [[ -z "$iplimit" ]] && iplimit=$IP_LIMIT
    if ! is_int "$iplimit"; then
        print_error "Batas IP harus berupa angka"
        pause_menu; return 1
    fi

    local expire
    expire=$(add_days "$days")

    if _sys_user_add "$user" "$pass" "$expire" /bin/false "$iplimit"; then
        echo ""
        print_success "Akun SSH berhasil dibuat"
        echo -e "${CYAN}----------------------------------------------${NC}"
        echo -e " Hostname : $(get_domain) ($(pubip))"
        echo -e " Port SSH : 22"
        echo -e " Port WS  : ${WS_PORT} (ws) / ${WSS_PORT} (wss)"
        echo -e " Path WS  : / (tanpa path)"
        echo -e " Username : ${user}"
        echo -e " Password : ${pass}"
        echo -e " Expired  : ${expire}"
        echo -e " Limit IP : ${iplimit}"
        echo -e "${CYAN}----------------------------------------------${NC}"
        # arsip info akun: satu-satunya tempat password disimpan (mode 600)
        local domain
        domain=$(get_domain)
        local info="/root/${user}-ssh-ws.txt"
        cat > "$info" <<EOF
=== AKUN SSH WEBSOCKET (${user}) ===
Host      : ${domain:-$(pubip)}
Port SSH  : 22
Port WS   : ${WS_PORT} (websocket) / ${WSS_PORT} (websocket secure)
Path      : / (tanpa path)
User      : ${user}
Password  : ${pass}
Expired   : ${expire}
Limit IP  : ${iplimit}
EOF
        chmod 600 "$info" 2>/dev/null
        tg_send "✅ <b>AKUN SSH BARU</b>%0AUser: $(tg_escape "$user")%0AExpired: ${expire}%0ALimit IP: ${iplimit}"
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
    prefix="${prefix//[^a-zA-Z0-9_-]/}"
    if [[ -z "$prefix" ]] || (( ${#prefix} > 20 )); then
        print_error "Prefix hanya alfanumerik/-/_ (maks 20 karakter)"
        pause_menu; return 1
    fi
    local user
    user="${prefix}$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
    local expire
    expire=$(add_hours "$TRIAL_HOURS")
    if [[ -z "$expire" ]]; then
        print_error "Durasi trial tidak valid (cek pengaturan)"
        pause_menu; return 1
    fi
    local pass
    pass=$(gen_passwd 10)

    if ! _sys_user_add "$user" "$pass" "$expire" /bin/false 1; then
        print_error "Gagal membuat akun trial"
        pause_menu; return 1
    fi
    db_add "$TRIAL_DB" "ssh|${user}|${expire}"
    echo ""
    print_success "Trial dibuat: ${user} (berlaku ${TRIAL_HOURS} jam, 1 IP)"
    echo -e " Password : ${pass}"
    echo -e " Expired  : ${expire}"
    tg_send "🧪 <b>TRIAL SSH</b>%0AUser: $(tg_escape "$user")%0AExpired: ${expire}"
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
    if ! is_int "$days"; then
        print_error "Masa aktif harus berupa angka (hari)"
        pause_menu; return 1
    fi
    local current expire
    current=$(awk -F'|' -v u="$user" '$1==u {print $4}' "$SSH_DB" 2>/dev/null | head -n1)
    if [[ -n "$current" ]] && is_expired "$current"; then
        expire=$(add_days "$days")
    else
        expire=$(date -d "${current:-$(date +%F)} +$days days" +"%Y-%m-%d %H:%M" 2>/dev/null)
    fi
    if [[ -z "$expire" ]]; then
        print_error "Gagal menghitung tanggal expire baru"
        pause_menu; return 1
    fi
    _chage_expire "$user" "$expire"
    # akun yang pernah expired dikunci cron -> wajib dibuka lagi
    _sys_user_unlock "$user"
    # rewrite field 4 (expired) for this user via awk (pipe-safe)
    local tmp
    tmp=$(mktemp)
    if awk -F'|' -v u="$user" -v e="$expire" 'BEGIN{OFS="|"} $1==u {$4=e} {print}' \
        "$SSH_DB" > "$tmp"; then
        mv "$tmp" "$SSH_DB"
        chmod 600 "$SSH_DB" 2>/dev/null
    else
        rm -f "$tmp"
    fi
    print_success "User ${user} diperpanjang sampai ${expire} (dan dibuka kembali)"
    tg_send "🔄 <b>RENEW SSH</b>%0AUser: $(tg_escape "$user")%0AExpired baru: ${expire}"
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
    if confirm "Yakin hapus user '${user}'?"; then
        _sys_user_del "$user"
        rm -f "/root/${user}-ssh-ws.txt"
        print_success "User ${user} dihapus"
        tg_send "🗑 <b>AKUN SSH DIHAPUS</b>%0AUser: $(tg_escape "$user")"
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
        ipnow=$(ssh_user_ip_count "$user" 2>/dev/null || echo "0")
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
    if ! _valid_password "$pass"; then
        print_error "Password tidak boleh memuat karakter ':' / baris baru"
        pause_menu; return 1
    fi
    echo "$user:$pass" | chpasswd
    _sys_user_unlock "$user"
    print_success "Password ${user} diganti menjadi: ${pass}"
    local info="/root/${user}-ssh-ws.txt"
    if [[ -f "$info" ]]; then
        # escape karakter sed supaya password dengan # & \\ tidak merusak file
        local esc="${pass//\\/\\\\}"
        esc="${esc//#/\\#}"
        esc="${esc//&/\\&}"
        sed -i "s#^Password  : .*#Password  : ${esc}#" "$info" 2>/dev/null
        chmod 600 "$info" 2>/dev/null
    fi
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
