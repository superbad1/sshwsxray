#!/bin/bash
# ============================================================
#  lib/expire.sh - Cek masa aktif akun SSH & Xray
# ============================================================

expire_check_menu() {
    print_header
    echo -e "${CYAN}>>> CEK MASA AKTIF AKUN${NC}"
    echo ""
    echo -e "${CYAN}--- Akun SSH ---${NC}"
    if [[ -s "$SSH_DB" ]]; then
        while IFS='|' read -r user _pass created expired _iplimit; do
            [[ -z "$user" ]] && continue
            local left
            left=$(days_left "$expired")
            if (( left < 0 )); then
                printf "  %-16s ${RED}EXPIRED (%d hari lalu)${NC}\n" "$user" "$(( -left ))"
            else
                printf "  %-16s ${GREEN}%-3d hari tersisa${NC}\n" "$user" "$left"
            fi
        done < "$SSH_DB"
    else
        echo -e " ${YELLOW}(tidak ada)${NC}"
    fi
    echo ""
    echo -e "${CYAN}--- Akun Xray ---${NC}"
    if [[ -s "$XRAY_DB" ]]; then
        while IFS='|' read -r proto uuid user created expired _iplimit; do
            [[ -z "$proto" ]] && continue
            local left
            left=$(days_left "$expired")
            if (( left < 0 )); then
                printf "  %-7s %-16s ${RED}EXPIRED (%d hari lalu)${NC}\n" "$proto" "$user" "$(( -left ))"
            else
                printf "  %-7s %-16s ${GREEN}%-3d hari tersisa${NC}\n" "$proto" "$user" "$left"
            fi
        done < "$XRAY_DB"
    else
        echo -e " ${YELLOW}(tidak ada)${NC}"
    fi
    echo ""
    if confirm "Kirim ringkasan ke Telegram?"; then
        local msg="📅 <b>LAPORAN MASA AKTIF</b>"
        while IFS='|' read -r user _pass _created expired _iplimit; do
            [[ -z "$user" ]] && continue
            msg+="%0ASSH $(tg_escape "$user"): $(days_left "$expired") hari"
        done < "$SSH_DB" 2>/dev/null
        while IFS='|' read -r proto uuid user _created expired _iplimit; do
            [[ -z "$proto" ]] && continue
            msg+="%0A${proto} $(tg_escape "$user"): $(days_left "$expired") hari"
        done < "$XRAY_DB" 2>/dev/null
        tg_send "$msg"
        print_success "Ringkasan terkirim"
    fi
    pause_menu
}
