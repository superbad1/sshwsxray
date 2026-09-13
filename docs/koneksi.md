# Panduan Koneksi Klien

Panduan menghubungkan aplikasi klien ke server yang di-install sshwsxray autoscript. Ganti `DOMAIN` dengan domain kamu (atau IP VPS), `PORT` sesuai output menu, dan `UUID`/password sesuai akun.

## Port Ringkas

| Layanan | Port | TLS | Catatan |
|---------|------|-----|---------|
| SSH langsung | 22 | - | client SSH biasa |
| SSH over WS | 80 | tidak | path standar `/` (tanpa path khusus) |
| SSH over WSS | 443 | ya | path standar `/` (tanpa path khusus) |
| VMess WS | 10086 | tidak | path `/<WS_PATH>` |
| VLESS WS | 10088 | tidak | path `/<WS_PATH>` |
| Trojan WS | 10091 | ya | path `/<WS_PATH>`, wajib domain+SSL |

> Transport yang dipakai **hanya WebSocket**. Port gRPC (10087/10089/10092) dan VLESS Reality (10090) tidak lagi dipakai, jadi tidak perlu dibuka di firewall.

## 1. SSH langsung (port 22)

```bash
ssh user@DOMAIN
# atau dengan password:
sshpass -p 'PASSWORD' ssh user@DOMAIN
```

## 2. SSH over WebSocket

Klien HTTP-WS (mis. aplikasi "HTTP Custom", "HTTP Injector", "v2rayNG plugin", atau `ws` tunnel client) dengan payload upgrade:

```
CONNECT [host][port] HTTP/1.0[crlf][crlf]
```

atau payload WebSocket standar:

```
GET / HTTP/1.1[crlf]Host: DOMAIN[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

Pengaturan:
- **Mode**: SSH over Websocket
- **Host/Address**: `DOMAIN` (atau IP)
- **Port**: `80` (ws) atau `443` (wss/SSL)
- **Path**: `/` (standar; path lain juga diterima / boleh dikosongkan)
- **SSH target**: port 22 di belakang tunnel

Setelah tunnel hidup, koneksi SSH berjalan di atasnya seperti SSH biasa.

## 3. VMess

**VMess WS** — link dari menu (atau manual):
```
vmess://<base64 dari JSON di bawah>
```
```json
{
  "v": "2",
  "ps": "nama-akun",
  "add": "DOMAIN",
  "port": "10086",
  "id": "UUID-KAMU",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "DOMAIN",
  "path": "/<WS_PATH>",
  "tls": ""
}
```

Aplikasi: v2rayNG (Android), v2box / Shadowrocket / Streisand (iOS), v2rayN (Windows), V2RayXS (macOS). Import link atau isi manual.

## 4. VLESS

**VLESS WS**:
```
vless://UUID@DOMAIN:10088?path=%2F<WS_PATH>&security=none&encryption=none&type=ws#nama-akun
```

## 5. Trojan (wajib domain + SSL)

**Trojan WS**:
```
trojan://PASSWORD@DOMAIN:10091?path=%2F<WS_PATH>&security=tls&sni=DOMAIN&type=ws#nama-akun
```

Aplikasi: sama dengan VMess/VLESS (semuanya mendukung trojan).

## Troubleshooting

| Gejala | Cek |
|--------|-----|
| SSH WS tidak konek | `systemctl status sshws`; cek log `journalctl -u sshws -n 30`; SSH-WS tanpa path khusus, jadi pakai path `/` |
| WSS gagal tapi WS jalan | cert SSL: `ls /etc/sshwsxray/cert/`; port 443 tidak keblokir ISP? |
| Trojan hilang dari config | Trojan butuh cert SSL; tanpa cert inbound-nya di-skip otomatis |
| Akun valid tapi tidak bisa internet | cek `journalctl -u xray -n 50`; cek IP limit/multi-login via menu monitoring |
| Port ditolak | buka port di firewall/security group: `ufw allow 80,443,10086,10088,10091/tcp` |
| Config lama masih ada gRPC/Reality | menu 2 (Xray) → 9) Rebuild config + restart |
