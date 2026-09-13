#!/bin/bash
# ============================================================
#  uninstall.sh - Remove sshwsxray autoscript completely
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
require_root

print_header
echo -e "${RED}>>> UNINSTALL SSHWSXRAY AUTOSCRIPT${NC}"
echo ""
confirm "Yakin mau menghapus semua komponen sshwsxray?"
if [[ $? -ne 0 ]]; then
    print_info "Dibatalkan."
    exit 0
fi

echo -e "\n${CYAN}==> Stop cron & services${NC}"
# cron dimatikan lebih dulu supaya tidak ada job yang jalan di tengah uninstall
rm -f /etc/cron.d/sshwsxray
pkill -f sshwsxray-cron 2>/dev/null
systemctl stop sshws sshws-tls xray 2>/dev/null
systemctl disable sshws sshws-tls 2>/dev/null
systemctl stop xray 2>/dev/null

echo -e "\n${CYAN}==> Hapus systemd unit${NC}"
rm -f /etc/systemd/system/sshws.service
rm -f /etc/systemd/system/sshws-tls.service
systemctl daemon-reload

echo -e "\n${CYAN}==> Hapus Xray${NC}"
if [[ -f /usr/local/share/xray/uninstall.sh ]]; then
    bash /usr/local/share/xray/uninstall.sh 2>/dev/null || true
else
    systemctl disable xray 2>/dev/null
    rm -f /usr/local/bin/xray /etc/systemd/system/xray.service
    rm -rf /usr/local/etc/xray /usr/local/share/xray
    systemctl daemon-reload
fi

echo -e "\n${CYAN}==> Hapus binary & cron${NC}"
rm -f /usr/local/bin/gost /usr/local/bin/netsense   # sisa versi lama
rm -f /usr/local/bin/sshwsxray /usr/local/bin/menu /usr/local/bin/sshwsxray-cron
rm -f /etc/cron.d/sshwsxray
rm -rf /usr/local/lib/sshwsxray

# hook renew certbot milik script ini ikut dibersihkan, kalau tidak akan
# mencoba me-restart service yang sudah dihapus setiap kali cert diperbarui
rm -f /etc/letsencrypt/renewal-hooks/deploy/sshwsxray.sh

echo -e "\n${CYAN}==> Hapus akun sistem buatan script${NC}"
# Akun SSH/trial adalah user Linux asli. Tanpa langkah ini, uninstall hanya
# menghapus database & config sementara akunnya tetap ada di /etc/passwd.
if [[ -f /etc/sshwsxray/ssh_users.db ]]; then
    while IFS='|' read -r _user _rest; do
        [[ -z "$_user" || "$_user" == "root" ]] && continue
        id "$_user" &>/dev/null || continue
        pkill -u "$_user" 2>/dev/null
        if userdel -r "$_user" 2>/dev/null || userdel "$_user" 2>/dev/null; then
            echo "  - akun ${_user} dihapus"
        else
            print_warning "Akun ${_user} gagal dihapus - hapus manual: userdel -r ${_user}"
        fi
        rm -f "/root/${_user}-ssh-ws.txt"
    done < /etc/sshwsxray/ssh_users.db
fi

echo -e "\n${CYAN}==> Hapus data${NC}"
rm -rf /etc/sshwsxray

echo -e "\n${CYAN}==> Restore sshd_config backup terbaru${NC}"
latest_backup=$(ls -1t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -n1)
if [[ -n "$latest_backup" ]]; then
    cp "$latest_backup" /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
fi

print_success "Uninstall selesai."
