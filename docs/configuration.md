# Konfigurasi setelah instalasi

Installer sengaja hanya menanyakan domain, email admin, dan kunci backup. Sisanya diatur di `/etc/sakala/secrets/api.local.env`, file yang dibaca setelah `api.env` dan tidak pernah ditimpa script. Setelah mengubahnya:

```bash
sudo sakala-compose up -d
```

Compose hanya membuat ulang service yang konfigurasinya berubah.

## Email

Tanpa mailer, email verifikasi dan reset kata sandi hanya muncul di log API (`sudo sakala-compose logs api`). Admin pertama sudah terverifikasi, jadi bisa login, tetapi orang lain yang mendaftar tidak bisa memverifikasi emailnya. Isi SMTP sebelum mengundang orang lain:

```dotenv
MAIL_MAILER=smtp
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=isi-username
MAIL_PASSWORD=isi-password
MAIL_FROM_ADDRESS=noreply@example.com
```

## GitHub App (opsional)

Tanpa GitHub App, orang men-deploy repository publik lewat URL. GitHub App dibutuhkan untuk login dengan GitHub, repository private, dan deploy otomatis saat push.

1. Buat GitHub App di akun atau organisasimu (Settings, Developer settings, GitHub Apps).
2. Isi URL berikut, dengan `example.com` diganti domainmu:
   - Callback URL: `https://api.example.com/auth/github/callback`
   - Setup URL: `https://api.example.com/auth/github/setup`, centang "Redirect on update"
   - Webhook URL: `https://api.example.com/api/v1/webhooks/github`, dengan webhook secret acak
3. Permission yang dipakai API: repository `Contents` read-only dan `Metadata` read-only, serta account `Email addresses` read-only untuk login. Event webhook: `Push`, plus event installation yang dikirim GitHub secara default. Daftar ini disusun dari dokumentasi `sakala-api` (`docs/AUTHENTICATION.md`) dan belum diuji pada instalasi self-host.
4. Buat private key, lalu tempel isinya ke file yang sudah disiapkan installer, tanpa mengubah pemilik dan mode-nya (dibaca uid 82 di image API):

   ```bash
   sudo tee /etc/sakala/secrets/github-app.pem > /dev/null < ~/downloads/nama-app.private-key.pem
   ```

5. Isi `api.local.env`:

   ```dotenv
   GITHUB_APP_ID=123456
   GITHUB_APP_SLUG=nama-app
   GITHUB_APP_CLIENT_ID=isi-client-id
   GITHUB_APP_CLIENT_SECRET=isi-client-secret
   GITHUB_APP_WEBHOOK_SECRET=isi-webhook-secret
   ```

## Batas anonim GitHub

Membaca repository publik tanpa token memakai batas anonim GitHub, 60 request per jam untuk seluruh server. Buat fine-grained token read-only untuk repository publik saja, lalu isi `GITHUB_PUBLIC_API_TOKEN` di `api.local.env`.

## Login Google (opsional)

Isi `GOOGLE_CLIENT_ID` dan `GOOGLE_CLIENT_SECRET` di `api.local.env`. Redirect URI di Google Cloud Console: `https://api.example.com/auth/google/callback`.

## Batas project

`/etc/sakala/agent.env` berisi batas node, misalnya jumlah container aktif (`SAKALA_MAX_ACTIVE_CONTAINERS`, dihitung installer dari memori server: memori dikurangi 2 GB, dibagi 256 MB, antara 2 dan 20). File itu ditulis ulang setiap `install.sh` atau `upgrade.sh` berjalan; ubah `SAKALA_MAX_ACTIVE_CONTAINERS` di `/etc/sakala/sakala.env` kalau perlu angka lain. Batas per workspace pribadi, misalnya jumlah project, diatur API lewat `api.local.env` (`SAKALA_MAX_PROJECTS_PER_USER`, default 3; namanya lebih tua dari fitur workspace). Team tanpa limit profile memakai `SAKALA_TEAM_MAX_PROJECTS`, `SAKALA_TEAM_MAX_ACTIVE_CONTAINERS`, dan `SAKALA_TEAM_MAX_ACTIVE_DEPLOYMENTS` (default 2, 2, dan 1). Admin bisa memberi batas lain lewat limit profile di area admin Console.

## Replika

Satu project bisa berjalan sebagai beberapa container dari image yang sama. Runtime router membagi request ke semuanya (`least_conn`), mencoba replika lain kalau satu gagal, dan agent menyalakan lagi replika yang berhenti. Deploy berjalan bergulir: route baru pindah setelah semua replika baru siap. Semua replika berjalan di server ini, jadi replika melindungi dari aplikasi yang crash atau di-restart, bukan dari server yang mati.

Defaultnya satu replika per project. Untuk mengizinkan lebih:

1. Di area admin Console, buka Profil batas dan buat profil dengan "Maks. replika" (`max_replicas`, 1 sampai 10).
2. Pasang profil itu ke workspace yang boleh memakainya.
3. Pemilik project mengisi jumlah replika di pengaturan project, lalu men-deploy ulang. Jumlah baru berlaku mulai deploy berikutnya.

