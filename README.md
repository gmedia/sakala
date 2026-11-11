# Sakala

Pasang dan jalankan Sakala di server sendiri. Repository ini adalah distribusi, bukan source code: installer, Compose, versi yang dipin, backup, dan dokumentasi self-host. Source tiap komponen ada di repository masing-masing ([sakala-api](https://github.com/gmedia/sakala-api), [sakala-console](https://github.com/gmedia/sakala-console), [sakala-agent](https://github.com/gmedia/sakala-agent)).

> **Status: versi pertama, terbukti terpasang di VM Ubuntu 24.04 bersih milik GitHub Actions, belum di server sungguhan.** Setiap pull request yang menyentuh installer menjalankan `install.sh`, deploy satu project di bawah gVisor, `upgrade.sh`, dan `uninstall.sh` di VM baru ([install-e2e](.github/workflows/install-e2e.yml)), dengan sertifikat dari CA lokal (`--tls internal`) karena runner tidak punya DNS publik. Yang belum terbukti: Let's Encrypt, domain selain `sakala.localhost` (agent v0.5.0 menolaknya), upgrade antar-rilis, dan restore. Pin Console masih v0.4.0, yang belum bisa diarahkan ke domain lain; lihat [Batasan saat ini](#batasan-saat-ini).

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
| gVisor (`runsc`) | rilis yang dipin, dicek dengan `.sha512` rilis dan pin di `versions.env` |
| PostgreSQL, Valkey, RustFS | container, data di Docker volume |
| API, worker queue, scheduler, Reverb, Console | container dari `ghcr.io/gmedia`, dipin dengan digest |
| Runtime router | Caddy di container `sakala-caddy`, route ditulis agent |
| Edge | Caddy di port 80 dan 443, HTTPS otomatis dari Let's Encrypt |
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

Pengaturan lanjutan, seperti SMTP, GitHub App, dan login Google, ada di [docs/configuration.md](docs/configuration.md). Tanpa SMTP, email hanya masuk ke log API.

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
| Console terbuka tapi tidak bisa login | `curl -s https://app.<domain>/runtime-config.js` harus menyebut `https://api.<domain>`; kalau tidak, pin Console belum mendukung konfigurasi runtime |
| Deploy macet di antrean | `systemctl status sakala-agent` dan `journalctl -u sakala-agent -n 50`; preflight agent menyebut check yang gagal |
| `runsc` tidak terdaftar | `docker info --format '{{json .Runtimes}}'`, lalu jalankan ulang `sudo ./install.sh` |
| Email verifikasi tidak sampai | SMTP belum diisi; lihat [docs/configuration.md](docs/configuration.md) |
| Backup gagal | `journalctl -u sakala-backup.service -n 50` dan `sudo /opt/sakala/scripts/backup.sh --check` |

Log semua komponen: `sudo sakala-compose logs --tail 100`.

## Batasan saat ini

- **Console.** Pin Console masih v0.4.0, yang menanam alamat API hosted saat build. Installer tetap selesai, tapi berhenti dengan peringatan (exit 3) sampai pin dipindah ke rilis Console yang membaca konfigurasi saat container start ([sakala-console#98](https://github.com/gmedia/sakala-console/pull/98)).
- **Agent hanya men-deploy ke domain Sakala hosted.** Sakala Agent v0.5.0 menolak project yang domainnya bukan `*.run.sakala.localhost`, `*.run.staging.sakala.dev`, atau `*.run.sakala.dev` (daftar tetap di `sakala-agent`, fungsi `valid_domain`). Jadi di domainmu sendiri, instalasi, login, dan inspeksi berjalan, tetapi setiap deploy gagal dengan `invalid_runtime_command` sampai pin agent dipindah ke rilis tanpa daftar itu. Tes end-to-end memakai `sakala.localhost` karena alasan ini.
- **Satu server.** Control plane dan aplikasi pengguna berbagi kernel host. gVisor menjadi batas utamanya, tapi akun agent punya akses Docker, yang setara root. Untuk aplikasi dari orang yang tidak kamu kenal, pemisahan host seperti di Sakala hosted lebih aman.
- **Belum diuji penuh.** Instalasi, deploy, upgrade dengan pin yang sama, dan uninstall diuji otomatis di VM GitHub Actions (`--tls internal`, domain `sakala.localhost`). Belum diuji: sertifikat Let's Encrypt, server sungguhan dengan DNS publik, upgrade antar-rilis, dan restore.
- **Hanya x86_64**, Ubuntu 24.04 dan 26.04.
- **Mode DNS** baru punya modul yang dipin untuk Cloudflare. Provider lain butuh `--dns-module` dan belum diuji.
- **Tanpa monitoring.** Tidak ada yang memberi tahu kalau backup berhenti atau disk penuh. Jalankan `backup.sh --check` dari monitoring yang kamu punya.
- **Mengganti domain** setelah instalasi belum didukung.
- **Landing page** Sakala tidak ikut dipasang.

## Kontribusi dan pengujian

```bash
shellcheck -x install.sh upgrade.sh uninstall.sh lib/common.sh scripts/*.sh tests/*.sh
tests/compose-config.sh   # docker compose config dengan env contoh
tests/edge-tls.sh         # edge Caddy sungguhan, CA internal, tanpa ACME
tests/dry-run.sh          # install, upgrade, uninstall di container Ubuntu (butuh internet)
```

GitHub Actions menjalankan semua perintah di atas di setiap pull request (`.github/workflows/lint.yml`). `.github/workflows/install-e2e.yml` memasang Sakala sungguhan di VM `ubuntu-24.04` baru milik GitHub dengan `tests/install-e2e.sh`: `install.sh --tls internal`, cek semua service, API dan Console lewat HTTPS, agent siap dengan `runsc`, login sebagai admin, deploy `examples/static-app` dari [sakala-infra](https://github.com/gmedia/sakala-infra) lewat API, lalu `upgrade.sh` dan `uninstall.sh`. Workflow ini jalan di pull request yang menyentuh installer, setiap minggu, dan manual lewat `workflow_dispatch`. Jangan jalankan `tests/install-e2e.sh` di server yang ingin kamu pertahankan; script itu mengubah seluruh mesin.

Lisensi: Apache-2.0.

---

## English

This repository installs Sakala on your own server. It is the distribution, not the source: installer, Compose files, pinned versions, backups, and self-host docs.

> **Status: first version, proven to install on a clean GitHub Actions Ubuntu 24.04 VM, not yet on a real server.** Every pull request that touches the installer runs `install.sh`, deploys a project under gVisor, and runs `upgrade.sh` and `uninstall.sh` on a fresh VM ([install-e2e](.github/workflows/install-e2e.yml)), with certificates from a local CA (`--tls internal`) because the runner has no public DNS. Not yet proven: Let's Encrypt, domains other than `sakala.localhost` (agent v0.5.0 refuses them), upgrades between releases, and restore. The pinned Console (v0.4.0) cannot be pointed at another domain yet.

**Who it is for.** Universities, communities, or small teams that want to run Sakala on one server, so people can deploy apps from GitHub to `https://<name>.run.<domain>`.

**Requirements.** A fresh Ubuntu 24.04 or 26.04 x86_64 server with at least 2 vCPU, 4 GB RAM, and 40 GB disk; root access; ports 80 and 443 open; a domain you control with `app.`, `api.`, and `*.run.` records pointing at the server; and an age key pair made on your own computer (`age-keygen`), whose public key you give to the installer.

**Existing Docker.** If Docker is already installed (`docker-ce`, Ubuntu's `docker.io`, or `moby-engine`), the installer reuses it when the daemon is rootful, Docker Engine is 24.0 or newer, the Compose plugin is 2.24 or newer, and buildx is present. Otherwise, or for a snap install, it stops and names what is missing; it never replaces or removes a Docker Engine it did not install. An existing `/etc/docker/daemon.json` keeps its settings: the installer only adds `default-address-pools` (and `log-driver: local` when unset), keeps a `.bak-<time>` copy, and restarts Docker.

**What gets installed.** Docker Engine (rootful), gVisor (checksum-verified), PostgreSQL, Valkey, RustFS, the Sakala API, workers, Reverb, and Console (pinned by digest), a runtime router and a public Caddy edge with automatic HTTPS, the Sakala Agent binary (verified against the release `SHA256SUMS` and the pin), and a daily encrypted backup timer. Every deployed app runs under gVisor on its own Docker network.

**Install.**

```bash
sudo git clone --branch <release-tag> https://github.com/gmedia/sakala.git /opt/sakala
cd /opt/sakala
sudo ./install.sh --domain sakala.example.com --email admin@example.com --age-recipient age1... --yes
```

It is idempotent: rerunning keeps the generated secrets, the agent credentials, and your own settings. It prints the URLs and the first admin password at the end. Mail, GitHub App, and Google login are set in `/etc/sakala/secrets/api.local.env` ([docs/configuration.md](docs/configuration.md)).

**TLS for projects.** By default each project hostname gets its own certificate on first visit, and only once the agent has written a route for it, so it works with any DNS provider. `--tls dns --dns-provider cloudflare` uses one wildcard certificate instead. `--tls internal` uses Caddy's local CA, for tests and private networks only, never for a public instance. See [docs/tls.md](docs/tls.md), which also specifies the endpoint `sakala-api` should add so Caddy can ask the API directly.

**Upgrade.** Check out a newer tag, then `sudo ./upgrade.sh`. It backs up first and stops if the backup fails, then pulls the new pins, migrates, and restarts what changed.

**Backup and restore.** Daily at 02:00 WIB (19:00 UTC) into `/var/lib/sakala/backups`, encrypted to your age public key: database, secrets including `APP_KEY`, and avatars. Keep the age private key and `APP_KEY` in a password manager. Restore drills run on your own computer with `scripts/restore.sh`; see the Indonesian section above for the commands.

**Uninstall.** `sudo ./uninstall.sh` takes a final backup, then removes projects, the control plane and its data, the agent, and the configuration. Backups are kept unless you pass `--delete-backups`. Docker and gVisor stay installed.

**Troubleshooting.** `sudo sakala-compose logs edge` for certificates, `journalctl -u sakala-agent` for deployments, `sudo /opt/sakala/scripts/backup.sh --check` for backups. The table above lists the common cases.

**Current limits.** Console v0.4.0 is pinned until a release with runtime configuration ships ([sakala-console#98](https://github.com/gmedia/sakala-console/pull/98)); the installer finishes but exits 3 with a warning until then. Sakala Agent v0.5.0 deploys only projects under `*.run.sakala.localhost`, `*.run.staging.sakala.dev`, or `*.run.sakala.dev` (a fixed list in `sakala-agent`), so on your own domain every deployment fails with `invalid_runtime_command` until the agent pin moves to a release without that list; the end-to-end test uses `sakala.localhost` for this reason. One server means the control plane and user apps share a kernel, with gVisor as the main boundary. Let's Encrypt issuance, a real server with public DNS, upgrades between releases, and restore are not tested yet. x86_64 only. DNS mode has a pinned module for Cloudflare only. No monitoring. Changing the domain after install is not supported. The Sakala landing page is not part of self-host.

License: Apache-2.0.
