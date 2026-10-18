/*
  ================================================================================
  SMART INDUSTRIAL COOLING & SMOKE EXHAUST SYSTEM (ESP32)
  Multi-Sensor : DHT22 (Suhu & Kelembapan) + MQ-135 (Sensor Kualitas Udara & Asap)
  Aktuator     : Modul Relay 1 Channel (Mengontrol Kipas Dinamo 5V / Beban Kipas)
  Fitur        : Histeresis Suhu Otomatis, Evakuasi Asap Darurat,
                 Web Dashboard (Port 80), Bot Telegram, Cloud MQTT (broker.emqx.io)
  Catatan      : Murni menggunakan saklar RELAY ON/OFF (Tanpa MOSFET, Tanpa Buzzer).
  ================================================================================
*/

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <UniversalTelegramBot.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include <WebServer.h>
#include <Preferences.h>

// ====== 1. PENGATURAN WIFI ======
#if __has_include(<wokwi_config.h>) || defined(WOKWI_SIMULATION)
  const char *WIFI_SSID = "Wokwi-GUEST";
  const char *WIFI_PASS = "";
#else
  const char *WIFI_SSID = "YOUR_WIFI_SSID";
  const char *WIFI_PASS = "YOUR_WIFI_PASSWORD";
#endif

// ====== 2. CLOUD MQTT BROKER (EMQX - Realtime & Gratis) ======
const char *MQTT_BROKER = "broker.emqx.io";
const int   MQTT_PORT   = 1883;
const char *TOPIC_DATA  = "hami_cooling/data";
const char *TOPIC_CMD   = "hami_cooling/cmd";

// ====== 3. BOT TELEGRAM ======
const char *BOT_TOKEN = "YOUR_TELEGRAM_BOT_TOKEN";
const char *CHAT_ID   = "YOUR_TELEGRAM_CHAT_ID";

// ====== 4. PIN HARDWARE ======
#define DHT_PIN        5    // Data Sensor DHT22 -> GPIO 5 (D5)
#define DHT_TYPE       DHT22
#define MQ135_PIN      34   // Analog Out MQ-135 -> GPIO 34 (ADC1)
#define RELAY_PIN      18   // Sinyal IN Modul Relay -> GPIO 18

// Konfigurasi Logika Modul Relay (Active HIGH: HIGH = Relay Menyala, LOW = Relay Mati)
#define RELAY_ACTIVE_HIGH true

// ====== 5. AMBANG BATAS SISTEM ======
// Suhu Histeresis untuk Kendali Relay Kipas
const float SUHU_KIPAS_NYALA = 30.0; // Suhu >= 30.0 C -> Relay ON (Mendinginkan)
const float SUHU_KIPAS_MATI  = 28.0; // Suhu <= 28.0 C -> Relay OFF (Standby Hemat Daya)

// Ambang Batas Sensor Asap MQ-135 (ADC 0 - 4095 pada ESP32 Fisik)
const int SMOKE_THRESHOLD_WARNING = 2400; // Waspada polusi/asap sedang
const int SMOKE_THRESHOLD_DANGER  = 3200; // Asap pekat / Darurat evakuasi

// Interval Pembacaan Sensor & Polling (ms)
const unsigned long READ_MS = 1500;
const unsigned long POLL_MS = 8000; // Polling Telegram 8s agar simulasi Wokwi tidak lag/freeze

DHT dht(DHT_PIN, DHT_TYPE);
WebServer server(80);
WiFiClient espClient;
PubSubClient mqttClient(espClient);
WiFiClientSecure secured_client;
UniversalTelegramBot bot(BOT_TOKEN, secured_client);
Preferences prefs;

// Variabel Data Sensor & Sistem
float temp = 0.0, hum = 0.0;
int smokeRaw = 0;
int smokePpmEstimate = 0;

bool relayState = false;    // false = Relay OFF, true = Relay ON
bool smokeHazard = false;
bool autoMode = false;      // Default awal FALSE (Manual) agar tidak otomatis online sendiri
bool hasData = false, sensorErr = false;
uint8_t errCount = 0;
String systemStatus = "Memulai sistem pendingin & exhaust...";

// Tracking Waktu
unsigned long lastRead = 0, lastPoll = 0, lastWifiCheck = 0, lastNotifyTry = 0;
unsigned long lastMqttRetry = 0;
bool prevRelayState = false;
bool prevSmokeHazard = false;

