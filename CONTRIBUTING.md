# Berkontribusi ke Sakala (distribusi self-host)

Repository ini berisi installer dan semua yang dibutuhkan untuk memasang Sakala di satu server. Source code API, Console, dan agent tidak ada di sini. Kalau kamu baru pertama kali, [Start Contributing](https://sakala.dev/docs/proyek/start-contributing) memetakan semua repository Sakala dan cara memilih pekerjaan.

Dengan ikut berpartisipasi, kamu setuju mengikuti [Code of Conduct](https://github.com/gmedia/.github/blob/main/CODE_OF_CONDUCT.md). Kerentanan keamanan jangan dilaporkan lewat issue publik; ikuti [Security Policy](https://github.com/gmedia/.github/blob/main/SECURITY.md).

English: [jump to the English section](#english).

## Yang ada di sini dan yang ada di repository lain

Di sini:

- `install.sh`, `upgrade.sh`, `uninstall.sh`, dan fungsi bersama di `lib/common.sh`;
- `compose.yaml`, konfigurasi edge di `caddy/`, file yang di-render di `templates/`, dan unit di `systemd/`;
- `scripts/backup.sh` dan `scripts/restore.sh`;
- `versions.env`, yaitu versi dan digest image yang dipasang;
- dokumentasi self-host di `README.md` dan `docs/`;
- test di `tests/` dan workflow di `.github/workflows/`.

Di repository lain:

- Perilaku API, Console, dan agent ada di [sakala-api](https://github.com/gmedia/sakala-api), [sakala-console](https://github.com/gmedia/sakala-console), dan [sakala-agent](https://github.com/gmedia/sakala-agent). Kalau instalasi berhasil tetapi sebuah fitur di Console salah, atau deploy gagal karena aplikasinya, laporkan di repository komponen itu.
- Runtime lokal untuk development ada di [sakala-infra](https://github.com/gmedia/sakala-infra).
- Situs dan dokumentasi publik ada di [sakala-landing](https://github.com/gmedia/sakala-landing).

Pin versi komponen di `versions.env` dipindahkan maintainer lewat pull request rilis, setelah komponennya dirilis. Kalau kamu butuh versi yang lebih baru, buka issue.

## Sebelum mulai

- Cari issue yang sudah ada. Yang cocok untuk orang baru berlabel [`good first issue`](https://github.com/gmedia/sakala/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22good%20first%20issue%22), dan fitur yang ingin dibantu berlabel [`help wanted`](https://github.com/gmedia/sakala/issues?q=is%3Aissue%20is%3Aopen%20label%3A%22help%20wanted%22). Tulis komentar di issue sebelum mengerjakannya.
- Untuk perubahan besar, misalnya opsi installer baru, komponen baru di `compose.yaml`, atau perubahan yang memengaruhi server yang sudah terpasang, buka issue atau thread di [Ideas](https://github.com/gmedia/sakala/discussions/categories/ideas) dulu. Mulai menulis kode setelah maintainer setuju dengan pendekatannya.
- Pertanyaan diajukan di [Q&A](https://github.com/gmedia/sakala/discussions/categories/q-a).

## Menyiapkan mesin

Kamu butuh Bash, Git, [ShellCheck](https://www.shellcheck.net/), dan Docker dengan plugin Compose. Semua test di bawah aman dijalankan di laptop. Selain mengunduh image Docker, test hanya membuat container dan direktori sementara lalu menghapusnya, dan tidak memasang apa pun di host.

## Pemeriksaan sebelum pull request

GitHub Actions menjalankan semua perintah ini di setiap pull request (`.github/workflows/lint.yml`), jadi jalankan dulu di mesinmu:

```bash
shellcheck -x install.sh upgrade.sh uninstall.sh lib/common.sh scripts/*.sh tests/*.sh
for f in install.sh upgrade.sh uninstall.sh lib/common.sh tests/*.sh; do bash -n "$f"; done
tests/compose-config.sh
tests/edge-tls.sh
tests/dry-run.sh
```

- `tests/compose-config.sh` menjalankan `docker compose config` terhadap `compose.yaml` dengan env contoh di direktori sementara, untuk kedua mode TLS. Ia memeriksa bahwa setiap image memakai digest yang dipin, hanya edge yang membuka port publik, dan token DNS hanya sampai ke edge. Cukup Docker CLI dengan plugin Compose, tanpa daemon.
- `tests/edge-tls.sh` menjalankan container Caddy sungguhan dengan CA internal, tanpa menghubungi Let's Encrypt. Ia membuktikan edge hanya menerbitkan sertifikat untuk hostname yang punya route. Butuh daemon Docker.
- `tests/dry-run.sh` menjalankan `install.sh`, `upgrade.sh`, dan `uninstall.sh` dengan `SAKALA_DRY_RUN=1` di container Ubuntu 24.04 dan 26.04 yang dibuang setelahnya. Paket apt, unduhan gVisor dan agent beserta checksum-nya, secret yang dibuat, dan file yang di-render dijalankan sungguhan. Langkah yang butuh systemd atau daemon Docker di dalam container hanya dicetak. Test ini butuh internet dan cukup lama (CI memberi batas 40 menit untuk kedua image). Untuk iterasi cepat, jalankan satu image saja: `tests/dry-run.sh ubuntu:24.04`.

Dry run bukan pengganti instalasi sungguhan. Itu tugas workflow di bagian berikut.

## Cara install-e2e membuktikan perubahan

Pull request yang menyentuh installer, `versions.env`, `compose.yaml`, `lib/`, `caddy/`, `templates/`, `systemd/`, atau `scripts/` juga menjalankan dua workflow di VM Ubuntu 24.04 baru milik GitHub:

- **install-e2e** (`tests/install-e2e.sh`) menjalankan `install.sh --tls internal` dengan domain `sakala.test`, memeriksa semua service, membuka Console di Chrome dan memastikan Console memanggil `https://api.sakala.test`, login sebagai admin, men-deploy `examples/static-app` dari sakala-infra di bawah gVisor, lalu menjalankan `upgrade.sh` dan `uninstall.sh`.
- **upgrade-e2e** (`tests/upgrade-e2e.sh`) memasang pin sebelumnya dari riwayat `versions.env`, men-deploy project, lalu meng-upgrade ke commit pull request dengan `upgrade.sh`. Ia memeriksa backup sebelum upgrade, migrasi, project lama yang tetap jalan tanpa deploy ulang, dan deploy baru.

Setiap fase adalah step tersendiri di workflow, jadi step yang merah langsung menunjukkan fase yang gagal. Kalau gagal, unduh artifact diagnostics dari halaman run. Untuk kontributor yang baru pertama kali, GitHub biasanya menunggu maintainer menyetujui workflow sebelum berjalan.

**Jangan jalankan `tests/install-e2e.sh` atau `tests/upgrade-e2e.sh` di mesin yang ingin kamu pertahankan.** Script itu memasang Docker, gVisor, dan Sakala, lalu menghapusnya lagi, dan mengubah seluruh mesin. Kalau ingin mencoba instalasi sungguhan sendiri, pakai VM Ubuntu baru yang boleh dibuang.

Beberapa hal belum dibuktikan workflow: penerbitan sertifikat Let's Encrypt, server sungguhan dengan DNS publik, dan restore ke server sungguhan. Kalau perubahanmu menyentuh bagian itu, tulis di pull request bagaimana kamu mengujinya.

## Commit dan pull request

- Commit mengikuti [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), misalnya `fix: keep daemon.json log settings on rerun` atau `docs: explain the DNS TLS mode`.
- Satu pull request untuk satu perubahan. Isi template pull request, termasuk perintah yang kamu jalankan.
- Kalau perilaku `install.sh`, `upgrade.sh`, `uninstall.sh`, backup, atau restore berubah, perbarui `README.md` di bagian bahasa Indonesia dan English, serta `docs/` bila relevan.
- Perubahan yang memengaruhi server yang sudah terpasang harus ditangani `upgrade.sh` tanpa langkah manual, dan dijelaskan di pull request.
- Jangan commit secret, file `.env`, kunci privat age, sertifikat, atau domain dan alamat IP server sungguhan. Test memakai `example.com`, `sakala.test`, dan kunci palsu.

---

## English

This repository holds the installer for running Sakala on one server: `install.sh`, `upgrade.sh`, `uninstall.sh`, Compose and Caddy files, systemd units, backup and restore scripts, the pins in `versions.env`, and the self-host docs. The API, Console, and agent source lives in their own repositories; report bugs in those components there. New to Sakala? [Start Contributing](https://sakala.dev/docs/proyek/start-contributing) maps every repository.

Participation follows the [Code of Conduct](https://github.com/gmedia/.github/blob/main/CODE_OF_CONDUCT.md). Report vulnerabilities privately as the [Security Policy](https://github.com/gmedia/.github/blob/main/SECURITY.md) describes, never in a public issue. Ask questions in [Q&A](https://github.com/gmedia/sakala/discussions/categories/q-a), and propose larger changes in an issue or in [Ideas](https://github.com/gmedia/sakala/discussions/categories/ideas) before writing code.

**Checks.** You need Bash, Git, ShellCheck, and Docker with the Compose plugin. Run the same checks CI runs (`.github/workflows/lint.yml`). Apart from pulling Docker images, they only create temporary containers and directories and install nothing on your host:

```bash
shellcheck -x install.sh upgrade.sh uninstall.sh lib/common.sh scripts/*.sh tests/*.sh
for f in install.sh upgrade.sh uninstall.sh lib/common.sh tests/*.sh; do bash -n "$f"; done
tests/compose-config.sh   # docker compose config with sample env, both TLS modes, no daemon needed
tests/edge-tls.sh         # real Caddy containers with an internal CA, no ACME
tests/dry-run.sh          # install, upgrade, uninstall with SAKALA_DRY_RUN=1 in throwaway Ubuntu containers
```

`tests/dry-run.sh` needs internet and takes a while; `tests/dry-run.sh ubuntu:24.04` runs one image.

**End-to-end proof.** Pull requests that touch the installer, `versions.env`, `compose.yaml`, `lib/`, `caddy/`, `templates/`, `systemd/`, or `scripts/` also run install-e2e and upgrade-e2e on a fresh GitHub Ubuntu 24.04 VM. install-e2e installs with `--tls internal` on `sakala.test`, checks every service and the Console in Chrome, deploys a project under gVisor, then upgrades and uninstalls. upgrade-e2e installs the previous pins, deploys a project, and upgrades to your commit. Each phase is its own step, so a red step names the phase that failed. Never run `tests/install-e2e.sh` or `tests/upgrade-e2e.sh` on a machine you want to keep. Let's Encrypt, a real server with public DNS, and restoring onto a real server are not covered; say in the pull request how you tested changes there.

**Pull requests.** Use Conventional Commits, keep one change per pull request, update both language sections of `README.md` when operator-visible behaviour changes, make `upgrade.sh` handle anything that affects existing installs, and never commit secrets, age private keys, or real server domains and addresses.
