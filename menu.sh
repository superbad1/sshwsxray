#!/bin/bash
# ============================================================
#  menu.sh - SSH Websocket + Xray Manager main menu
#  Usage: sshwsxray  (symlink installed by setup.sh)
# ============================================================

# Resolve symlinks so `sshwsxray` works from /usr/local/bin
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
require_root
load_config
apply_config_defaults

for lib in telegram ssh xray xray_users monitor backup expire; do
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/${lib}.sh"
done

# ============================================================
# Submenus
# ============================================================

menu_ssh() {
    while true; do
        print_header
        echo -e "${CYAN}>>> MENU SSH / SSH WEBSOCKET${NC}"
        echo ""
        echo -e "  1) Buat akun SSH"
        echo -e "  2) Akun trial"
        echo -e "  3) Renew akun"
        echo -e "  4) Hapus akun"
        echo -e "  5) Daftar akun"
        echo -e "  6) Ganti password"
        echo -e "  7) User online / multi-login"
        echo -e "  x) Kembali"
        echo ""
        read -rp "Pilih menu: " choice
        case "$choice" in
            1) ssh_create ;;
            2) ssh_trial ;;
            3) ssh_renew ;;
            4) ssh_delete ;;
            5) ssh_list ;;
            6) ssh_chpass ;;
            7) ssh_online ;;
            x|X) return 0 ;;
            *) print_warning "Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

menu_xray() {
    while true; do
        print_header
        echo -e "${CYAN}>>> MENU XRAY (VMESS / VLESS / TROJAN)${NC}"
        echo ""
        echo -e "  1) Buat akun"
        echo -e "  2) Akun trial"
        echo -e "  3) Renew akun"
        echo -e "  4) Hapus akun"
        echo -e "  5) Daftar akun + traffic"
        echo -e "  6) Detail & link akun"
        echo -e "  7) Status service xray"
        echo -e "  8) Restart xray"
        echo -e "  9) Rebuild config + restart"
        echo -e "  x) Kembali"
        echo ""
        read -rp "Pilih menu: " choice
        case "$choice" in
            1) xray_user_create ;;
            2) xray_user_trial ;;
            3) xray_user_renew ;;
            4) xray_user_delete ;;
            5) xray_user_traffic_menu ;;
            6) xray_user_show_menu ;;
            7) xray_show_status ;;
            8) xray_restart_menu ;;
            9) xray_rebuild_menu ;;
            x|X) return 0 ;;
            *) print_warning "Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

menu_monitor() {
    while true; do
        print_header
        echo -e "${CYAN}>>> MENU MONITORING${NC}"
        echo ""
        echo -e "  1) Info sistem"
        echo -e "  2) User online"
        echo -e "  3) Cek masa aktif akun"
        echo -e "  4) Speedtest"
        echo -e "  x) Kembali"
        echo ""
        read -rp "Pilih menu: " choice
        case "$choice" in
            1) sysinfo ;;
            2) monitor_online ;;
            3) expire_check_menu ;;
            4) speedtest_run ;;
            x|X) return 0 ;;
            *) print_warning "Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

menu_backup() {
    while true; do
        print_header
        echo -e "${CYAN}>>> MENU BACKUP & RESTORE${NC}"
        echo ""
        echo -e "  1) Backup sekarang"
        echo -e "  2) Daftar backup"
        echo -e "  3) Restore dari file backup"
        echo -e "  x) Kembali"
        echo ""
        read -rp "Pilih menu: " choice
        case "$choice" in
            1) backup_menu ;;
            2) backup_list_menu ;;
            3) backup_restore_menu ;;
            x|X) return 0 ;;
            *) print_warning "Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

