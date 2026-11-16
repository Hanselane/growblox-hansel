# Growblox Hansel

Panduan untuk **Growblox Hansel 0.1.1**. *Learn to own.*

Script autofarm Growblox (Roblox) yang dibangun bertahap. Versi ini berisi **pondasi**: menyambung ke game, menyimpan setting per akun, dan jendela dengan tab fitur. Fitur farming ditambah satu per satu (lihat [Status fitur](#status-fitur)).

Alur yang dituju setelah semua fitur jadi: **tanam semua farm → PNB selama pohon tumbuh → panen farm yang matang → pindahkan blok dan seed → tanam ulang → ulangi**.

## Daftar isi

- [Status fitur](#status-fitur)
- [Requirements](#requirements)
- [Mulai](#mulai)
- [Tab di jendela](#tab-di-jendela)
- [Menyambung ke game](#menyambung-ke-game)
- [Data yang disimpan](#data-yang-disimpan)
- [Troubleshooting](#troubleshooting)
- [Pertanyaan umum](#pertanyaan-umum)
- [Untuk developer](#untuk-developer)
- [Kredit](#kredit)

## Status fitur

| Fitur | Tab | Status |
| --- | --- | --- |
| Pondasi: connect, retry, simpan setting, loader GitHub | Settings | Selesai, dites di game (v0.1.0) |
| Place & Break + Auto Collect | Place & Break | Belum |
| Planting | Planting | Belum |
| Harvest | Harvest | Belum |
| Rotation | Rotation | Belum |

## Requirements

- Executor yang punya fungsi `getgc`, `getupvalues` (atau `debug.getupvalue`), `readfile`/`writefile`/`makefolder`, dan `game:HttpGet`. Sudah dites di **Delta**.
- Akun Roblox yang sudah login dan karakter yang sudah berdiri di dalam sebuah world.
- Koneksi internet untuk download pertama. Setelah itu file disimpan di cache executor.

## Mulai

1. Masuk ke world mana saja di Growblox dan tunggu karakter bisa digerakkan.
2. Paste baris ini ke executor, lalu execute:

   ```lua
   loadstring(game:HttpGet("https://raw.githubusercontent.com/Hanselane/growblox-hansel/main/loader.lua"))()
   ```

3. Jendela **Growblox Hansel** muncul. Buka tab **Settings**. Status harus berubah menjadi `Tersambung ke NAMAWORLD.`

Loader mengambil rilis terbaru, mengecek ukuran dan checksum setiap file, lalu menyimpannya di `workspace/GrowbloxHansel/cache/`. File yang rusak atau setengah ter-download ditolak dan tidak dijalankan. Loader juga menolak jalan selama masih ada task aktif, supaya tidak ada dua script yang berebut kontrol.

## Tab di jendela

| Tab | Isi |
| --- | --- |
| **Place & Break** | PNB dan **Auto Collect** (ambil drop di sekitar karakter, dengan jangkauan yang bisa diatur). Belum dibuat. |
| **Planting** | Tanam seed di daftar world farm. Belum dibuat. |
| **Harvest** | Panen farm dan simpan hasilnya ke Display Box. Belum dibuat. |
| **Rotation** | Gabungan semua fitur, berjalan terus. Belum dibuat. |
| **Settings** | Status, **Reconnect to game**, **Copy diagnostics**, **Unload script**, dan log aktivitas. |

## Menyambung ke game

Script mencari objek world, avatar, backpack, dan data item langsung di memori game. Setelah ganti server atau saat world masih loading, objek itu belum ada, sehingga muncul pesan `found 0`.

Script **mencoba lagi otomatis** sampai 8 kali dengan jeda 4 detik. Selama itu status menampilkan `World belum siap (...). Coba lagi 1/7...`. Begitu world selesai dimuat dan karakter siap, status berubah menjadi `Tersambung`.

Hanya pesan "belum siap" yang dicoba ulang. Kesalahan lain, misalnya dua world terdeteksi sekaligus (`found 2`), langsung berhenti, karena menunggu tidak akan memperbaikinya.

## Data yang disimpan

Semua data ada di folder workspace executor, dipisah per akun Roblox:

```text
GrowbloxHansel/
  cache/<rilis>/                 file script yang sudah di-download
  accounts/<UserId>/session.json setting terakhir, dipulihkan otomatis saat script dimuat
  accounts/<UserId>/profiles/    profil yang disimpan
```

Setiap file ditulis dengan aman: ditulis ke `.pending` dulu dan dicek, versi lama disimpan sebagai `.bak`, baru file asli ditimpa. Profil lama tetap bisa dibaca walaupun versi baru menambah setting; setting yang belum ada diisi nilai bawaan.

## Troubleshooting

| Gejala | Penyebab | Yang dilakukan |
| --- | --- | --- |
| Status masih `Coba lagi ...` lalu gagal setelah 8 kali | Karakter belum masuk world, atau masih di world picker | Masuk ke world, tunggu karakter bisa digerakkan, lalu **Settings → Reconnect to game** |
| `found 0` terus padahal sudah di dalam world | Kemungkinan Growblox atau executor baru update | **Copy diagnostics** dan laporkan. Lihat baris `World tables` dan `Registry` |
| `Stop task yang lagi jalan dulu` saat execute | Masih ada task aktif dari script sebelumnya | Matikan task dulu, tunggu sebentar, baru execute ulang |
| `File ... tidak cocok` | Download terpotong, atau GitHub belum selesai memperbarui file | Tunggu 1–5 menit, lalu execute ulang |
| Executor bilang ada execution yang masih berjalan | Execute dua kali terlalu cepat | Tunggu sampai jendela muncul |

**Copy diagnostics** menyalin versi, world, status, hasil pencarian objek game, dan 15 baris log terakhir. Kirim teks itu saat melaporkan masalah.

## Pertanyaan umum

**Apakah harus download ulang setiap kali?** Tidak. Rilis yang sama diambil dari cache. Download baru hanya terjadi saat ada rilis baru.

**Apakah bisa dipakai banyak akun?** Bisa. Setting dan profil disimpan per `UserId`, jadi akun yang berbeda tidak saling menimpa.

**Bagaimana cara menghentikan script?** **Settings → Unload script**. Menutup jendela juga menghentikannya.

## Untuk developer

Struktur kode, cara build, tes offline, dan cara merilis versi baru ada di [DEVELOPMENT.md](DEVELOPMENT.md).

## Kredit

Struktur dan sebagian fungsi diadaptasi dari [Claris Growblox Autofarm](https://github.com/Clarissv/Claris-Growblox-Autofarm) karya Clarissv. Bagian yang diadaptasi ditandai di komentar setiap file. UI memakai [WindUI](vendor/WindUI.LICENSE) (lisensi MIT).
