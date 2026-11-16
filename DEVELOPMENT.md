# Development

Catatan teknis untuk mengubah dan merilis Growblox Hansel. Panduan pemakai ada di [README.md](README.md).

## Struktur

```text
src/
  core.lua       logika murni: validasi config, nama world, seed, baris farm, syarat task.
  navigation.lua perencana rute jalan/lompat (disalin utuh dari Clarissv).
  net.lua      token Stop, pause, request ke server dengan batas waktu.
  state.lua    simpan/baca file JSON per akun: session, profil, checkpoint resume.
  bridge.lua   SATU-SATUNYA modul yang mencari objek game di memori (getgc). Connect + retry.
  actions.lua  aksi dasar: hitung item, baca tile, sinkron tas dengan server.
  movement.lua pegang kontrol karakter, jalan ke tile, masuk world, auto-resume setelah teleport.
  storage.lua  Display Box: baca isi, ambil, setor, simpan posisi box.
  jobs.lua     mulai/stop task. Fitur mendaftar lewat Jobs.register(mode, spec).
  plant.lua    fitur Planting + isi tab Planting.
  ui.lua       jendela WindUI dan tab.
  main.lua     titik masuk: merangkai semua modul.
tests/         tes offline (Lua 5.4 lewat Python lupa) dengan game palsu. tests/plant.lua punya simulasi fisika jalan.
build.mjs      gabungkan src/, buat releases/<hash>/ dan loader.lua.
loader.template.lua  template loader. loader.lua dibuat dari sini; jangan edit loader.lua.
loader-local.lua     loader dari file lokal, untuk tes tanpa GitHub.
```

Aturan utama: **hanya `bridge.lua` yang tahu bentuk objek game.** Kalau Growblox update dan script terus `found 0`, cukup `bridge.lua` yang diperbaiki.

Setiap modul (kecuali `core.lua`) mengembalikan fungsi `function(G) ... end`. `G` adalah kotak alat bersama yang diisi `main.lua`: state `App`, modul lain, dan semua fungsi executor/Roblox. Di tes, isi `G` diganti versi palsu.

## Build & tes

```text
node build.mjs           # dist/main.lua, releases/<hash>/main.lua, loader.lua
pip install lupa         # sekali saja
python3 tests/run.py     # tes modul + smoke test bundle + tes loader
```

## Rilis versi baru

1. Edit `src/`, naikkan `version` di `package.json`.
2. `node build.mjs && python3 tests/run.py`
3. Commit semua perubahan, termasuk folder `releases/` dan `loader.lua`, lalu push.

Folder `releases/<hash>/` tidak pernah ditimpa. Loader lama yang masih di-cache GitHub tetap menunjuk file yang cocok dengan checksum-nya.

## Tes lokal tanpa GitHub

Copy `dist/main.lua` dan `vendor/WindUI.lua` ke `workspace/GrowbloxHansel/` di executor, lalu jalankan isi `loader-local.lua`.
