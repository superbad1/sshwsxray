#!/bin/bash
# ============================================================
#  tests/test_wiring.sh - Pastikan seluruh menu & cron terhubung
#
#  menu.sh hanya menjalankan menu bila dieksekusi langsung, jadi di sini
#  cukup di-source lalu diperiksa: semua fungsi yang dipanggil menu harus
#  benar-benar terdefinisi (menangkap fungsi yang dihapus/berganti nama).
# ============================================================
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SSHWSXRAY_INSTALL_DIR="$SANDBOX/etc"
mkdir -p "$SSHWSXRAY_INSTALL_DIR"
set --
# shellcheck source=../menu.sh
source "$PROJECT_ROOT/menu.sh"

failures=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1 (got='$2' want='$3')"
        failures=$((failures + 1))
    fi
}

# fungsi yang dipanggil dari menu utama & submenu
WANTED_FUNCS="
main_menu menu_ssh menu_xray menu_monitor menu_backup menu_settings
ssh_create ssh_trial ssh_renew ssh_delete ssh_list ssh_chpass ssh_online
xray_user_create xray_user_trial xray_user_renew xray_user_delete
xray_user_traffic_menu xray_user_show_menu xray_show_status xray_restart_menu
xray_rebuild_menu
sysinfo monitor_online expire_check_menu speedtest_run
backup_menu backup_list_menu backup_restore_menu
"
for fn in $WANTED_FUNCS; do
    check "fungsi tersedia: $fn" "$(declare -F "$fn" >/dev/null && echo ada)" "ada"
done

# fungsi helper lintas-file yang dipakai menu/cron
HELPERS="
tg_send tg_send_file tg_backup tg_restore tg_escape
xray_render_config xray_validate xray_safe_restart xray_restart
xray_traffic_update xray_user_traffic xray_stats_query
ssh_user_ip_count _alert_once monitor_enforce
ensure_db_files is_int is_expired days_left save_config load_config
apply_config_defaults gen_uuid gen_passwd fmt_bytes
_tg_archive_create _chage_expire _sys_user_unlock _valid_password
"
for fn in $HELPERS; do
    check "helper tersedia: $fn" "$(declare -F "$fn" >/dev/null && echo ada)" "ada"
done

# fungsi yang memang sudah dibuang tidak boleh dipanggil lagi
for gone in netsense_add_user netsense_del_user netsense_count_ips db_del; do
    check "sudah dibuang: $gone" "$(declare -F "$gone" >/dev/null && echo masih_ada || echo bersih)" "bersih"
done

# target dalam case menu harus ada fungsinya (deteksi salah tulis)
missing=0
while read -r fn; do
    [[ -z "$fn" ]] && continue
    declare -F "$fn" >/dev/null || { echo "FAIL  menu memanggil fungsi tidak ada: $fn"; missing=1; }
done < <(grep -oE '^\s+[0-9x|Xa-zA-Z]+\)\s+[a-z_][a-zA-Z0-9_]*\s+;;' "$PROJECT_ROOT/menu.sh" \
         | sed -E 's/^[[:space:]]*[^)]*\)[[:space:]]*//; s/[[:space:]]*;;$//' | sort -u)
check "semua handler menu terdefinisi" "$missing" "0"

# cron script harus meng-source semua lib yang dipakainya
CRON_BODY=$(sed -n '/^write_cron_script()/,/^}/p' "$PROJECT_ROOT/install.sh")
for lib in common telegram ssh xray monitor; do
    if echo "$CRON_BODY" | grep -q "lib/${lib}.sh"; then
        echo "PASS  cron meng-source lib/${lib}.sh"
    else
        echo "FAIL  cron tidak meng-source lib/${lib}.sh"
        failures=$((failures + 1))
    fi
done

echo
if (( failures == 0 )); then
    echo "ALL WIRING TESTS PASSED"
else
    echo "FAILED: $failures"
    exit 1
fi
