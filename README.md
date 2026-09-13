# sshwsxray — SSH Websocket + Xray-core Autoscript

Autoscript instalasi dan manajemen user untuk tunnel **SSH over WebSocket** dan **Xray-core (VMess / VLESS / Trojan)** dengan menu CLI di terminal, untuk VPS **Debian 10/11/12** dan **Ubuntu 20.04/22.04/24.04**.

## Fitur

**Manajemen akun**
- SSH & SSH WebSocket: buat / trial / renew / hapus / daftar / ganti password
- Xray VMess, VLESS, Trojan: buat / trial / renew / hapus / daftar, link sharing otomatis (ws, gRPC, Reality)
- Masa aktif otomatis (expired date), akun trial per-jam, renew menjumlah dari sisa masa aktif

**Keamanan & monitoring**
- Limit IP per akun SSH (via `netsense` + pemutusan sesi oleh cron)
- Deteksi multi-login (alert Telegram saat sesi ganda terdeteksi)
- Auto-hapus akun Xray yang expired + lock akun SSH expired
- Traffic per akun Xray via StatsService API Xray
- Info sistem: CPU, RAM, disk, uptime, status semua service
- Speedtest server

**Infrastruktur**
- SSH over WebSocket (ws port 80 / wss port 443) via [gost v3](https://github.com/go-gost/gost)
- Xray-core via installer resmi [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- VLESS Reality (stealth TLS tanpa butuh domain)
- SSL Let's Encrypt otomatis (certbot standalone) + renew hook
- Backup/restore lokal + kirim backup ke Telegram bot
- Notifikasi Telegram: akun dibuat/hapus/renew, trial, expired, multi-login, limit IP
- Auto reboot opsional tiap 05:00

## Arsitektur

```
Klien (HTTP-WS) ──► port 80/443  gost  forward+ws/wss ──► 127.0.0.1:22 (sshd)
Klien (Vmess/Vless/Trojan ws)  ──► port 10086/10088/10091 (Xray, path /<WS_PATH>)
Klien (Vmess/Vless/Trojan gRPC) ──► port 10087/10089/10092 (Xray, serviceName <WS_PATH>-grpc)
Klien (VLESS Reality)           ──► port 10090 (Xray, direct TLS, tanpa domain)
```

- gost listen WebSocket (plain di 80, TLS di 443) dan forward payload TCP ke sshd lokal — klien SSH-WS terhubung seperti SSH biasa.
- Xray listen langsung di 0.0.0.0 untuk WS (plain/TLS) dan gRPC; Trojan wajib TLS.
- Konfigurasi Xray dirender dari database user (`/etc/sshwsxray/xray_users.db`) setiap ada perubahan akun, lalu service di-restart otomatis.
- Cron tiap menit (`/usr/local/bin/sshwsxray-cron`): expire akun, limit IP, alert multi-login, auto reboot.

## Instalasi

```bash
sudo bash setup.sh
```

Installer akan:
1. Deteksi OS/arch (amd64/arm64)
2. Install dependencies (curl, jq, python3, openssl, cron, openssh-server, speedtest-cli)
3. Tanya domain untuk SSL (opsional, harus sudah A-record ke IP VPS)
4. Konfigurasi sshd (port 22), install gost, Xray-core, certbot
5. Render config Xray, pasang cron, buat symlink `sshwsxray`

### Tanpa domain
Jalankan tanpa mengisi domain. wss/443 dan Trojan TLS tidak aktif; VMess/VLESS ws+gRPC dan VLESS Reality tetap jalan. SSL bisa ditambahkan kapan saja dari **menu 5 → 9** (`setup.sh --ssl-only`).

## Penggunaan

```bash
sudo sshwsxray
```

| Menu | Isi |
|------|-----|
| 1) SSH / SSH Websocket | buat, trial, renew, hapus, daftar, ganti password, user online |
| 2) Xray | buat/trial/renew/hapus akun VMess/VLESS/Trojan, link sharing, traffic, restart service |
| 3) Monitoring | info sistem, user online, cek masa aktif, speedtest |
| 4) Backup & Restore | backup tar.gz lokal (rotasi 5), kirim ke Telegram, restore |
| 5) Pengaturan | domain, path WS, limit IP, trial, auto reboot, Telegram bot, Reality key, SSL |

## Port Default

| Port | Layanan |
|------|---------|
| 22 | OpenSSH |
| 80 | SSH over WebSocket (ws, gost) |
| 443 | SSH over WebSocket Secure (wss, gost, butuh SSL) |
| 10085 | Xray stats API (localhost only) |
| 10086 | VMess WebSocket |
| 10087 | VMess gRPC |
| 10088 | VLESS WebSocket |
| 10089 | VLESS gRPC |
| 10090 | VLESS Reality |
| 10091 | Trojan WebSocket (TLS) |
| 10092 | Trojan gRPC (TLS) |

Semua port dapat diubah di `/etc/sshwsxray/config` lalu restart service.

## File Penting

| Path | Fungsi |
|------|--------|
| `/etc/sshwsxray/config` | Konfigurasi global (domain, port, telegram, dll) |
| `/etc/sshwsxray/ssh_users.db` | Database user SSH |
| `/etc/sshwsxray/xray_users.db` | Database akun Xray |
| `/etc/sshwsxray/xray_traffic.db` | Snapshot traffic per akun |
| `/etc/sshwsxray/reality.keys` | Key VLESS Reality |
| `/usr/local/etc/xray/config.json` | Config Xray (dirender otomatis) |
| `/etc/systemd/system/gost-websocket*.service` | Unit systemd gost |
| `/root/backup/` | Arsip backup |

## Telegram Bot

1. Buat bot via [@BotFather](https://t.me/BotFather), salin token
2. Kirim pesan ke bot kamu (agar chat id terdaftar)
3. Ambil chat id via `https://api.telegram.org/bot<TOKEN>/getUpdates`
4. Isi token + chat id di **menu 5 → 6**

Coba test dengan **menu 5 → 7**.

## Catatan Keamanan

- `PermitRootLogin yes` dipakai secara default ala autoscript klasik — disarankan ganti ke `prohibit-password` dan pakai key SSH.
- Semua `.db` dan key disimpan dengan permission `600`, direktori data `700`.
- Limit IP via cron punya jeda sampai 60 detik; untuk enforcement real-time, integrasikan `netsense` langsung di PAM.
- Backup berisi `/etc/shadow` — jaga file backup & chat Telegram bot kamu.

## Uninstall

```bash
sudo bash uninstall.sh
```

Menghapus service gost/Xray, binary, cron, dan `/etc/sshwsxray`, lalu restore sshd_config dari backup.
