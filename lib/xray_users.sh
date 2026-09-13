#!/bin/bash
# ============================================================
#  lib/xray_users.sh - VMess / VLESS / Trojan account CRUD
#  DB format (separator |): proto|uuid|user|created|expired|iplimit
# ============================================================

_xray_gen_uuid() { gen_uuid; }

_xray_record_exists() {  # _xray_record_exists <proto> <user>
    awk -F'|' -v p="$1" -v u="$2" '$1==p && $3==u {found=1} END{exit !found}' "$XRAY_DB" 2>/dev/null
}

_xray_get_field() {  # _xray_get_field <proto> <user> <field_number>
    awk -F'|' -v p="$1" -v u="$2" '$1==p && $3==u {print $'"$3"'; exit}' "$XRAY_DB" 2>/dev/null
}

_xray_update_field() {  # _xray_update_field <proto> <user> <field_number> <new_value>
    local proto="$1" user="$2" field="$3" value="$4"
    awk -F'|' -v p="$proto" -v u="$user" -v f="$field" -v v="$value" \
        'BEGIN{OFS="|"} $1==p && $3==u {$f=v} {print}' \
        "$XRAY_DB" > "${XRAY_DB}.tmp" && mv "${XRAY_DB}.tmp" "$XRAY_DB"
}

_xray_delete_record() {  # _xray_delete_record <proto> <user>
    awk -F'|' -v p="$1" -v u="$2" '$1==p && $3==u {next} {print}' \
        "$XRAY_DB" > "${XRAY_DB}.tmp" && mv "${XRAY_DB}.tmp" "$XRAY_DB"
}

# ---------- Create account ----------
xray_user_create() {
    print_header
    echo -e "${CYAN}>>> BUAT AKUN XRAY${NC}"
    echo ""
    echo -e " 1) VMess"
    echo -e " 2) VLESS"
    echo -e " 3) Trojan"
    read -rp "Pilih protokol [1-3]: " choice
    local proto
    case "$choice" in
        1) proto="vmess" ;;
        2) proto="vless" ;;
        3) proto="trojan" ;;
        *) print_error "Pilihan tidak valid"; pause_menu; return 1 ;;
    esac

    read -rp "Username: " user
    if ! [[ "$user" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        print_error "Username 3-32 karakter alfanumerik/-/_"
        pause_menu; return 1
    fi
    _xray_record_exists "$proto" "$user" && { print_error "User ${proto} '$user' sudah ada"; pause_menu; return 1; }

    read -rp "Masa aktif (hari) [30]: " days
    [[ -z "$days" ]] && days=30
    read -rp "Batas IP [${IP_LIMIT}]: " iplimit
    [[ -z "$iplimit" ]] && iplimit=$IP_LIMIT

    local uuid
    uuid=$(_xray_gen_uuid) || { pause_menu; return 1; }
    local expire
    expire=$(add_days "$days")

    db_add "$XRAY_DB" "${proto}|${uuid}|${user}|$(date +%F)|${expire}|${iplimit}"
    xray_render_config && xray_safe_restart

    echo ""
    print_success "Akun ${proto} '${user}' dibuat (expired ${expire}, limit ${iplimit} IP)"
    xray_user_show "$proto" "$user"
    tg_send "✅ <b>AKUN ${proto^^} BARU</b>%0AUser: ${user}%0AExpired: ${expire}"
    pause_menu
}

# ---------- Trial ----------
xray_user_trial() {
    print_header
    echo -e "${CYAN}>>> AKUN TRIAL XRAY (${TRIAL_HOURS} JAM)${NC}"
    echo ""
    echo -e " 1) VMess  2) VLESS  3) Trojan"
    read -rp "Pilih protokol [1-3]: " choice
    local proto
    case "$choice" in
        1) proto="vmess" ;;
        2) proto="vless" ;;
        3) proto="trojan" ;;
        *) print_error "Pilihan tidak valid"; pause_menu; return 1 ;;
    esac
    local user="tr-${proto}-$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)"
    local expire
    expire=$(add_hours "$TRIAL_HOURS")
    local uuid
    uuid=$(_xray_gen_uuid) || { pause_menu; return 1; }

    db_add "$XRAY_DB" "${proto}|${uuid}|${user}|$(date +%F)|${expire}|1"
    xray_render_config && xray_safe_restart
    print_success "Trial ${proto} '${user}' dibuat (${TRIAL_HOURS} jam, 1 IP)"
    xray_user_show "$proto" "$user"
    tg_send "🧪 <b>TRIAL ${proto^^}</b>%0AUser: ${user}%0AExpired: ${expire}"
    pause_menu
}