// Forward Declaration
void publishMQTTData();
void evaluateSystemLogic();

// ---------- FUNGSI KENDALI RELAY ----------
void setRelay(bool turnOn) {
  relayState = turnOn;
  if (turnOn) {
    pinMode(RELAY_PIN, OUTPUT);
    digitalWrite(RELAY_PIN, LOW); // Tarik ke GND (0V) -> Modul Relay MENYALA
  } else {
    pinMode(RELAY_PIN, INPUT);    // Floating / Hi-Z (Persis seperti kabel IN dicabut) -> Modul Relay PASTI MATI
  }
}

// ---------- FILTER MULTISAMPLING ANALOG MQ-135 ----------
int readFilteredMQ135() {
  long sum = 0;
  const int NUM_SAMPLES = 32;
  for (int i = 0; i < NUM_SAMPLES; i++) {
    sum += analogRead(MQ135_PIN);
    delayMicroseconds(150);
  }
  return (int)(sum / NUM_SAMPLES);
}

// ---------- ESTIMASI PPM KUALITAS UDARA / ASAP MQ-135 ----------
int calculateEstimatedPPM(int rawAdc) {
  // Baseline udara ruangan fisik ESP32 (ADC ~1200 - 1800) = ~400 - 680 PPM (Normal)
  // Menghindari PPM langsung mentok 3000 akibat noise motor DC atau hembusan angin
  if (rawAdc <= 1200) {
    return 400; // Udara sangat bersih / baseline ruangan
  }
  float ratio = (float)(rawAdc - 1200) / (4095.0 - 1200.0);
  int ppm = 400 + (int)(pow(ratio, 1.35) * 2600.0);
  return constrain(ppm, 400, 3000);
}

// ---------- EVALUASI LOGIKA MULTI-SENSOR & RELAY ----------
// ---------- EVALUASI LOGIKA MULTI-SENSOR & RELAY ----------
void evaluateSystemLogic() {
  if (!hasData) return;

  // Evaluasi status indikator asap (untuk alert & visualisasi)
  if (smokeRaw >= SMOKE_THRESHOLD_DANGER) {
    smokeHazard = true;
  } else {
    smokeHazard = false;
  }

  // JIKA MODE OTOMATIS MATI (MODE MANUAL AKTIF):
  // SENSOR SAMA SEKALI TIDAK MENGUBAH / MENIMPA STATUS RELAY!
  // RELAY MURNI MENGIKUTI PERINTAH MANUAL USER (/on atau /off).
  if (!autoMode) {
    if (smokeHazard) {
      systemStatus = relayState ? "Manual: Kipas Relay ON (Peringatan: Asap Pekat!)"
                                : "Manual: Kipas Relay OFF (Peringatan: Asap Pekat!)";
    } else if (smokeRaw >= SMOKE_THRESHOLD_WARNING) {
      systemStatus = relayState ? "Manual: Kipas Relay ON (Waspada Polusi)"
                                : "Manual: Kipas Relay OFF (Waspada Polusi)";
    } else {
      systemStatus = relayState ? "Mode Manual: Kipas Relay ON"
                                : "Mode Manual: Kipas Relay OFF";
    }
    return;
  }

  // JIKA MODE OTOMATIS AKTIF (autoMode == true):
  // 1. Prioritas Evakuasi Asap Pekat & Pencemaran Udara
  if (smokeHazard) {
    systemStatus = "Otomatis: BAHAYA ASAP PEKAT! (Exhaust ON)";
    setRelay(true);
    return;
  } else if (smokeRaw >= SMOKE_THRESHOLD_WARNING) {
    systemStatus = "Otomatis: Waspada Polusi Udara (Exhaust ON)";
    setRelay(true);
    return;
  }

  // 2. Kendali Suhu Otomatis (Histeresis)
  if (temp >= SUHU_KIPAS_NYALA) {
    systemStatus = "Otomatis: Suhu Panas (Kipas Relay ON)";
    setRelay(true);
  } else if (temp <= SUHU_KIPAS_MATI) {
    systemStatus = "Otomatis: Suhu Dingin (Kipas Relay OFF)";
    setRelay(false);
  } else {
    // Zona Histeresis (28.1 - 29.9 C)
    if (relayState) {
      systemStatus = "Otomatis: Mendinginkan Ruangan (Relay ON)";
    } else {
      systemStatus = "Otomatis: Suhu Normal Nyaman (Relay OFF)";
    }
  }
}

