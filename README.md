# 📱 Smart Cooling & Smoke Exhaust Remote (Flutter & Dart)

Aplikasi mobile kontrol dan monitoring jarak jauh (*remote control*) berbasis **Flutter & Dart** untuk sistem pendingin dan evakuasi asap industri:
**ESP32 + Sensor DHT22 + Sensor Kualitas Udara & Asap MQ-135 + MOSFET PWM + Alarm Buzzer + Smart RGB LED**.

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

---

## 🚀 Cara Menjalankan & Menghubungkan

### Skenario A: Uji Coba dengan Simulator Wokwi
1. Buka dan jalankan simulasi Wokwi di folder:
   `smartCooling by dht22 and mq135/diagram.json`
2. Jalankan aplikasi Flutter:
   ```bash
   cd mobile
   flutter run
   ```
3. Di tab **MQTT Cloud**, broker default adalah `broker.emqx.io` dengan topik `hami_cooling/data`. Status akan langsung **Terhubung** saat Wokwi mempublikasikan data.

### Skenario B: Hardware ESP32 Fisik
1. Hubungkan ESP32 ke WiFi yang memiliki akses internet.
2. Aplikasi mobile di HP Android akan langsung menerima update data sensor secara realtime dari broker EMQX.

