# Growblox Hansel

Panduan untuk **Growblox Hansel 0.3.3**. *Learn to own.*

Script autofarm Growblox (Roblox) yang dibangun bertahap. Versi ini berisi pondasi (menyambung ke game, menyimpan setting per akun) fitur **Planting**, dan **Place & Break**. Fitur lain ditambah satu per satu (lihat [Status fitur](#status-fitur)).

Alur yang dituju setelah semua fitur jadi: **tanam semua farm → PNB selama pohon tumbuh → panen farm yang matang → pindahkan blok dan seed → tanam ulang → ulangi**.

## Daftar isi

- [Status fitur](#status-fitur)
- [Requirements](#requirements)
- [Mulai](#mulai)
- [Tab di jendela](#tab-di-jendela)
- [Place & Break](#place--break)
- [Planting](#planting)
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
| Place & Break | Place & Break | Selesai (v0.3.0), dites offline. Auto drop seed menunggu hasil rekaman |
| Planting | Planting | Selesai (v0.2.0), dites offline |
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
| **Place & Break** | PNB dengan grid 5x5, hit delay, stock dari lantai, drop seed, perekam aksi game. |
| **Planting** | Tanam seed di daftar world farm, isi ulang dari Display Box. |
| **Harvest** | Panen farm dan simpan hasilnya ke Display Box. Belum dibuat. |
| **Rotation** | Gabungan semua fitur, berjalan terus. Belum dibuat. |
| **Settings** | Status, **Stop task**, **Reconnect to game**, **Copy diagnostics**, **Unload script**, dan log aktivitas. |

## Place & Break

Place & Break menaruh blok di tile yang dipilih di sekitar karakter, memukulnya sampai pecah, lalu memungut seed, gem, dan blok yang jatuh. Layout tab mengikuti gaya script Crusader; logika place/break diadaptasi dari Claris Growblox v0.1.43.

### Requirements

- Blok yang bisa di-PNB ada di tas (blok biasa yang punya hit; bukan background, lock, door, atau display).
- Izin edit di area PNB.
- Tile yang dipilih kosong. Tile yang berisi blok lain dilewati, tidak dipukul.
- Untuk **Auto take stock**: blok stock berserakan di lantai, di world yang sama dengan PNB.

### Setup

1. Pilih blok di **Block in your backpack**. Tekan **Refresh block** kalau daftar kosong.
2. Tekan **Atur PNB tiles (5x5)**. Panel kotak 5x5 muncul; kotak tengah **You** adalah posisi karakter. Klik kotak lain untuk memilih tile yang di-place & break. Klik lagi untuk membatalkan. **Clear tiles** menghapus semua pilihan.
3. Atur **Hit delay**: jeda antar pukulan (0,22–2 detik).
4. Opsional, stock dari lantai: berdiri di tempat blok stock berserakan, tekan **Set stock position here**, lalu nyalakan **Auto take stock**.
5. Berdiri di posisi PNB, lalu nyalakan **Place & Break**. Posisi PNB adalah tempat karakter berdiri saat toggle dinyalakan.

Peta tile juga tampil sebagai teks di tab: `[Y]` = karakter, `[#]` = tile terpilih.

### Cara kerja

1. Taruh blok di setiap tile terpilih yang kosong, urut dari atas ke bawah, kiri ke kanan. Setiap place dicek ke server: blok di tas harus berkurang satu.
2. Pukul setiap tile sampai pecah, dengan jeda **Hit delay** di antara pukulan.
3. Pungut seed, gem, dan blok yang jatuh di sekitar grid (2,75 tile ke samping, 3 ke atas, 2,5 ke bawah). Drop yang ditolak server 3 kali dilewati, PNB tetap lanjut.
4. Blok di tas habis: dengan **Auto take stock**, jalan ke stock position, lalu datangi tiap tumpukan blok dalam area 6 tile kiri-kanan (3 atas, 2 bawah) sampai tas penuh atau area kosong, lalu kembali. Hasilnya tercatat di diagnostics (`Stock terakhir`). Tanpa itu, PNB berhenti.

| Status | Artinya |
| --- | --- |
| `Selesai: blok di tas habis.` | Blok habis dan Auto take stock mati |
| `Selesai: stock blok di lantai habis.` | Tidak ada blok lagi di stock position |
| `Semua tile PNB terhalang blok lain.` | Semua tile terpilih berisi blok lain; kosongkan atau pilih tile lain |
| `Karakter bergeser; kembali ke posisi PNB...` | Karakter terdorong saat place/break; script jalan balik ke spot dan lanjut |
| `Karakter terus bergeser dari posisi PNB` | Terdorong lebih dari 10 kali dalam 1 menit; PNB berhenti |

### Auto drop seed dan perekam aksi

Cara game men-drop item ke lantai belum diketahui, jadi **Auto drop seed belum bisa dipakai**. Untuk menemukannya:

1. Tekan **Rekam aksi drop (30 detik)**.
2. Dalam 30 detik itu, drop seed **secara manual** sekali.
3. Tunggu sampai status berubah jadi `Rekaman selesai` (30 detik), baru buka **Settings → Copy diagnostics**. Bagian `Rekaman aksi game` berisi panggilan yang jarang terjadi (aksi manual lo); fungsi yang dipanggil tiap frame cuma diringkas di baris `Sering (diabaikan)`. Perekam juga menyadap semua kiriman ke server (`remote ...:FireServer`); baris `Sadap server` menunjukkan apakah executor mendukungnya.

Kirim hasil itu untuk dibuatkan Auto drop seed. Perekam hanya mencatat; ia tidak mengirim apa pun ke server, dan fungsi asli dipulihkan setelah 30 detik.

## Planting

Planting mengisi tanah kosong di setiap world farm dengan seed, berurutan sesuai daftar world. Logikanya sama dengan Planting di Claris Growblox v0.1.43.

### Requirements

- Satu **world storage** berisi Display Box yang **hanya berisi seed** yang mau ditanam.
- Satu atau lebih **world farm** yang bisa dimasuki langsung pakai nama. World storage tidak boleh ada di daftar farm.
- Baris tanam: tile kosong dengan **tanah padat atau platform tepat di bawahnya**. Baris harus bisa dicapai dengan jalan atau lompat dari pintu masuk world.
- Izin edit di area farm (world lock / area lock). Tile tanpa izin dilewati.
- Tas punya tempat untuk seed.

### Setup

1. Masuk ke **world storage** dan berdiri di sebelah Display Box seed.
2. Buka tab **Planting**, tekan **Save seed Display Box**. World storage dan jenis seed ikut terisi otomatis dari isi box.
3. Kalau box masih kosong, pilih seed di **Seed to plant**. Pakai **Find seed by name or ID** kalau seed-nya tidak muncul.
4. Isi **Dirt farm worlds (in order)**, dipisah koma:

   ```text
   FARM1, FARM2, FARM3
   ```

5. Nyalakan **Plant seeds**.

### Cara kerja

1. Script masuk ke farm pertama dan mendeteksi baris tanam. Kalau ada dua baris atau lebih yang lebarnya minimal 3 tile, baris pendek (box, batu pijakan) diabaikan.
2. Menanam mulai dari baris paling atas, **zigzag**: baris ke-1 kiri ke kanan, baris ke-2 kanan ke kiri, dan seterusnya.
3. Seed ditanam **sambil jalan**, maksimal 8 seed per batch. Setiap batch dicek ke server: jumlah seed di tas harus berkurang sesuai tile yang benar-benar tertanam.
4. Tile yang ditolak atau tidak terkonfirmasi tidak menghentikan task. Tile itu ditunda dan dicoba **sekali lagi dari baris di bawahnya**. Kalau masih gagal, tile dilewati dan dicatat.
5. Seed di tas habis: script ke world storage, ambil seed dari box, lalu kembali ke farm dan baris yang sama.
6. Farm selesai: lanjut ke world berikutnya. Semua farm selesai: task berhenti dengan status `Finished planting all configured farms.`
7. Box seed kosong: task berhenti dengan status `Planting stopped: the seed storage box is empty.` dan menyebut farm yang belum selesai.

| Status / tile | Artinya |
| --- | --- |
| `Processed FARM1: N tiles skipped due to access or route.` | Farm selesai; N tile dilewati karena tidak terjangkau atau tidak ada izin |
| `Retrying planting at X, Y from below...` | Mencoba ulang tile tertunda dari baris di bawahnya |
| `Trying another route around the obstacle...` | Rute jalan gagal, script merencanakan rute lain (maks 4 kali) |
| `skipped N unconfirmed tiles near X, Y` | Server tidak mengonfirmasi N seed; tile ditunda, task lanjut |

### Pindah server dan resume

Sebelum masuk world, progress disimpan: world ke berapa, baris terakhir, tile yang dilewati, dan batch seed yang belum terkonfirmasi. Kalau masuk world membuat pindah server, script dijalankan lagi otomatis dan **Planting lanjut sendiri** (butuh executor yang punya `queue_on_teleport`).

Kalau tidak lanjut otomatis, jalankan loader lagi lalu tekan **Resume planting**. Checkpoint berlaku 6 jam.

Kalau task berhenti saat **mengambil seed dari box**, script menolak resume karena tidak tahu apakah seed sudah masuk tas. Cek tas dan box, lalu tekan **Clear saved planting** dan mulai lagi.

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
| `The saved Display Box must be in the entered storage world` | World storage beda dengan world tempat box disimpan | Simpan ulang box dengan **Save seed Display Box** |
| `This storage box contains a different item` | Box seed berisi item lain | Pakai box yang khusus berisi satu jenis seed |
| `Could not reach the saved position` | Rute ke baris/box terhalang | Buka jalan, tambah pijakan, atau pindahkan box |
| `A seed storage withdrawal was interrupted` | Task berhenti saat mengambil seed | Cek tas dan box, **Clear saved planting**, mulai lagi |

**Copy diagnostics** menyalin versi, world, status, hasil pencarian objek game, dan 15 baris log terakhir. Kirim teks itu saat melaporkan masalah.

## Pertanyaan umum

**Kenapa versi baru belum muncul?** GitHub menyimpan `main/loader.lua` di cache sampai 5 menit. Tunggu sebentar lalu execute ulang. Auto-resume setelah pindah server tidak terpengaruh: ia selalu memakai versi yang sama dengan yang sedang jalan.

**Apakah harus download ulang setiap kali?** Tidak. Rilis yang sama diambil dari cache. Download baru hanya terjadi saat ada rilis baru.

**Apakah bisa dipakai banyak akun?** Bisa. Setting dan profil disimpan per `UserId`, jadi akun yang berbeda tidak saling menimpa.

**Bagaimana cara menghentikan script?** **Settings → Unload script**. Menutup jendela juga menghentikannya.

## Untuk developer

Struktur kode, cara build, tes offline, dan cara merilis versi baru ada di [DEVELOPMENT.md](DEVELOPMENT.md).

## Kredit

Struktur dan sebagian fungsi diadaptasi dari [Claris Growblox Autofarm](https://github.com/Clarissv/Claris-Growblox-Autofarm) karya Clarissv. Bagian yang diadaptasi ditandai di komentar setiap file. UI memakai [WindUI](vendor/WindUI.LICENSE) (lisensi MIT).
