# sshwsxray — SSH Websocket + Xray-core Autoscript

Autoscript instalasi dan manajemen user untuk tunnel **SSH over WebSocket** dan **Xray-core (VMess / VLESS / Trojan)** dengan menu CLI di terminal, untuk VPS **Debian 10/11/12** dan **Ubuntu 20.04/22.04/24.04**.

## Fitur

**Manajemen akun**
- SSH & SSH WebSocket: buat / trial / renew / hapus / daftar / ganti password
- Xray VMess, VLESS, Trojan: buat / trial / renew / hapus / daftar, link sharing otomatis (transport WebSocket)
- Masa aktif otomatis (expired date), akun trial per-jam, renew menjumlah dari sisa masa aktif

**Keamanan & monitoring**
- Limit IP per akun SSH — dihitung sendiri dari koneksi sshd yang aktif (`ss` + `ps`, tanpa script pihak ketiga), pemutusan oleh cron. Klien yang masuk lewat WebSocket ikut terhitung benar-benar: bridge mencatat IP aslinya (`/etc/sshwsxray/ws_peers.db`), karena di sisi sshd koneksi WS terlihat datang dari loopback
- Deteksi multi-login (alert Telegram saat sesi ganda terdeteksi, dengan cooldown 30 menit supaya tidak spam)
- Auto-hapus akun Xray yang expired + lock akun SSH expired (dan otomatis dibuka lagi saat di-renew)
- Traffic per akun Xray via StatsService API Xray (query via python, tanpa binary `nc`)
- ⚠️ Limit IP hanya berlaku untuk akun **SSH**; protokol Xray tidak punya penegakan limit IP per akun
- Info sistem: CPU, RAM, disk, uptime, status semua service
- Speedtest server

