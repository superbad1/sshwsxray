#!/bin/bash
# ============================================================
#  lib/backup.sh - Backup & restore lokal (dengan rotasi)
#
#  Arsip TIDAK memuat /etc/shadow (hash password). Pembuatan arsip memakai
#  _tg_archive_create() dari lib/telegram.sh supaya isinya konsisten dengan
#  backup yang dikirim ke Telegram.
# ============================================================

BACKUP_DIR="/root/backup"
KEEP_LAST=5

_make_archive() {  # -> prints archive path
    local hostname stamp file
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null
    hostname=$(hostname)
    stamp=$(date +%Y%m%d-%H%M%S)
    file="${BACKUP_DIR}/backup-${hostname}-${stamp}.tar.gz"
    if declare -F _tg_archive_create >/dev/null 2>&1; then
        _tg_archive_create "$file"
    else
        tar -czf "$file" /etc/sshwsxray 2>/dev/null
        [[ -f "$XRAY_CONFIG" ]] && tar -rzf "$file" -C / usr/local/etc/xray/config.json 2>/dev/null
        chmod 600 "$file" 2>/dev/null
    fi
    [[ -s "$file" ]] || return 1
    echo "$file"
}

_rotate_backups() {
    # keep newest KEEP_LAST archives
    ls -1t "${BACKUP_DIR}"/backup-*.tar.gz 2>/dev/null | tail -n +$(( KEEP_LAST + 1 )) | xargs -r rm -f
}

backup_menu() {
    print_header
    echo -e "${CYAN}>>> BACKUP SERVER${NC}"
    echo ""
    local file
    file=$(_make_archive) || { print_error "Backup gagal"; pause_menu; return 1; }
    print_success "Backup dibuat: $file ($(du -h "$file" | awk '{print $1}'))"
    _rotate_backups
    load_config
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        if confirm "Kirim juga ke Telegram?"; then
            tg_backup
        fi
    fi
    pause_menu
}

backup_list_menu() {
    print_header
    echo -e "${CYAN}>>> DAFTAR BACKUP (${BACKUP_DIR})${NC}"
    echo ""
    if ls -1 "${BACKUP_DIR}"/backup-*.tar.gz &>/dev/null; then
        ls -lh "${BACKUP_DIR}"/backup-*.tar.gz | awk '{printf " %-10s %s\n", $5, $9}'
    else
        echo -e "${YELLOW}Belum ada backup.${NC}"
    fi
    pause_menu
}

backup_restore_menu() {
    print_header
    echo -e "${CYAN}>>> RESTORE BACKUP${NC}"
    echo ""
    if ! ls -1 "${BACKUP_DIR}"/backup-*.tar.gz &>/dev/null; then
        echo -e "${YELLOW}Belum ada backup di ${BACKUP_DIR}.${NC}"
        pause_menu; return 1
    fi
    ls -1t "${BACKUP_DIR}"/backup-*.tar.gz | nl -w2 -s') '
    echo ""
    read -rp "Nomor backup yang di-restore [0=batal]: " num
    if ! is_int "$num" || [[ "$num" == "0" ]]; then
        print_info "Dibatalkan"; pause_menu; return 0
    fi
    local file
    file=$(ls -1t "${BACKUP_DIR}"/backup-*.tar.gz | sed -n "${num}p")
    if [[ -z "$file" ]]; then
        print_error "Nomor tidak ada dalam daftar"
        pause_menu; return 1
    fi
    if confirm "Restore dari $(basename "$file")? Data akun saat ini akan ditimpa (snapshot otomatis dibuat)."; then
        tg_restore "$file"
    fi
    pause_menu
}
