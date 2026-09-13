#!/bin/bash
# Sandbox unit tests for lib helpers (no root, no services needed)
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SCRIPT_DIR="$PROJECT_ROOT"
export SSHWSXRAY_INSTALL_DIR="$SANDBOX/sshwsxray"
# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
apply_config_defaults
mkdir -p "$INSTALL_DIR"

failures=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1 (got='$2' want='$3')"
        failures=$((failures + 1))
    fi
}
check_true() {
    if [[ "$2" == 0 ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1 (exit=$2)"
        failures=$((failures + 1))
    fi
}

# ---------- date helpers ----------
today=$(date +%F)
check "add_days 0 = today" "$(add_days 0)" "$today"
check "add_days 30 format" "$(add_days 30 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')" "1"
check "add_hours format" "$(add_hours 5 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$')" "1"

past=$(date -d "-2 days" +%F)
check_true "is_expired (masa lalu)" "$(is_expired "$past"; echo $?)"
future=$(add_days 5)
check "is_expired (masa depan) false" "$(is_expired "$future" && echo yes || echo no)" "no"
check "days_left 5" "$(days_left "$future")" "4"
check "days_left overdue negatif" "$(days_left "$past" | grep -c '^-\|^0$')" "1"

# ---------- config save/load ----------
save_config DOMAIN "contoh.com"
save_config WS_PATH "wsxray"
load_config
check "save/load DOMAIN" "$DOMAIN" "contoh.com"
check "save/load WS_PATH" "$WS_PATH" "wsxray"
check "save_config sync var di shell" "$DOMAIN" "contoh.com"
save_config DOMAIN "baru.com"
check "save_config update existing" "$DOMAIN" "baru.com"

# ---------- save_config escaping (regression) ----------
# nilai dengan & | # \ " harus tidak merusak file maupun gagal senyap
for raw in 'a&b' 'p|q' 'hash#tag' 'back\slash' 'quote"x' 'koma,titik'; do
    save_config DOMAIN "$raw"
    # baca ulang dari file (subshell) -> membuktikan file tetap valid
    got=$(unset DOMAIN; . "$CONFIG_FILE" >/dev/null 2>&1; printf '%s' "$DOMAIN")
    check "save_config round-trip: $raw" "$got" "$raw"
done
save_config DOMAIN "contoh.com"

# ---------- db add (pipe format) ----------
DB="$SANDBOX/test.db"
db_add "$DB" "vmess|uuid-1|alice|2026-09-13|2026-10-13 12:30|2"
db_add "$DB" "vless|uuid-2|bob|2026-09-13|2026-10-13|2"
check "db_add baris" "$(wc -l < "$DB")" "2"
# kolom expired dengan jam tidak menggeser field
check "field ke-6 tetap iplimit" "$(awk -F'|' '$3=="alice"{print $6}' "$DB")" "2"

# ---------- ensure_db_files: tidak boleh menimpa data yang ada ----------
ensure_db_files
echo "budi|-|2026-09-13|2026-10-13|2" > "$INSTALL_DIR/ssh_users.db"
ensure_db_files
check "ensure_db_files tidak mengosongkan DB" "$(wc -l < "$INSTALL_DIR/ssh_users.db")" "1"
check "ensure_db_files membuat trial_users.db" "$( [[ -f "$INSTALL_DIR/trial_users.db" ]] && echo ada)" "ada"
check "ensure_db_files mode DB 600" "$(stat -c %a "$INSTALL_DIR/ssh_users.db")" "600"

# ---------- is_int ----------
check "is_int 30" "$(is_int 30 && echo yes || echo no)" "yes"
check "is_int abc" "$(is_int abc && echo yes || echo no)" "no"
check "is_int kosong" "$(is_int "" && echo yes || echo no)" "no"

# ---------- is_expired defensif untuk nilai rusak ----------
check "is_expired('') -> belum expired" "$(is_expired "" && echo expired || echo aman)" "aman"
check "is_expired('abc') -> belum expired" "$(is_expired "abc" && echo expired || echo aman)" "aman"
check "days_left('') tidak error" "$(days_left "" 2>/dev/null)" "0"

# ---------- fmt_bytes ----------
check "fmt_bytes B"  "$(fmt_bytes 512)"    "512 B"
check "fmt_bytes KB" "$(fmt_bytes 2048)"   "2.00 KB"
check "fmt_bytes MB" "$(fmt_bytes 2097152)" "2.00 MB"
check "fmt_bytes GB" "$(fmt_bytes 2147483648)" "2.00 GB"

# ---------- gen helpers ----------
u=$(gen_uuid)
check "gen_uuid format" "$(echo "$u" | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')" "1"
p=$(gen_passwd 16)
check "gen_passwd length" "${#p}" "16"

# ---------- cert_paths ----------
check "cert_paths tanpa cert" "$(cert_paths >/dev/null 2>&1 && echo ok || echo empty)" "empty"
mkdir -p "$INSTALL_DIR/cert"
echo cert > "$INSTALL_DIR/cert/fullchain.pem"
echo key  > "$INSTALL_DIR/cert/privkey.pem"
save_config CERT_DIR "$INSTALL_DIR/cert"
read -r cf kf < <(cert_paths)
check "cert_paths cert file" "$cf" "$INSTALL_DIR/cert/fullchain.pem"
check "cert_paths key file"  "$kf" "$INSTALL_DIR/cert/privkey.pem"

# ---------- load_config under set -e (regression) ----------
bash -c "set -e; source '$PROJECT_ROOT/lib/common.sh'; load_config; echo done" > /dev/null 2>&1
check_true "load_config aman di bawah set -e" "$?"

# ---------- xray record helpers via awk (same logic as xray_users.sh) ----------
XDB="$SANDBOX/xray.db"
echo "vmess|uuid-1|alice|2026-09-13|2026-09-20 10:00|2" > "$XDB"
# exists check
awk -F'|' -v p=vmess -v u=alice '$1==p && $3==u {found=1} END{exit !found}' "$XDB"
check_true "record exists check" "$?"
# get field 5 (expired with time)
f5=$(awk -F'|' -v p=vmess -v u=alice '$1==p && $3==u {print $5; exit}' "$XDB")
check "get field 5 (expired+time)" "$f5" "2026-09-20 10:00"
# update field 5
newexp="2026-10-20 10:00"
awk -F'|' -v p=vmess -v u=alice -v f=5 -v v="$newexp" 'BEGIN{OFS="|"} $1==p && $3==u {$f=v} {print}' "$XDB" > "${XDB}.tmp" && mv "${XDB}.tmp" "$XDB"
check "update field 5" "$(awk -F'|' '$3=="alice"{print $5}' "$XDB")" "$newexp"
# delete record
awk -F'|' -v p=vmess -v u=alice '$1==p && $3==u {next} {print}' "$XDB" > "${XDB}.tmp" && mv "${XDB}.tmp" "$XDB"
check "delete record" "$(wc -l < "$XDB")" "0"

# ---------- ssh db renew logic (same awk as ssh_renew) ----------
SDB="$SANDBOX/ssh.db"
echo "budi|rahasia|2026-09-13|2026-09-20|2" > "$SDB"
user="budi"
current=$(awk -F'|' -v u="$user" '$1==u {print $4}' "$SDB" | head -n1)
check "ssh renew: baca expired" "$current" "2026-09-20"
expire=$(date -d "$current +30 days" +"%Y-%m-%d %H:%M")
awk -F'|' -v u="$user" -v e="$expire" 'BEGIN{OFS="|"} $1==u {$4=e} {print}' "$SDB" > "${SDB}.tmp" && mv "${SDB}.tmp" "$SDB"
check "ssh renew: update expired" "$(awk -F'|' '$1=="budi"{print $4}' "$SDB")" "$expire"
check "ssh renew: field lain utuh" "$(awk -F'|' '$1=="budi"{print $2}' "$SDB")" "rahasia"

echo
if (( failures == 0 )); then
    echo "ALL BASH TESTS PASSED"
else
    echo "FAILED: $failures"
    exit 1
fi