**Infrastruktur**
- SSH over WebSocket (ws port 80 / wss port 443) via **bridge WebSocket kustom** (`lib/sshws.py`, pure Python stdlib tanpa dependency)
- Xray-core via installer resmi [XTLS/Xray-install](https://github.com/XTLS/Xray-install) — transport **WebSocket** (gRPC & Reality tidak dipakai)
- SSL Let's Encrypt otomatis (certbot standalone) + renew hook
- Backup/restore lokal + kirim backup ke Telegram bot
- Notifikasi Telegram: akun dibuat/hapus/renew, trial, expired, multi-login, limit IP
- Auto reboot opsional tiap 05:00

## Arsitektur

```
                            ┌── path ≠ route ──► 127.0.0.1:22      (sshd)
Klien ──► 80 / 443 ──► sshws.py (router berbasis path)
                            ├── /<token vmess> ─► 127.0.0.1:10086 (Xray vmess ws)
                            ├── /<token vless> ─► 127.0.0.1:10088 (Xray vless ws)
                            └── /<token trojan ► 127.0.0.1:10093 (Xray trojan ws, tanpa TLS)
```

**SSH-WebSocket dan Xray memakai port yang sama (80 dan 443).** Yang
membedakan bukan port, melainkan **path** pada request upgrade — sama seperti
cara nginx memisahkan beberapa layanan di satu port.

Semua inbound Xray memakai transport **WebSocket** saja; gRPC dan Reality tidak dirender.

- `sshws.py` menjalankan dua hal sekaligus:
  - **jalur SSH** (default): balas `101 Switching Protocols` sendiri, lalu teruskan stream TCP mentah ke sshd — tanpa framing, masking, ping/pong, atau pembungkusan payload.
  - **jalur Xray**: bila path cocok dengan sebuah `--route`, request upgrade diteruskan **apa adanya** ke inbound Xray (`Xray` sendiri yang menjawab 101), lalu byte disalurkan dua arah.
- SSH-WS memakai **path standar `/`**: tidak ada path khusus, jadi klien boleh meminta `/` maupun path lain (bridge memeriksa route lebih dulu).
- Setiap protokol Xray punya **path acak sendiri** (12 karakter, dibuat saat instalasi dan disimpan di config) supaya tidak mudah ditebak: VMess, VLESS, dan Trojan masing-masing satu token.
- Bridge dijalankan dua instance: `sshws` (plain, port 80) dan `sshws-tls` (TLS via cert Let's Encrypt, port 443). Trojan hanya didaftarkan di 443 karena butuh TLS; TLS diterima bridge, jadi Xray memakai inbound kedua tanpa TLS di loopback (`trojan-mux-in`, port 10093).
- Port lama Xray (10086/10088/10091) **tetap terbuka** bila ingin disambung langsung tanpa bridge; Trojan di 10091 memakai TLS-nya sendiri.
- Konfigurasi Xray dirender dari database user (`/etc/sshwsxray/xray_users.db`) setiap ada perubahan akun, lalu service di-restart otomatis.
- Cron tiap menit (`/usr/local/bin/sshwsxray-cron`): snapshot traffic Xray, expire akun, limit IP, alert multi-login, auto reboot.

## Bridge WebSocket (`lib/sshws.py`)

Pengganti gost — ditulis dengan Python stdlib murni, tanpa dependency tambahan:

```bash
# websocket biasa (port 80): SSH di semua path, Xray di path yang didaftarkan
python3 lib/sshws.py --port 80 --target 127.0.0.1:22 \
    --route "/<token-vmess>=127.0.0.1:10086" \
    --route "/<token-vless>=127.0.0.1:10088"

# websocket secure (port 443): ditambah route Trojan lewat inbound mux
python3 lib/sshws.py --port 443 --target 127.0.0.1:22 \
    --route "/<token-vmess>=127.0.0.1:10086" \
    --route "/<token-vless>=127.0.0.1:10088" \
    --route "/<token-trojan>=127.0.0.1:10093" \
    --tls --cert /etc/sshwsxray/cert/fullchain.pem --key /etc/sshwsxray/cert/privkey.pem
```

| Flag | Fungsi | Default |
|------|--------|---------|
| `--port` | port listen (wajib) | — |
| `--path` | path untuk SSH; `/` = terima semua path | `/` |
| `--target` | target TCP SSH (sshd) | `127.0.0.1:22` |
| `--route` | `/path=host:port` — teruskan path itu ke backend lain (Xray); bisa diulang | — |
| `--tls` `--cert` `--key` | aktifkan wss | nonaktif |
| `--max-connections` | batas koneksi bersamaan | 1024 |
| `--max-per-ip` | batas koneksi SSH per-IP (route Xray tidak dihitung) | 16 |
| `--handshake-timeout` | timeout handshake | 10s |
| `--connect-timeout` | timeout konek ke backend | 10s |
| `--verbose` | log debug | nonaktif |

Sudah ditangani: validasi header `Upgrade: websocket` + `Connection: Upgrade`,
balasan `Sec-WebSocket-Accept` (bila klien mengirim key), penerusan byte mentah
tanpa framing, data yang dipipelkan bersama handshake tetap utuh, TCP_NODELAY
(latensi SSH tetap rendah), penolakan request non-upgrade (400), dan TLS 1.2+.

Bila `--path` diisi selain `/`, pencocokan path ditegakkan lagi (path lain dibalas 404).

Test:

```bash
python3 tests/test_sshws.py     # 34 test: handshake '/', path bebas, mode ketat, echo mentah, pipelined, 1MB payload, TLS, konkurensi, per-IP, router --route (Xray) + TLS
bash tests/test_install.sh      # bootstrap installer (stub curl, tanpa jaringan)
bash tests/test_installer.sh    # fungsi installer di sandbox
```

## Instalasi

Satu perintah — tanpa mengunduh arsip, tanpa ekstrak, tanpa langkah manual:

```bash
curl -fsSL https://raw.githubusercontent.com/superbad1/sshwsxray/main/install.sh | sudo bash
```

`install.sh` adalah **satu berkas yang melakukan semuanya** (dulu terpisah
menjadi `install.sh` + `setup.sh`). Berkas ini punya dua mode, ditentukan dari
cara ia dipanggil:

| Cara dipanggil | Mode | Yang dilakukan |
|---|---|---|
| dibaca dari pipe (`curl … \| sudo bash`) | bootstrap | unduh berkas aplikasi satu per satu (raw) ke direktori sementara, lalu jalankan salinan hasil unduhan |
| sebagai berkas dengan `lib/` di sebelahnya | in-place | langsung menjalankan instalasi |

Mode in-place itulah yang berjalan saat bootstrap dan saat menu Pengaturan → 8
memanggil `SSL_ONLY=1 /usr/local/lib/sshwsxray/install.sh`. Tidak ada git,
tidak ada arsip, tidak ada ekstrak, tidak ada argumen — semua pengaturan
ditanyakan saat instalasi atau diubah kapan saja lewat menu `sudo menu`.

Yang ditangani bagian bootstrap:
- menolak jalan bila bukan root, dan berhenti lebih awal bila OS bukan Debian/Ubuntu
- memasang `curl` sendiri bila belum ada
- berhenti dengan nama berkas yang gagal diunduh (tanpa melanjutkan ke instalasi)
- menghubungkan ulang stdin ke `/dev/tty`, sehingga pertanyaan domain tetap bisa dijawab walau script dibaca dari pipe

Yang ditangani bagian instalasi:
1. Deteksi OS/arch (amd64/arm64)
2. Install dependencies (curl, wget, tar, python3, openssl, cron, openssh-server, iproute2, procps, speedtest-cli)
3. Tanya domain untuk SSL (opsional, harus sudah A-record ke IP VPS)
4. Konfigurasi sshd (port 22), pasang bridge WebSocket (`sshws`/`sshws-tls`), Xray-core, certbot
5. Render config Xray, pasang cron, salin aplikasi ke `/usr/local/lib/sshwsxray`, buat symlink `menu` dan `sshwsxray`

Daftar berkas yang diunduh dipatok di dalam `install.sh`; `tests/test_install.sh`
membandingkannya dengan isi repo, jadi berkas baru di `lib/` yang lupa
didaftarkan akan langsung ketahuan.

### Tanpa domain
Jalankan tanpa mengisi domain. wss/443 dan Trojan TLS tidak aktif; VMess WS dan VLESS WS tetap jalan. SSL bisa ditambahkan kapan saja dari **menu 5 → 8** (perintah dijalankannya `SSL_ONLY=1 install.sh`).

## Penggunaan

```bash
sudo menu
```

`menu` dan `sshwsxray` sama-sama symlink ke `/usr/local/lib/sshwsxray/menu.sh`;
pakai yang mana saja.

| Menu | Isi |
|------|-----|
| 1) SSH / SSH Websocket | buat, trial, renew, hapus, daftar, ganti password, user online |
| 2) Xray | buat/trial/renew/hapus akun VMess/VLESS/Trojan, link sharing, traffic, restart service, rebuild config |
| 3) Monitoring | info sistem, user online, cek masa aktif, speedtest |
| 4) Backup & Restore | backup tar.gz lokal (rotasi 5), kirim ke Telegram, restore |
| 5) Pengaturan | domain, path Xray (acak), limit IP, trial, auto reboot, Telegram bot, SSL |