Ada tiga batas yang berlaku bersamaan:

| Batas | Tempat | Default |
| --- | --- | --- |
| Replika per project untuk workspace | `max_replicas` di limit profile | 1 (tanpa profil) |
| Replika per deploy yang diterima agent | `SAKALA_MAX_REPLICAS_PER_PROJECT` di `agent.env` | 4 |
| Container aktif di server ini, setiap replika dihitung satu | `SAKALA_MAX_ACTIVE_CONTAINERS` di `sakala.env` | dihitung dari memori |

Deploy yang meminta lebih dari batas agent gagal dengan `runtime_replicas_exceeded`, dan yang melebihi kapasitas server gagal dengan `runtime_capacity_exceeded`. `agent.env` ditulis ulang setiap `install.sh` atau `upgrade.sh`, jadi kalau perlu batas agent lain, ubah template-nya lewat pull request atau tanyakan dulu di Discussions.

Replika hanya cocok untuk aplikasi stateless. File yang ditulis ke disk container dan session di memori tidak dibagi antar replika.

## Sleep otomatis

Sleep otomatis menghentikan project yang tidak menerima request selama sekian menit, dan menyalakannya lagi saat diminta. Container dan route-nya disimpan, jadi alamat project tetap. Di instalasi ini sleep mati: `api.env` berisi `SAKALA_PROJECT_IDLE_SLEEP_MINUTES=0`.

Sebelum menyalakannya, ketahui batasannya di satu server: **sampai agent mendukung `SAKALA_PUBLIC_API_URL`, membuka project yang sedang tidur belum membangunkannya.** Halaman tunggu yang dipasang agent meminta wake ke alamat `SAKALA_API_URL` milik agent, dan di sini alamat itu adalah API lewat loopback (`http://127.0.0.1:8100`), yang tidak bisa dijangkau browser pengunjung. Pengunjung melihat halaman "Proyek sedang dinyalakan" selama sekitar 2 menit, lalu "Proyek belum bisa dinyalakan". Project tetap bisa dinyalakan dari Console oleh pemiliknya. Batasan ini berlaku sampai rilis sakala-agent yang mendukung `SAKALA_PUBLIC_API_URL` (alamat API publik untuk halaman tunggu) dipin di `versions.env`; installer akan mengisinya dengan `https://api.<domain>`.

Kalau tetap ingin memakainya:

- Untuk semua workspace, isi menit di `api.local.env`, misalnya `SAKALA_PROJECT_IDLE_SLEEP_MINUTES=30`, lalu `sudo sakala-compose up -d`.
- Untuk sebagian workspace, biarkan nilai global `0`, lalu isi "Tidur otomatis (menit)" (`idle_sleep_minutes`) di limit profile workspace itu. Kosong berarti ikut nilai global, `0` berarti tidak pernah tidur.

Trafik diukur dari counter request per hostname di runtime router (`metrics { per_host }` di `caddy/runtime.Caddyfile`), yang tidak pernah dibuka ke luar server.

## Tautan di email

Footer setiap email menautkan kebijakan privasi dan syarat layanan di `<SAKALA_LANDING_URL>/privasi` dan `/syarat`, dan header-nya memuat logo dari `SAKALA_MAIL_LOGO_URL`. Keduanya default ke situs Sakala hosted (`https://sakala.dev`). Kalau instalasimu punya kebijakan sendiri, isi keduanya di `api.local.env`; logonya PNG 280 x 118 lewat HTTPS.

## Domain Console dan project

Dua file berikut ditulis ulang installer dari domainmu setiap `install.sh` atau `upgrade.sh` berjalan, jadi jangan diedit:

- `/etc/sakala/console.env` berisi `PUBLIC_API_URL`, `PUBLIC_APP_URL`, dan `PUBLIC_REVERB_*`. Console membacanya saat container start dan menimpa nilai yang tertanam di image, jadi browser memanggil `https://api.<domain>`. Semua nilainya publik; `PUBLIC_REVERB_KEY` adalah app key publik Reverb, bukan secret-nya.
- `/etc/sakala/agent.env` berisi `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.<domain>`, nilai yang sama dengan `SAKALA_PROJECT_DEFAULT_DOMAIN` di `api.env`. Agent menolak deploy dengan `invalid_runtime_command` untuk domain di luar suffix itu.

Keduanya wajib. Tanpa `SAKALA_PROJECT_DEFAULT_DOMAIN`, API v0.6.0 ke atas memberi project baru alamat `<nama>.sakala.app` milik Sakala hosted, dan tanpa `SAKALA_PROJECT_DOMAIN_SUFFIXES`, agent v0.8.0 ke atas hanya menerima domain Sakala hosted. Jangan menimpa salah satunya di `api.local.env`.

`agent.env` tidak mengisi `SAKALA_AGENT_EDGE_ADDRESS` dan `SAKALA_AGENT_REGION`. Keduanya hanya dipakai Sakala Edge dan penempatan per region di Sakala dengan beberapa server runtime, yang belum didukung repository ini.
