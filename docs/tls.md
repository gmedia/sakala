# TLS untuk project: `*.run.<domain>`

`app.<domain>` dan `api.<domain>` mendapat sertifikat Let's Encrypt biasa lewat edge Caddy. Yang perlu dipilih hanya cara project mendapat sertifikat, karena nama `<project>.run.<domain>` baru ada setelah orang men-deploy. Untuk instalasi publik, installer punya dua mode. Mode ketiga, `internal`, hanya untuk tes dan jaringan privat; lihat [bagian terakhir](#mode-internal-hanya-untuk-tes-dan-jaringan-privat).

| | `on-demand` (default) | `dns` |
| --- | --- | --- |
| Sertifikat | satu per hostname project, diminta saat kunjungan pertama | satu wildcard `*.run.<domain>` |
| Butuh dari DNS | record `*.run.<domain>` ke server | record yang sama, plus token API DNS provider |
| Provider DNS | apa saja | yang punya modul `caddy-dns` |
| Kunjungan pertama ke project baru | beberapa detik lebih lambat | langsung |
| Batas Let's Encrypt | 50 sertifikat baru per domain terdaftar per minggu | satu sertifikat |

Pilih `dns` kalau instalasi akan punya lebih dari sekitar 40 project baru per minggu, atau kalau domainnya juga dipakai layanan lain yang meminta banyak sertifikat.

## Mode `on-demand`

Caddy hanya meminta sertifikat untuk hostname yang lolos pertanyaan `ask`. Tanpa penjaga itu, siapa pun bisa membuka `acak-123.run.<domain>` berkali-kali dan menghabiskan kuota Let's Encrypt domainmu.

Saat ini penjaganya ada di edge sendiri, tanpa bantuan API (`caddy/edge.Caddyfile`, situs `127.0.0.1:5555`):

1. Caddy bertanya `GET /tls-ask?domain=<hostname>` ke situs internal di container edge.
2. Situs itu menolak nama di luar `.run.<domain>`, lalu mengirim `HEAD /` ke runtime router dengan `Host: <hostname>`.
3. Runtime router (`caddy/runtime.Caddyfile`) menjawab hostname yang tidak punya route dengan `404` dan header `X-Sakala-Route: missing`. Jawaban dengan header itu berarti tolak, jawaban lain berarti boleh.

Jadi sertifikat hanya diminta untuk project yang route-nya sudah ditulis agent, termasuk project yang aplikasinya sendiri menjawab `404`. `tests/edge-tls.sh` membuktikan ini dengan Caddy sungguhan.

Konsekuensinya: pertanyaan `ask` mengirim satu `HEAD /` ke aplikasi project saat sertifikatnya pertama kali diminta. Project yang menolak `HEAD` tetap lolos, karena yang dilihat hanya header dari router.

### Yang sebaiknya ditambahkan di API

Router hanya tahu project yang sudah berhasil di-deploy. API tahu lebih awal dan bisa menjadi satu sumber kebenaran, termasuk nanti untuk custom domain. `sakala-api` v0.3.0 belum punya endpoint yang bisa ditanya Caddy. Usulannya:

```text
GET /api/v1/tls/ask?domain=<hostname>
```

- **Jawaban:** `200` tanpa body kalau `domain` sama persis dengan `default_domain` project yang belum dihapus (soft delete dihitung sebagai dihapus). Selain itu `404`. Parameter yang hilang, kosong, atau bukan hostname: `422`.
- **Pencocokan:** huruf kecil, tanpa port, tanpa titik di akhir. Tidak ada wildcard.
- **Auth:** tanpa auth, karena Caddy tidak bisa mengirim kredensial. Yang bocor hanya "project dengan hostname ini ada", dan hostname project memang publik.
- **Rate limit:** throttle sendiri yang longgar (misalnya 120 per menit per IP), karena Caddy sudah membatasi permintaan on-demand dan hanya bertanya untuk hostname yang belum punya sertifikat.
- **Bukan bagian dari kontrak Console:** tidak perlu masuk OpenAPI publik.
- **Nanti, custom domain:** endpoint yang sama menjawab `200` untuk domain milik project yang sudah terverifikasi.