## Port Default

| Port | Layanan | Untuk klien |
|------|---------|-------------|
| 22 | OpenSSH | SSH langsung |
| **80** | **bridge `sshws.service`** (ws) | **SSH-WebSocket + VMess WS + VLESS WS** (dibedakan path) |
| **443** | **bridge `sshws-tls.service`** (wss, butuh SSL) | **SSH-WSS + VMess WS + VLESS WS + Trojan WS** (dibedakan path) |
| 10085 | Xray stats API | tidak — localhost saja (dipakai cron) |
| 10086 | VMess WebSocket langsung | opsional (tanpa bridge) |
| 10088 | VLESS WebSocket langsung | opsional (tanpa bridge) |
| 10091 | Trojan WebSocket (TLS sendiri) | opsional (tanpa bridge) |
| 10093 | Trojan mux (`trojan-mux-in`) | tidak — loopback, dipakai bridge 443 |
| 10087/10089/10090/10092 | _(tidak dipakai — gRPC & Reality dihapus)_ | — |

Klien cukup memakai **80 atau 443** untuk semuanya; path acak yang menentukan
protokolnya (lihat `sudo menu` → 5, atau menu Xray → 6 untuk link akun).
Port 10086/10088/10091 tetap terbuka bila ingin menyambung langsung.

Semua port dapat diubah di `/etc/sshwsxray/config` lalu restart service.
Mengganti path dilakukan lewat **menu 5 → 2** (path baru dibuat acak, config
Xray dirender ulang, unit bridge ditulis ulang, lalu kedua service di-restart).

