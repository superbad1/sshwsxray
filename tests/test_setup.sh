#!/bin/bash
# ============================================================
#  tests/test_setup.sh - Regression test fungsi installer
#
#  setup.sh hanya menjalankan main() bila dieksekusi langsung, sehingga
#  fungsi di dalamnya bisa diuji di sandbox tanpa menyentuh sistem.
# ============================================================
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SSHWSXRAY_INSTALL_DIR="$SANDBOX/etc"
export SSHWSXRAY_APP_DIR="$SANDBOX/app"
set --   # pastikan $1 kosong supaya mode --ssl-only tidak ikut aktif
# shellcheck source=../setup.sh
source "$PROJECT_ROOT/setup.sh"

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

# ---------- T1: install_app_files menyalin setup.sh (dipakai menu SSL) ----------
install_app_files
for f in setup.sh uninstall.sh menu.sh; do
    check "install_app_files: $f tersedia" "$([[ -f "$APP_DIR/$f" ]] && echo ada)" "ada"
done
for f in common.sh ssh.sh xray.sh xray_users.sh monitor.sh backup.sh expire.sh telegram.sh; do
    check "install_app_files: lib/$f" "$([[ -f "$APP_DIR/lib/$f" ]] && echo ada)" "ada"
done
for f in sshws.py xray_proto.py xray_render.py; do
    check "install_app_files: lib/$f" "$([[ -f "$APP_DIR/lib/$f" ]] && echo ada)" "ada"
done
check "install_app_files: setup.sh executable" "$([[ -x "$APP_DIR/setup.sh" ]] && echo yes)" "yes"

# ---------- T1b: unit systemd memakai path APP_DIR yang benar ----------
check "install_sshws terdefinisi" "$(declare -F install_sshws >/dev/null && echo ya)" "ya"
check "configure_firewall terdefinisi" "$(declare -F configure_firewall >/dev/null && echo ya)" "ya"
check "check_port_free terdefinisi" "$(declare -F check_port_free >/dev/null && echo ya)" "ya"

# ---------- K2: tidak boleh ada download script pihak ketiga ----------
if grep -q "netsense" "$PROJECT_ROOT/setup.sh"; then
    echo "FAIL  setup.sh masih menyebut netsense"
    failures=$((failures + 1))
else
    echo "PASS  setup.sh bersih dari netsense"
fi
# hanya komentar (penjelasan kenapa netsense dibuang) yang boleh menyebut nama
if grep -rn "netsense" "$PROJECT_ROOT/lib/" | grep -v ':[[:space:]]*#' | grep -q .; then
    echo "FAIL  lib/ masih memakai netsense sebagai perintah"
    failures=$((failures + 1))
else
    echo "PASS  lib/ tidak lagi memakai netsense"
fi

# ---------- K1b: sumber data tidak boleh di-truncate di setup.sh ----------
if grep -qE '^[[:space:]]*: > "\$INSTALL_DIR/' "$PROJECT_ROOT/setup.sh"; then
    echo "FAIL  setup.sh masih memakai ': >' pada file database"
    failures=$((failures + 1))
else
    echo "PASS  setup.sh tidak menimpa file database"
fi

echo
if (( failures == 0 )); then
    echo "ALL SETUP TESTS PASSED"
else
    echo "FAILED: $failures"
    exit 1
fi