Setelah endpoint itu ada di versi API yang dipin, ganti blok global di `caddy/edge.Caddyfile` menjadi `ask http://api-web:8080/api/v1/tls/ask` dan hapus situs `127.0.0.1:5555`.

## Mode `dns`

```bash
sudo SAKALA_DNS_API_TOKEN=... ./install.sh --tls dns --dns-provider cloudflare
```

Installer membangun image edge dengan modul DNS lewat `caddy/Dockerfile.dns` (xcaddy, beberapa menit, butuh sekitar 1 GB memori sementara), menyimpan token di `/etc/sakala/secrets/dns.env` (mode `0600`, hanya dibaca container edge), dan menulis `/etc/sakala/edge/run-tls.caddy`.

Hanya `cloudflare` yang modulnya sudah dipin (`github.com/caddy-dns/cloudflare@v0.2.4`). Untuk Cloudflare, buat token dengan izin `Zone:DNS:Edit` untuk zona domainmu saja.

Provider lain:

```bash
sudo SAKALA_DNS_API_TOKEN=... ./install.sh --tls dns \
  --dns-provider <nama> --dns-module github.com/caddy-dns/<nama>@<versi>
```

Baris `dns <nama> {env.SAKALA_DNS_API_TOKEN}` cocok untuk modul yang menerima token sebagai satu-satunya argumen. Untuk provider yang butuh field lain, ubah `/etc/sakala/edge/run-tls.caddy` sesuai README modulnya, simpan nilai tambahannya di `/etc/sakala/secrets/dns.env`, lalu `sudo sakala-compose up -d edge`. Installer tidak menimpa file itu selama mode dan provider tidak berubah. Kombinasi selain Cloudflare belum diuji.

## Uji coba tanpa menghabiskan kuota

Untuk instalasi percobaan, arahkan edge ke Let's Encrypt staging. Sertifikatnya tidak dipercaya browser, tapi kuotanya terpisah:

```bash
sudo sed -i 's|^SAKALA_ACME_CA=.*|SAKALA_ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory|' /etc/sakala/sakala.env
sudo sakala-compose up -d edge
```

## Mode `internal`: hanya untuk tes dan jaringan privat

```bash
sudo ./install.sh --domain sakala.test --email admin@sakala.test --age-recipient age1... --tls internal --yes
```

Semua hostname, termasuk `app.` dan `api.`, mendapat sertifikat dari CA lokal Caddy, bukan dari Let's Encrypt. Tidak ada request ACME, jadi server tidak perlu nama DNS publik maupun port yang terbuka dari internet. Itulah yang dipakai tes end-to-end di runner GitHub (`.github/workflows/install-e2e.yml`).

**Jangan pakai untuk instalasi publik.** Browser dan klien lain menolak sertifikatnya sampai root CA itu dipercaya secara manual di setiap perangkat, dan siapa pun yang memegang kunci CA di volume edge bisa menerbitkan sertifikat yang dipercaya perangkat tersebut. Installer mencetak peringatan setiap kali mode ini dipilih.

Yang ditulis installer:

- `/etc/sakala/edge/global.d/00-sakala-tls-internal.caddy` berisi `local_certs` dan `skip_install_trust`. File ini milik installer dan dihapus kalau mode diganti; opsi global milikmu taruh di file lain di `global.d`.
- `/etc/sakala/edge/run-tls.caddy` berisi `tls internal`, satu sertifikat wildcard untuk `*.run.<domain>`.

Root CA ada di volume edge. Ambil, lalu percayai di klien yang perlu, atau berikan langsung ke `curl`:

```bash
sudo sakala-compose exec -T edge cat /data/caddy/pki/authorities/local/root.crt > sakala-local-ca.crt
curl --cacert sakala-local-ca.crt https://api.sakala.test/up
```

Hostname tetap harus mengarah ke server, misalnya lewat DNS internal atau `/etc/hosts`. Mengganti mode dengan menjalankan ulang installer (`--tls on-demand` atau `--tls dns`) menulis ulang kedua file di atas dan me-restart edge.