# ---------- Renew ----------
xray_user_renew() {
    print_header
    echo -e "${CYAN}>>> RENEW AKUN XRAY${NC}"
    echo ""
    xray_user_list brief
    read -rp "Protokol (vmess/vless/trojan): " proto
    read -rp "Username: " user
    if ! _xray_record_exists "$proto" "$user"; then
        print_error "Akun tidak ditemukan"; pause_menu; return 1
    fi
    read -rp "Tambah masa aktif (hari) [30]: " days
    [[ -z "$days" ]] && days=30
    local current expire
    current=$(_xray_get_field "$proto" "$user" 5)
    if [[ -n "$current" ]] && is_expired "$current"; then
        expire=$(add_days "$days")
    else
        expire=$(date -d "${current:-$(date +%F)} +$days days" +"%Y-%m-%d %H:%M")
    fi
    _xray_update_field "$proto" "$user" 5 "$expire"
    print_success "Akun ${proto} '${user}' diperpanjang sampai ${expire}"
    tg_send "🔄 <b>RENEW ${proto^^}</b>%0AUser: ${user}%0AExpired baru: ${expire}"
    pause_menu
}

# ---------- Delete ----------
xray_user_delete() {
    print_header
    echo -e "${CYAN}>>> HAPUS AKUN XRAY${NC}"
    echo ""
    xray_user_list brief
    read -rp "Protokol (vmess/vless/trojan): " proto
    read -rp "Username: " user
    if ! _xray_record_exists "$proto" "$user"; then
        print_error "Akun tidak ditemukan"; pause_menu; return 1
    fi
    confirm "Yakin hapus akun ${proto} '${user}'?" || { pause_menu; return 0; }
    _xray_delete_record "$proto" "$user"
    sed -i "/^[^|]*|${user}|/d" "$TRIAL_DB" 2>/dev/null
    xray_render_config && xray_safe_restart
    print_success "Akun ${proto} '${user}' dihapus"
    tg_send "🗑 <b>AKUN ${proto^^} DIHAPUS</b>%0AUser: ${user}"
    pause_menu
}

