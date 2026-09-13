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
    for svc in ssh gost-websocket gost-websocket-tls xray cron; do
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
    local ports="$GOST_PORT $GOST_TLS_PORT $XRAY_VMESS_WS_PORT $XRAY_VLESS_WS_PORT $XRAY_TROJAN_WS_PORT $XRAY_VLESS_REALITY_PORT"
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

# ---------- netsense IP limit ----------
netsense_add_user() {  # <user> <iplimit>
    local user="$1" iplimit="$2"
    command -v netsense &>/dev/null || return 1
    netsense add "${user}" --limit "${iplimit}" 2>/dev/null
}

netsense_del_user() {  # <user>
    command -v netsense &>/dev/null || return 1
    netsense del "$1" 2>/dev/null
}

netsense_count_ips() {  # <user> -> jumlah IP unik yang sedang dipakai
    local user="$1"
    who 2>/dev/null | awk -v u="$user" '$1==u {print $NF}' | tr -d '()' | grep -E '^[0-9a-fA-F:.]+$' | sort -u | wc -l
}

# ---------- Enforcement: expire + IP limit + multi-login ----------
# Designed to run from cron every minute.
monitor_enforce() {
    load_config

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
        local removed=0
        while IFS='|' read -r proto uuid user _created expired _iplimit; do
            [[ -z "$proto" ]] && continue
            if is_expired "$expired"; then
                awk -F'|' -v p="$proto" -v i="$uuid" -v u="$user" \
                    '$1==p && $2==i && $3==u {next} {print}' "$xdb" > "${xdb}.tmp" \
                    && mv "${xdb}.tmp" "$xdb"
                removed=1
                tg_send "⌛ <b>EXPIRED</b>%0AAkun ${proto} '${user}' dihapus otomatis"
            fi
        done < "$xdb"
        (( removed == 1 )) && { xray_render_config; xray_restart; }
    fi

    # 4) IP limit & multi-login per SSH user
    if [[ -f "$db" ]]; then
        while IFS='|' read -r user _pass _created _expired iplimit; do
            [[ -z "$user" ]] && continue
            id "$user" &>/dev/null || continue
            iplimit=${iplimit:-$IP_LIMIT}
            # multi-login: lebih dari satu sesi untuk user yang sama
            local sessions
            sessions=$(who | awk -v u="$user" '$1==u' | wc -l)
            if (( sessions > 1 )); then
                tg_send "⚠️ <b>MULTI-LOGIN</b>%0AUser SSH '${user}' terdeteksi ${sessions} sesi bersamaan"
            fi
            # IP limit: kill semua sesi user jika IP unik melebihi batas
            local ips
            ips=$(netsense_count_ips "$user")
            if (( ips > iplimit )); then
                pkill -u "$user" 2>/dev/null
                tg_send "🚫 <b>LIMIT IP</b>%0AUser SSH '${user}' diputus (${ips} IP > limit ${iplimit})"
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
