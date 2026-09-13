#!/bin/bash
# ============================================================
#  lib/telegram.sh - Telegram notification & backup helpers
#
#  Semua fungsi di sini mengembalikan status SEBENARNYA (0 hanya bila
#  Telegram menerima permintaan dengan HTTP 200). Sebelumnya error ditelan
#  dengan "|| true" sehingga menu selalu melaporkan sukses.
# ============================================================

# Escape teks untuk parse_mode=HTML
tg_escape() {  # tg_escape <teks>
    local s="${1:-}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

_tg_configured() {
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

# Send a text message. Return 1 bila gagal / belum dikonfigurasi.
tg_send() {  # tg_send "<message>"
    load_config
    # diam saat belum dikonfigurasi: fungsi ini juga dipanggil dari cron tiap
    # menit, dan mencetak peringatan terus-menerus hanya membuat spam log/mail.
    _tg_configured || return 1
    # pemanggil lama memakai %0A sebagai baris baru -> ubah jadi newline asli,
    # lalu biarkan curl yang meng-encode (jadi & dan = ikut aman).
    local msg="${1:-}" code
    msg="${msg//%0A/$'\n'}"
    code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${msg}" \
        --data-urlencode "parse_mode=HTML" 2>/dev/null)
    [[ "$code" == "200" ]]
}

# Send a file as document. Return 1 bila gagal.
tg_send_file() {  # tg_send_file <file> [caption]
    local file="$1" caption="${2:-}" cap code
    load_config
    _tg_configured || return 1
    [[ -f "$file" ]] || return 1
    cap="${caption//%0A/$'\n'}"
    code=$(curl -s --max-time 120 -o /dev/null -w '%{http_code}' \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${file}" \
        -F "caption=${cap}" 2>/dev/null)
    [[ "$code" == "200" ]]
}

# Anggota arsip backup, ditulis sebagai path RELATIF terhadap root.
# /etc/shadow sengaja TIDAK diikutkan (hash password).
_backup_members() {
    printf '%s\n' etc/sshwsxray etc/passwd etc/group etc/letsencrypt
    if [[ -f "$XRAY_CONFIG" ]]; then
        printf '%s\n' usr/local/etc/xray/config.json
    fi
    return 0
}

# Isi arsip backup.
#
# SATU panggilan tar saja: `tar -r` TIDAK bisa menambahkan isi ke arsip
# terkompresi (GNU tar: "Cannot update compressed archives"), dan itulah yang
# dulu membuat config Xray tidak pernah ikut ter-backup - gagalnya senyap
# karena stderr dibuang.
_tg_archive_create() {  # _tg_archive_create <path> [root]
    local file="$1" root="${2:-/}" m rc=0
    local -a members=() present=()

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        members+=("$m")
    done < <(_backup_members)

    for m in "${members[@]}"; do
        [[ -e "${root}/${m}" ]] && present+=("$m")
    done
    (( ${#present[@]} > 0 )) || return 1

    tar -czf "$file" -C "$root" "${present[@]}" 2>/dev/null || rc=1
    (( rc == 0 )) || { rm -f "$file"; return 1; }
    chmod 600 "$file" 2>/dev/null
    return 0
}

# Full backup -> tarball -> send to Telegram
tg_backup() {
    load_config
    if ! _tg_configured; then
        print_error "Telegram belum dikonfigurasi (isi bot token & chat id di menu pengaturan)."
        return 1
    fi

    local backup_dir="/root/backup"
    local hostname ip stamp file
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir" 2>/dev/null
    hostname=$(hostname)
    ip=$(pubip)
    stamp=$(date +%Y%m%d-%H%M%S)
    file="${backup_dir}/backup-${hostname}-${stamp}.tar.gz"

    print_info "Membuat arsip backup..."
    if ! _tg_archive_create "$file" || [[ ! -s "$file" ]]; then
        print_error "Arsip backup kosong/gagal dibuat"
        rm -f "$file"
        return 1
    fi
    # pastikan data akun benar-benar ada di dalam arsip sebelum dikirim
    if ! tar -tzf "$file" 2>/dev/null | grep -q 'etc/sshwsxray'; then
        print_error "Arsip tidak memuat data akun - backup dibatalkan"
        rm -f "$file"
        return 1
    fi

    print_info "Mengirim ke Telegram..."
    if tg_send_file "$file" "Backup ${hostname} (${ip}) ${stamp}"; then
        print_success "Backup terkirim ke Telegram: $(basename "$file")"
        tg_send "✅ <b>BACKUP</b>%0AHostname: $(tg_escape "$hostname")%0AIP: ${ip}%0AWaktu: ${stamp}"
        return 0
    fi
    print_error "Gagal mengirim backup ke Telegram. Arsip tetap tersimpan di: $file"
    return 1
}

# Restore data aplikasi dari arsip backup.
# Sengaja HANYA mengekstrak /etc/sshwsxray dan config Xray - tidak pernah
# menimpa /etc/passwd, /etc/shadow, /etc/group, sehingga arsip yang tidak
# cocok tidak bisa mengunci akses root ke server.
tg_restore() {  # tg_restore <backup.tar.gz>
    local file="$1"
    [[ -f "$file" ]] || { print_error "File tidak ditemukan: $file"; return 1; }

    if ! tar -tzf "$file" >/dev/null 2>&1; then
        print_error "Arsip rusak atau bukan tar.gz yang valid"
        return 1
    fi

    # snapshot data saat ini sebelum ditimpa
    local safe="/root/backup/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p /root/backup
    chmod 700 /root/backup 2>/dev/null
    if tar -czf "$safe" -C / etc/sshwsxray 2>/dev/null; then
        print_info "Snapshot data lama: $safe"
    fi

    local members="etc/sshwsxray"
    if tar -tzf "$file" 2>/dev/null | grep -qx 'usr/local/etc/xray/config.json'; then
        members="$members usr/local/etc/xray/config.json"
    fi
    print_info "Me-restore data aplikasi dari backup..."
    if ! tar -xzf "$file" -C / $members 2>/dev/null; then
        print_error "Ekstraksi gagal"
        return 1
    fi

    load_config
    apply_config_defaults
    ensure_db_files

    # Recreate SSH users yang hilang + buka kembali yang terkunci
    local db="$INSTALL_DIR/ssh_users.db"
    if [[ -f "$db" ]]; then
        while IFS='|' read -r user _pass created expired _iplimit; do
            [[ -z "$user" || "$user" == "root" ]] && continue
            if ! id "$user" &>/dev/null; then
                useradd -s /bin/false -M "$user" 2>/dev/null || continue
                local newpass
                newpass=$(gen_passwd 10)
                echo "$user:$newpass" | chpasswd 2>/dev/null
                print_warning "User $user dibuat ulang dengan password baru: ${newpass}"
            fi
            _chage_expire "$user" "$expired"
            _sys_user_unlock "$user"
        done < "$db"
    fi

    xray_render_config && systemctl restart xray 2>/dev/null || true
    print_success "Restore selesai."
}