# ---------- List ----------
xray_user_list() {  # xray_user_list [brief|full]
    local mode="${1:-full}"
    if [[ ! -s "$XRAY_DB" ]]; then
        echo -e "${YELLOW}Belum ada akun xray.${NC}"
        return 0
    fi
    if [[ "$mode" == "brief" ]]; then
        awk -F'|' '{printf "  %-7s %-16s expired: %s\n", $1, $3, $5}' "$XRAY_DB"
        return 0
    fi
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    printf "${WHITE} %-7s %-16s %-20s %-5s %-10s${NC}\n" "PROTO" "USERNAME" "EXPIRED" "IPLIM" "TRAFFIC"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    while IFS='|' read -r proto uuid user _created expired iplimit; do
        [[ -z "$proto" ]] && continue
        local status traffic
        if is_expired "$expired"; then
            status="${RED}EXPIRED${NC}"
        else
            status="${GREEN}ACTIVE${NC}"
        fi
        traffic=$(xray_user_traffic "$uuid" 2>/dev/null || echo 0)
        printf " %-7s %-16b %-20s %-5s %-10s\n" "$proto" "$status" "$expired" "${iplimit:-1}" "$(fmt_bytes "$traffic")"
    done < "$XRAY_DB"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

xray_user_list_menu() {
    print_header
    echo -e "${CYAN}>>> DAFTAR AKUN XRAY${NC}"
    echo ""
    xray_user_list full
    pause_menu
}

# ---------- Show account details / links ----------
xray_user_show() {  # xray_user_show <proto> <user>
    local proto="$1" user="$2"
    local rec
    rec=$(awk -F'|' -v p="$proto" -v u="$user" '$1==p && $3==u {print; exit}' "$XRAY_DB" 2>/dev/null)
    [[ -z "$rec" ]] && { print_error "Akun tidak ditemukan"; return 1; }
    local uuid expired iplimit
    uuid=$(_xray_get_field "$proto" "$user" 2)
    expired=$(_xray_get_field "$proto" "$user" 5)
    iplimit=$(_xray_get_field "$proto" "$user" 6)

    local domain
    domain=$(get_domain)
    local host="${domain:-$(pubip)}"
    local path="${WS_PATH}"
    local sn
    sn=$(echo "$REALITY_SERVER_NAMES" | awk '{print $1}')

    echo -e "${CYAN}----------------------------------------------${NC}"
    echo -e " ${BOLD}AKUN ${proto^^}: ${user}${NC}"
    echo -e " UUID/Pass : ${uuid}"
    echo -e " Expired   : ${expired}"
    echo -e " Limit IP  : ${iplimit}"
    echo -e "${CYAN}----------------------------------------------${NC}"

    if [[ "$proto" == "vmess" ]]; then
        # vmess:// base64(JSON)
        local json b64
        json=$(python3 -c "
import json
print(json.dumps({'v':'2','ps':'${user}-ws','add':'${host}','port':'${XRAY_VMESS_WS_PORT}','id':'${uuid}','aid':'0','scy':'auto','net':'ws','type':'none','host':'${host}','path':'/${path}','tls':''}, separators=(',',':')))
")
        b64=$(echo -n "$json" | base64 -w0)
        echo -e " VMess WS   : vmess://${b64}"
        json=$(python3 -c "
import json
print(json.dumps({'v':'2','ps':'${user}-grpc','add':'${host}','port':'${XRAY_VMESS_GRPC_PORT}','id':'${uuid}','aid':'0','scy':'auto','net':'grpc','type':'none','host':'${host}','path':'${path}-grpc','tls':''}, separators=(',',':')))
")
        b64=$(echo -n "$json" | base64 -w0)
        echo -e " VMess gRPC : vmess://${b64}"
    elif [[ "$proto" == "vless" ]]; then
        echo -e " VLESS WS    : vless://${uuid}@${host}:${XRAY_VLESS_WS_PORT}?path=%2F${path}&security=none&encryption=none&type=ws#${user}-ws"
        echo -e " VLESS gRPC  : vless://${uuid}@${host}:${XRAY_VLESS_GRPC_PORT}?serviceName=${path}-grpc&security=none&encryption=none&type=grpc#${user}-grpc"
        echo -e " VLESS REAL  : vless://${uuid}@${host}:${XRAY_VLESS_REALITY_PORT}?security=reality&encryption=none&pbk=${REALITY_PUBLIC_KEY:-}&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${sn}&sid=${REALITY_SHORT_ID:-}#${user}-reality"
    elif [[ "$proto" == "trojan" ]]; then
        echo -e " Trojan WS   : trojan://${uuid}@${host}:${XRAY_TROJAN_WS_PORT}?path=%2F${path}&security=tls&sni=${host}&type=ws#${user}-ws"
        echo -e " Trojan gRPC : trojan://${uuid}@${host}:${XRAY_TROJAN_GRPC_PORT}?serviceName=${path}-grpc&security=tls&sni=${host}&type=grpc#${user}-grpc"
    fi
    echo -e "${CYAN}----------------------------------------------${NC}"
    return 0
}

xray_user_show_menu() {
    print_header
    echo -e "${CYAN}>>> DETAIL AKUN XRAY${NC}"
    echo ""
    xray_user_list brief
    echo ""
    read -rp "Protokol (vmess/vless/trojan): " proto
    read -rp "Username: " user
    echo ""
    xray_user_show "$proto" "$user"
    pause_menu
}

# ---------- Traffic per user ----------
xray_user_traffic_menu() {
    print_header
    echo -e "${CYAN}>>> TRAFFIC AKUN XRAY (sejak snapshot terakhir)${NC}"
    echo ""
    print_info "Mengambil statistik dari Xray API..."
    xray_traffic_update
    xray_user_list full
    pause_menu
}
