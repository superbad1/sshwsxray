#!/bin/bash
# ============================================================
#  lib/monitor.sh - System info, online users, IP limits,
#                   multi-login detection, speedtest (sshwsxray)
# ============================================================

# ---------- System info ----------
sysinfo() {
    print_header
    echo -e "${CYAN}>>> INFO SISTEM${NC}"
    echo ""
    local uptime os cpu mem swap disk ip
    os=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
    uptime=$(uptime -p 2>/dev/null | sed 's/up //')
    cpu=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | sed 's/^ //')
    cpu="${cpu} ($(nproc) core)"
    mem=$(free -m | awk '/Mem:/{printf "%sMB / %sMB (%.0f%%)", $3, $2, $3/$2*100}')
    swap=$(free -m | awk '/Swap:/{printf "%sMB / %sMB", $3, $2}')
    disk=$(df -h / | awk 'NR==2{printf "%s / %s (%s used)", $3, $2, $5}')
    ip=$(pubip)
    local virt="unknown"
    [[ -d /proc/vz ]] && virt="OpenVZ"
    systemd-detect-virt &>/dev/null && virt=$(systemd-detect-virt)

    echo -e " OS        : ${os}"
    echo -e " Uptime    : ${uptime}"
    echo -e " CPU       : ${cpu}"
    echo -e " RAM       : ${mem}"
    echo -e " Swap      : ${swap}"
    echo -e " Disk      : ${disk}"
    echo -e " IP Publik : ${ip}"
    echo -e " Domain    : $(get_domain)"
    echo -e " Virt      : ${virt}"
    echo -e " Xray      : $(xray_status) ($(command -v xray &>/dev/null && xray version | head -n1 | awk '{print $2}'))"
    echo ""
    echo -e "${CYAN}--- Banderole layanan ---${NC}"
    for svc in ssh sshws sshws-tls xray cron; do
        if systemctl is-active "$svc" &>/dev/null; then
            printf "  %-22s ${GREEN}RUNNING${NC}\n" "$svc"
        else
            printf "  %-22s ${RED}STOPPED${NC}\n" "$svc"
        fi
    done
    pause_menu
}

# ---------- Online users (ssh sessions + xray connections) ----------
monitor_online() {
    print_header
    echo -e "${CYAN}>>> MONITOR USER ONLINE${NC}"
    echo ""
    echo -e "${CYAN}--- Sesi SSH aktif ---${NC}"
    who -u 2>/dev/null | awk '{printf " %-12s %-16s %-8s %s %s\n", $1, $3, $2, $4, $5}' || echo " (tidak ada)"
    echo ""
    echo -e "${CYAN}--- Koneksi ke port tunnel (WS/Xray) ---${NC}"
    local found=0
    local ports="$WS_PORT $WSS_PORT $XRAY_VMESS_WS_PORT $XRAY_VLESS_WS_PORT $XRAY_TROJAN_WS_PORT"
    for p in $ports; do
        [[ -z "$p" ]] && continue
        local count
        count=$(ss -tn state established "( sport = :${p} )" 2>/dev/null | tail -n +2 | wc -l)
        if (( count > 0 )); then
            printf "  port %-6s : %s koneksi\n" "$p" "$count"
            found=1
        fi
    done
    (( found == 0 )) && echo -e " ${YELLOW}(tidak ada koneksi aktif)${NC}"
    pause_menu
}

# ---------- Pengukuran sesi SSH ----------
# Menghitung IP unik per user langsung dari koneksi sshd yang ESTABLISHED.
# Dulu ini memakai `netsense` (script pihak ketiga) yang sumbernya sudah 404,
# sehingga tidak ada lagi dependency eksternal di sini.
_peer_ip() {  # buang port dari "ip:port" / "[v6]:port"
    local a="$1"
    if [[ "$a" == \[*\]:* ]]; then
        a="${a%%]*}"
        a="${a#[}"
    else
        a="${a%:*}"
    fi
    echo "$a"
}

# cetak "user ip" untuk tiap sesi SSH yang sedang berjalan
_ssh_session_pairs() {
    command -v ss &>/dev/null || return 0
    local line peer pid owner
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        peer=$(echo "$line" | awk '{print $5}')
        pid=$(echo "$line" | grep -o 'pid=[0-9]*' | head -n1 | cut -d= -f2)
        [[ -z "$peer" || -z "$pid" ]] && continue
        # sshd child yang memegang socket sudah turun ke user pemilik sesi
        owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z "$owner" || "$owner" == "root" ]] && continue
        printf '%s %s\n' "$owner" "$(_peer_ip "$peer")"
    done < <(ss -H -tn state established '( sport = :22 )' -p 2>/dev/null)
}

# fallback bila `ss` tidak tersedia / tidak menampilkan proses
_ssh_session_pairs_who() {
    who 2>/dev/null | awk '$NF ~ /^\(/ {gsub(/[()]/, "", $NF); print $1, $NF}'
}

ssh_user_ip_count() {  # <user> -> jumlah IP unik yang sedang dipakai
    local user="$1" out
    out=$(_ssh_session_pairs)
    [[ -z "$out" ]] && out=$(_ssh_session_pairs_who)
    [[ -z "$out" ]] && { echo 0; return 0; }
    echo "$out" | awk -v u="$user" '$1==u {print $2}' | sort -u | wc -l
}

