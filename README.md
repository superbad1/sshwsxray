# sshwsxray — SSH Websocket + Xray-core Autoscript

Autoscript instalasi dan manajemen user untuk tunnel **SSH over WebSocket** dan **Xray-core (VMess / VLESS / Trojan)** dengan menu CLI di terminal, untuk VPS **Debian 10/11/12** dan **Ubuntu 20.04/22.04/24.04**.

## Fitur

**Manajemen akun**
- SSH & SSH WebSocket: buat / trial / renew / hapus / daftar / ganti password
- Xray VMess, VLESS, Trojan: buat / trial / renew / hapus / daftar, link sharing otomatis (transport WebSocket)
- Masa aktif otomatis (expired date), akun trial per-jam, renew menjumlah dari sisa masa aktif

**Keamanan & monitoring**
- Limit IP per akun SSH — dihitung sendiri dari koneksi sshd yang aktif (`ss` + `ps`, tanpa script pihak ketiga), pemutusan oleh cron
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
Klien (HTTP-WS) ──► port 80/443  sshws.py  (WebSocket bridge, path /) ──► 127.0.0.1:22 (sshd)
Klien (Vmess/Vless/Trojan ws)  ──► port 10086/10088/10091 (Xray, path /<WS_PATH>)
```

Semua inbound Xray memakai transport **WebSocket** saja; gRPC dan Reality tidak dirender.

- `sshws.py` hanya melakukan **handshake/upgrade** WebSocket (balas `101 Switching Protocols`), lalu stream TCP diteruskan mentah ke sshd lokal — tanpa framing, masking, ping/pong, atau pembungkusan payload.
- SSH-WS memakai **path standar `/`**: tidak ada path khusus, jadi klien boleh meminta `/` maupun path lain. `WS_PATH` hanya dipakai Xray (VMess/VLESS/Trojan WS).
- Bridge dijalankan dua instance: `sshws` (plain, port 80) dan `sshws-tls` (TLS via cert Let's Encrypt, port 443).
- Xray listen langsung di 0.0.0.0 untuk WS (plain/TLS) dan gRPC; Trojan wajib TLS.
- Konfigurasi Xray dirender dari database user (`/etc/sshwsxray/xray_users.db`) setiap ada perubahan akun, lalu service di-restart otomatis.
- Cron tiap menit (`/usr/local/bin/sshwsxray-cron`): expire akun, limit IP, alert multi-login, auto reboot.

## Bridge WebSocket (`lib/sshws.py`)

Pengganti gost — ditulis dengan Python stdlib murni, tanpa dependency tambahan:

```bash
# websocket biasa (port 80) — path standar '/', tanpa path khusus
python3 lib/sshws.py --port 80  --target 127.0.0.1:22

# websocket secure (port 443)
python3 lib/sshws.py --port 443 --target 127.0.0.1:22 \
    --tls --cert /etc/sshwsxray/cert/fullchain.pem --key /etc/sshwsxray/cert/privkey.pem
```

| Flag | Fungsi | Default |
|------|--------|---------|
| `--port` | port listen (wajib) | — |
| `--path` | path WebSocket; `/` = terima semua path | `/` |
| `--target` | target TCP (sshd) | `127.0.0.1:22` |
| `--tls` `--cert` `--key` | aktifkan wss | nonaktif |
| `--max-connections` | batas koneksi bersamaan | 1024 |
| `--handshake-timeout` | timeout handshake | 10s |
| `--connect-timeout` | timeout konek ke sshd | 10s |
| `--verbose` | log debug | nonaktif |

Sudah ditangani: validasi header `Upgrade: websocket` + `Connection: Upgrade`,
balasan `Sec-WebSocket-Accept` (bila klien mengirim key), penerusan byte mentah
tanpa framing, data yang dipipelkan bersama handshake tetap utuh, TCP_NODELAY
(latensi SSH tetap rendah), penolakan request non-upgrade (400), dan TLS 1.2+.

Bila `--path` diisi selain `/`, pencocokan path ditegakkan lagi (path lain dibalas 404).

Test:

```bash
python3 tests/test_sshws.py     # 21 test: handshake '/', path bebas, mode ketat, echo mentah, pipelined, 1MB payload, TLS, konkurensi
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
ditanyakan saat instalasi atau diubah kapan saja lewat menu `sudo sshwsxray`.

