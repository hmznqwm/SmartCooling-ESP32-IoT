# 📱 Smart Cooling & Smoke Exhaust Remote (Flutter & Dart)

Aplikasi mobile kontrol dan monitoring jarak jauh (*remote control*) berbasis **Flutter & Dart** untuk sistem pendingin dan evakuasi asap industri:
**ESP32 + Sensor DHT22 + Sensor Kualitas Udara & Asap MQ-135 + MOSFET PWM + Alarm Buzzer + Smart RGB LED**.

## Skematik Rangkaian Simulasi Wokwi (ESP32 + DHT22 + MQ-135 + Relay)

![Skematik Rangkaian Wokwi ESP32](docs/skematik_wokwi_esp32.png)

---

## ✨ Fitur Utama Aplikasi

1. **Dial Spidometer Presisi Kualitas Udara & Asap (MQ-135):**
   - Menampilkan estimasi konsentrasi asap / gas dalam satuan **PPM** (0 - 2000 PPM) dan nilai mentah ADC (0 - 4095).
   - Indikator warna dinamis: 🟢 **Aman (<400 PPM)**, 🟡 **Waspada (400-999 PPM)**, 🔴 **Bahaya/Darurat (≥1000 PPM)**.
2. **Monitoring Suhu & Kelembapan Presisi (DHT22):**
   - Spidometer suhu (°C) dan kelembapan (%) realtime via Cloud MQTT (EMQX) atau HTTP Bridge.
3. **Status Kipas Dinamis (PWM 0% - 100%):**
   - Indikator kecepatan kipas dan mode evakuasi darurat otomatis saat terdeteksi asap pekat.
4. **Panel Kendali Jarak Jauh (Remote Buttons):**
   - `🤖 Mode Otomatis` : Prioritas keselamatan asap dan histeresis pendinginan suhu.
   - `⚡ Kipas ON` : Menyalakan kipas secara manual (100%).
   - `🛑 Kipas OFF` : Mematikan kipas secara manual (0%).
5. **Mode Koneksi Fleksibel:**
   - **Cloud MQTT (EMQX):** Realtime via internet tanpa perlu port forwarding.
   - **HTTP Bridge Lokal:** Polling via script `mqtt_bridge.js` di laptop (`:9080`).
   - **Mode Demo Interaktif:** Simulasi slider suhu, kelembapan, dan asap langsung di aplikasi tanpa hardware.

## 🔌 Panduan Cara Menyambungkan Aplikasi dengan ESP32

Aplikasi ini dirancang dengan arsitektur multi-jalur (*hybrid connectivity*) yang fleksibel sesuai kondisi lapangan:

### 1. Jaringan Lokal / WiFi yang Sama (Direct Local IP / HTTP)
* **Kondisi:** Smartphone/Laptop berada di satu jaringan WiFi atau Hotspot yang sama dengan ESP32.
* **Cara Kerja:**
  - ESP32 mendapatkan IP lokal (misalnya `192.168.1.50` atau IP lokal Wokwi).
  - Masukkan IP address ESP32 tersebut ke dalam menu pengaturan koneksi di aplikasi.
  - Aplikasi langsung berkomunikasi melalui protokol HTTP port 80 untuk membaca sensor dan mengirim perintah kontrol secara instan tanpa latensi internet.

### 2. Koneksi Nirkabel Langsung (Bluetooth / BLE)
* **Kondisi:** Digunakan saat berada di dekat alat tanpa tersambung ke jaringan router WiFi.
* **Cara Kerja:**
  - Aktifkan Bluetooth pada HP dan nyalakan perangkat ESP32.
  - Pilih perangkat ESP32 dari daftar pemindaian Bluetooth aplikasi untuk pairing langsung.
  - Pengguna dapat memantau indikator sensor dan menyalakan/mematikan kipas tanpa ketergantungan sinyal internet maupun access point eksternal.

### 3. Jarak Jauh Tanpa Batas via Cloud Broker MQTT (Remote Anywhere)
* **Kondisi:** Pengguna bepergian ke mana saja, di luar rumah/pabrik, atau menggunakan paket data seluler (4G/5G).
* **Cara Kerja:**
  - ESP32 terhubung ke internet dan secara otomatis mempublikasikan data sensor (`DHT22` & `MQ-135`) ke Cloud Broker (`broker.emqx.io`) pada topik `hami_cooling/data`.
  - Aplikasi mobile di HP Anda otomatis mengaktifkan fitur **Cloud Fallback / MQTT Subscriber**.
  - **Hasilnya:** Anda tetap bisa memonitor suhu, mendeteksi asap, dan mengontrol relay kipas dari belahan dunia mana pun secara *realtime* tanpa perlu pengaturan Port Forwarding atau IP Publik statis.

---

## 🚀 Cara Menjalankan & Menghubungkan

### Skenario A: Uji Coba dengan Simulator Wokwi
1. Buka folder `firmware_esp32/` dan jalankan simulasi Wokwi (`diagram.json`).
2. Jalankan aplikasi Flutter:
   ```bash
   cd mobile
   flutter run
   ```
3. Broker default `broker.emqx.io` dengan topik `hami_cooling/data` akan langsung saling terhubung secara otomatis.

### Skenario B: Hardware ESP32 Fisik
1. Upload file `firmware_esp32/sketch.ino` ke modul ESP32 Anda.
2. Masukkan SSID dan Password WiFi tempat alat diletakkan.
3. Buka aplikasi di smartphone, dan sistem siap digunakan baik dalam jaringan lokal maupun jarak jauh.


