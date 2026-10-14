# Screenshoot

Aplikasi screenshot ala [Lightshot](https://app.prntscr.com/) untuk macOS, berjalan di menu bar. Pilih area layar, coret-coret, lalu copy, simpan, atau upload ke Google Drive. Bisa juga merekam layar per area.

## Fitur

- **Screenshot area**: layar dibekukan dan diredupkan, lalu drag untuk memilih area. Ukuran area dalam pixel tampil di atas seleksi.
- **Alat coret**: pen, garis, panah, kotak, lingkaran, marker (stabilo), dan teks.
- **Pilihan warna**: merah, kuning, hijau, biru, hitam, putih.
- **Tebal coretan**: tipis, sedang, tebal.
- **Output**: copy ke clipboard, simpan PNG, atau upload ke Google Drive (link langsung disalin ke clipboard).
- **Gallery**: daftar screenshot yang sudah diupload ke Google Drive, lengkap dengan thumbnail.
- **Screen record**: rekam area tertentu ke file `.mov` (H.264, 60 fps, kursor ikut terekam).
- **Hotkey global custom** untuk screenshot dan screen record.
- Hasil gambar memakai resolusi penuh Retina, dan mendukung multi-monitor.

## Kebutuhan

- macOS 15 atau lebih baru
- Xcode / Swift toolchain (Swift 5.9+)
- Disarankan: sertifikat **Apple Development** di Keychain, supaya izin Screen Recording tidak hilang setiap build (lihat [Izin](#izin))

## Build & jalankan

```bash
./build.sh
open build/Screenshoot.app
```

`build.sh` melakukan beberapa hal berurutan:

1. Build dengan SwiftPM.
2. Membungkus hasilnya jadi `build/Screenshoot.app`.
3. Menandatangani app (sign). Secara otomatis memakai sertifikat `Apple Development` atau `Developer ID Application` pertama yang ditemukan.

Untuk memakai sertifikat tertentu:

```bash
SIGN_IDENTITY="Apple Development: Nama Kamu (XXXXXXXXXX)" ./build.sh
```

App tidak muncul di Dock. Cari ikon kamera di menu bar.

## Izin

Saat pertama kali dipakai, macOS akan meminta izin **Screen Recording**:

1. Izinkan di **System Settings → Privacy & Security → Screen Recording**.
2. Buka ulang app.

Izin ini terikat ke tanda tangan app. Kalau app di-sign ad-hoc (tanpa sertifikat), izin akan diminta lagi setiap kali build ulang. Untuk menghapus izin lama:

```bash
tccutil reset ScreenCapture com.local.screenshoot
```

> macOS 15+ sesekali menampilkan pengingat bahwa app ini merekam layar. Itu aturan sistem dan tidak bisa dimatikan dari app.

## Cara pakai

### Hotkey global (default)

| Hotkey | Aksi |
|---|---|
| ⇧⌘1 | Screenshot |
| ⇧⌘2 | Mulai screen record (pilih area, lalu Enter). Tekan lagi untuk berhenti. |

Ganti hotkey di **menu bar → Settings… → Hotkey**:

1. Klik tombol hotkey yang ingin diganti.
2. Tekan kombinasi baru. Kombinasi wajib memakai ⌘, ⌥, atau ⌃.
3. Tekan Esc untuk batal.

### Saat memilih area screenshot

| Tombol | Aksi |
|---|---|
| Enter / ⌘C | Copy ke clipboard |
| ⌘S | Simpan PNG |
| ⌘D | Upload ke Google Drive |
| ⌘Z | Undo coretan terakhir |
| Esc | Batal |

Klik ikon alat yang sedang aktif untuk mematikannya. Setelah itu, drag lagi untuk memilih area baru.

### Screen record

1. Tekan hotkey record, lalu pilih area.
2. Tekan Enter atau tombol ⏺ untuk mulai merekam.
3. Selama merekam, ikon menu bar berubah jadi ⏹ merah.
4. Tekan hotkey record lagi, atau pilih **Stop Recording** di menu, untuk berhenti.
5. File `Screen Recording <tanggal>.mov` tersimpan di Desktop, dan Finder terbuka dengan file itu terpilih.

## Upload ke Google Drive

Upload memakai Google Drive API dengan OAuth. Kamu perlu membuat OAuth client sendiri:

1. Buka [Google Cloud Console](https://console.cloud.google.com/) dan buat project.
2. Aktifkan **Google Drive API**.
3. Isi **OAuth consent screen**, lalu tambahkan email kamu sebagai *Test user*.
4. Buka **Credentials → Create credentials → OAuth client ID**, pilih tipe **Desktop app**.
5. Di app: **menu bar → Settings…**, isi **Client ID** dan **Client Secret**, lalu klik **Sign in with Google**.
6. Selesaikan login di browser.

Panduan langkah demi langkah (bahasa Inggris, dengan link langsung ke Google Cloud Console) juga ada di **menu bar → Settings… → Google Drive setup guide**. Kalau login gagal dengan `Error 403: access_denied`, ikuti langkah 5 di panduan itu: tambahkan email kamu sebagai test user, atau publish app.

Setelah login, tekan ⌘D atau tombol ☁️ di toolbar. File diupload ke folder **Screenshoot** di My Drive (dibuat otomatis saat upload pertama), dibuat bisa dilihat siapa saja yang punya link, lalu link-nya disalin ke clipboard.

Nama folder bisa diganti di **Settings… → Folder**. Kalau kolom dikosongkan, file diupload ke root My Drive. Kalau folder dihapus atau masuk Trash, app membuat folder baru pada upload berikutnya.

### Gallery

**Menu bar → Gallery…** menampilkan semua screenshot yang pernah diupload app ini, diurutkan dari yang terbaru. Ini termasuk upload lama di root My Drive.

- Klik dua kali untuk membuka file di browser.
- Klik kanan untuk **Open in Browser** atau **Copy Link**.
- Klik **Refresh** untuk memuat ulang. Kalau Gallery sedang terbuka, daftarnya diperbarui otomatis setelah upload selesai.
- File yang dihapus atau dipindah ke Trash di Drive tidak ditampilkan.

Catatan:

- App hanya memakai scope `drive.file`, jadi hanya bisa mengakses file dan folder yang ia buat sendiri. Folder buatanmu sendiri dengan nama yang sama tidak akan dipakai; app membuat folder sendiri.
- Client Secret dan refresh token disimpan di **Keychain**. Client ID disimpan di UserDefaults. Tidak ada yang disimpan di repo.
- Selama consent screen masih berstatus **Testing**, login kedaluwarsa setelah 7 hari. Publish ke **Production** supaya tidak perlu login ulang tiap minggu.

## Struktur proyek

```
Sources/Screenshoot/
  main.swift         App menu bar, alur capture, ScreenCaptureKit
  Overlay.swift      Overlay seleksi, alat coret, toolbar, copy/save
  GoogleDrive.swift  OAuth (loopback + PKCE), upload, daftar file, Keychain
  Gallery.swift      Jendela Gallery (grid thumbnail file di Drive)
  Settings.swift     Jendela Settings dan toast
  HotKeys.swift      Hotkey global (Carbon) dan perekam kombinasi tombol
  Recorder.swift     Screen record dengan SCRecordingOutput
Icon/
  make-icon.swift    Generator ikon app
  AppIcon.icns       Ikon hasil generator
Info.plist           Bundle info (LSUIElement, ikon, versi minimum)
build.sh             Build + bundle + sign
```

Ikon digambar oleh script. Untuk mengubahnya, edit `Icon/make-icon.swift` lalu jalankan:

```bash
swift Icon/make-icon.swift && ./build.sh
```

## Belum didukung

- Ubah ukuran area seleksi lewat handle (sementara: drag ulang untuk seleksi baru)
- Seleksi yang melewati lebih dari satu monitor
- Rekam suara (sistem maupun mikrofon)
- Upload video ke Google Drive
- Ukuran teks yang bisa diatur (tetap 18 pt)
