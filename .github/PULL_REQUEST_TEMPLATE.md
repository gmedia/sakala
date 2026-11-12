## Ringkasan

Jelaskan perubahan utama pada pull request ini secara singkat.

## Jenis Perubahan

- [ ] `feat` - kemampuan baru
- [ ] `fix` - perbaikan bug
- [ ] `docs` - dokumentasi
- [ ] `refactor` - perubahan struktur tanpa mengubah behavior
- [ ] `test` - pengujian
- [ ] `ci` - automation repository
- [ ] `chore` - maintenance, termasuk pin versi

## Area yang Terdampak

- [ ] `install.sh`
- [ ] `upgrade.sh`
- [ ] `uninstall.sh`
- [ ] Backup / restore
- [ ] Compose / Caddy / templates / systemd
- [ ] `versions.env`
- [ ] Documentation
- [ ] Tests / CI
- [ ] Security boundary

## Cara Menguji

Tuliskan perintah yang dijalankan dan hasilnya:

```bash
shellcheck -x install.sh upgrade.sh uninstall.sh lib/common.sh scripts/*.sh tests/*.sh
tests/compose-config.sh
tests/edge-tls.sh
tests/dry-run.sh
```

Tulis juga yang tidak bisa diuji otomatis (misalnya Let's Encrypt atau server dengan DNS publik) dan bagaimana kamu mengujinya.

## Checklist

- [ ] Commit mengikuti Conventional Commits (`type(scope): message`).
- [ ] Scope perubahan kecil dan jelas.
- [ ] Tidak ada secret, token, credential, kunci privat age, atau domain dan IP server sungguhan.
- [ ] Script baru atau yang diubah memakai strict mode seperti script di sekitarnya (`set -euo pipefail`, atau `set -eu` di `scripts/`) dan aman dijalankan ulang.
- [ ] Server yang sudah terpasang ditangani `upgrade.sh` tanpa langkah manual, bila terdampak.
- [ ] `README.md` (bagian Indonesia dan English) dan `docs/` diperbarui bila perilaku untuk operator berubah.

## Related Issue

Closes #