// ---------- PEMBACAAN SENSOR ----------
void readSensors() {
  static float smoothedSmokeRaw = -1.0;
  int currentSample = readFilteredMQ135();
  if (smoothedSmokeRaw < 0) {
    smoothedSmokeRaw = currentSample;
  } else {
    // Bobot 75% nilai lama + 25% nilai baru untuk meredam lonjakan dinamo
    smoothedSmokeRaw = (smoothedSmokeRaw * 0.75f) + (currentSample * 0.25f);
  }
  smokeRaw = (int)smoothedSmokeRaw;
  smokePpmEstimate = calculateEstimatedPPM(smokeRaw);

  float h = dht.readHumidity();
  float t = dht.readTemperature();

  if (isnan(t) || isnan(h)) {
    if (errCount < 255) errCount++;
    Serial.println("[Sensor] DHT22 Gagal Dibaca! (Pastikan kabel SDA terhubung ke Pin GPIO 5 / D5)");
    if (errCount >= 3) {
      sensorErr = true;
      hasData = true;
      if (autoMode) {
        systemStatus = "Peringatan: DHT22 Error (Relay ON Safemode)";
        setRelay(true);
      } else {
        systemStatus = relayState ? "Manual: Kipas Relay ON (Sensor Error)"
                                  : "Manual: Kipas Relay OFF (Sensor Error)";
      }
    }
    evaluateSystemLogic();
    publishMQTTData();
    return;
  }

  errCount = 0;
  sensorErr = false;
  hasData = true;
  temp = t;
  hum = h;

  evaluateSystemLogic();
  publishMQTTData();

  String ipStr = (WiFi.status() == WL_CONNECTED) ? WiFi.localIP().toString() : "WiFi Putus";
  Serial.printf("Suhu: %.1f C | Lembap: %.1f %% | MQ-135: %d ADC | Mode: %s | Relay: %s | IP: %s\n",
                temp, hum, smokeRaw,
                autoMode ? "OTOMATIS" : "MANUAL",
                relayState ? "ON" : "OFF", ipStr.c_str());
}

// ---------- PUBLISH DATA KE CLOUD MQTT BROKER ----------
void publishMQTTData() {
  if (!mqttClient.connected()) return;

  char json[380];
  snprintf(json, sizeof(json),
           "{\"valid\":%s,\"temp\":%.1f,\"hum\":%.1f,\"smoke_raw\":%d,\"smoke_ppm\":%d,\"smoke_hazard\":%s,\"relay_state\":%s,\"fan_pct\":%d,\"status\":\"%s\",\"auto\":%s,\"err\":%s}",
           hasData ? "true" : "false", temp, hum, smokeRaw, smokePpmEstimate,
           smokeHazard ? "true" : "false", relayState ? "true" : "false",
           relayState ? 100 : 0, systemStatus.c_str(),
           autoMode ? "true" : "false", sensorErr ? "true" : "false");

  mqttClient.publish(TOPIC_DATA, json, false); // Retain = false agar broker tidak menyimpan data usang saat ESP32 mati
}

