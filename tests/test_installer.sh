#!/bin/bash
# ============================================================
#  tests/test_installer.sh - Regression test fungsi installer
#
#  install.sh hanya menjalankan main() bila dieksekusi langsung, sehingga
#  fungsi di dalamnya bisa diuji di sandbox tanpa menyentuh sistem.
# ============================================================
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SSHWSXRAY_INSTALL_DIR="$SANDBOX/etc"
export SSHWSXRAY_APP_DIR="$SANDBOX/app"
export SCRIPT_DIR="$PROJECT_ROOT"
# WAJIB di-set SEBELUM lib/bridge.sh di-source: SYSTEMD_DIR dibaca saat source,
# dan tanpa override test ini akan menulis unit ke /etc/systemd/system asli.
export SSHWSXRAY_SYSTEMD_DIR="$SANDBOX/systemd"
mkdir -p "$SSHWSXRAY_SYSTEMD_DIR" "$SANDBOX/stub"
printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/stub/systemctl"
chmod +x "$SANDBOX/stub/systemctl"
export PATH="$SANDBOX/stub:$PATH"

# lib/common.sh di-source terpisah dari install.sh: install.sh memuatnya saat
# instalasi benar-benar dijalankan, bukan saat di-source oleh test.
# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=../lib/bridge.sh
source "$PROJECT_ROOT/lib/bridge.sh"
# shellcheck source=../install.sh
source "$PROJECT_ROOT/install.sh"

failures=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1 (got='$2' want='$3')"
        failures=$((failures + 1))
    fi
}

# ---------- K1: init_data tidak boleh menghapus database ----------
echo "budi|-|2026-09-13|2026-10-13|2" > /dev/null   # noop, hindari shellcheck
mkdir -p "$INSTALL_DIR"
echo "budi|-|2026-09-13|2026-10-13|2" > "$INSTALL_DIR/ssh_users.db"
echo "vmess|uuid-1|ani|2026-09-13|2026-10-13|0" > "$INSTALL_DIR/xray_users.db"

init_data
check "init_data: ssh_users.db tidak dikosongkan" "$(wc -l < "$INSTALL_DIR/ssh_users.db")" "1"
check "init_data: xray_users.db tidak dikosongkan" "$(wc -l < "$INSTALL_DIR/xray_users.db")" "1"
check "init_data: xray_traffic.db dibuat" "$([[ -f "$INSTALL_DIR/xray_traffic.db" ]] && echo ada)" "ada"
check "init_data: trial_users.db dibuat" "$([[ -f "$INSTALL_DIR/trial_users.db" ]] && echo ada)" "ada"
check "init_data: izin DB 600" "$(stat -c %a "$INSTALL_DIR/ssh_users.db")" "600"
check "init_data: izin direktori 700" "$(stat -c %a "$INSTALL_DIR")" "700"

# idempotent: dijalankan dua kali tetap aman
init_data
check "init_data idempotent" "$(wc -l < "$INSTALL_DIR/ssh_users.db")" "1"

# ---------- T1: install_app_files menyalin install.sh (dipakai menu SSL) ----------
install_app_files
for f in install.sh uninstall.sh menu.sh; do
    check "install_app_files: $f tersedia" "$([[ -f "$APP_DIR/$f" ]] && echo ada)" "ada"
done
for f in common.sh ssh.sh xray.sh xray_users.sh monitor.sh backup.sh expire.sh telegram.sh bridge.sh; do
    check "install_app_files: lib/$f" "$([[ -f "$APP_DIR/lib/$f" ]] && echo ada)" "ada"
done
for f in sshws.py xray_proto.py xray_render.py; do
    check "install_app_files: lib/$f" "$([[ -f "$APP_DIR/lib/$f" ]] && echo ada)" "ada"
done
check "install_app_files: install.sh executable" "$([[ -x "$APP_DIR/install.sh" ]] && echo yes)" "yes"

# ---------- T1b: unit systemd memakai path APP_DIR yang benar ----------
check "bridge_write_units terdefinisi (lib/bridge.sh)" "$(declare -F bridge_write_units >/dev/null && echo ya)" "ya"
check "configure_firewall terdefinisi" "$(declare -F configure_firewall >/dev/null && echo ya)" "ya"
check "check_port_free terdefinisi" "$(declare -F check_port_free >/dev/null && echo ya)" "ya"

# ---------- K2: tidak boleh ada download script pihak ketiga ----------
if grep -q "netsense" "$PROJECT_ROOT/install.sh"; then
    echo "FAIL  install.sh masih menyebut netsense"
    failures=$((failures + 1))
else
    echo "PASS  install.sh bersih dari netsense"
fi
# hanya komentar (penjelasan kenapa netsense dibuang) yang boleh menyebut nama
if grep -rn "netsense" "$PROJECT_ROOT/lib/" | grep -v ':[[:space:]]*#' | grep -q .; then
    echo "FAIL  lib/ masih memakai netsense sebagai perintah"
    failures=$((failures + 1))
else
    echo "PASS  lib/ tidak lagi memakai netsense"
fi

