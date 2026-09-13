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

echo -e "\n${CYAN}==> Stop & disable services${NC}"
systemctl stop gost-websocket gost-websocket-tls xray 2>/dev/null
systemctl disable gost-websocket gost-websocket-tls 2>/dev/null
systemctl stop xray 2>/dev/null

echo -e "\n${CYAN}==> Hapus systemd unit${NC}"
rm -f /etc/systemd/system/gost-websocket.service
rm -f /etc/systemd/system/gost-websocket-tls.service
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
rm -f /usr/local/bin/gost /usr/local/bin/netsense
rm -f /usr/local/bin/sshwsxray /usr/local/bin/sshwsxray-cron
rm -f /etc/cron.d/sshwsxray
rm -rf /usr/local/lib/sshwsxray

echo -e "\n${CYAN}==> Hapus data${NC}"
rm -rf /etc/sshwsxray

echo -e "\n${CYAN}==> Restore sshd_config backup terbaru${NC}"
latest_backup=$(ls -1t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -n1)
if [[ -n "$latest_backup" ]]; then
    cp "$latest_backup" /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
fi

print_success "Uninstall selesai."