// ---------- PROSES PERINTAH DARI APLIKASI / MQTT ----------
void executeCommand(String action) {
  action.trim();
  Serial.println("[Perintah Masuk]: " + action);
  String actLower = action;
  actLower.toLowerCase();

  if (actLower == "/auto" || actLower == "auto" || actLower == "/auto_on" || actLower == "auto_on" || actLower == "/otomatis") {
    autoMode = true;
    evaluateSystemLogic();
    prefs.putBool("auto", true);
    Serial.println("-> Mode Otomatis DIAKTIFKAN. Kendali diserahkan ke sensor.");
  } else if (actLower == "/auto_off" || actLower == "auto_off" || actLower == "/manual" || actLower == "manual") {
    autoMode = false;
    evaluateSystemLogic();
    prefs.putBool("auto", false);
    Serial.println("-> Mode Otomatis DIMATIKAN. Mode Manual aktif.");
  } else if (actLower == "/auto_toggle" || actLower == "auto_toggle") {
    autoMode = !autoMode;
    evaluateSystemLogic();
    prefs.putBool("auto", autoMode);
    Serial.printf("-> Mode Otomatis di-toggle menjadi: %s\n", autoMode ? "ON" : "OFF");
  } else if (actLower == "/on" || actLower == "on" || actLower == "/max") {
    autoMode = false; // Mematikan mode otomatis agar kipas tetap ON biasa
    setRelay(true);
    evaluateSystemLogic();
    prefs.putBool("auto", false);
    prefs.putBool("relay", true);
    Serial.println("-> Mode Manual: Kipas Relay ON biasa.");
  } else if (actLower == "/off" || actLower == "off") {
    autoMode = false; // Mematikan mode otomatis agar kipas tetap OFF biasa (tidak dilawan sensor)
    setRelay(false);
    evaluateSystemLogic();
    prefs.putBool("auto", false);
    prefs.putBool("relay", false);
    Serial.println("-> Mode Manual: Kipas Relay OFF biasa.");
  } else if (actLower == "/toggle" || actLower == "toggle") {
    autoMode = false;
    setRelay(!relayState);
    evaluateSystemLogic();
    prefs.putBool("auto", false);
    prefs.putBool("relay", relayState);
    Serial.printf("-> Mode Manual: Kipas Relay di-toggle: %s\n", relayState ? "ON" : "OFF");
  }

  publishMQTTData();
}

// ---------- CALLBACK MQTT ----------
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String message = "";
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  message.trim();
  executeCommand(message);
}

// ---------- REKONEKSI MQTT ----------
void reconnectMQTT() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (millis() - lastMqttRetry < 4000) return;
  lastMqttRetry = millis();

  String clientId = "ESP32_HamiRelay_" + String(random(0xffff), HEX);
  Serial.print("[MQTT] Menghubungkan ke Cloud Broker (" + String(MQTT_BROKER) + ")...");
  // LWT: Jika ESP32 mati tiba-tiba, broker EMQX akan otomatis mempublish pesan offline
  if (mqttClient.connect(clientId.c_str(), TOPIC_DATA, 0, false, "{\"valid\":false,\"status\":\"Offline\"}")) {
    Serial.println(" Terhubung!");
    mqttClient.subscribe(TOPIC_CMD);
    publishMQTTData();
  } else {
    Serial.printf(" Gagal (rc=%d)\n", mqttClient.state());
  }
}