menu_settings() {
    while true; do
        print_header
        echo -e "${CYAN}>>> MENU PENGATURAN${NC}"
        echo ""
        load_config
        echo -e "  Domain           : ${DOMAIN:-belum diset}"
        echo -e "  Path SSH-WS      : / (standar, tanpa path)"
        echo -e "  Path Xray WS     : /${WS_PATH}"
        echo -e "  Transport Xray   : WebSocket (ws) saja"
        echo -e "  Batas IP default : ${IP_LIMIT}"
        echo -e "  Trial (jam)      : ${TRIAL_HOURS}"
        echo -e "  Auto reboot      : ${AUTO_REBOOT} (1=aktif 05:00)"
        echo -e "  Telegram         : $([[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && echo terkonfigurasi || echo belum)"
        echo ""
        echo -e "  1) Set domain"
        echo -e "  2) Set path WebSocket (Xray)"
        echo -e "  3) Set batas IP default"
        echo -e "  4) Set durasi trial (jam)"
        echo -e "  5) Toggle auto reboot"
        echo -e "  6) Konfigurasi Telegram bot"
        echo -e "  7) Test notifikasi Telegram"
        echo -e "  8) Install / perbarui sertifikat SSL"
        echo -e "  x) Kembali"
        echo ""
        read -rp "Pilih menu: " choice
        case "$choice" in
            1)
                read -rp "Domain: " d
                if [[ "$d" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    save_config DOMAIN "$d"
                    echo "$d" > "$INSTALL_DIR/domain"
                    print_success "Domain diset: $d"
                else
                    print_error "Format domain tidak valid"
                fi
                pause_menu ;;
            2)
                read -rp "Path Xray WS (tanpa slash depan): " p
                p="${p#/}"
                [[ -n "$p" ]] && { save_config WS_PATH "$p"; print_success "Path Xray WS: /$p"; }
                xray_render_config && xray_safe_restart
                pause_menu ;;
            3)
                read -rp "Batas IP: " n
                [[ "$n" =~ ^[0-9]+$ ]] && { save_config IP_LIMIT "$n"; print_success "Limit IP: $n"; }
                pause_menu ;;
            4)
                read -rp "Durasi trial (jam): " h
                [[ "$h" =~ ^[0-9]+$ ]] && { save_config TRIAL_HOURS "$h"; print_success "Trial: ${h} jam"; }
                pause_menu ;;
            5)
                load_config
                if [[ "${AUTO_REBOOT:-0}" == "1" ]]; then save_config AUTO_REBOOT 0; else save_config AUTO_REBOOT 1; fi
                print_success "Auto reboot toggled"
                pause_menu ;;
            6)
                read -rp "Telegram bot token: " tok
                read -rp "Telegram chat id: " chat
                save_config TELEGRAM_BOT_TOKEN "$tok"
                save_config TELEGRAM_CHAT_ID "$chat"
                print_success "Telegram disimpan"
                pause_menu ;;
            7)
                if tg_send "🔔 Test notifikasi dari $(hostname)"; then
                    print_success "Pesan test terkirim (cek Telegram kamu)"
                else
                    print_error "Gagal - periksa token/chat id"
                fi
                pause_menu ;;
            8)
                "$SCRIPT_DIR/setup.sh" --ssl-only
                pause_menu ;;
            x|X) return 0 ;;
            *) print_warning "Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

# ============================================================
# Main menu
# ============================================================
while true; do
    print_header
    echo ""
    echo -e "  ${CYAN}--- MANAJEMEN AKUN ---${NC}"
    echo -e "  1) SSH / SSH Websocket"
    echo -e "  2) Xray (VMess/VLESS/Trojan)"
    echo -e "  ${CYAN}--- SISTEM ---${NC}"
    echo -e "  3) Monitoring"
    echo -e "  4) Backup & Restore"
    echo -e "  5) Pengaturan"
    echo -e "  6) Info sistem"
    echo -e "  x) Keluar"
    echo ""
    read -rp "Pilih menu: " choice
    case "$choice" in
        1) menu_ssh ;;
        2) menu_xray ;;
        3) menu_monitor ;;
        4) menu_backup ;;
        5) menu_settings ;;
        6) sysinfo ;;
        x|X) clear; exit 0 ;;
        *) print_warning "Pilihan tidak valid"; sleep 1 ;;
    esac
done
