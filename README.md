# Growblox Hansel

Panduan untuk **Growblox Hansel 0.6.5**. *Learn to own.*

Script autofarm Growblox (Roblox) yang dibangun bertahap. Versi ini berisi pondasi (menyambung ke game, menyimpan setting per akun) fitur **Planting**, dan **Place & Break**. Fitur lain ditambah satu per satu (lihat [Status fitur](#status-fitur)).

Alur yang dituju setelah semua fitur jadi: **tanam semua farm → PNB selama pohon tumbuh → panen farm yang matang → pindahkan blok dan seed → tanam ulang → ulangi**.

## Daftar isi

- [Status fitur](#status-fitur)
- [Requirements](#requirements)
- [Mulai](#mulai)
- [Tab di jendela](#tab-di-jendela)
- [Place & Break](#place--break)
- [Planting](#planting)
- [Growscan](#growscan)
- [Scan world otomatis](#scan-world-otomatis)
- [Harvest](#harvest)
- [Rotation](#rotation)
- [Settings](#settings)
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
| Place & Break | Place & Break | Place/break dites di game. Pungut 5x5, stock, dan seed ke box: v0.3.5, dites offline |
| Auto Collect | Place & Break | Selesai (v0.3.4), dites offline |
| Planting | Planting | Selesai (v0.2.0), dites offline |
| Scan world otomatis | Harvest, Rotation | v0.6.0: tanaman & Display Box dideteksi sendiri tiap world |
| Growscan (scan manual semua item) | Harvest | v0.6.4, dites offline |
| Harvest (Fist) + Replant during harvest | Harvest | v0.4.0, dites offline |
| Rotation (harvest → PNB → replant, multi world) | Rotation | v0.5.0, dites offline |

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
| **Place & Break** | PNB dengan grid 5x5, hit delay, Auto Collect + jangkauan, stock dan seed lewat Display Box. |
| **Planting** | Tanam seed di daftar world farm, isi ulang dari Display Box. |
| **Harvest** | Harvest multi world (Fist) dengan Replant during harvest. Tanaman & Display Box dideteksi otomatis tiap world. |
| **Rotation** | List world farm sendiri: harvest sampai target blok, PNB di samping, replant, ulang, pindah world. Jalan terus. |
| **Settings** | Status, **Stop task**, **Reconnect to game**, **Copy diagnostics**, Anti-AFK, Rejoin world and return to PNB & Harvest, jeda dan batas waktu, **Unload script**, dan log aktivitas. |

## Place & Break

Place & Break menaruh blok di tile yang dipilih di sekitar karakter, memukulnya sampai pecah, lalu memungut seed, gem, dan blok yang jatuh. Layout tab mengikuti gaya script Crusader; logika place/break diadaptasi dari Claris Growblox v0.1.43.

### Requirements

- Blok yang bisa di-PNB ada di tas (blok biasa yang punya hit; bukan background, lock, door, atau display).
- Izin edit di area PNB.
- Tile yang dipilih kosong. Tile yang berisi blok lain dilewati, tidak dipukul.
- Untuk **Auto take stock**: Display Box berisi blok yang di-PNB saja, di world yang sama dengan PNB.
- Untuk **Auto drop seed**: Display Box kosong (atau berisi seed yang sama) di world PNB.

### Setup

1. Pilih blok di **Block in your backpack**. Tekan **Refresh block** kalau daftar kosong.
2. Tekan **Atur PNB tiles (5x5)**. Panel kotak 5x5 muncul; kotak tengah **You** adalah posisi karakter. Klik kotak lain untuk memilih tile yang di-place & break. Klik lagi untuk membatalkan. **Clear tiles** menghapus semua pilihan.
3. Atur **Hit delay**: jeda antar pukulan (0,22–2 detik).
4. Opsional, stock dari Display Box: berdiri di samping box berisi blok, tekan **Set stock position here**, lalu nyalakan **Auto take stock**.
5. Opsional, buang seed: berdiri di samping Display Box, tekan **Set seed drop position here**, atur batas seed, lalu nyalakan **Auto drop seed**.
6. Berdiri di posisi PNB, lalu nyalakan **Place & Break**. Posisi PNB adalah tempat karakter berdiri saat toggle dinyalakan.

Peta tile juga tampil sebagai teks di tab: `[Y]` = karakter, `[#]` = tile terpilih.

### Cara kerja

1. Taruh blok di setiap tile terpilih yang kosong, urut dari atas ke bawah, kiri ke kanan. Setiap place dicek ke server: blok di tas harus berkurang satu.
2. Pukul setiap tile sampai pecah, dengan jeda **Hit delay** di antara pukulan.
3. Pungut seed, gem, dan blok yang jatuh di sekitar grid (2,75 tile ke samping, 3 ke atas, 2,5 ke bawah). Server cuma terima pungut sejauh sekitar 1 tile, jadi drop di pinggir grid 5x5 didatangi: karakter melangkah ke lantai terdekat, memungut, lalu kembali ke spot. Drop yang tidak terjangkau dilewati, PNB tetap lanjut.
4. Blok di tas habis: dengan **Auto take stock**, jalan ke Display Box stock, ambil blok (`DisplayItem`, cara PNB Claris Growblox: "Refilling blocks from the right storage box"), lalu kembali. Hasilnya di diagnostics (`Stock terakhir`). Tanpa itu, PNB berhenti.
5. Seed di tas mencapai batas: dengan **Auto drop seed**, jalan ke Display Box seed, taruh semua seed (`DisplayItem`, cara PNB Claris Growblox), lalu kembali.

| Status | Artinya |
| --- | --- |
| `Selesai: blok di tas habis.` | Blok habis dan Auto take stock mati |
| `Selesai: Display Box stock kosong.` | Box stock sudah tidak berisi blok |
| `Semua tile PNB terhalang blok lain.` | Semua tile terpilih berisi blok lain; kosongkan atau pilih tile lain |
| `Karakter bergeser; kembali ke posisi PNB...` | Karakter terdorong saat place/break; script jalan balik ke spot dan lanjut |
| `Karakter terus bergeser dari posisi PNB` | Terdorong lebih dari 10 kali dalam 1 menit; PNB berhenti |

### Auto Collect

Toggle **Auto Collect** dan slider **Jangkauan collect (tile)** (0,5 sampai 5, bawaan 2) ada di tab Place & Break.

- **Saat tidak ada task jalan**: tiap 0,3 detik, semua item di lantai (blok, seed, gem, item lain) dalam jangkauan karakter dipungut **tanpa jalan**. Item yang ditolak server 3x dilewati selama 15 detik.
- **Saat PNB jalan**: setelah memecah, PNB memungut semua item di area grid PNB atau jangkauan Auto Collect, mana yang lebih luas. Kalau Auto Collect mati, PNB cuma memungut blok, seed, dan gem di area grid.

### Jangkauan pungut server (diukur otomatis)

Script tidak tahu pasti sejauh apa server Growblox menerima pungut tanpa jalan, jadi **diukur**:

- Selama server belum pernah menolak, tiap pungut di area (grid PNB, baris panen, area stock) dicoba dulu dari tempat berdiri. Jarak tiap pungut dicatat: diterima atau ditolak.
- Jarak terjauh yang pernah **diterima** dipakai sebagai jangkauan berikutnya (maks 5 tile). Kalau server menerima 2 tile, PNB 5x5 memungut semua tanpa jalan.
- Drop yang lebih jauh dari itu didatangi: karakter jalan ke lantai terdekat, pungut, lalu kembali.
- Diagnostics: baris `Jangkauan pungut server: diterima Nx (terjauh X tile), ditolak Nx (terdekat Y tile); dipakai Z tile`.

### Kenapa seed ditaruh ke Display Box, bukan di-drop ke lantai

Perintah server untuk drop item ke lantai belum diketahui; Claris Growblox juga tidak punya. PNB Claris Growblox menaruh seed ke Display Box (`DisplayItem`), dan Auto drop seed memakai cara yang sama. Profil lama yang menyimpan seed drop position di lantai otomatis dikosongkan; set ulang di samping Display Box.

## Planting

Planting mengisi tanah kosong di setiap world farm dengan seed, berurutan sesuai daftar world. Logikanya sama dengan Planting di Claris Growblox v0.1.43.

### Requirements

- Satu **world storage** berisi Display Box dengan seed yang mau ditanam. World storage **boleh sama** dengan dirt farm world (box di world farm itu sendiri).
- Box **boleh berisi item lain**. Game cuma punya perintah "ambil semua", jadi script mengambil semua isi box lalu langsung menaruh balik item lain ke box yang sama; yang tersisa di tas cuma seed yang dipilih. Kalau menaruh balik gagal, Planting berhenti dengan pesan (item itu ada di tas).
- Satu atau lebih **world farm** yang bisa dimasuki langsung pakai nama.
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

## Growscan

Tombol **Scan world (Growscan)** di tab **Harvest** men-scan world yang sedang lo masuki, mirip Growscan di Growtopia. Semua dibaca dari memori game, tanpa request ke server, dan hasilnya tampil lengkap (tanpa batas daftar):

| Bagian | Isi |
| --- | --- |
| Pohon | Per jenis seed: jumlah, mateng, tumbuh, kapan semuanya mateng |
| Floating | Semua item yang melayang, per jenis |
| Blok | Semua blok di world, per jenis |
| Display Box | Isi tiap box |
| Total item | Floating + isi semua Display Box per jenis, contoh `Sugar Cane (954): 1362 (floating 1240, box 122)` |

**Copy hasil Growscan** menyalin hasilnya ke clipboard (kalau executor mendukung); hasil terakhir juga ikut ke **Copy diagnostics**. Batasan: hanya world yang sedang dimasuki, dan hasilnya snapshot.

## Scan world otomatis

Harvest dan Rotation tidak perlu scan manual. Tiap masuk world farm, script otomatis:

1. Membaca seluruh world dari memori game (tanpa request ke server): pohon mateng/tumbuh, item floating, blok, isi Display Box. Laporannya ikut ke **Copy diagnostics** (bagian `World Scan`).
2. Menentukan **tanaman** = jenis seed yang paling banyak ditanam di world itu.
3. Mencari **Display Box** untuk menyimpan: box yang sudah berisi blok/seed tanaman itu didahulukan, lalu box kosong; kalau seri, yang paling dekat. Box berisi item lain tidak disentuh. World tanpa box yang cocok dilewati dengan alasan di daftar world.

Status pohon dihitung dari waktu tanam + lama tumbuh item, sama seperti Claris Growblox. Sejak update Growblox 17 Nov 2026, tabel pohon dicari dengan sidik jari (tabel di sekitar fungsi world yang punya data pohon di tile berisi seed).

## Harvest

Panen pakai Fist, diadaptasi dari Claris Growblox v0.1.43. Bedanya: Claris menunggu **semua** pohon mateng; di sini yang dipanen **pohon yang sudah mateng saja**, yang masih tumbuh dibiarkan.

### Setup

1. Isi **World harvest (urut)**, pisahkan dengan koma (sama seperti list world Planting).
2. Pastikan tiap world punya Display Box kosong atau berisi blok/seed tanamannya (dideteksi otomatis).
3. Opsional: nyalakan **Replant during harvest**.
4. Nyalakan **Harvest**. Semua world di list dipanen satu kali jalan.

### Cara kerja

1. Per world: masuk, scan otomatis (tanaman + Display Box), lalu cek pohon mana yang mateng.
2. Panen baris per baris, zigzag dari atas (sama seperti Planting). Tiap pohon mateng: jalan ke pohon, pukul (maks 3x) sampai tile kosong.
3. **Pukul sambil collect**: hasil tiap pohon langsung dipungut dari tempat berdiri; pickup bawaan game juga tetap nyala saat jalan. Sisa drop di baris itu dipungut sebelum pindah baris.
4. **Replant during harvest** (opsional): tile yang baru dipanen langsung ditanam lagi pakai seed di tas, termasuk seed hasil panen barusan. Tiap tanam dicek ke server; yang ditolak dilewati, panen tetap lanjut.
5. Tas hampir penuh: blok (dan seed lebih dari 100 kalau replant nyala) disimpan dulu ke Display Box world itu, lalu lanjut. Selesai satu world, semua blok dan seed disimpan ke box itu, lalu world berikutnya.
6. Daftar **World harvest** menampilkan per world: dipanen, ditanam ulang, tanaman, mateng/tumbuh, dan box yang dipakai.

Dengan **Rejoin world and return to PNB & Harvest** nyala: keluar ke world picker atau avatar mati saat Harvest = masuk lagi ke world yang sedang dipanen, scan ulang, lanjut panen (pohon yang sudah dipanen tidak dihitung lagi). Berhenti kalau gagal 3x berturut-turut tanpa ada pohon yang berhasil dipanen di antaranya. Pindah server: script dimuat ulang (butuh `queue_on_teleport`) dan Harvest lanjut dari checkpoint.

Belum ada: panen pakai Dear John Tractor, dan menunggu otomatis sampai pohon berikutnya mateng.

## Rotation

Rotation versi Hansel (bukan Full Rotation Claris). List world-nya **terpisah** dari list world Planting.

### Setup

1. Isi **World farm rotasi (urut)**, pisahkan dengan koma.
2. Atur **Harvest sampai blok di tas** (bawaan 180).
3. Nyalakan **Rotation**. Tanaman dan Display Box tiap world dideteksi otomatis saat masuk world.

Display Box tidak wajib untuk Rotation: kalau di world itu tidak ada box kosong / berisi seed-blok tanamannya, rotasi tetap jalan dan seed sisa tetap di tas (diagnostics: `Catatan box`). World yang dilewati (misal tidak ada pohon) alasannya muncul di status dan diagnostics (`World rotasi ...`).

### Cara kerja

Per world, berurutan:

1. Masuk world, scan otomatis (tanaman + Display Box), cek pohon.
2. **Harvest** pohon yang mateng (zigzag dari atas, pukul sambil collect) sampai blok di tas mencapai target.
3. **PNB** di tempat berhenti panen: 1 tile kosong di samping (kanan dulu, lalu kiri), sampai blok habis. Kalau di situ tidak ada tile kosong, karakter pindah ke tile bekas panen lain yang sampingnya kosong. Kalau tetap tidak ada, Rotation memanen 2 pohon lagi (walau blok sudah mencapai target) supaya ada tile kosong, lalu PNB.
4. **Replant**, urutannya:
   1. lubang (tile kosong yang bisa ditanam) di baris **di atas** posisi sekarang, supaya farm tidak bolong-bolong;
   2. tile yang barusan dipanen, termasuk tile PNB;
   3. tile kosong lain di farm yang bisa ditanam.
   Seed habis = berhenti; sisanya ditanam di putaran berikutnya.
5. Ulangi 1–4 sampai tidak ada pohon mateng di world itu.
6. Simpan **seed** sisa ke Display Box world itu (blok tidak pernah disimpan), lalu lanjut ke world berikutnya.

Setelah world terakhir, balik ke world pertama. Kalau satu putaran penuh tidak ada yang dipanen, Rotation menunggu sampai pohon tercepat mateng (maks 10 menit per tunggu) lalu putar lagi. Di tengah putaran, kalau seed di tas hampir penuh: **replant dulu** (urutan yang sama), baru kalau masih penuh kelebihannya (di atas 100) disimpan ke box world itu. Jadi jarang jalan jauh ke box di tengah PNB.

### Kalau error atau berhenti di tengah jalan

- **Error kecil** saat satu langkah PNB/panen (request ke server timeout, tile berubah saat settle, pukul gagal) dilewati: tunggu 0,5 detik lalu lanjut langkah berikutnya, tanpa mengulang world.
- **Error lain di tengah jalan** (jalan timeout, request box gagal, dll.) tidak langsung menghentikan rotasi: tunggu 3 detik lalu ulangi world itu dari scan. Rotasi baru berhenti kalau gagal **5x berturut-turut tanpa kemajuan** sama sekali.
- **Keluar world / avatar mati / pindah server** ikut setting **Rejoin world and return to PNB & Harvest**: masuk lagi ke world yang sedang dikerjakan dan lanjut dari scan.
- **Checkpoint** (world ke berapa) selalu disimpan saat masuk tiap world dan tiap 2 menit, berlaku 6 jam. Kalau rotasi berhenti karena error atau script dimuat ulang, tekan **Resume rotation** untuk lanjut dari world terakhir. **Stop** manual menghapus checkpoint.
- PNB yang tidak maju 8 putaran berturut-turut (place/break ditolak) dihentikan dan rotasi lanjut ke replant, supaya tidak muter selamanya.

Diagnostics `Waktu rotasi` menunjukkan berapa detik habis di tiap tahap (harvest, PNB, replant, masuk & scan world, simpan seed), rata-rata per pohon/blok/tile, dan persentasenya, supaya optimasi berikutnya berdasarkan data. Saat PNB, pungut drop dilewati kalau di area belum ada drop (tanpa jeda dan tanpa request inventory); drop yang muncul belakangan terambil di putaran berikutnya.

Daftar **World rotasi** dan diagnostics (`Rotation:`) menampilkan total dipanen, blok PNB, ditanam ulang, tile kosong yang tersisa, berapa kali diulang karena error, error kecil yang dilewati, dan error terakhir.

## Settings

Diadaptasi dari tab Settings Claris Growblox v0.1.43. Setting cuma bisa diubah saat tidak ada task jalan, dan tersimpan di profil.

| Setting | Bawaan | Fungsi |
| --- | --- | --- |
| **Anti-AFK** | On | Saat Roblox mendeteksi idle, script mengirim klik virtual (`VirtualUser`), maksimal sekali per menit, supaya tidak di-kick karena AFK. |
| **Rejoin world and return to PNB & Harvest** | On | Kalau keluar ke world picker, avatar mati, atau pindah server: **PNB** masuk lagi ke world PNB (maks 3 percobaan), jalan balik ke spot, lalu lanjut. **Harvest** masuk lagi ke world farm, scan ulang, lalu lanjut panen. Juga dipakai Planting untuk lanjut dari checkpoint. |
| **Jeda setelah place** | 0,2 dtk | Jeda setelah menaruh blok/seed. |
| **Waktu tunggu drop** | 0,1 dtk | Jeda sebelum memungut drop. |
| **Batas waktu request server** | 10 dtk | Request ke server yang lebih lama dari ini dianggap gagal. |
| **Batas waktu jalan** | 30 dtk | Perjalanan karakter yang lebih lama dari ini dianggap gagal. |

Hit delay dan batas seed ada di tab Place & Break.

Mental keluar world (ke world picker, ke world lain, atau karakter hilang sesaat) dianggap bisa dipulihkan, bukan alasan berhenti: task masuk lagi ke world-nya lalu lanjut (PNB balik ke spot, Harvest/Rotation scan ulang lalu lanjut). Kalau script dimuat ulang setelah mental/pindah server dan masih di world picker, script tetap tersambung dari picker (menunggu game sampai ~2 menit) dan task-nya sendiri yang masuk ke world tujuan.

Pindah server saat PNB: kalau executor punya `queue_on_teleport`, script dimuat ulang otomatis di server baru dan PNB dilanjutkan dari checkpoint (spot PNB tersimpan, berlaku 6 jam). Diagnostics menampilkan baris `Anti-AFK` dan `Rejoin & balik ke PNB/Harvest` (berapa kali masuk ulang per task).

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
| `This storage box contains a different item` | Box (Harvest/stock/seed PNB) berisi item lain | Untuk fitur itu pakai box khusus; box seed Planting boleh campur |
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