// ---------- DASHBOARD WEB PORT 80 ----------
const char PAGE[] PROGMEM = R"rawliteral(
<!DOCTYPE html><html lang="id"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sistem Pendingin & Smoke Exhaust ESP32 (Relay)</title>
<style>
:root{--bg:#090d16;--card:#131d31;--border:#1e2e4f;--text:#e2e8f0;--muted:#94a3b8;--primary:#38bdf8;--danger:#ef4444;--warn:#eab308;--success:#22c55e}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--text);padding:20px;text-align:center}
h1{font-size:1.5rem;color:var(--primary);margin-bottom:4px}
.sub{font-size:.85rem;color:var(--muted);margin-bottom:20px}
.container{max-width:720px;margin:0 auto;display:flex;flex-direction:column;gap:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px;text-align:left}
.card .title{font-size:.75rem;color:var(--muted);text-transform:uppercase;font-weight:700;letter-spacing:1px}
.card .val{font-size:1.75rem;font-weight:800;margin-top:6px}
.card.full{grid-column:1/-1}
.badge{display:inline-block;padding:4px 10px;border-radius:20px;font-size:.8rem;font-weight:700;margin-top:8px}
.badge.safe{background:#065f46;color:#a7f3d0}
.badge.warn{background:#854d0e;color:#fef08a}
.badge.danger{background:#991b1b;color:#fecaca}
.banner{padding:12px;border-radius:12px;font-size:.9rem;font-weight:600;display:flex;align-items:center;justify-content:center;gap:8px}
.banner.ok{background:#064e3b;border:1px solid #059669;color:#a7f3d0}
.banner.alert{background:#7f1d1d;border:1px solid #dc2626;color:#fee2e2}
.btn-group{display:flex;gap:8px;flex-wrap:wrap;justify-content:center;margin-top:14px}
button{background:#1e293b;border:1px solid var(--border);color:var(--text);padding:10px 18px;border-radius:10px;font-weight:600;cursor:pointer;font-size:.85rem;transition:all .2s ease}
button:hover{filter:brightness(1.1)}
button.primary{background:#0284c7;color:#fff;border:none}
button.danger{background:#e11d48;color:#fff;border:none}
button.auto-off{background:#475569;color:#cbd5e1;border:1px solid #64748b}
</style></head><body>
<div class="container">
  <div>
    <h1>Smart Cooling & Smoke Exhaust ESP32</h1>
    <div class="sub">Sensor DHT22 &bull; Sensor Asap MQ-135 &bull; Modul Relay 1 Channel &bull; Kipas 5V</div>
  </div>
  <div id="status-banner" class="banner ok">Memeriksa kondisi lingkungan...</div>
  <div class="grid">
    <div class="card">
      <div class="title">Suhu Ruangan</div>
      <div class="val" id="temp">--</div>
    </div>
    <div class="card">
      <div class="title">Kelembapan</div>
      <div class="val" id="hum">--</div>
    </div>
    <div class="card">
      <div class="title">Asap / Gas (MQ-135)</div>
      <div class="val" id="smoke">--</div>
    </div>
    <div class="card">
      <div class="title">Status Saklar Relay</div>
      <div class="val" id="relay">--</div>
    </div>
  </div>
  <div class="card full">
    <div class="title">Panel Kendali Cepat</div>
    <div class="btn-group">
      <button id="btn-auto" class="primary" onclick="toggleAuto()">🤖 Mode Otomatis</button>
      <button class="primary" style="background:#059669" onclick="sendCmd('/on')">⚡ Nyalakan Kipas (Relay ON)</button>
      <button class="danger" onclick="sendCmd('/off')">🛑 Matikan Kipas (Relay OFF)</button>
    </div>
  </div>
</div>
<script>
let isAutoActive = true;
function toggleAuto(){
  sendCmd(isAutoActive ? '/auto_off' : '/auto_on');
}
function sendCmd(act){fetch('/cmd?action='+encodeURIComponent(act)).then(updateData);}
function updateData(){
  fetch('/data').then(r=>r.json()).then(d=>{
    isAutoActive = d.auto;
    document.getElementById('temp').textContent=d.temp+' °C';
    document.getElementById('hum').textContent=d.hum+' %';
    document.getElementById('smoke').textContent=d.smoke_ppm+' PPM ('+d.smoke_raw+' ADC)';
    const rEl=document.getElementById('relay');
    if(d.relay_state){
      rEl.innerHTML='<span style="color:#34d399">MENYALA (ON)</span>';
    }else{
      rEl.innerHTML='<span style="color:#94a3b8">STANDBY (OFF)</span>';
    }
    const btnAuto = document.getElementById('btn-auto');
    if (btnAuto) {
      if (d.auto) {
        btnAuto.className = 'primary';
        btnAuto.innerHTML = '🤖 Mode Otomatis (AKTIF) - Klik utk Matikan';
      } else {
        btnAuto.className = 'auto-off';
        btnAuto.innerHTML = '🖐️ Mode Manual (NONAKTIF) - Klik utk Aktifkan';
      }
    }
    const b=document.getElementById('status-banner');
    b.textContent=d.status;
    b.className=d.smoke_hazard?'banner alert':'banner ok';
  }).catch(()=>{});
}
setInterval(updateData,1500);updateData();
</script></body></html>
)rawliteral";

void handleRoot() {
  server.send_P(200, "text/html", PAGE);
}

void handleData() {
  char json[380];
  snprintf(json, sizeof(json),
           "{\"valid\":%s,\"temp\":%.1f,\"hum\":%.1f,\"smoke_raw\":%d,\"smoke_ppm\":%d,\"smoke_hazard\":%s,\"relay_state\":%s,\"fan_pct\":%d,\"status\":\"%s\",\"auto\":%s,\"err\":%s}",
           hasData ? "true" : "false", temp, hum, smokeRaw, smokePpmEstimate,
           smokeHazard ? "true" : "false", relayState ? "true" : "false",
           relayState ? 100 : 0, systemStatus.c_str(),
           autoMode ? "true" : "false", sensorErr ? "true" : "false");
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "application/json", json);
}

void handleCmd() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  if (server.hasArg("action")) {
    executeCommand(server.arg("action"));
  }
  server.send(200, "text/plain", "OK");
}

// ---------- BOT TELEGRAM ----------
String buildTelegramReport() {
  if (!hasData) return "Belum ada data sensor.";
  String msg = "📊 *STATUS SISTEM ESP32 (RELAY + MQ-135)*\n\n";
  msg += "🌡️ *Suhu:* " + String(temp, 1) + " °C\n";
  msg += "💧 *Kelembapan:* " + String(hum, 1) + " %\n";
  msg += "💨 *Sensor Asap MQ-135:* " + String(smokeRaw) + " ADC (~" + String(smokePpmEstimate) + " PPM)\n";
  msg += "🚨 *Status Asap:* " + String(smokeHazard ? "🔴 BAHAYA PEKAT" : (smokeRaw >= 1400 ? "🟡 WASPADA" : "🟢 AMAN")) + "\n";
  msg += "🔌 *Saklar Relay Kipas:* " + String(relayState ? "⚡ MENYALA (ON)" : "🛑 MATI (OFF)") + "\n";
  msg += "⚙️ *Mode Kendali:* " + String(autoMode ? "🤖 Otomatis (Dikontrol Sensor)" : "🖐️ Manual (Dikontrol Tombol)") + "\n";
  msg += "📌 *Keterangan:* " + systemStatus;
  return msg;
}

void handleTelegramMessages(int numNewMessages) {
  for (int i = 0; i < numNewMessages; i++) {
    String chat_id = String(bot.messages[i].chat_id);
    String text = bot.messages[i].text;
    text.trim();
    String textLower = text;
    textLower.toLowerCase();

    Serial.println("[Telegram] Perintah: " + text);

    if (textLower == "/status" || textLower == "status" || textLower == "/suhu" || textLower == "/asap") {
      bot.sendMessage(chat_id, buildTelegramReport(), "Markdown");
    } else if (textLower == "/auto" || textLower == "/auto_on" || textLower == "/otomatis") {
      executeCommand("/auto_on");
      bot.sendMessage(chat_id, "✅ *Mode Otomatis DIAKTIFKAN*\nSensor sekarang otomatis mengontrol kipas berdasarkan suhu & asap.", "Markdown");
    } else if (textLower == "/manual" || textLower == "/auto_off" || textLower == "manual") {
      executeCommand("/auto_off");
      bot.sendMessage(chat_id, "🖐️ *Mode Otomatis DIMATIKAN*\nSistem beralih ke Mode Manual. Sensor tidak akan menimpa saklar kipas.\nGunakan /on atau /off.", "Markdown");
    } else if (textLower == "/on" || textLower == "/max") {
      executeCommand("/on");
      bot.sendMessage(chat_id, "⚡ *Relay Kipas Dinyalakan (ON)*\n[Mode Manual Aktif - Kipas Tetap ON Biasa]", "Markdown");
    } else if (textLower == "/off") {
      executeCommand("/off");
      bot.sendMessage(chat_id, "🛑 *Relay Kipas Dimatikan (OFF)*\n[Mode Manual Aktif - Kipas Tetap OFF Biasa]", "Markdown");
    } else if (textLower == "/start" || textLower == "/help" || textLower == "help") {
      String help = "🤖 *DAFTAR PERINTAH SMART COOLING ESP32*\n\n";
      help += "📊 `/status` - Cek pembacaan sensor & status relay\n";
      help += "🤖 `/auto` - Nyalakan Mode Otomatis (dikendalikan sensor)\n";
      help += "🖐️ `/manual` - Matikan Mode Otomatis (mode manual)\n";
      help += "⚡ `/on` - Nyalakan Kipas (Relay ON biasa)\n";
      help += "🛑 `/off` - Matikan Kipas (Relay OFF biasa)\n";
      bot.sendMessage(chat_id, help, "Markdown");
    }
  }
}

void checkSafetyNotifications() {
  if (millis() - lastNotifyTry < 20000) return;

  if (smokeHazard && !prevSmokeHazard) {
    lastNotifyTry = millis();
    prevSmokeHazard = true;
    String alert = "🚨 *[PERINGATAN DARURAT ASAP PEKAT]* 🚨\nTerdeteksi asap/gas tinggi: *" +
                   String(smokeRaw) + " ADC* (~" + String(smokePpmEstimate) + " PPM)!\n" +
                   "Status Relay: *MENYALA OTOMATIS (EXHAUST ON)*";
    bot.sendMessage(CHAT_ID, alert, "Markdown");
    return;
  }

  if (!smokeHazard && prevSmokeHazard) {
    lastNotifyTry = millis();
    prevSmokeHazard = false;
    String recovery = "✅ *[KONDISI AMAN KEMBALI]*\nKadar asap telah turun (Nilai: " + String(smokeRaw) + " ADC).\nSistem kembali ke mode normal.";
    bot.sendMessage(CHAT_ID, recovery, "Markdown");
    return;
  }

  if (!smokeHazard && autoMode && relayState != prevRelayState) {
    lastNotifyTry = millis();
    String notif = "🌀 *Pembaruan Status Relay Kipas:*\n" +
                   systemStatus + " (Suhu: " + String(temp, 1) + " °C)\n" +
                   "Relay: *" + String(relayState ? "MENYALA (ON)" : "MATI (OFF)") + "*";
    bot.sendMessage(CHAT_ID, notif, "Markdown");
    prevRelayState = relayState;
  }
}

// ---------- SETUP SISTEM ----------
void setup() {
  Serial.begin(115200);

  // Inisialisasi NVS Flash Storage untuk status persisten
  prefs.begin("cooling", false);
  autoMode = prefs.getBool("auto", false);
  relayState = prefs.getBool("relay", false);
  setRelay(relayState);
  Serial.printf("[NVS Storage] Memuat Mode: %s | Relay: %s\n", autoMode ? "OTOMATIS" : "MANUAL", relayState ? "ON" : "OFF");

  // Inisialisasi Pin Analog MQ-135
  pinMode(MQ135_PIN, INPUT);

  dht.begin();
  lastRead = millis();

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);

  Serial.println("\n[WiFi] Memindai jaringan WiFi sekitar...");
  int n = WiFi.scanNetworks();
  String targetSSID = "realmi 9i";
  bool foundCandidate = false;
  const char *HOTSPOT_LIST[] = {"realmi 9i", "realme 9i", "Realme 9i", "Realmi 9i", "RMX3491"};
  for (int i = 0; i < n; ++i) {
    String scanned = WiFi.SSID(i);
    Serial.printf("  [Scan]: '%s' (%d dBm)\n", scanned.c_str(), WiFi.RSSI(i));
    for (const char *cand : HOTSPOT_LIST) {
      if (scanned.equalsIgnoreCase(cand)) {
        targetSSID = scanned;
        foundCandidate = true;
        break;
      }
    }
    if (foundCandidate) break;
  }

  Serial.printf("[WiFi] Menghubungkan ke: '%s'...\n", targetSSID.c_str());
  WiFi.begin(targetSSID.c_str(), WIFI_PASS);
  unsigned long startW = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startW < 12000) {
    delay(250);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\n[WiFi] TERHUBUNG! IP ESP32: %s\n", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("\n[WiFi] Gagal terhubung. Pastikan Hotspot HP aktif & frekuensi 2.4 GHz.");
  }

  // Setup Cloud MQTT
  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setCallback(mqttCallback);

  secured_client.setInsecure();

  server.on("/", handleRoot);
  server.on("/data", handleData);
  server.on("/cmd", handleCmd);
  server.begin();

  Serial.println("Sistem Smart Cooling & Smoke Exhaust (Relay + MQ-135) Siap Beroperasi!");
}

// ---------- LOOP UTAMA ----------
void loop() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!mqttClient.connected()) {
      reconnectMQTT();
    } else {
      mqttClient.loop();
    }
  }

  if (millis() - lastRead >= READ_MS) {
    lastRead = millis();
    readSensors();
  }

  server.handleClient();

  if (WiFi.status() == WL_CONNECTED && millis() - lastPoll >= POLL_MS) {
    int numNewMessages = bot.getUpdates(bot.last_message_received + 1);
    while (numNewMessages) {
      handleTelegramMessages(numNewMessages);
      numNewMessages = bot.getUpdates(bot.last_message_received + 1);
    }
    lastPoll = millis();
  }

  if (WiFi.status() == WL_CONNECTED) {
    checkSafetyNotifications();
  }

  if (WiFi.status() != WL_CONNECTED) {
    if (millis() - lastWifiCheck > 15000) {
      lastWifiCheck = millis();
      WiFi.disconnect();
      WiFi.begin(WIFI_SSID, WIFI_PASS);
    }
  }
}