Yang ditangani bagian bootstrap:
- menolak jalan bila bukan root, dan berhenti lebih awal bila OS bukan Debian/Ubuntu
- memasang `curl` sendiri bila belum ada
- berhenti dengan nama berkas yang gagal diunduh (tanpa melanjutkan ke instalasi)
- menghubungkan ulang stdin ke `/dev/tty`, sehingga pertanyaan domain tetap bisa dijawab walau script dibaca dari pipe

Yang ditangani bagian instalasi:
1. Deteksi OS/arch (amd64/arm64)
2. Install dependencies (curl, jq, python3, openssl, cron, openssh-server, speedtest-cli)
3. Tanya domain untuk SSL (opsional, harus sudah A-record ke IP VPS)
4. Konfigurasi sshd (port 22), pasang bridge WebSocket (`sshws`/`sshws-tls`), Xray-core, certbot
5. Render config Xray, pasang cron, salin aplikasi ke `/usr/local/lib/sshwsxray`, buat symlink `sshwsxray`

Daftar berkas yang diunduh dipatok di dalam `install.sh`; `tests/test_install.sh`
membandingkannya dengan isi repo, jadi berkas baru di `lib/` yang lupa
didaftarkan akan langsung ketahuan.

### Tanpa domain
Jalankan tanpa mengisi domain. wss/443 dan Trojan TLS tidak aktif; VMess WS dan VLESS WS tetap jalan. SSL bisa ditambahkan kapan saja dari **menu 5 → 8** (perintah dijalankannya `SSL_ONLY=1 install.sh`).

## Penggunaan

```bash
sudo sshwsxray
```

| Menu | Isi |
|------|-----|
| 1) SSH / SSH Websocket | buat, trial, renew, hapus, daftar, ganti password, user online |
| 2) Xray | buat/trial/renew/hapus akun VMess/VLESS/Trojan, link sharing, traffic, restart service, rebuild config |
| 3) Monitoring | info sistem, user online, cek masa aktif, speedtest |
| 4) Backup & Restore | backup tar.gz lokal (rotasi 5), kirim ke Telegram, restore |
| 5) Pengaturan | domain, path WS (Xray), limit IP, trial, auto reboot, Telegram bot, SSL |

## Port Default

| Port | Layanan |
|------|---------|
| 22 | OpenSSH |
| 80 | SSH over WebSocket (ws, bridge `sshws.service`, path standar `/`) |
| 443 | SSH over WebSocket Secure (wss, bridge `sshws-tls.service`, path standar `/`, butuh SSL) |
| 10085 | Xray stats API (localhost only) |
| 10086 | VMess WebSocket |
| 10087 | _(tidak dipakai — gRPC dihapus)_ |
| 10088 | VLESS WebSocket |
| 10089 | _(tidak dipakai — gRPC dihapus)_ |
| 10090 | _(tidak dipakai — Reality dihapus)_ |
| 10091 | Trojan WebSocket (TLS) |
| 10092 | _(tidak dipakai — gRPC dihapus)_ |

Semua port dapat diubah di `/etc/sshwsxray/config` lalu restart service.

Kalau `ufw` terpasang & aktif, installer membuka port-port di atas otomatis.
Kalau tidak, pastikan port tersebut terbuka di firewall/security group VPS
(pesan peringatan akan ditampilkan di akhir instalasi).

`WS_MAX_PER_IP` (default `16`) membatasi jumlah koneksi SSH-WebSocket
bersamaan dari satu alamat IP; isi `0` untuk mematikannya.

## File Penting

| Path | Fungsi |
|------|--------|
| `/etc/sshwsxray/config` | Konfigurasi global (domain, port, telegram, dll) |
| `/etc/sshwsxray/ssh_users.db` | Database user SSH |
| `/etc/sshwsxray/xray_users.db` | Database akun Xray |
| `/etc/sshwsxray/xray_traffic.db` | Snapshot traffic per akun |
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
