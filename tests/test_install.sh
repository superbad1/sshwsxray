#!/bin/bash
# ============================================================
#  tests/test_install.sh - Regression test untuk install.sh
#
#  install.sh punya dua mode yang ditentukan dari cara pemanggilannya:
#    * dibaca dari pipe ('curl ... | sudo bash')  -> mode bootstrap:
#      unduh berkas aplikasi, lalu jalankan salinan hasil unduhan
#    * sebagai berkas dengan lib/ di sebelahnya    -> mode in-place:
#      langsung menjalankan instalasi
#
#  Test ini menguji MODE BOOTSTRAP memakai stub 'curl' di PATH yang melayani
#  URL raw dari direktori fixture lokal, jadi alur unduh -> jalankan salinan
#  benar-benar berjalan tanpa jaringan dan tanpa menyentuh sistem.
#  (Fungsi-fungsi installer diuji terpisah di tests/test_installer.sh.)
# ============================================================
set -u
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

INSTALLER="$PROJECT_ROOT/install.sh"

failures=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1 (got='$2' want='$3')"
        failures=$((failures + 1))
    fi
}
check_contains() {  # check_contains <label> <haystack> <needle>
    if [[ "$2" == *"$3"* ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1 (output tidak memuat '$3')"
        failures=$((failures + 1))
    fi
}
# Cek pola hanya pada baris perintah (komentar boleh menyebut apa saja)
code_contains() { grep -nE -- "$1" "$INSTALLER" | grep -v ':[[:space:]]*#' | grep -q .; }

# ============================================================
#  1. Struktur & sifat dasar script
# ============================================================
check "install.sh ada" "$([[ -f "$INSTALLER" ]] && echo ada)" "ada"
check "install.sh executable" "$([[ -x "$INSTALLER" ]] && echo yes)" "yes"
if bash -n "$INSTALLER"; then echo "PASS  syntax install.sh"; else echo "FAIL  syntax install.sh"; failures=$((failures + 1)); fi
check "setup.sh sudah tidak ada lagi" \
    "$([[ -f "$PROJECT_ROOT/setup.sh" ]] && echo masih-ada || echo terhapus)" "terhapus"

# Persyaratan: satu baris, TANPA git
if code_contains '\bgit\b'; then
    echo "FAIL  install.sh memakai perintah git"
    failures=$((failures + 1))
else
    echo "PASS  install.sh bebas dari git"
fi

# Persyaratan: TANPA arsip / ekstrak
for pat in 'archive/refs' '\.tar\.gz' 'unzip' 'gzip -d' 'tar -x'; do
    if code_contains "$pat"; then
        echo "FAIL  install.sh masih memakai '$pat' (harus tanpa arsip/ekstrak)"
        failures=$((failures + 1))
    else
        echo "PASS  install.sh bebas dari '$pat'"
    fi
done
# tar boleh muncul hanya sebagai paket dependensi (dipakai lib/backup.sh),
# bukan sebagai perintah pembuka arsip installer
non_pkg_tar="$(grep -nE '\btar\b' "$INSTALLER" | grep -v ':[[:space:]]*#' | grep -v 'apt-get install' | grep -c .)"
check "tar hanya paket dependensi, bukan pembuka arsip" "$non_pkg_tar" "0"

# Persyaratan: TANPA argumen, opsi, fork/branch/tag
# (positional parameter di dalam fungsi, mis. check_port_free "$1", bukan argumen CLI)
for pat in 'SSHWSXRAY_REPO' 'SSHWSXRAY_BRANCH' 'SSHWSXRAY_TARBALL' 'SSHWSXRAY_DRY_RUN' \
           'usage\(\)' '--help' 'getopts' 'shift' '"\$@"'; do
    if grep -qE -- "$pat" "$INSTALLER"; then
        echo "FAIL  install.sh masih memuat '$pat' (harusnya tanpa argumen/opsi)"
        failures=$((failures + 1))
    else
        echo "PASS  install.sh bebas dari '$pat'"
    fi
done

# Unduhan harus lewat raw, satu berkas per request
check "RAW_BASE menunjuk raw main" \
    "$(grep -c '^RAW_BASE="https://raw.githubusercontent.com/superbad1/sshwsxray/main"$' "$INSTALLER")" "1"
if grep -qF 'fetch "${RAW_BASE}/${f}"' "$INSTALLER"; then
    echo "PASS  unduhan per berkas memakai \$RAW_BASE/\$f"
else
    echo "FAIL  unduhan per berkas tidak memakai \$RAW_BASE"
    failures=$((failures + 1))
fi

# Dua mode harus dikenali dari cara pemanggilan
if grep -q 'BASH_SOURCE\[0\]' "$INSTALLER" && grep -q 'lib/common.sh"' "$INSTALLER"; then
    echo "PASS  install.sh mendeteksi mode (pipe vs berkas+lib)"
else
    echo "FAIL  install.sh tidak mendeteksi mode kerja"
    failures=$((failures + 1))
fi
if grep -q 'SSL_ONLY' "$INSTALLER" && grep -q 'ssl_only' "$INSTALLER"; then
    echo "PASS  mode SSL saja tersedia untuk menu"
else
    echo "FAIL  mode SSL saja tidak ada di install.sh"
    failures=$((failures + 1))
fi

# ============================================================
#  2. Manifest harus sama dengan isi repo
# ============================================================
repo_paths="$(
    { echo install.sh; echo menu.sh; echo uninstall.sh
      (cd "$PROJECT_ROOT" && ls lib/*.sh lib/*.py)
    } | sort
)"
manifest_paths="$(sed -n '/^MANIFEST="$/,/^"$/p' "$INSTALLER" | sed '1d;$d' | grep -v '^$' | sort)"

if [[ "$manifest_paths" == "$repo_paths" ]]; then
    echo "PASS  manifest install.sh sama dengan isi repo"
else
    echo "FAIL  manifest install.sh beda dengan isi repo"
    echo "      hanya di install.sh: $(comm -13 <(echo "$repo_paths") <(echo "$manifest_paths") | tr '\n' ' ')"
    echo "      hanya di repo      : $(comm -23 <(echo "$repo_paths") <(echo "$manifest_paths") | tr '\n' ' ')"
    failures=$((failures + 1))
fi

# ============================================================
#  3. Penjagaan root
# ============================================================
chmod 755 "$SANDBOX"
cp -f "$INSTALLER" "$SANDBOX/install.sh"
chmod 755 "$SANDBOX/install.sh"
if command -v setpriv >/dev/null 2>&1 && setpriv --reuid=65534 --regid=65534 --clear-groups id >/dev/null 2>&1; then
    nonroot_out="$(setpriv --reuid=65534 --regid=65534 --clear-groups \
        bash "$SANDBOX/install.sh" 2>&1)"
    nonroot_rc=$?
    check "non-root ditolak" "$([[ $nonroot_rc -ne 0 ]] && echo ya)" "ya"
    check_contains "non-root: pesan menyebut root" "$nonroot_out" "harus dijalankan sebagai root"
    check_contains "non-root: ada petunjuk sudo bash" "$nonroot_out" "sudo bash"
else
    echo "SKIP  uji non-root (setpriv tidak tersedia)"
fi

# ============================================================
#  4. Fixture + stub curl (melayani URL raw dari disk)
# ============================================================
STUB_DIR="$SANDBOX/stub"
FIXTURE="$SANDBOX/fixture"
mkdir -p "$STUB_DIR"

make_stub_curl() {  # make_stub_curl <fixture_dir> <path>
    cat > "$2" <<STUB
#!/bin/bash
# stub curl untuk pengujian: tidak menyentuh jaringan
dest=""; url=""; prev=""
for a in "\$@"; do
    [[ "\$prev" == "-o" ]] && dest="\$a"
    [[ "\$a" == http* ]] && url="\$a"
    prev="\$a"
done
[[ -n "\$dest" && -n "\$url" ]] || exit 2
rel="\${url##*/sshwsxray/main/}"
src="$1/\$rel"
[[ -f "\$src" ]] || { echo "404: Not Found" >&2; exit 22; }
cp -f "\$src" "\$dest"
STUB
    chmod 755 "$2"
}

build_fixture() {  # build_fixture <mode>  (ok | missing)
    local mode="$1" rel dir
    rm -rf "$FIXTURE"
    for rel in $manifest_paths; do
        dir="$FIXTURE/$(dirname "$rel")"
        mkdir -p "$dir"
        : > "$FIXTURE/$rel"
    done
    # install.sh di fixture diganti stub: bootstrap harus menjalankan SALINAN
    # hasil unduhan (bukan dirinya sendiri yang sedang dibaca dari pipe).
    cat > "$FIXTURE/install.sh" <<STUB
#!/bin/bash
echo "STUB_INSTALLER_DIJALANKAN"
echo "\$(cd "\$(dirname "\$0")" && pwd)" > "$SANDBOX/run-dir"
read -rp "Domain untuk SSL (kosongkan jika tanpa domain): " D
echo "STUB_DOMAIN=[\$D]"
STUB
    chmod 755 "$FIXTURE/install.sh"
    [[ "$mode" == "missing" ]] && rm -f "$FIXTURE/lib/sshws.py"
    return 0
}

# Bentuk pemakaian yang sesungguhnya: script dibaca dari pipe.
# (Menjalankan install.sh sebagai berkas dari dalam repo berarti mode
#  in-place dan itu akan memasang sistem - tidak boleh terjadi di test.)
piped()  { bash -c "cat '$INSTALLER' | bash" 2>&1; }

# ============================================================
#  5. Alur bootstrap (butuh root + OS debian/ubuntu)
# ============================================================
os_id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
if [[ ${EUID} -ne 0 ]]; then
    echo "SKIP  uji alur bootstrap (butuh root)"
elif [[ "$os_id" != "debian" && "$os_id" != "ubuntu" ]]; then
    echo "SKIP  uji alur bootstrap (OS ${os_id:-tidak diketahui} tidak didukung installer)"
else
    export TMPDIR="$SANDBOX/tmp"
    mkdir -p "$TMPDIR"
    export PATH="$STUB_DIR:$PATH"

    # ---- 5a. happy path ----
    build_fixture ok
    make_stub_curl "$FIXTURE" "$STUB_DIR/curl"
    rm -f "$SANDBOX/run-dir"
    happy_out="$(piped)"
    happy_rc=$?
    total="$(echo "$manifest_paths" | wc -w)"
    check "bootstrap exit 0" "$happy_rc" "0"
    check_contains "bootstrap: jumlah berkas diumumkan" "$happy_out" "Mengunduh $total berkas"
    check_contains "bootstrap: semua berkas terunduh" "$happy_out" "$total berkas terunduh"
    check_contains "bootstrap: salinan hasil unduhan dijalankan" "$happy_out" "STUB_INSTALLER_DIJALANKAN"
    check "bootstrap: installer jalan dari hasil unduhan" \
        "$([[ -f "$SANDBOX/run-dir" && "$(cat "$SANDBOX/run-dir")" == "$SANDBOX/tmp/"* ]] && echo ya)" "ya"
    check "bootstrap: direktori sementara dibersihkan" \
        "$([[ -d "$(cat "$SANDBOX/run-dir" 2>/dev/null)" ]] && echo masih-ada || echo bersih)" "bersih"
    check "bootstrap: TMPDIR bersih setelah selesai" "$(ls -A "$TMPDIR" | wc -l)" "0"

    # ---- 5b. satu berkas gagal diunduh (404) ----
    build_fixture missing
    make_stub_curl "$FIXTURE" "$STUB_DIR/curl"
    miss_out="$(piped)"
    miss_rc=$?
    check "berkas hilang: exit != 0" "$([[ $miss_rc -ne 0 ]] && echo ya)" "ya"
    check_contains "berkas hilang: nama berkas disebut" "$miss_out" "lib/sshws.py"
    check_contains "berkas hilang: saran periksa koneksi" "$miss_out" "Periksa koneksi"
    check "berkas hilang: instalasi tidak pernah dijalankan" \
        "$([[ "$miss_out" == *"STUB_INSTALLER_DIJALANKAN"* ]] && echo dijalankan || echo tidak)" "tidak"
    check "berkas hilang: TMPDIR dibersihkan" "$(ls -A "$TMPDIR" | wc -l)" "0"

    # ---- 5c. seluruh unduhan gagal (koneksi mati) ----
    make_stub_curl "$SANDBOX/tanpa-berkas" "$STUB_DIR/curl"
    dead_out="$(piped)"
    check "koneksi mati: exit != 0" "$([[ "$dead_out" == *"Gagal mengunduh"* ]] && echo ya)" "ya"
    check_contains "koneksi mati: nama berkas pertama disebut" "$dead_out" "install.sh"

    # ---- 5d. dijalankan sebagai berkas TANPA lib/ di sebelahnya ----
    # Ini juga mode bootstrap (yang membedakan adalah ada/tidaknya lib/).
    SOLO_DIR="$SANDBOX/solo"
    mkdir -p "$SOLO_DIR"
    cp -f "$INSTALLER" "$SOLO_DIR/install.sh"
    chmod 755 "$SOLO_DIR/install.sh"
    build_fixture ok
    make_stub_curl "$FIXTURE" "$STUB_DIR/curl"
    rm -f "$SANDBOX/run-dir"
    solo_out="$(bash "$SOLO_DIR/install.sh" </dev/null 2>&1)"
    check "berkas tanpa lib/: exit 0" "$?" "0"
    check_contains "berkas tanpa lib/: tetap bootstrap" "$solo_out" "STUB_INSTALLER_DIJALANKAN"

    # ---- 5e. prompt saat script dipipe (inti 'curl | sudo bash') ----
    # Tanpa controlling terminal: harus lanjut dengan peringatan jelas, bukan
    # mati dengan "No such device or address".
    build_fixture ok
    make_stub_curl "$FIXTURE" "$STUB_DIR/curl"
    notty_out="$(printf 'vpn.contoh.test\n' | piped)"
    notty_rc=$?
    check "dipipe tanpa terminal: installer tidak mati" "$notty_rc" "0"
    check_contains "dipipe tanpa terminal: peringatan jelas" "$notty_out" "Tidak ada terminal"
    check_contains "dipipe tanpa terminal: lanjut (domain kosong)" "$notty_out" "STUB_DOMAIN=[]"

    if command -v script >/dev/null 2>&1; then
        tty_out="$(printf 'vpn.contoh.test\n' | script -qc "cat '$INSTALLER' | bash" /dev/null 2>/dev/null)"
        check_contains "dipipe + terminal: prompt terjawab" "$tty_out" "STUB_DOMAIN=[vpn.contoh.test]"
    else
        echo "SKIP  uji prompt via terminal (perintah 'script' tidak tersedia)"
    fi

    # ---- 5f. mode SSL saja (dipakai menu Pengaturan -> 8) ----
    # Dijalankan sebagai berkas di direktori yang punya lib/, dengan
    # lib/common.sh tiruan. Tanpa domain, jalur ini harus berhenti sendiri
    # tanpa menyentuh sistem sama sekali.
    SOLO_SSL="$SANDBOX/solo-ssl"
    mkdir -p "$SOLO_SSL/lib"
    cp -f "$INSTALLER" "$SOLO_SSL/install.sh"
    cat > "$SOLO_SSL/lib/common.sh" <<'STUB'
print_warning() { echo "[WARN ] $1"; }
print_error()   { echo "[ERROR] $1" >&2; }
print_success() { echo "[ OK  ] $1"; }
print_info()    { echo "[INFO ] $1"; }
load_config()   { return 0; }
apply_config_defaults() { return 0; }
ensure_db_files() { return 0; }
get_domain()    { echo ""; }
STUB
    # lib/bridge.sh ikut di-source oleh alur SSL; di fixture ini cukup stub
    cat > "$SOLO_SSL/lib/bridge.sh" <<'STUB'
bridge_write_units() { return 0; }
STUB
    ssl_out="$(SSL_ONLY=1 bash "$SOLO_SSL/install.sh" </dev/null 2>&1)"
    ssl_rc=$?
    check "SSL saja tanpa domain: exit != 0" "$([[ $ssl_rc -ne 0 ]] && echo ya)" "ya"
    check_contains "SSL saja: domain belum diset" "$ssl_out" "Domain belum diset"
    check_contains "SSL saja: gagal dengan pesan jelas" "$ssl_out" "SSL gagal"

    unset TMPDIR
fi

# ============================================================
#  6. README
# ============================================================
if grep -q "raw.githubusercontent.com/superbad1/sshwsxray/main/install.sh" "$PROJECT_ROOT/README.md"; then
    echo "PASS  README memuat URL one-liner"
else
    echo "FAIL  README belum memuat URL one-liner"
    failures=$((failures + 1))
fi
if grep -q "SSHWSXRAY_BRANCH\|SSHWSXRAY_REPO\|git clone" "$PROJECT_ROOT/README.md"; then
    echo "FAIL  README masih menyebut clone / opsi branch"
    failures=$((failures + 1))
else
    echo "PASS  README tanpa clone & tanpa opsi branch"
fi

echo
if (( failures == 0 )); then
    echo "ALL INSTALL TESTS PASSED"
else
    echo "FAILED: $failures"
    exit 1
fi
