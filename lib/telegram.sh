#!/bin/bash
# ============================================================
#  lib/telegram.sh - Telegram notification & backup helpers
# ============================================================

# Send a text message. Silent no-op if bot is not configured.
tg_send() {  # tg_send "<message>"
    load_config
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
    curl -s --max-time 10 -o /dev/null \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="$1" \
        -d parse_mode="HTML" 2>/dev/null || true
}

# Send a file as document. Silent no-op if bot is not configured.
tg_send_file() {  # tg_send_file <file> [caption]
    local file="$1" caption="${2:-}"
    load_config
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 1
    [[ -f "$file" ]] || return 1
    curl -s --max-time 120 -o /dev/null \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"${file}" \
        -F caption="${caption}" 2>/dev/null || true
}

# Full backup -> tarball -> send to Telegram
tg_backup() {
    load_config
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        print_error "Telegram belum dikonfigurasi (isi bot token & chat id di menu pengaturan)."
        return 1
    fi

    local backup_dir="/root/backup"
    local hostname ip stamp file
    mkdir -p "$backup_dir"
    hostname=$(hostname)
    ip=$(pubip)
    stamp=$(date +%Y%m%d-%H%M%S)
    file="${backup_dir}/backup-${hostname}-${stamp}.tar.gz"

    print_info "Membuat arsip backup..."
    tar -czf "$file" \
        /etc/sshwsxray \
        /etc/shadow \
        /etc/passwd \
        /etc/group \
        /etc/letsencrypt 2>/dev/null
    [[ -f "$XRAY_CONFIG" ]] && tar -rzf "$file" -C / usr/local/etc/xray/config.json 2>/dev/null

    print_info "Mengirim ke Telegram..."
    if tg_send_file "$file" "Backup ${hostname} (${ip}) ${stamp}"; then
        print_success "Backup terkirim ke Telegram: $(basename "$file")"
        tg_send "✅ <b>BACKUP</b>%0AHostname: ${hostname}%0AIP: ${ip}%0AWaktu: ${stamp}"
        return 0
    fi
    print_error "Gagal mengirim backup. Simpan manual di: $file"
    return 1
}

# Restore users from a backup tarball created by tg_backup
tg_restore() {  # tg_restore <backup.tar.gz>
    local file="$1"
    [[ -f "$file" ]] || { print_error "File tidak ditemukan: $file"; return 1; }
    print_info "Me-restore /etc/sshwsxray dari backup..."
    tar -xzf "$file" -C / 2>/dev/null || { print_error "Ekstraksi gagal"; return 1; }
    print_info "Me-restore user system dari /etc/passwd + /etc/shadow..."

    # Recreate sshwsxray SSH users (shell /bin/false) that are missing
    local db="$INSTALL_DIR/ssh_users.db"
    if [[ -f "$db" ]]; then
        while IFS='|' read -r user _pass created expired _iplimit; do
            [[ -z "$user" ]] && continue
            if ! id "$user" &>/dev/null && [[ "$user" != "root" ]]; then
                useradd -e "${expired%% *}" \
                        -s /bin/false -M "$user" 2>/dev/null
                # password is unknown (hashed per system); admin must reset via menu
                print_warning "User $user dibuat ulang TANPA password lama - silakan reset."
            fi
            chage -d "$created" "$user" 2>/dev/null
            chage -E "${expired%% *}" "$user" 2>/dev/null
        done < "$db"
    fi
    systemctl restart xray 2>/dev/null || true
    print_success "Restore selesai."
}