# ---------- Alert anti-spam ----------
# Kirim notifikasi maksimal sekali per <key> dalam <menit> menit supaya cron
# tiap menit tidak membanjiri Telegram.
ALERT_STATE="$INSTALL_DIR/.alertstate"
_alert_once() {  # _alert_once <key> <menit> <pesan>
    local key="$1" window="$2" msg="$3"
    local now last tmp
    now=$(date +%s)
    last=0
    if [[ -f "$ALERT_STATE" ]]; then
        last=$(awk -F'|' -v k="$key" '$1==k {print $2}' "$ALERT_STATE" 2>/dev/null | head -n1)
    fi
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last < window * 60 )) && return 0
    tmp=$(mktemp)
    if [[ -f "$ALERT_STATE" ]]; then
        awk -F'|' -v k="$key" '$1!=k' "$ALERT_STATE" > "$tmp"
    fi
    echo "${key}|${now}" >> "$tmp"
    tail -n 200 "$tmp" > "${tmp}.keep" && mv "${tmp}.keep" "$ALERT_STATE" || mv "$tmp" "$ALERT_STATE"
    rm -f "$tmp"
    chmod 600 "$ALERT_STATE" 2>/dev/null
    tg_send "$msg"
}

# ---------- Enforcement: expire + IP limit + multi-login ----------
# Designed to run from cron every minute.
monitor_enforce() {
    load_config
    apply_config_defaults

    # 1) Auto-reboot option
    if [[ "${AUTO_REBOOT:-0}" == "1" ]]; then
        local h m
        h=$(date +%H); m=$(date +%M)
        if [[ "$h" == "05" && "$m" == "00" ]]; then
            tg_send "🔁 Server reboot otomatis (05:00)"
            reboot
        fi
    fi

    # 2) Expire SSH users -> lock password & kill sessions
    local db="$INSTALL_DIR/ssh_users.db"
    if [[ -f "$db" ]]; then
        while IFS='|' read -r user _pass _created expired _iplimit; do
            [[ -z "$user" ]] && continue
            id "$user" &>/dev/null || continue
            if is_expired "$expired"; then
                passwd -l "$user" &>/dev/null
                pkill -u "$user" 2>/dev/null
            fi
        done < "$db"
    fi

    # 3) Expire Xray users -> remove from DB and re-render config
    local xdb="$INSTALL_DIR/xray_users.db"
    if [[ -f "$xdb" ]]; then
        local removed=0 tmp
        while IFS='|' read -r proto uuid user _created expired _iplimit; do
            [[ -z "$proto" ]] && continue
            if is_expired "$expired"; then
                tmp=$(mktemp)
                if awk -F'|' -v p="$proto" -v i="$uuid" -v u="$user" \
                    '!($1==p && $2==i && $3==u)' "$xdb" > "$tmp"; then
                    mv "$tmp" "$xdb"
                    chmod 600 "$xdb" 2>/dev/null
                else
                    rm -f "$tmp"
                fi
                removed=1
                tg_send "⌛ <b>EXPIRED</b>%0AAkun ${proto} '$(tg_escape "$user")' dihapus otomatis"
            fi
        done < "$xdb"
        (( removed == 1 )) && { xray_render_config && xray_restart; }
    fi

    # 4) IP limit & multi-login per SSH user
    if [[ -f "$db" ]]; then
        while IFS='|' read -r user _pass _created _expired iplimit; do
            [[ -z "$user" ]] && continue
            id "$user" &>/dev/null || continue
            iplimit=${iplimit:-$IP_LIMIT}
            [[ "$iplimit" =~ ^[0-9]+$ ]] || iplimit=$IP_LIMIT
            # multi-login: lebih dari satu sesi untuk user yang sama
            local sessions
            sessions=$(who 2>/dev/null | awk -v u="$user" '$1==u' | wc -l)
            if (( sessions > 1 )); then
                _alert_once "multi:${user}" 30 \
                    "⚠️ <b>MULTI-LOGIN</b>%0AUser SSH '$(tg_escape "$user")' terdeteksi ${sessions} sesi bersamaan"
            fi
            # IP limit: kill semua sesi user jika IP unik melebihi batas
            local ips
            ips=$(ssh_user_ip_count "$user")
            [[ "$ips" =~ ^[0-9]+$ ]] || ips=0
            if (( ips > iplimit )); then
                pkill -u "$user" 2>/dev/null
                _alert_once "iplimit:${user}" 30 \
                    "🚫 <b>LIMIT IP</b>%0AUser SSH '$(tg_escape "$user")' diputus (${ips} IP > limit ${iplimit})"
            fi
        done < "$db"
    fi

    return 0
}

# ---------- Speedtest ----------
speedtest_run() {
    print_header
    echo -e "${CYAN}>>> SPEEDTEST SERVER${NC}"
    echo ""
    if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
        print_info "Menginstall speedtest-cli..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y speedtest-cli >/dev/null 2>&1
        fi
    fi
    if command -v speedtest &>/dev/null; then
        speedtest --accept-license --accept-gdpr 2>/dev/null
    elif command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple
    else
        print_error "speedtest tidak tersedia. Install manual: apt install speedtest-cli"
    fi
    pause_menu
}