# ---------- K1b: sumber data tidak boleh di-truncate di install.sh ----------
if grep -qE '^[[:space:]]*: > "\$INSTALL_DIR/' "$PROJECT_ROOT/install.sh"; then
    echo "FAIL  install.sh masih memakai ': >' pada file database"
    failures=$((failures + 1))
else
    echo "PASS  install.sh tidak menimpa file database"
fi

# ---------- setup.sh sudah tidak ada lagi (install.sh yang melakukan semua) ----------
check "setup.sh sudah tidak ada di repo" \
    "$([[ -f "$PROJECT_ROOT/setup.sh" ]] && echo masih-ada || echo terhapus)" "terhapus"
check "install.sh memuat logika installer (install_all)" \
    "$(declare -F install_all >/dev/null && echo ada || echo tidak)" "ada"
check "install.sh memuat bootstrap (download_app_files)" \
    "$(declare -F download_app_files >/dev/null && echo ada || echo tidak)" "ada"
check "install.sh memuat mode SSL saja (ssl_only)" \
    "$(declare -F ssl_only >/dev/null && echo ada || echo tidak)" "ada"
check "menu memanggil install.sh untuk SSL" \
    "$(grep -c 'SSL_ONLY=1 "\$SCRIPT_DIR/install.sh"' "$PROJECT_ROOT/menu.sh")" "1"

# ---------- K3: ask() harus tahan EOF (regression 'read' + set -e) ----------
# Sebuah 'read' telanjang di bawah 'set -e' menghentikan SELURUH instalasi
# tanpa pesan saat stdin habis (mis. dijalankan Ansible/cloud-init tanpa
# terminal). Installer sekarang memakai helper ask().
printf -v ask_script 'set -euo pipefail; source "%s/install.sh"; ask "Domain: " X </dev/null; echo "LANJUT-${X:-BELUM}"\n' "$PROJECT_ROOT"
ask_out=$(bash -c "$ask_script" 2>/dev/null)
check "ask(): EOF tidak mematikan instalasi" "$ask_out" "LANJUT-BELUM"
printf -v ask_script2 'set -euo pipefail; source "%s/install.sh"; ask "Domain: " X; echo "GOT-$X"\n' "$PROJECT_ROOT"
ask_out2=$(printf 'contoh.com\n' | bash -c "$ask_script2" 2>/dev/null)
check "ask(): jawaban terbaca" "$ask_out2" "GOT-contoh.com"
check "install.sh bebas 'read' telanjang" \
    "$(grep -cE '^[[:space:]]*read([[:space:]]|$)' "$PROJECT_ROOT/install.sh")" "0"

# ---------- K4: hanya paket yang benar-benar dipakai ----------
# ss (iproute2) & pkill/ps (procps) dipakai limit IP + monitoring tapi dulu
# tidak pernah diminta; jq dipasang tapi tidak dipakai sama sekali.
PKG_SRC=$(sed -n '/^install_packages()/,/^}/p' "$PROJECT_ROOT/install.sh")
check "install_packages memasang iproute2 (ss)" \
    "$(printf '%s\n' "$PKG_SRC" | grep -q 'iproute2' && echo ya || echo tidak)" "ya"
check "install_packages memasang procps (pkill/ps)" \
    "$(printf '%s\n' "$PKG_SRC" | grep -q ' procps' && echo ya || echo tidak)" "ya"
check "jq tidak dipasang lagi" \
    "$(printf '%s\n' "$PKG_SRC" | grep -cE '\bjq\b')" "0"

# ---------- K5: arsip backup WAJIB memuat config Xray ----------
# 'tar -r' tidak bisa menambah isi ke arsip .tar.gz ("Cannot update compressed
# archives"), dan itulah yang dulu membuat config Xray tidak pernah ter-backup.
AR="$SANDBOX/arroot"
mkdir -p "$AR/etc/sshwsxray" "$AR/usr/local/etc/xray"
echo 'budi|-|2026-09-13|2026-10-13|2' > "$AR/etc/sshwsxray/ssh_users.db"
echo '{"log":{}}' > "$AR/usr/local/etc/xray/config.json"
# shellcheck source=../lib/telegram.sh
source "$PROJECT_ROOT/lib/telegram.sh"
XRAY_CONFIG="$AR/usr/local/etc/xray/config.json"
check "_tg_archive_create sukses" "$(_tg_archive_create "$SANDBOX/b.tar.gz" "$AR" && echo ok || echo gagal)" "ok"
check "arsip memuat data akun" \
    "$(tar -tzf "$SANDBOX/b.tar.gz" | grep -q 'etc/sshwsxray' && echo ya || echo tidak)" "ya"
check "arsip memuat config Xray" \
    "$(tar -tzf "$SANDBOX/b.tar.gz" | grep -q 'usr/local/etc/xray/config.json' && echo ya || echo tidak)" "ya"
check "arsip tidak memuat /etc/shadow" \
    "$(tar -tzf "$SANDBOX/b.tar.gz" | grep -c 'shadow')" "0"
check "anggota arsip yang tidak ada dilewati" \
    "$(tar -tzf "$SANDBOX/b.tar.gz" | grep -c 'letsencrypt')" "0"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