Installer **tidak menyentuh firewall sama sekali** — tidak memasang, tidak
mengaktifkan, dan tidak menambah aturan apa pun pada `ufw`, `iptables`, maupun
`nftables`. Firewall sepenuhnya urusanmu: pastikan port di atas terbuka lewat
security group VPS atau firewall pilihanmu. Daftar port yang perlu dibuka
ditampilkan sebagai peringatan di akhir instalasi.

`WS_MAX_PER_IP` (default `16`) membatasi jumlah koneksi SSH-WebSocket
bersamaan dari satu alamat IP; isi `0` untuk mematikannya. Koneksi Xray lewat
bridge **tidak** dihitung, karena satu klien Xray bisa membuka banyak koneksi
sah.

## File Penting

| Path | Fungsi |
|------|--------|
| `/etc/sshwsxray/config` | Konfigurasi global (domain, port, telegram, dll) |
| `/etc/sshwsxray/ssh_users.db` | Database user SSH |
| `/etc/sshwsxray/xray_users.db` | Database akun Xray |
| `/etc/sshwsxray/xray_traffic.db` | Snapshot traffic per akun |
| `/etc/sshwsxray/config` | juga menyimpan path acak: `XRAY_VMESS_WS_PATH`, `XRAY_VLESS_WS_PATH`, `XRAY_TROJAN_WS_PATH` |
| `/usr/local/lib/sshwsxray/lib/bridge.sh` | Penulisan unit systemd bridge (route Xray per protokol) |
| `/usr/local/etc/xray/config.json` | Config Xray (dirender otomatis) |
| `/usr/local/lib/sshwsxray/install.sh` | Installer (dipakai menu 5 → 8 untuk SSL) |
| `/usr/local/lib/sshwsxray/menu.sh` | Menu utama (`sshwsxray`) |
| `/usr/local/lib/sshwsxray/sshws.py` | Bridge WebSocket kustom (pengganti gost) |
| `/etc/systemd/system/sshws*.service` | Unit systemd bridge WebSocket |
| `/root/backup/` | Arsip backup |

## Telegram Bot

1. Buat bot via [@BotFather](https://t.me/BotFather), salin token
2. Kirim pesan ke bot kamu (agar chat id terdaftar)
3. Ambil chat id via `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. Isi token + chat id di **menu 5 → 6**

Coba test dengan **menu 5 → 7**.

## Catatan Keamanan

- `PermitRootLogin yes` dipakai secara default ala autoscript klasik — disarankan ganti ke `prohibit-password` dan pakai key SSH.
  `sshd_config` hasil installer divalidasi dengan `sshd -t` sebelum dipakai; kalau tidak valid, config lama otomatis dikembalikan.
- Semua `.db`, config, dan key disimpan dengan permission `600`, direktori data `700`.
- **Password SSH tidak disimpan di database** (field password diisi `-`). Satu-satunya tempat password ada adalah file info akun `/root/<user>-ssh-ws.txt` (mode `600`).
- Arsip backup **tidak memuat `/etc/shadow`**. Restore hanya mengekstrak data aplikasi (`/etc/sshwsxray` + config Xray) dan tidak pernah menimpa `/etc/passwd`, `/etc/shadow`, `/etc/group`.
- Restore membuat snapshot otomatis (`/root/backup/pre-restore-*.tar.gz`) sebelum menimpa data. User yang dibuat ulang mendapat password acak baru yang ditampilkan sekali.
- Config Xray divalidasi (`xray run -test`) sebelum restart; kalau tidak valid, config lama otomatis dipulihkan sehingga service tidak ikut mati.
- Limit IP via cron punya jeda sampai 60 detik karena cron berjalan tiap menit.
- Installer tidak lagi mengunduh script pihak ketiga — hanya paket apt resmi + installer resmi Xray.
- Arsip backup memuat `/etc/sshwsxray/config` (termasuk token bot Telegram). Simpan arsip & chat bot dengan aman.

## Uninstall

```bash
sudo bash uninstall.sh
```

Menghapus service sshws/Xray, binary, cron, dan `/etc/sshwsxray`, lalu restore sshd_config dari backup.
Akun SSH/trial yang dibuat script juga dihapus (`userdel -r`, termasuk home dan file info di `/root/<user>-ssh-ws.txt`).
