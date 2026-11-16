# Growblox Hansel

Script autofarm Growblox (Roblox) buat belajar. Struktur dan banyak fungsinya diadaptasi dari
[Claris Growblox Autofarm](https://github.com/Clarissv/Claris-Growblox-Autofarm) karya Clarissv.
Repo Clarissv tidak mencantumkan lisensi. Kredit untuk ide dan struktur aslinya ada di sana;
bagian yang diadaptasi ditandai di komentar tiap file.

UI memakai [WindUI](vendor/WindUI.LICENSE) (lisensi MIT).

## Status

| Bagian | Status |
| --- | --- |
| Pondasi (connect, retry, simpan setting, UI dasar, loader GitHub) | v0.1.0 — selesai, dites offline |
| Planting | belum |
| Harvest | belum |
| Place & Break | belum |
| Auto Collect | belum (contoh lama: `learn/auto-collect.lua`) |

## Struktur

```
src/
  core.lua     logika murni: validasi config, nama world, seed. Tidak menyentuh game.
  net.lua      token Stop, pause, request ke server dengan batas waktu.
  state.lua    simpan/baca file JSON per akun: session, profil, checkpoint resume.
  bridge.lua   SATU-SATUNYA modul yang cari objek game di memori (getgc). Connect + retry.
  actions.lua  aksi dasar: hitung item, baca tile, sinkron tas dengan server.
  ui.lua       jendela WindUI dan tab.
  main.lua     titik masuk: rangkai semua modul.
tests/         tes offline (Lua 5.4 via Python lupa) dengan game palsu.
build.mjs      gabungkan src/, bikin releases/<hash>/ dan loader.lua.
loader.template.lua  template loader (loader.lua dibuat dari sini, jangan edit loader.lua).
loader-local.lua     loader versi file lokal, buat tes tanpa GitHub.
```

Aturan utama: **cuma `bridge.lua` yang tahu bentuk objek game.** Kalau Growblox update dan
script error "found 0" terus, yang diperbaiki cukup `bridge.lua`.

## Build & tes

```
node build.mjs             # hasil: dist/main.lua
pip install lupa           # sekali saja
python3 tests/run.py       # tes semua modul + smoke test bundle
```

## Pasang di executor (Delta)

Paste satu baris ini ke executor:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Hanselane/growblox-hansel/main/loader.lua"))()
```

Loader mengambil rilis terbaru, mengecek ukuran dan checksum tiap file, lalu menyimpannya di
`workspace/GrowbloxHansel/cache/`. File yang rusak atau beda versi ditolak.
Data setting tersimpan di `workspace/GrowbloxHansel/accounts/<UserId>/`.

Tanpa internet / buat tes lokal: copy `dist/main.lua` dan `vendor/WindUI.lua` ke
`workspace/GrowbloxHansel/`, lalu jalankan `loader-local.lua`.

## Rilis versi baru

1. Edit `src/`, naikkan `version` di `package.json`.
2. `node build.mjs && python3 tests/run.py`
3. Commit **semua** perubahan, termasuk folder `releases/` dan `loader.lua`, lalu push.

Folder `releases/<hash>/` tidak pernah ditimpa. Jadi loader lama yang masih ke-cache
GitHub tetap menunjuk file yang cocok dengan checksum-nya.

## Perubahan dari Clarissv

- **Connect dicoba ulang** kalau world belum dimuat (`found 0`) atau avatar belum siap:
  maksimal 8x dengan jeda 4 detik. Error lain (misal `found 2`) langsung berhenti.
- **Profil lama tetap terbaca** saat ada setting baru: key yang hilang diisi nilai bawaan.
- **Tiap modul dibungkus fungsi sendiri** saat build, jadi tidak kena batas 200 `local` Lua.
