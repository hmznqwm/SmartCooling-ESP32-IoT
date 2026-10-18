# ❄️ Smart Cooling & Smoke Exhaust System ESP32 (DHT22 + MQ-135 + Relay 1 Channel)

Sistem pendingin cerdas dan evakuasi asap otomatis berbasis **ESP32** menggunakan:
* **Sensor Suhu & Kelembapan:** DHT22 (GPIO 4)
* **Sensor Kualitas Udara & Asap:** MQ-135 (GPIO 34)
* **Saklar Aktuator:** Modul Relay 1 Channel (GPIO 18) mengendalikan Kipas Dinamo 5V / Exhaust Fan
* **IoT & Remote:** Web Dashboard (Port 80), Bot Telegram, Cloud MQTT (`broker.emqx.io`), dan Aplikasi Mobile Flutter

> **Catatan Konfigurasi:** Sistem ini menggunakan saklar **RELAY murni (ON / OFF)** tanpa driver MOSFET PWM, tanpa dioda flyback tambahan, dan tanpa buzzer alarm.

---

## 📌 Skema Perkabelan (Wiring Diagram)

| Komponen | Pin Komponen | Pin ESP32 | Keterangan |
| :--- | :--- | :--- | :--- |
| **DHT22** | VCC | `3V3` | Daya sensor 3.3V |
| | GND | `GND` | Ground bersama |
| | SDA / Data | `GPIO 4` | Sinyal data digital |
| **MQ-135** | VCC | `3V3` / `VIN` | Daya sensor |
| | GND | `GND` | Ground bersama |
| | A0 (Analog) | `GPIO 34` | Pembacaan ADC (0 - 4095) |
| **Modul Relay** | VCC | `VIN` (5V) | Daya koil relay |
| | GND | `GND` | Ground bersama |
| | IN | `GPIO 18` | Sinyal kendali digital |
| **Kipas 5V** | (+) | `Relay NO` | Melalui kontak relay |
| | (-) | `GND` | Ground daya kipas |
| **Relay COM**| COM | `VIN` (5V) | Sumber daya kipas |

---

## ⚙️ Logika Kontrol Cerdas

1. **Prioritas Keselamatan Asap / Gas (MQ-135):**
   * **Bahaya Pekat (ADC ≥ 2000):** Relay otomatis **ON** (Evakuasi asap darurat maksimum).
   * **Waspada Polusi (ADC ≥ 1400):** Relay otomatis **ON** untuk membersihkan udara.
2. **Kendali Suhu Histeresis (Bila Asap Aman):**
   * **Suhu ≥ 30.0 °C:** Relay **ON** (Kipas mendinginkan ruangan).
   * **Suhu ≤ 28.0 °C:** Relay **OFF** (Kipas standby hemat energi).
   * **Suhu 28.1 – 29.9 °C:** Mempertahankan status relay sebelumnya (mencegah relay cetak-cetek berulang kali).
3. **Mode Manual:**
   * Pengguna dapat memaksa Relay ON atau Relay OFF kapan saja melalui tombol Web, Telegram, atau Aplikasi Mobile.

---

## 🚀 Cara Menjalankan

1. **Simulasi Wokwi:**
   * Buka file `diagram.json` di VS Code.
   * Tekan tombol **Play / Start Simulation**.
2. **Aplikasi Mobile Flutter:**
   * Masuk ke folder `mobile_mq135` dan jalankan `flutter run`.
   * Aplikasi otomatis terhubung via broker `broker.emqx.io` pada topik `hami_cooling/data`.