# ---------- K6: unit systemd bridge ----------
check "SYSTEMD_DIR tidak menunjuk /etc asli" \
    "$([[ "$SYSTEMD_DIR" == "$SANDBOX"/* ]] && echo aman || echo BAHAYA)" "aman"
load_config; apply_config_defaults
rm -f "$SSHWSXRAY_SYSTEMD_DIR"/sshws.service "$SSHWSXRAY_SYSTEMD_DIR"/sshws-tls.service
bridge_write_units >/dev/null 2>&1
UNIT_P="$SSHWSXRAY_SYSTEMD_DIR/sshws.service"
check "unit sshws dibuat di SYSTEMD_DIR" "$([[ -f "$UNIT_P" ]] && echo ada || echo tidak)" "ada"
check "unit sshws memakai --peer-map" "$(grep -c -- '--peer-map' "$UNIT_P")" "1"
check "unit sshws route vmess" \
    "$(grep -c -- "/${XRAY_VMESS_WS_PATH}=127.0.0.1:${XRAY_VMESS_WS_PORT}" "$UNIT_P")" "1"
check "unit sshws route vless" \
    "$(grep -c -- "/${XRAY_VLESS_WS_PATH}=127.0.0.1:${XRAY_VLESS_WS_PORT}" "$UNIT_P")" "1"
check "tanpa cert: unit WSS tidak dibuat" \
    "$([[ -f "$SSHWSXRAY_SYSTEMD_DIR/sshws-tls.service" ]] && echo ada || echo tidak)" "tidak"

mkdir -p "$INSTALL_DIR/cert"
echo CERT > "$INSTALL_DIR/cert/fullchain.pem"
echo KEY  > "$INSTALL_DIR/cert/privkey.pem"
save_config CERT_DIR "$INSTALL_DIR/cert"
bridge_write_units >/dev/null 2>&1
UNIT_T="$SSHWSXRAY_SYSTEMD_DIR/sshws-tls.service"
check "dengan cert: unit WSS dibuat" "$([[ -f "$UNIT_T" ]] && echo ada || echo tidak)" "ada"
check "dengan cert: bridge memakai TLS" "$(grep -c -- '--tls --cert' "$UNIT_T")" "1"
check "dengan cert: cert_paths dipakai (bukan path dipatok)" \
    "$(grep -c -- "--cert ${INSTALL_DIR}/cert/fullchain.pem" "$UNIT_T")" "1"
check "dengan cert: route trojan ke inbound mux" \
    "$(grep -c -- "/${XRAY_TROJAN_WS_PATH}=127.0.0.1:${XRAY_TROJAN_MUX_PORT}" "$UNIT_T")" "1"

# cert hilang -> unit WSS lama harus dibuang, bukan dibiarkan gagal start
rm -f "$INSTALL_DIR/cert/fullchain.pem" "$INSTALL_DIR/cert/privkey.pem"
save_config CERT_DIR ""
bridge_write_units >/dev/null 2>&1
check "cert hilang: unit WSS lama dibuang" \
    "$([[ -f "$UNIT_T" ]] && echo masih_ada || echo dibuang)" "dibuang"

# ---------- K7: uninstall tidak meninggalkan akun sistem ----------
check "uninstall menghapus akun sistem (userdel)" \
    "$(grep -c 'userdel' "$PROJECT_ROOT/uninstall.sh")" "2"
check "uninstall membaca ssh_users.db" \
    "$(grep -q 'ssh_users.db' "$PROJECT_ROOT/uninstall.sh" && echo ya || echo tidak)" "ya"

# ---------- K8: SSL tidak berebut port 80 dengan bridge ----------
ISS_SRC=$(sed -n '/^issue_ssl()/,/^}/p' "$PROJECT_ROOT/install.sh")
stop_line=$(printf '%s\n' "$ISS_SRC" | grep -n 'systemctl stop sshws' | head -n1 | cut -d: -f1)
cert_line=$(printf '%s\n' "$ISS_SRC" | grep -n 'certbot certonly' | head -n1 | cut -d: -f1)
check "issue_ssl: sshws dihentikan sebelum certbot standalone" \
    "$([[ -n "$stop_line" && -n "$cert_line" && "$stop_line" -lt "$cert_line" ]] && echo ya || echo tidak)" "ya"
check "issue_ssl: sshws dinyalakan kembali" \
    "$(printf '%s\n' "$ISS_SRC" | grep -c 'systemctl start sshws')" "1"

# ---------- K9: tidak ada systemctl yang bisa membatalkan instalasi ----------
# Jalur instalasi berjalan dengan 'set -e' sampai akhir; satu service yang
# gagal start tidak boleh menggagalkan pemasangan menu/cron/symlink.
unguarded=$(grep -nhE '^[[:space:]]*systemctl ' "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/lib/bridge.sh" \
    | grep -vE '\|\| true|\|\| print_warning|\|\| systemctl|is-active|daemon-reload' | wc -l)
check "semua systemctl di installer tahan gagal" "$unguarded" "0"

echo
if (( failures == 0 )); then
    echo "ALL INSTALLER TESTS PASSED"
else
    echo "FAILED: $failures"
    exit 1
fi
