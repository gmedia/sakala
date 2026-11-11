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

`/etc/sakala/agent.env` berisi batas node, misalnya jumlah container aktif (`SAKALA_MAX_ACTIVE_CONTAINERS`, dihitung installer dari memori server: memori dikurangi 2 GB, dibagi 256 MB, antara 2 dan 20). File itu ditulis ulang setiap `install.sh` atau `upgrade.sh` berjalan; ubah `SAKALA_MAX_ACTIVE_CONTAINERS` di `/etc/sakala/sakala.env` kalau perlu angka lain. Batas per user, misalnya jumlah project, diatur API lewat `api.local.env` (`SAKALA_MAX_PROJECTS_PER_USER`, default 3).
