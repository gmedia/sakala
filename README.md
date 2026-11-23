# Sakala

Pasang dan jalankan Sakala di server sendiri. Repository ini adalah distribusi, bukan source code: installer, Compose, versi yang dipin, backup, dan dokumentasi self-host. Source tiap komponen ada di repository masing-masing ([sakala-api](https://github.com/gmedia/sakala-api), [sakala-console](https://github.com/gmedia/sakala-console), [sakala-agent](https://github.com/gmedia/sakala-agent)).

> **Status: versi pertama, terbukti terpasang di VM Ubuntu 24.04 bersih (VM GitHub Actions, dan untuk pin pertama 2026-11-18, dengan API v0.6.0, juga VM QEMU/KVM lokal), belum di server sungguhan.** Setiap pull request yang menyentuh installer menjalankan `install.sh`, deploy satu project di bawah gVisor, `upgrade.sh`, dan `uninstall.sh` di VM baru ([install-e2e](.github/workflows/install-e2e.yml)), dengan domain self-hosted `sakala.test` lewat `/etc/hosts` dan sertifikat dari CA lokal (`--tls internal`), karena runner tidak punya DNS publik. Tes itu juga membuka Console di Chrome dan memastikan Console memanggil `api.sakala.test`, bukan API Sakala hosted, menidurkan project lalu membangunkannya dari Chrome, dan men-deploy ulang dari image yang live. Workflow kedua ([upgrade-e2e](.github/workflows/upgrade-e2e.yml)) memasang pin sebelumnya, men-deploy project, lalu meng-upgrade ke pin sekarang dengan `upgrade.sh`. Yang belum terbukti: Let's Encrypt, server sungguhan dengan DNS publik, dan restore ke server sungguhan; lihat [Batasan saat ini](#batasan-saat-ini).

English: [jump to the English section](#english).

## Untuk siapa

Untuk kampus, komunitas, atau tim kecil yang ingin menjalankan Sakala sendiri di satu server: mahasiswa men-deploy aplikasi dari GitHub, dan setiap aplikasi mendapat alamat `https://<nama>.run.<domain>`. Semua komponen ada di satu server, seperti staging Sakala. Kalau butuh memisahkan control plane dari aplikasi pengguna, ini belum versinya.

## Kebutuhan

- Server baru Ubuntu 24.04 atau 26.04, x86_64, minimal 2 vCPU dan 4 GB RAM, disk 40 GB atau lebih. VM biasa cukup; gVisor memakai platform `systrap` dan tidak butuh nested virtualization.
- Akses root, port 80 dan 443 terbuka dari internet.
- Docker boleh belum ada. Kalau sudah ada (paket `docker-ce`, `docker.io` Ubuntu, atau `moby-engine`), installer memakainya selama daemon-nya rootful, Docker Engine minimal 24.0, plugin Compose minimal 2.24, dan buildx terpasang. Kalau tidak memenuhi, atau Docker terpasang sebagai snap, installer berhenti dan menyebut yang kurang. Installer tidak pernah mengganti atau menghapus Docker yang tidak dipasangnya sendiri.
- Domain yang kamu kelola, misalnya `sakala.example.com`, dengan tiga record DNS ke IP server:

  | Record | Untuk |
  | --- | --- |
  | `app.sakala.example.com` | Console |
  | `api.sakala.example.com` | API, realtime, avatar |
  | `*.run.sakala.example.com` | aplikasi yang di-deploy |

- Pasangan kunci [age](https://github.com/FiloSottile/age) untuk backup, dibuat di komputermu sendiri:

  ```bash
  age-keygen -o sakala-backup.key   # simpan di password manager, jangan di server
  age-keygen -y sakala-backup.key   # kunci publik age1..., yang diberikan ke installer
  ```

## Yang dipasang

| Komponen | Bentuk |
| --- | --- |
| Docker Engine (rootful) | paket dari download.docker.com, atau paket Ubuntu kalau rilisnya belum tersedia di sana; Docker yang sudah ada dipakai kalau memenuhi syarat di atas. `/etc/docker/daemon.json` yang sudah ada dipertahankan; installer hanya menambahkan `default-address-pools` (dan `log-driver: local` kalau belum diatur), menyimpan salinan `.bak-<waktu>`, lalu me-restart Docker |
| gVisor (`runsc`) | rilis yang dipin, dicek dengan `.sha512` rilis dan pin di `versions.env`; didaftarkan ke Docker dengan batas tulis 1 GB per container (`SAKALA_GVISOR_OVERLAY_SIZE`) |
| PostgreSQL, Valkey, RustFS | container, data di Docker volume |
| API, worker queue, scheduler, Reverb, Console | container dari `ghcr.io/gmedia`, dipin dengan digest |
| Runtime router | Caddy di container `sakala-caddy`, route ditulis agent; membagi trafik ke semua replika project |
| Edge publik | Caddy di port 80 dan 443 (service `edge`), HTTPS otomatis dari Let's Encrypt, meneruskan `*.run.<domain>` langsung ke runtime router. Ini bukan Sakala Edge; lihat [Sakala Edge](#sakala-edge-tidak-dipasang) |
| Sakala Agent | binary di `/usr/local/bin`, dicek dengan `SHA256SUMS` rilis dan pin di `versions.env`, berjalan sebagai `sakala-agent.service` |
| Backup harian | `sakala-backup.timer`, 02.00 WIB, terenkripsi ke kunci publik age-mu |

Setiap aplikasi pengguna berjalan di bawah gVisor, di network Docker-nya sendiri, dengan batas memori, CPU, dan jumlah proses.

Lokasi file di server:

```text
/opt/sakala/              repository ini (installer, Compose, versions.env)
/etc/sakala/              konfigurasi; secrets/ bermode 0700, isinya 0600
/var/lib/sakala/          workspace agent, route project, backups/
```

## Instalasi

```bash
sudo git clone --branch <tag-rilis> https://github.com/gmedia/sakala.git /opt/sakala
cd /opt/sakala
sudo ./install.sh
```

Installer menanyakan domain, email admin, dan kunci publik age. Untuk instalasi tanpa tanya-jawab:

```bash
sudo ./install.sh --domain sakala.example.com --email admin@example.com \
  --age-recipient age1... --yes
```

Yang dilakukannya, berurutan: memeriksa OS dan resource, memasang paket dasar, Docker, dan gVisor, membuat secret secara lokal (mode `0600`), menyalakan control plane, menjalankan migrasi, membuat admin pertama, mendaftarkan agent, memasang timer backup, lalu mencetak URL serta kata sandi admin. Menjalankannya lagi aman: secret, kredensial agent, dan pengaturanmu dipertahankan.

Setelah selesai, buka `https://app.<domain>` dan login dengan email serta kata sandi yang dicetak. Simpan kata sandi itu, lalu hapus `/etc/sakala/secrets/initial-admin-password`. Sertifikat diminta saat tiap hostname pertama kali dibuka, jadi kunjungan pertama bisa lebih lambat beberapa detik.

Pengaturan lanjutan, seperti SMTP, GitHub App, login Google, batas build per jam, replika, sleep otomatis, release command, redeploy tanpa build, metrik, dan database terkelola, ada di [docs/configuration.md](docs/configuration.md). Pengaturan API ditulis di `/etc/sakala/secrets/api.local.env` dan pengaturan agent di `/etc/sakala/secrets/agent.local.env`; script tidak pernah menimpa keduanya. Tanpa SMTP, email hanya masuk ke log API.

### Replika dan sleep otomatis

Keduanya mati setelah instalasi, dan admin yang menyalakannya:

- **Replika.** Satu project bisa berjalan sebagai beberapa container di server ini, dan runtime router membagi pengunjung ke semuanya. Setiap project dibatasi satu replika sampai admin membuat limit profile dengan `max_replicas` lebih dari 1 di area admin Console (Profil batas) lalu memasangnya ke workspace. Setiap replika dihitung sebagai satu container aktif, jadi batas node `SAKALA_MAX_ACTIVE_CONTAINERS` tetap berlaku. Hanya cocok untuk aplikasi stateless.
- **Sleep otomatis.** `SAKALA_PROJECT_IDLE_SLEEP_MINUTES=0` di `api.env`, jadi tidak ada project yang ditidurkan. Kalau dinyalakan, pengunjung yang membuka project yang sedang tidur membangunkannya lewat `https://api.<domain>` (`SAKALA_PUBLIC_API_URL` di `agent.env`). Caranya ada di [docs/configuration.md](docs/configuration.md#sleep-otomatis).

### Database terkelola (mati)

Database PostgreSQL terkelola dari API v0.9.0 dan agent v0.12.0 tidak ditawarkan di instalasi ini: `api.env` berisi `SAKALA_DATABASE_DEFAULT_MAX_COUNT=0`, agent tidak menjalankan peran database, dan Console menyebut database belum tersedia di server ini. Aplikasi tetap bisa memakai database yang kamu kelola sendiri lewat environment variable. Menyalakannya butuh instance PostgreSQL terpisah dengan TLS dan backup sendiri; gambaran langkahnya ada di [docs/configuration.md](docs/configuration.md#database-terkelola) dan belum diuji repository ini.

### Sakala Edge (tidak dipasang)

Sakala Edge adalah service yang menyusun route `*.<domain>` ke runtime router beberapa node, untuk Sakala dengan lebih dari satu server runtime. Di satu server, edge publik meneruskan `*.run.<domain>` langsung ke runtime router di server yang sama, jadi Sakala Edge tidak dibutuhkan dan installer tidak memasangnya, walaupun binary `sakala-edge` ikut di rilis agent. `SAKALA_AGENT_EDGE_ADDRESS` dan `SAKALA_AGENT_REGION` di `agent.env` sengaja kosong. Instalasi multi-node belum didukung repository ini.

### Alamat pengunjung di aplikasi

Aplikasi menerima `X-Forwarded-Proto: https` dan alamat pengunjung di `X-Forwarded-For`. Edge mengganti header `X-Forwarded-*` yang dikirim pengunjung, dan runtime router hanya mempertahankannya kalau datang dari edge, yaitu dari subnet network `sakala-runtime` yang ditulis installer ke `SAKALA_RUNTIME_TRUSTED_PROXIES` di `/etc/sakala/sakala.env`. Sejak agent v0.14.0, route setiap project mengisi `X-Forwarded-For` dan `X-Real-IP` dengan alamat pengunjung saja, jadi aplikasi yang hanya mempercayai hop terdekat, seperti Laravel dengan `trustProxies(at: '*')`, melihat alamat pengunjung yang benar. Instalasi lama mendapat pengaturan ini dari `upgrade.sh`, yang membuat ulang runtime router, jadi project tidak terjangkau sebentar sampai agent menyambungkan router lagi ke network project. Detailnya di [docs/configuration.md](docs/configuration.md#alamat-pengunjung-dan-header-x-forwarded-).

### TLS untuk project

Defaultnya, setiap project mendapat sertifikat sendiri saat pertama kali dibuka, dan hanya kalau agent sudah menulis route untuk hostname itu. Cara ini bekerja dengan provider DNS apa pun. Alternatifnya, satu sertifikat wildcard lewat DNS provider:

```bash
sudo SAKALA_DNS_API_TOKEN=... ./install.sh --tls dns --dns-provider cloudflare
```

Perbandingan, cara kerjanya, dan endpoint yang sebaiknya ditambahkan di API ada di [docs/tls.md](docs/tls.md). Di sana juga ada mode `--tls internal`, yang memakai CA lokal Caddy untuk tes dan jaringan privat. Mode itu tidak untuk instalasi publik.

## Upgrade

```bash
cd /opt/sakala
sudo git fetch --tags
sudo git checkout <tag-baru>
sudo ./upgrade.sh
```

`upgrade.sh` membackup dulu dan berhenti kalau backup gagal. Setelah itu ia menarik image sesuai pin baru, menjalankan migrasi, membuat ulang service yang berubah, dan memperbarui agent serta gVisor kalau pin-nya berubah. Image lama tidak membatalkan migrasi, jadi kembali ke versi sebelumnya berarti checkout tag lama, restore backup yang baru dibuat, lalu `upgrade.sh --skip-backup`.

### Catatan upgrade: rilis 2026-11-23 (v0.2.0)

Rilis ini memindahkan pin ke API v0.11.0, Console v0.12.0, dan agent v0.16.2, rilis yang sama dengan Sakala hosted saat ini. Caddy, PostgreSQL, Valkey, RustFS, dan gVisor tidak berubah. Yang baru:

- **Rollback dan restart.** Anggota yang boleh deploy bisa mengembalikan project ke deployment sukses sebelumnya dari tab Riwayat, tanpa build kalau image-nya masih disimpan, dan me-restart container tanpa build. Deploy otomatis dijeda setelah rollback. Image GC agent kini menyimpan image yang live dan satu sebelumnya per project, berapa pun umurnya ([Rollback dan restart](docs/configuration.md#rollback-dan-restart)).
- **Deploy tanpa menunggu analisis.** Deployment yang dibuat sebelum analisis project selesai ditahan sampai port-nya diketahui (paling lama 15 menit, `SAKALA_DEPLOYMENT_INSPECTION_WAIT_SECONDS=900`), jadi project bisa di-deploy segera setelah dibuat.
- **Batas tulis disk project.** Setiap container project boleh menulis paling banyak 1 GB ke filesystem-nya. Angka lain, atau `none`, diisi di `SAKALA_GVISOR_OVERLAY_SIZE` di `/etc/sakala/sakala.env` ([Batas tulis disk project](docs/configuration.md#batas-tulis-disk-project)).
- **Halaman 404** "Belum ada aplikasi di alamat ini" untuk alamat di bawah `run.<domain>` yang tidak punya project, dan halaman project yang tidur kini menautkan Console (`SAKALA_PUBLIC_CONSOLE_URL=https://app.<domain>` di `agent.env`).
- **Versi dokumen hukum ditetapkan.** `api.env` kini berisi `SAKALA_LEGAL_*_VERSION` (`syarat-v1`, `penggunaan-wajar-v1`, `privasi-v1`) tanpa tanggal berlaku, supaya instalasimu tidak ikut berganti ke `privasi-v2` milik Sakala hosted pada 30 November 2026 ([Dokumen hukum](docs/configuration.md#dokumen-hukum)).
- **Console.** Undang beberapa orang sekaligus, kirim ulang undangan yang kedaluwarsa, pengaturan project yang dikelompokkan, satu halaman Pengaturan untuk akun, dan kolom database di limit profile.

Tidak ada langkah manual dan tidak ada syarat Docker baru. `upgrade.sh` membackup, menjalankan tiga migrasi API v0.11.0 (kolom nullable baru di `deployments` dan `projects`, index, dan tabel `legal_change_announcements`, tanpa backfill), membuat ulang container API dan Console, mendaftarkan ulang `runsc` dengan batas 1 GB lalu me-reload Docker, memasang agent v0.16.2, membangun ulang image sandbox Railpack, lalu me-restart agent. Upgrade dari v0.1.0 juga membuat ulang runtime router untuk halaman 404, jadi project tidak terjangkau sebentar sampai agent menyambungkan router lagi ke network-nya; jalankan upgrade di luar jam sibuk. Project yang sedang berjalan mendapat batas 1 GB setelah di-deploy ulang, di-restart, atau dibangunkan. `SAKALA_IMAGE_GC_MAX_AGE_SECONDS` tidak lagi ditulis ke `agent.env`. Setelah upgrade:

```bash
jq -c '.runtimes.runsc.runtimeArgs' /etc/docker/daemon.json      # ["--platform=systrap","--overlay2=root:self,size=1g"]
grep SAKALA_LEGAL_PRIVACY_NOTICE_VERSION /etc/sakala/secrets/api.env   # privasi-v1
grep SAKALA_PUBLIC_CONSOLE_URL /etc/sakala/agent.env                 # https://app.<domain>
```

### Catatan upgrade: rilis 2026-11-20

Rilis ini memindahkan pin ke API v0.10.0, Console v0.11.0, agent v0.15.0, dan Caddy 2.11.9. Yang baru:

- **Redeploy tanpa build.** Redeploy commit yang sedang live tanpa perubahan yang memengaruhi build memakai ulang image yang live, dan tidak dihitung di batas build per jam. Redeploy konfigurasi pertama setelah upgrade masih build satu kali ([docs/configuration.md](docs/configuration.md#redeploy-tanpa-build)).
- **Metrik project.** Tab Metrik di Console menampilkan CPU, memori, replika, dan restart. Tidak ada yang perlu diatur.
- **Alamat pengunjung.** `X-Forwarded-For` dan `X-Real-IP` hanya berisi alamat pengunjung. Route lama mendapatnya setelah project di-deploy ulang, di-restart, atau dibangunkan.
- **Email notifikasi** untuk deployment gagal, aplikasi crash, dan push yang dilewati, kalau SMTP sudah diisi.
- **Wizard dan monorepo.** Variabel dari `.env.example`, tempel isi `.env`, monorepo JavaScript, dan push di monorepo yang hanya men-deploy project yang file-nya berubah. Tanpa pengaturan.
- **Database terkelola tetap mati.** `upgrade.sh` menulis `SAKALA_DATABASE_DEFAULT_MAX_COUNT=0` ke `api.env` ([Database terkelola](#database-terkelola-mati)).
- **`agent.local.env`.** `upgrade.sh` membuat `/etc/sakala/secrets/agent.local.env` yang berisi komentar saja, untuk pengaturan agent milikmu, dan `sakala-agent.service` membacanya setelah `agent.env`.

Tidak ada langkah manual dan tidak ada syarat Docker baru. `upgrade.sh` membackup, menjalankan enam migrasi API v0.8.0 sampai v0.10.0 (tabel baru untuk metrik, database, dan preferensi email, serta kolom baru tanpa backfill), membuat ulang container API, Console, edge, dan runtime router, memasang agent v0.15.0, membangun ulang image sandbox Railpack, lalu me-restart agent. Karena image Caddy naik, project tidak terjangkau sebentar, seperti pada rilis 2026-11-18; jalankan upgrade di luar jam sibuk. Setelah upgrade:

```bash
grep SAKALA_DATABASE_DEFAULT_MAX_COUNT /etc/sakala/secrets/api.env    # 0
grep agent.local.env /etc/systemd/system/sakala-agent.service       # EnvironmentFile=-/etc/sakala/secrets/agent.local.env
```

### Catatan upgrade: rilis kedua 2026-11-18

Rilis ini memindahkan pin ke API v0.7.0, Console v0.8.0, dan agent v0.10.0. Yang baru:

- **Project yang tidur bisa dibangunkan pengunjung.** `upgrade.sh` menambahkan `SAKALA_PUBLIC_API_URL=https://api.<domain>` ke `/etc/sakala/agent.env`, jadi halaman tunggu project yang tidur meminta wake ke API publik, bukan ke alamat loopback agent. Sleep otomatis tetap mati sampai kamu menyalakannya.
- **Batas build per jam.** Setiap workspace boleh memulai 20 deployment per 60 menit; admin tidak dibatasi. `upgrade.sh` menulis `SAKALA_PROJECT_MAX_BUILDS_PER_HOUR=20` ke `api.env`. Angka lain, atau `0` untuk mematikannya, diisi di `api.local.env` ([docs/configuration.md](docs/configuration.md#batas-build-per-jam)).
- **Release command.** Pemilik project bisa mengisi perintah, misalnya migrasi database, yang dijalankan sekali per deployment sebelum versi baru menerima traffic. Batas waktunya `SAKALA_RELEASE_COMMAND_TIMEOUT_SECONDS=600` di `agent.env`; operator tidak perlu mengatur apa pun ([docs/configuration.md](docs/configuration.md#release-command)).
- **Cookie host-only.** Runtime router menghapus atribut `Domain` dari cookie aplikasi, supaya cookie satu project tidak terkirim ke project lain. Route lama mendapatnya setelah project di-deploy ulang, di-restart, atau dibangunkan.

Pemantauan kesehatan Sakala Edge di API hanya berlaku untuk instalasi dengan Sakala Edge, yang tidak dipasang di sini. `upgrade.sh` menjalankan migrasi API v0.7.0, membuat ulang container API dan Console, memasang agent v0.10.0, lalu me-restart agent. Image Caddy tidak berubah. Setelah upgrade:

```bash
grep -E 'SAKALA_(PUBLIC_API_URL|RELEASE_COMMAND_TIMEOUT_SECONDS)' /etc/sakala/agent.env   # https://api.<domain> dan 600
grep SAKALA_PROJECT_MAX_BUILDS_PER_HOUR /etc/sakala/secrets/api.env                     # 20
```

### Catatan upgrade: rilis 2026-11-18

Rilis ini memindahkan pin ke API v0.6.0, Console v0.7.0, agent v0.9.1, dan Caddy 2.11.8. Yang baru: replika project, sleep otomatis (mati secara default), region, dan dukungan Sakala Edge di API dan agent.

Sejak versi ini, API dan agent memakai domain Sakala hosted (`sakala.app`) kalau tidak diberi domain. Installer sudah selalu menulis keduanya dari domainmu, jadi tidak ada yang perlu kamu ubah:

- `SAKALA_PROJECT_DEFAULT_DOMAIN=run.<domain>` di `/etc/sakala/secrets/api.env`. Tanpa ini, project baru mendapat alamat `<nama>.sakala.app`.
- `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.<domain>` di `/etc/sakala/agent.env`. Tanpa ini, agent v0.8.0 ke atas menolak setiap deploy dengan `invalid_runtime_command`.

`upgrade.sh` menulis ulang kedua file itu dari template, menambahkan `SAKALA_PROJECT_IDLE_SLEEP_MINUTES=0` ke `api.env` dan `SAKALA_MAX_REPLICAS_PER_PROJECT=4` ke `agent.env`, menjalankan migrasi API v0.6.0, membuat ulang container yang pin atau konfigurasinya berubah, lalu memasang agent v0.9.1. Domain project yang sudah ada tidak berubah, jadi `projects:move-domain` tidak perlu dijalankan. Karena image Caddy ikut naik, edge publik dan runtime router dibuat ulang, jadi project tidak terjangkau sebentar: di uji upgrade, project lama menjawab 502 lalu menolak koneksi selama total sekitar 36 detik, lalu kembali 200 tanpa deploy ulang. Jalankan upgrade di luar jam sibuk. Setelah upgrade:

```bash
grep -E 'SAKALA_PROJECT_(DEFAULT_DOMAIN|IDLE_SLEEP_MINUTES)' /etc/sakala/secrets/api.env   # run.<domain> dan 0
journalctl -u sakala-agent | grep 'one label under' | tail -n 1                            # harus menyebut run.<domain>
```

### Catatan upgrade: rilis 2026-11-12

Rilis ini memindahkan pin ke API v0.4.0, Console v0.5.0, dan agent v0.6.0. Instalasi yang dipasang sebelumnya memakai Console v0.4.0, yang menanam alamat Sakala hosted (`app.sakala.dev` dan API-nya) saat build, dan agent v0.5.0, yang hanya mau men-deploy ke domain Sakala hosted. Di instalasi seperti itu, `install.sh` keluar dengan exit 3, Console mengarahkan browser ke API hosted, dan setiap deploy gagal dengan `invalid_runtime_command`.

`upgrade.sh` membereskan semuanya tanpa langkah manual:

1. Membackup, lalu menjalankan migrasi API v0.4.0. Migrasi itu membuat workspace pribadi untuk setiap user dan memindahkan project mereka ke sana.
2. Menulis ulang `/etc/sakala/console.env` dan membuat ulang container Console. Console v0.5.0 membaca `PUBLIC_API_URL`, `PUBLIC_APP_URL`, dan `PUBLIC_REVERB_*` dari file itu saat container start, jadi browser memanggil `https://api.<domain>`.
3. Memasang agent v0.6.0, menulis `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.<domain>` ke `/etc/sakala/agent.env` (nilainya sama dengan `SAKALA_PROJECT_DEFAULT_DOMAIN` API), membangun ulang image sandbox Railpack, lalu me-restart agent.

Setelah upgrade, cek dua hal, lalu deploy ulang project yang dulu gagal:

```bash
curl -s https://app.<domain>/runtime-config.js        # harus menyebut https://api.<domain>
journalctl -u sakala-agent | grep 'one label under'   # harus menyebut run.<domain>
```

Installer tidak lagi keluar dengan exit 3. Kalau Console tidak mengarah ke `https://api.<domain>`, installer berhenti dengan error yang menyebut file dan log yang perlu dicek. Upgrade dari pin lama (API v0.3.0, Console v0.4.0, agent v0.5.0) ke pin ini diuji otomatis oleh [upgrade-e2e](.github/workflows/upgrade-e2e.yml): backup sebelum upgrade lolos `backup.sh --check` dan bisa di-restore, migrasi jalan, admin mendapat workspace pribadi yang memegang project lamanya, project lama tetap menjawab 200 tanpa deploy ulang, dan deploy baru berhasil. Instalasi lama di tes itu memakai domain `sakala.localhost`, karena agent v0.5.0 hanya mau men-deploy di bawah domain Sakala hosted; setelah upgrade domain yang sama tetap dipakai lewat `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.sakala.localhost`.

Untuk perintah Compose lain, installer memasang `sakala-compose`, misalnya `sudo sakala-compose ps` atau `sudo sakala-compose logs -f api`.

## Backup dan restore

Setiap malam, `scripts/backup.sh` menulis satu set ke `/var/lib/sakala/backups/<waktu UTC>/`: dump database, `/etc/sakala/secrets` (berisi `APP_KEY`), dan data avatar. Semuanya terenkripsi ke kunci publik age, jadi server bisa menulis backup tapi tidak bisa membacanya. 14 set terakhir disimpan.

Dua hal yang tidak boleh hilang, dan sebaiknya disimpan di password manager:

- **Kunci privat age.** Tanpanya semua backup tidak terbaca.
- **`APP_KEY`** (di `/etc/sakala/secrets/generated.env`). Ia mengenkripsi environment variable project di database. Setiap set backup membawa salinannya.

Cek kesehatan backup:

```bash
sudo /opt/sakala/scripts/backup.sh --check
systemctl list-timers sakala-backup.timer
```

Backup yang belum pernah di-restore belum terbukti. Uji di komputermu (butuh Docker dan age), tanpa menyentuh server:

```bash
rsync -a root@server:/var/lib/sakala/backups/ ./sakala-sets/
scripts/restore.sh --set ./sakala-sets/<set> --identity sakala-backup.key > laporan.txt
```

Untuk menimpa database yang sedang berjalan, hentikan aplikasi dulu, lalu kirim dump yang sudah didekripsi lewat SSH. Kunci privat tetap di komputermu:

```bash
ssh root@server 'systemctl stop sakala-agent sakala-backup.timer && sakala-compose stop api api-web reverb queue scheduler'
age -d -i sakala-backup.key ./sakala-sets/<set>/db.dump.age \
  | ssh root@server '/opt/sakala/scripts/restore.sh --overwrite-database sakala-postgres-1 --dump - --confirm-database sakala_api'
ssh root@server 'cd /opt/sakala && ./upgrade.sh --skip-backup && systemctl start sakala-backup.timer'
```

Tanpa `--confirm-database`, `restore.sh` hanya mencetak rencananya. Database lama diganti nama, bukan dihapus, sampai kamu menghapusnya sendiri. Salinan ke server lain bisa diaktifkan lewat `BACKUP_REMOTE` di `/etc/sakala/backup.env`.

Yang tidak ikut dibackup: tulisan setelah backup terakhir, Valkey (hanya cache), dan container project (kembali dengan redeploy).

## Uninstall

```bash
sudo /opt/sakala/uninstall.sh
```

Script ini membuat satu backup terakhir, lalu menghapus project yang di-deploy, control plane beserta datanya, agent, unit systemd, dan `/etc/sakala`. Backup di `/var/lib/sakala/backups` tetap disimpan, kecuali dengan `--delete-backups`. Docker Engine dan gVisor tidak dihapus.

## Troubleshooting

| Gejala | Cek |
| --- | --- |
| Browser menolak sertifikat `app.` atau `api.` | DNS sudah mengarah ke server? Port 80 dan 443 terbuka? `sudo sakala-compose logs edge` |
| Project baru tidak bisa dibuka lewat HTTPS | Deploy-nya berhasil? Sertifikat on-demand hanya diminta setelah route ada. `sudo sakala-compose logs edge \| grep -i tls` |
| Console terbuka tapi tidak bisa login | `curl -s https://app.<domain>/runtime-config.js` harus menyebut `https://api.<domain>`; kalau tidak, cek `/etc/sakala/console.env` dan `sudo sakala-compose logs console` |
| Deploy gagal dengan `invalid_runtime_command` | `/etc/sakala/agent.env` harus berisi `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.<domain>`; jalankan ulang `sudo ./install.sh` kalau belum |
| Project baru mendapat alamat `<nama>.sakala.app` | `/etc/sakala/secrets/api.env` harus berisi `SAKALA_PROJECT_DEFAULT_DOMAIN=run.<domain>`, dan `api.local.env` tidak boleh menimpanya; jalankan ulang `sudo ./install.sh` |
| Aplikasi membuat URL `http://` padahal dibuka lewat HTTPS | `grep SAKALA_RUNTIME_TRUSTED_PROXIES /etc/sakala/sakala.env` harus sama dengan subnet di `docker network inspect sakala-runtime`; jalankan ulang `sudo ./install.sh` kalau belum |
| Project tidak bisa diberi lebih dari satu replika | Workspace-nya butuh limit profile dengan `max_replicas` di atas 1 (area admin Console, Profil batas) |
| Deploy macet di antrean | `systemctl status sakala-agent` dan `journalctl -u sakala-agent -n 50`; preflight agent menyebut check yang gagal |
| `runsc` tidak terdaftar | `docker info --format '{{json .Runtimes}}'`, lalu jalankan ulang `sudo ./install.sh` |
| Email verifikasi tidak sampai | SMTP belum diisi; lihat [docs/configuration.md](docs/configuration.md) |
| Halaman Database menyebut "belum tersedia di server ini" | Memang mati secara default; lihat [Database terkelola](#database-terkelola-mati) |
| Backup gagal | `journalctl -u sakala-backup.service -n 50` dan `sudo /opt/sakala/scripts/backup.sh --check` |

Log semua komponen: `sudo sakala-compose logs --tail 100`.

## Batasan saat ini

- **Satu server.** Control plane dan aplikasi pengguna berbagi kernel host. gVisor menjadi batas utamanya, tapi akun agent punya akses Docker, yang setara root. Untuk aplikasi dari orang yang tidak kamu kenal, pemisahan host seperti di Sakala hosted lebih aman.
- **Belum diuji penuh.** Instalasi, Console di browser, deploy, upgrade dengan pin yang sama, upgrade dari pin sebelumnya, dan uninstall diuji otomatis di VM GitHub Actions (`--tls internal`, domain `sakala.test`, atau `sakala.localhost` untuk instalasi pin lama). Restore baru diuji ke database scratch. Belum diuji: sertifikat Let's Encrypt, server sungguhan dengan DNS publik, dan restore ke server sungguhan.
- **Hanya x86_64**, Ubuntu 24.04 dan 26.04.
- **Mode DNS** baru punya modul yang dipin untuk Cloudflare. Provider lain butuh `--dns-module` dan belum diuji.
- **Tanpa monitoring.** Tidak ada yang memberi tahu kalau backup berhenti atau disk penuh. Jalankan `backup.sh --check` dari monitoring yang kamu punya.
- **Tanpa filter lalu lintas keluar.** Aplikasi yang di-deploy bisa menghubungi alamat apa pun yang dijangkau server, termasuk port host dan jaringan privat di sekitarnya. Sakala hosted memasang filter egress di node runtime-nya; di sini belum, jadi batasi sendiri lewat firewall host kalau server berada di jaringan yang perlu dilindungi.
- **Database terkelola** belum dipasang installer ([Database terkelola](#database-terkelola-mati)).
- **Mengganti domain** setelah instalasi belum didukung.
- **Landing page** Sakala tidak ikut dipasang. Console masih menautkan dokumen hukum dan panduan di `https://sakala.dev`, karena alamatnya tertanam di image Console ([Dokumen hukum](docs/configuration.md#dokumen-hukum)).

## Kontribusi dan pengujian

Panduan untuk kontributor, termasuk apa yang ada di repository ini dan cara membuktikan perubahan, ada di [CONTRIBUTING.md](CONTRIBUTING.md). Ringkasnya:

```bash
shellcheck -x install.sh upgrade.sh uninstall.sh lib/common.sh scripts/*.sh tests/*.sh
tests/compose-config.sh   # docker compose config dengan env contoh
tests/edge-tls.sh         # edge Caddy sungguhan, CA internal, tanpa ACME
tests/dry-run.sh          # install, upgrade, uninstall di container Ubuntu (butuh internet)
```

GitHub Actions menjalankan semua perintah di atas di setiap pull request (`.github/workflows/lint.yml`). `.github/workflows/install-e2e.yml` memasang Sakala sungguhan di VM `ubuntu-24.04` baru milik GitHub dengan `tests/install-e2e.sh`: `install.sh --tls internal` dengan domain `sakala.test`, cek semua service, API dan Console lewat HTTPS, Console di Chrome memanggil `https://api.sakala.test` dan tidak ada host lain, agent siap dengan `runsc` dan suffix `run.sakala.test`, container di bawah `runsc` yang menulis 1.200 MB ke filesystem-nya berhenti dengan ENOSPC, login sebagai admin, deploy `examples/static-app` dari [sakala-infra](https://github.com/gmedia/sakala-infra) lewat API, menyalakan sleep otomatis satu menit sampai project tidur lalu mematikannya lagi, membuka project yang tidur di Chrome dan menunggu halaman tunggu membangunkannya lewat `https://api.sakala.test`, deploy ulang yang harus memakai ulang image yang live, lalu `upgrade.sh` dan `uninstall.sh`. Workflow ini jalan di pull request yang menyentuh installer, setiap minggu, dan manual lewat `workflow_dispatch`. `.github/workflows/upgrade-e2e.yml` (`tests/upgrade-e2e.sh`) memilih pin sebelumnya dari riwayat `versions.env`, yaitu parent dari commit terbaru yang mengubah pin, atau ref dari input `from_ref` di `workflow_dispatch`. Ia meng-clone repository ini ke `/opt/sakala` di commit itu, memasang dan men-deploy project, lalu `git checkout` ke commit sekarang dan menjalankan `upgrade.sh`. Setelah itu ia mengecek backup yang diambil `upgrade.sh` (lengkap, dari image API lama, lolos `backup.sh --check`, dan bisa di-restore ke database scratch), migrasi tanpa yang tertunda, workspace pribadi yang memegang project lama, semua service di digest yang baru, Console di browser, versi agent di API admin, project lama yang tetap 200 tanpa deploy ulang, deploy baru, dan `GET /api/v1/admin/overview`. Domainnya mengikuti agent lama: sebelum v0.6.0 agent hanya mau domain hosted, jadi pin seperti itu dipasang sebagai `sakala.localhost`, seperti tes instalasi pada masanya; pin yang lebih baru memakai `sakala.test`. Jangan jalankan `tests/install-e2e.sh` atau `tests/upgrade-e2e.sh` di server yang ingin kamu pertahankan; script itu mengubah seluruh mesin.

Lisensi: Apache-2.0.

---

## English

This repository installs Sakala on your own server. It is the distribution, not the source: installer, Compose files, pinned versions, backups, and self-host docs.

> **Status: first version, proven to install on a clean Ubuntu 24.04 VM (GitHub Actions, and for the first 2026-11-18 pins, with API v0.6.0, also a local QEMU/KVM VM), not yet on a real server.** Every pull request that touches the installer runs `install.sh`, deploys a project under gVisor, and runs `upgrade.sh` and `uninstall.sh` on a fresh VM ([install-e2e](.github/workflows/install-e2e.yml)), on the self-hosted domain `sakala.test` through `/etc/hosts`, with certificates from a local CA (`--tls internal`) because the runner has no public DNS. It also opens the Console in Chrome and requires it to call `api.sakala.test`, not the hosted Sakala API, lets the project fall asleep and wakes it from Chrome, and redeploys it from the live image. A second workflow ([upgrade-e2e](.github/workflows/upgrade-e2e.yml)) installs the previous pins, deploys a project, and upgrades to the current pins with `upgrade.sh`. Not yet proven: Let's Encrypt, a real server with public DNS, and restoring onto a real server.

**Who it is for.** Universities, communities, or small teams that want to run Sakala on one server, so people can deploy apps from GitHub to `https://<name>.run.<domain>`.

**Requirements.** A fresh Ubuntu 24.04 or 26.04 x86_64 server with at least 2 vCPU, 4 GB RAM, and 40 GB disk; root access; ports 80 and 443 open; a domain you control with `app.`, `api.`, and `*.run.` records pointing at the server; and an age key pair made on your own computer (`age-keygen`), whose public key you give to the installer.

**Existing Docker.** If Docker is already installed (`docker-ce`, Ubuntu's `docker.io`, or `moby-engine`), the installer reuses it when the daemon is rootful, Docker Engine is 24.0 or newer, the Compose plugin is 2.24 or newer, and buildx is present. Otherwise, or for a snap install, it stops and names what is missing; it never replaces or removes a Docker Engine it did not install. An existing `/etc/docker/daemon.json` keeps its settings: the installer only adds `default-address-pools` (and `log-driver: local` when unset), keeps a `.bak-<time>` copy, and restarts Docker.

**What gets installed.** Docker Engine (rootful), gVisor (checksum-verified, registered with a 1 GB cap on what each container writes to its root filesystem), PostgreSQL, Valkey, RustFS, the Sakala API, workers, Reverb, and Console (pinned by digest), a runtime router and a public Caddy edge with automatic HTTPS, the Sakala Agent binary (verified against the release `SHA256SUMS` and the pin), and a daily encrypted backup timer. Every deployed app runs under gVisor on its own Docker network.

**Sakala Edge is not installed.** Sakala Edge builds the routes from project hostnames to the runtime routers of several nodes, for a Sakala with more than one runtime server. On one server the public edge (the `edge` Compose service, plain Caddy) proxies `*.run.<domain>` straight to the local runtime router, so the installer leaves Sakala Edge out even though the agent release ships the `sakala-edge` binary, and keeps `SAKALA_AGENT_EDGE_ADDRESS` and `SAKALA_AGENT_REGION` unset in `agent.env`. Multi-node installs are not supported by this repository yet.

**Visitor address in apps.** Apps receive `X-Forwarded-Proto: https` and the visitor's address in `X-Forwarded-For`. The edge replaces any `X-Forwarded-*` header a visitor sends, and the runtime router keeps those headers only from the edge, that is from the subnet of the `sakala-runtime` network, which the installer writes to `SAKALA_RUNTIME_TRUSTED_PROXIES` in `/etc/sakala/sakala.env`. Never `private_ranges`: the router sits on every project's network, so a workload could forge the address another project's app sees. Since agent v0.14.0 each project route sets `X-Forwarded-For` and `X-Real-IP` to the visitor's address alone, so apps that trust only their nearest hop, such as Laravel with `trustProxies(at: '*')`, see the real visitor. Existing installs get the setting from `upgrade.sh`, which recreates the runtime router, so projects are briefly unreachable until the agent reconnects the router to their networks. See [docs/configuration.md](docs/configuration.md#alamat-pengunjung-dan-header-x-forwarded-) for overrides.

**Replicas and idle sleep** are both off after install. A project runs one container until an admin creates a limit profile with `max_replicas` above 1 (Console admin area, limit profiles) and assigns it to the workspace; the runtime router then spreads visitors across the replicas, and each replica counts against the node's `SAKALA_MAX_ACTIVE_CONTAINERS`. Replicas only suit stateless apps. Idle sleep is off through `SAKALA_PROJECT_IDLE_SLEEP_MINUTES=0` in `api.env`. When turned on, a visitor who opens a sleeping project wakes it through `https://api.<domain>`, the agent's `SAKALA_PUBLIC_API_URL`; see [docs/configuration.md](docs/configuration.md#sleep-otomatis).

**Managed databases are off.** The managed PostgreSQL databases of API v0.9.0 and agent v0.12.0 are not offered here: `api.env` sets `SAKALA_DATABASE_DEFAULT_MAX_COUNT=0`, the agent runs no database role, and the Console says databases are not available on this server. Apps can still use a database you run yourself through environment variables. Turning them on takes a separate PostgreSQL instance with TLS and its own backups; [docs/configuration.md](docs/configuration.md#database-terkelola) sketches the steps, which this repository does not test yet.

**Your own settings.** API settings go in `/etc/sakala/secrets/api.local.env` (`sudo sakala-compose up -d` after editing) and agent settings in `/etc/sakala/secrets/agent.local.env` (`sudo systemctl restart sakala-agent`). The scripts never rewrite either file.

**Install.**

```bash
sudo git clone --branch <release-tag> https://github.com/gmedia/sakala.git /opt/sakala
cd /opt/sakala
sudo ./install.sh --domain sakala.example.com --email admin@example.com --age-recipient age1... --yes
```

It is idempotent: rerunning keeps the generated secrets, the agent credentials, and your own settings. It prints the URLs and the first admin password at the end. Mail, GitHub App, and Google login are set in `/etc/sakala/secrets/api.local.env` ([docs/configuration.md](docs/configuration.md)).

**TLS for projects.** By default each project hostname gets its own certificate on first visit, and only once the agent has written a route for it, so it works with any DNS provider. `--tls dns --dns-provider cloudflare` uses one wildcard certificate instead. `--tls internal` uses Caddy's local CA, for tests and private networks only, never for a public instance. See [docs/tls.md](docs/tls.md), which also specifies the endpoint `sakala-api` should add so Caddy can ask the API directly.

**Upgrade.** Check out a newer tag, then `sudo ./upgrade.sh`. It backs up first and stops if the backup fails, then pulls the new pins, migrates, and restarts what changed.

**Upgrade note, release of 2026-11-23 (v0.2.0).** This release pins API v0.11.0, Console v0.12.0, and agent v0.16.2, the releases hosted Sakala runs now; Caddy, PostgreSQL, Valkey, RustFS, and gVisor do not change. Members who can deploy can roll a project back to an earlier successful deployment from the History tab, without a build while its image is kept, and restart it without a build; auto-deploy pauses after a rollback. The agent's image GC now keeps each project's live image and the one before it, whatever their age, and `SAKALA_IMAGE_GC_MAX_AGE_SECONDS`, which it ignores, is no longer written to `agent.env`. A deployment created before the project analysis finishes waits for it (up to 15 minutes). Each project container may write at most 1 GB to its root filesystem under gVisor (`--overlay2=root:self,size=1g`, the cap hosted Sakala uses), so one project cannot fill the disk the control plane shares; set `SAKALA_GVISOR_OVERLAY_SIZE` in `/etc/sakala/sakala.env` to another size or `none` and rerun `install.sh` ([docs/configuration.md](docs/configuration.md#batas-tulis-disk-project)). Unknown hostnames under `run.<domain>` get a 404 page, and the sleeping page links the Console (`SAKALA_PUBLIC_CONSOLE_URL`). `api.env` now fixes the legal document versions at `syarat-v1`, `penggunaan-wajar-v1`, and `privasi-v1` with no effective date, so a self-hosted install does not switch to hosted Sakala's `privasi-v2` on 30 November 2026; publish your own documents and name their versions in `api.local.env` ([docs/configuration.md](docs/configuration.md#dokumen-hukum)). No manual step and no new Docker requirement: `upgrade.sh` backs up, runs three API v0.11.0 migrations (new nullable columns, indexes, and the `legal_change_announcements` table, no backfill), recreates the API and Console containers, registers `runsc` again with the cap and reloads Docker, installs agent v0.16.2, rebuilds the Railpack sandbox image, and restarts the agent. From v0.1.0 it also recreates the runtime router for the 404 page, so projects are briefly unreachable; upgrade outside busy hours. Running projects get the cap at their next deploy, restart, or wake. Afterwards, `jq -c '.runtimes.runsc.runtimeArgs' /etc/docker/daemon.json` must show `--overlay2=root:self,size=1g`.

**Upgrade note, release of 2026-11-20.** This release pins API v0.10.0, Console v0.11.0, agent v0.15.0, and Caddy 2.11.9. A redeploy of the live commit with nothing build-affecting changed now reuses the live image instead of building, and does not count against the hourly build limit; the first config redeploy after the upgrade still builds once. The Console gains a Metrics tab (CPU, memory, replicas, restarts) with nothing to configure. `X-Forwarded-For` and `X-Real-IP` carry only the visitor's address; existing routes get it at their next deploy, restart, or wake. With SMTP configured, failed deployments, crashed apps, and skipped pushes are emailed. The wizard reads `.env.example`, accepts a pasted `.env`, and handles JavaScript monorepos, and a push to a monorepo deploys only the projects whose files changed. Managed databases stay off: `upgrade.sh` writes `SAKALA_DATABASE_DEFAULT_MAX_COUNT=0` to `api.env`. `upgrade.sh` also creates `/etc/sakala/secrets/agent.local.env`, holding comments only, which `sakala-agent.service` now reads after `agent.env`. No manual step and no new Docker requirement: `upgrade.sh` backs up, runs six API migrations from v0.8.0 to v0.10.0 (new tables for metrics, databases, and email preferences, and new columns without a backfill), recreates the API, Console, edge, and runtime router containers, installs agent v0.15.0, rebuilds the Railpack sandbox image, and restarts the agent. The new Caddy image makes projects briefly unreachable, as in the 2026-11-18 release, so upgrade outside busy hours. Afterwards, `grep SAKALA_DATABASE_DEFAULT_MAX_COUNT /etc/sakala/secrets/api.env` must show `0`.

**Upgrade note, second release of 2026-11-18.** This release pins API v0.7.0, Console v0.8.0, and agent v0.10.0. Visitors can now wake a sleeping project: `upgrade.sh` adds `SAKALA_PUBLIC_API_URL=https://api.<domain>` to `/etc/sakala/agent.env`, so the sleeping page asks the public API to wake the project instead of the agent's loopback address (idle sleep stays off until you turn it on). Each workspace may start 20 deployments per rolling hour, admins excepted: `upgrade.sh` writes `SAKALA_PROJECT_MAX_BUILDS_PER_HOUR=20` to `api.env`, and another number, or `0` to turn the limit off, goes in `api.local.env`. Project owners can set a release command, such as database migrations, that runs once per deployment before the new version takes traffic; it needs nothing from the operator, and its time limit is `SAKALA_RELEASE_COMMAND_TIMEOUT_SECONDS=600` in `agent.env`. The runtime router now strips the `Domain` attribute from app cookies, so one project's cookies do not reach another; existing routes get it at their next deploy, restart, or wake. The API's Edge health monitoring only applies with Sakala Edge, which is not installed here. `upgrade.sh` runs the API v0.7.0 migrations, recreates the API and Console containers, and installs and restarts agent v0.10.0; the Caddy image does not change. Afterwards, `grep -E 'SAKALA_(PUBLIC_API_URL|RELEASE_COMMAND_TIMEOUT_SECONDS)' /etc/sakala/agent.env` must show `https://api.<domain>` and `600`.

**Upgrade note, release of 2026-11-18.** This release pins API v0.6.0, Console v0.7.0, agent v0.9.1, and Caddy 2.11.8, which bring project replicas, idle sleep (off by default), regions, and Sakala Edge support in the API and agent. From these versions the API and the agent fall back to hosted Sakala's `sakala.app` when no domain is configured. The installer has always written both from your domain, so nothing changes for you: `SAKALA_PROJECT_DEFAULT_DOMAIN=run.<domain>` in `/etc/sakala/secrets/api.env` (without it new projects get `<name>.sakala.app`) and `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.<domain>` in `/etc/sakala/agent.env` (without it agent v0.8.0 and newer refuse every deployment with `invalid_runtime_command`). `upgrade.sh` rewrites both files from the templates, adds `SAKALA_PROJECT_IDLE_SLEEP_MINUTES=0` to `api.env` and `SAKALA_MAX_REPLICAS_PER_PROJECT=4` to `agent.env`, runs the API v0.6.0 migrations, recreates the containers whose pin or configuration changed, and installs agent v0.9.1. Existing project domains stay as they are, so `projects:move-domain` is not needed. The new Caddy image recreates the public edge and the runtime router, so projects are briefly unreachable: in the upgrade test the old project answered 502 and then refused connections for about 36 seconds in total, then answered 200 again without a redeploy. Upgrade outside busy hours.

**Upgrade note, release of 2026-11-12.** This release pins API v0.4.0, Console v0.5.0, and agent v0.6.0. Earlier installs ran Console v0.4.0, which baked in the hosted Sakala addresses (`app.sakala.dev` and its API), and agent v0.5.0, which deployed only under the hosted Sakala domains: `install.sh` exited 3, the Console sent browsers to the hosted API, and every deployment failed with `invalid_runtime_command`. `upgrade.sh` fixes all of it with no manual step. It backs up, runs the API v0.4.0 migrations (each user gets a personal workspace that takes over their projects), rewrites `/etc/sakala/console.env` and recreates the Console, which reads `PUBLIC_*` from it when the container starts, and installs agent v0.6.0 with `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.<domain>` in `/etc/sakala/agent.env`, the same value as the API's `SAKALA_PROJECT_DEFAULT_DOMAIN`. Afterwards, `curl -s https://app.<domain>/runtime-config.js` must name `https://api.<domain>` and `journalctl -u sakala-agent | grep 'one label under'` must name `run.<domain>`; then redeploy projects that failed before. The installer no longer exits 3: a Console that does not point at `https://api.<domain>` stops it with an error. Upgrading from the old pins to these is tested by [upgrade-e2e](.github/workflows/upgrade-e2e.yml): the backup taken first passes `backup.sh --check` and restores, the migrations run, the admin gets a personal workspace holding their old project, the old project keeps answering 200 without a redeploy, and a new deployment succeeds. Its old install uses `sakala.localhost`, because agent v0.5.0 deploys only under the hosted Sakala domains; after the upgrade the same domain keeps working through `SAKALA_PROJECT_DOMAIN_SUFFIXES=run.sakala.localhost`.

**Backup and restore.** Daily at 02:00 WIB (19:00 UTC) into `/var/lib/sakala/backups`, encrypted to your age public key: database, secrets including `APP_KEY`, and avatars. Keep the age private key and `APP_KEY` in a password manager. Restore drills run on your own computer with `scripts/restore.sh`; see the Indonesian section above for the commands.

**Uninstall.** `sudo ./uninstall.sh` takes a final backup, then removes projects, the control plane and its data, the agent, and the configuration. Backups are kept unless you pass `--delete-backups`. Docker and gVisor stay installed.

**Troubleshooting.** `sudo sakala-compose logs edge` for certificates, `journalctl -u sakala-agent` for deployments, `sudo /opt/sakala/scripts/backup.sh --check` for backups. The table above lists the common cases.

**Current limits.** One server means the control plane and user apps share a kernel, with gVisor as the main boundary. Let's Encrypt issuance, a real server with public DNS, and restoring onto a real server are not tested yet (restore is tested into a scratch database only). x86_64 only. DNS mode has a pinned module for Cloudflare only. No monitoring. No egress filter: deployed apps can reach anything the server can, including host ports and nearby private networks, which hosted Sakala filters on its runtime nodes; restrict it with a host firewall if the server sits on a network that needs protecting. Managed databases are not installed. Changing the domain after install is not supported. The Sakala landing page is not part of self-host, and the Console still links the legal documents and guides on `https://sakala.dev`, because those addresses are built into the Console image.

License: Apache-2.0.
