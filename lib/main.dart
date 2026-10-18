import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const SmartCoolingApp());
}

typedef SmartCoolingRelayApp = SmartCoolingApp;

class SmartCoolingApp extends StatelessWidget {
  final bool autoConnect;
  const SmartCoolingApp({super.key, this.autoConnect = true});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Cooling',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF0F172A),
          surface: Colors.white,
        ),
        fontFamily: 'Roboto',
      ),
      home: RelayRemoteScreen(autoConnect: autoConnect),
    );
  }
}

class ESP32RelayData {
  final bool valid;
  final double temp;
  final double hum;
  final int smokeRaw;
  final int smokePpm;
  final bool smokeHazard;
  final bool relayState;
  final int fanPct;
  final double tempOn;
  final double tempOff;
  final String status;
  final bool autoMode;
  final bool err;

  ESP32RelayData({
    required this.valid,
    required this.temp,
    required this.hum,
    required this.smokeRaw,
    required this.smokePpm,
    required this.smokeHazard,
    required this.relayState,
    required this.fanPct,
    required this.tempOn,
    required this.tempOff,
    required this.status,
    required this.autoMode,
    required this.err,
  });

  factory ESP32RelayData.initial() {
    return ESP32RelayData(
      valid: false,
      temp: 0.0,
      hum: 0.0,
      smokeRaw: 0,
      smokePpm: 0,
      smokeHazard: false,
      relayState: false,
      fanPct: 0,
      tempOn: 30.0,
      tempOff: 28.0,
      status: 'Menghubungkan ke ESP32...',
      autoMode: false,
      err: false,
    );
  }

  factory ESP32RelayData.fromJson(Map<String, dynamic> json) {
    final bool rState = json['relay'] == true ||
        json['relay_state'] == true ||
        (json['fan_pct'] != null && (json['fan_pct'] as num).toInt() > 0);
    return ESP32RelayData(
      valid: json['valid'] ?? true,
      temp: (json['temp'] as num?)?.toDouble() ?? 0.0,
      hum: (json['hum'] as num?)?.toDouble() ?? 0.0,
      smokeRaw: (json['smoke_raw'] as num?)?.toInt() ?? 0,
      smokePpm: (json['smoke_ppm'] as num?)?.toInt() ?? 0,
      smokeHazard: json['smoke_hazard'] == true,
      relayState: rState,
      fanPct: (json['fan_pct'] as num?)?.toInt() ?? (rState ? 100 : 0),
      tempOn: (json['temp_on'] as num?)?.toDouble() ?? 30.0,
      tempOff: (json['temp_off'] as num?)?.toDouble() ?? 28.0,
      status: json['status'] ?? (rState ? 'Kipas ON' : 'Kipas OFF'),
      autoMode: json['auto'] == true,
      err: json['err'] ?? false,
    );
  }
}

class RelayRemoteScreen extends StatefulWidget {
  final bool autoConnect;
  const RelayRemoteScreen({super.key, this.autoConnect = true});

  @override
  State<RelayRemoteScreen> createState() => _RelayRemoteScreenState();
}

class _RelayRemoteScreenState extends State<RelayRemoteScreen> with TickerProviderStateMixin {
  String host = '172.29.136.105';
  Timer? _pollingTimer;
  SharedPreferences? _prefs;

  bool isConnected = false;
  bool isLoading = false;
  ESP32RelayData data = ESP32RelayData.initial();

  final TextEditingController _ipController = TextEditingController();

  late AnimationController _tempAnimController;
  late Animation<double> _tempAnimation;
  double _prevTemp = 0.0;

  late AnimationController _humAnimController;
  late Animation<double> _humAnimation;
  double _prevHum = 0.0;

  late AnimationController _smokeAnimController;
  late Animation<double> _smokeAnimation;
  double _prevSmoke = 0.0;

  MqttServerClient? _mqttClient;
  bool _isMqttConnected = false;
  bool _isLocalConnected = false;
  Timer? _watchdogTimer;

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    // Jika dalam 3.5 detik tidak ada data segar dari ESP32, otomatis ubah status ke offline (kuning)
    _watchdogTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && isConnected) {
        setState(() {
          isConnected = false;
        });
        debugPrint('[Watchdog] Tidak ada data dari ESP32 dalam 3.5s -> Status: OFFLINE');
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _ipController.text = host;

    _tempAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _tempAnimation = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _tempAnimController, curve: Curves.easeOutCubic),
    );

    _humAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _humAnimation = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _humAnimController, curve: Curves.easeOutCubic),
    );

    _smokeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _smokeAnimation = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _smokeAnimController, curve: Curves.easeOutCubic),
    );

    _loadPersistedSettings();

    if (widget.autoConnect) {
      _startDirectHttp();
    }
  }

  Future<void> _loadPersistedSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final savedHost = prefs.getString('saved_esp32_host');
      final savedAuto = prefs.getBool('saved_esp32_auto_mode');
      final savedRelay = prefs.getBool('saved_esp32_relay_state');

      if (mounted) {
        setState(() {
          if (savedHost != null && savedHost.isNotEmpty) {
            host = savedHost;
            _ipController.text = host;
          }
          final bool currentAuto = savedAuto ?? false;
          final bool currentRelay = savedRelay ?? false;
          data = ESP32RelayData(
            valid: false,
            temp: data.temp,
            hum: data.hum,
            smokeRaw: data.smokeRaw,
            smokePpm: data.smokePpm,
            smokeHazard: data.smokeHazard,
            relayState: currentRelay,
            fanPct: currentRelay ? 100 : 0,
            tempOn: data.tempOn,
            tempOff: data.tempOff,
            status: currentAuto
                ? 'Mode Otomatis Aktif'
                : (currentRelay ? 'Mode Manual: Kipas Relay ON' : 'Mode Manual: Kipas Relay OFF'),
            autoMode: currentAuto,
            err: data.err,
          );
        });
      }
    } catch (e) {
      debugPrint('[SharedPreferences Init Error]: $e');
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _watchdogTimer?.cancel();
    _mqttClient?.disconnect();
    _ipController.dispose();
    _tempAnimController.dispose();
    _humAnimController.dispose();
    _smokeAnimController.dispose();
    super.dispose();
  }

  Future<void> _initMqttFallback() async {
    if (_isMqttConnected && _mqttClient != null) return;
    try {
      final client = MqttServerClient(
        'broker.emqx.io',
        'flutter_hami_${math.Random().nextInt(999999)}',
      );
      client.port = 1883;
      client.keepAlivePeriod = 20;
      client.logging(on: false);
      client.onDisconnected = () {
        _isMqttConnected = false;
        debugPrint('[Cloud MQTT Fallback] Disconnected');
      };

      final connMessage = MqttConnectMessage()
          .withClientIdentifier(client.clientIdentifier)
          .startClean()
          .withWillQos(MqttQos.atMostOnce);
      client.connectionMessage = connMessage;

      await client.connect();
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _mqttClient = client;
        _isMqttConnected = true;
        debugPrint('[Cloud MQTT Fallback] Terhubung ke broker.emqx.io');

        client.subscribe('hami_cooling/data', MqttQos.atMostOnce);
        client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
          for (final msg in messages) {
            final recMess = msg.payload as MqttPublishMessage;
            final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
            try {
              final decoded = jsonDecode(payload) as Map<String, dynamic>;
              // Jika sedang di luar WiFi (lokal gagal), gunakan data realtime dari Cloud MQTT
              if (!_isLocalConnected && mounted) {
                _handleIncomingData(ESP32RelayData.fromJson(decoded));
              }
            } catch (_) {}
          }
        });
      }
    } catch (e) {
      debugPrint('[Cloud MQTT Fallback Error]: $e');
    }
  }

  void _startDirectHttp() {
    _fetchHttpData();
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _fetchHttpData();
    });
  }

  Future<void> _fetchHttpData() async {
    final candidateHosts = [
      host,
      '172.29.136.105',
      '192.168.43.150',
      '192.168.43.100',
      '192.168.43.101',
      '192.168.43.184',
      '192.168.43.200',
      '192.168.1.100',
      '10.0.2.2:9080',
    ];

    bool localSuccess = false;
    for (final h in candidateHosts.toSet()) {
      if (h.isEmpty) continue;
      try {
        final uri = Uri.parse('http://$h/data');
        final response = await http.get(uri).timeout(const Duration(milliseconds: 1200));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body) as Map<String, dynamic>;
          if (mounted) {
            host = h;
            _isLocalConnected = true;
            localSuccess = true;
            _handleIncomingData(ESP32RelayData.fromJson(decoded));
          }
          return;
        }
      } catch (_) {}
    }

    // Jika gagal ke semua host lokal (sedang bepergian jauh / beda WiFi)
    if (!localSuccess) {
      _isLocalConnected = false;
      // Otomatis switch dan dengarkan data dari Cloud MQTT di latar belakang
      _initMqttFallback();
      if (!_isMqttConnected && mounted) {
        setState(() {
          isConnected = false;
        });
      }
    }
  }

  void _handleIncomingData(ESP32RelayData newData) {
    if (!mounted) return;

    // Animasi Suhu
    if ((newData.temp - _prevTemp).abs() > 0.05) {
      _tempAnimation = Tween<double>(
        begin: _prevTemp,
        end: newData.temp,
      ).animate(
        CurvedAnimation(parent: _tempAnimController, curve: Curves.easeOutCubic),
      );
      _tempAnimController.forward(from: 0.0);
      _prevTemp = newData.temp;
    }

    // Animasi Kelembapan
    if ((newData.hum - _prevHum).abs() > 0.1) {
      _humAnimation = Tween<double>(
        begin: _prevHum,
        end: newData.hum,
      ).animate(
        CurvedAnimation(parent: _humAnimController, curve: Curves.easeOutCubic),
      );
      _humAnimController.forward(from: 0.0);
      _prevHum = newData.hum;
    }

    // Animasi Asap / MQ-135
    if ((newData.smokePpm.toDouble() - _prevSmoke).abs() > 2.0) {
      _smokeAnimation = Tween<double>(
        begin: _prevSmoke,
        end: newData.smokePpm.toDouble(),
      ).animate(
        CurvedAnimation(parent: _smokeAnimController, curve: Curves.easeOutCubic),
      );
      _smokeAnimController.forward(from: 0.0);
      _prevSmoke = newData.smokePpm.toDouble();
    }

    setState(() {
      data = newData;
      isConnected = data.valid;
    });

    if (newData.valid) {
      _resetWatchdog();
      _prefs?.setBool('saved_esp32_auto_mode', newData.autoMode);
      _prefs?.setBool('saved_esp32_relay_state', newData.relayState);
    }
  }

  Future<void> _sendCommand(String action) async {
    setState(() => isLoading = true);
    try {
      // Optimistic Local State Update agar UI langsung merespons seketika
      bool? optAuto;
      bool? optRelay;
      String? optStatus;

      if (action == '/auto' || action == '/auto_on') {
        optAuto = true;
        optStatus = 'Mode Otomatis Aktif';
      } else if (action == '/auto_off' || action == '/manual') {
        optAuto = false;
        optStatus = data.relayState ? 'Mode Manual: Kipas Relay ON' : 'Mode Manual: Kipas Relay OFF';
      } else if (action == '/on') {
        optAuto = false;
        optRelay = true;
        optStatus = 'Mode Manual: Kipas Relay ON';
      } else if (action == '/off') {
        optAuto = false;
        optRelay = false;
        optStatus = 'Mode Manual: Kipas Relay OFF';
      }

      if (optAuto != null) {
        _prefs?.setBool('saved_esp32_auto_mode', optAuto);
      }
      if (optRelay != null) {
        _prefs?.setBool('saved_esp32_relay_state', optRelay);
      }

      if (mounted && (optAuto != null || optRelay != null)) {
        setState(() {
          data = ESP32RelayData(
            valid: data.valid,
            temp: data.temp,
            hum: data.hum,
            smokeRaw: data.smokeRaw,
            smokePpm: data.smokePpm,
            smokeHazard: data.smokeHazard,
            relayState: optRelay ?? data.relayState,
            fanPct: (optRelay ?? data.relayState) ? 100 : 0,
            tempOn: data.tempOn,
            tempOff: data.tempOff,
            status: optStatus ?? data.status,
            autoMode: optAuto ?? data.autoMode,
            err: data.err,
          );
        });
      }

      bool sentLocally = false;
      if (_isLocalConnected) {
        try {
          final uri = Uri.parse('http://$host/cmd?action=${Uri.encodeComponent(action)}');
          final resp = await http.get(uri).timeout(const Duration(seconds: 2));
          if (resp.statusCode == 200) {
            sentLocally = true;
            await Future.delayed(const Duration(milliseconds: 250));
            await _fetchHttpData();
          }
        } catch (_) {
          sentLocally = false;
        }
      }

      // Jika tidak sedang satu WiFi lokal, kirim otomatis via Cloud MQTT di latar belakang
      if (!sentLocally) {
        if (_mqttClient == null || !_isMqttConnected) {
          await _initMqttFallback();
        }
        if (_mqttClient != null && _isMqttConnected) {
          final builder = MqttClientPayloadBuilder();
          builder.addString(action);
          _mqttClient!.publishMessage(
            'hami_cooling/cmd',
            MqttQos.atMostOnce,
            builder.payload!,
          );
          debugPrint('[Cloud MQTT Fallback] Perintah terkirim via Cloud: $action');
        }
      }
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  void _showSettingsDialog() {
    _ipController.text = host;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.tune_rounded, size: 20, color: Color(0xFF0F172A)),
            ),
            const SizedBox(width: 12),
            const Text(
              'Pengaturan IP ESP32',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const Text('Alamat IP ESP32 (Hotspot HP):',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF475569))),
              const SizedBox(height: 6),
              TextField(
                controller: _ipController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: '192.168.43.150',
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF0F172A), width: 1.5)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFF64748B)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ESP32 terhubung langsung ke Hotspot HP ("realmi 9i"). Anda bisa melihat IP perangkat di Pengaturan HP > Hotspot Pribadi > Manajemen Perangkat.',
                        style: TextStyle(fontSize: 11, color: Color(0xFF475569), height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0F172A),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              final newIp = _ipController.text.trim();
              if (newIp.isNotEmpty) {
                setState(() {
                  host = newIp;
                });
                _prefs?.setString('saved_esp32_host', host);
                _fetchHttpData();
              }
              Navigator.pop(ctx);
            },
            child: const Text('Simpan & Hubungkan', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 18,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: const Color(0xFFE2E8F0), height: 1.0),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/logo/LogoRemote.png',
                  width: 22,
                  height: 22,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Smart Cooling & Exhaust',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: Color(0xFF0F172A), size: 22),
            onPressed: _showSettingsDialog,
            tooltip: 'Pengaturan IP ESP32',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildConnectionBar(),
              const SizedBox(height: 14),
              _buildTwinGaugesRow(),
              const SizedBox(height: 14),
              _buildMq135GaugeCard(),
              const SizedBox(height: 14),
              _buildStatusSummaryRow(),
              const SizedBox(height: 14),
              _buildControlPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionBar() {
    final Color lampColor = isConnected ? const Color(0xFF16A34A) : const Color(0xFFF59E0B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x060F172A),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.memory_rounded,
                  size: 20,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hardware ESP32 Fisik',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'IP: $host',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: lampColor,
                  boxShadow: [
                    BoxShadow(
                      color: lampColor.withValues(alpha: 0.5),
                      blurRadius: 6,
                      spreadRadius: 1.5,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20, color: Color(0xFF64748B)),
                onPressed: _fetchHttpData,
                tooltip: 'Segarkan Koneksi',
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
              ),
            ],
          ),
        ],
      ),
    );
  }


  Widget _buildTwinGaugesRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Gauge Suhu Ruangan
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x060F172A),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              children: [
                const Center(
                  child: Text(
                    'SUHU RUANGAN',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF64748B),
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _tempAnimController,
                  builder: (context, _) {
                    final double currentVal = _tempAnimController.isAnimating
                        ? _tempAnimation.value
                        : data.temp;

                    return SizedBox(
                      width: 155,
                      height: 148,
                      child: CustomPaint(
                        painter: PrecisionSpeedometerPainter(
                          value: currentVal,
                          min: 0.0,
                          max: 50.0,
                          unit: '°C',
                          marks: const [0, 10, 20, 30, 40, 50],
                          activeColor: data.temp >= data.tempOn
                              ? const Color(0xFFDC2626)
                              : const Color(0xFF0284C7),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),

        // 2. Gauge Kelembapan Udara
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x060F172A),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              children: [
                const Center(
                  child: Text(
                    'KELEMBAPAN',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF64748B),
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _humAnimController,
                  builder: (context, _) {
                    final double currentVal = _humAnimController.isAnimating
                        ? _humAnimation.value
                        : data.hum;

                    return SizedBox(
                      width: 155,
                      height: 148,
                      child: CustomPaint(
                        painter: PrecisionSpeedometerPainter(
                          value: currentVal,
                          min: 0.0,
                          max: 100.0,
                          unit: '%',
                          marks: const [0, 20, 40, 60, 80, 100],
                          activeColor: const Color(0xFF0284C7),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMq135GaugeCard() {
    final double smokePpmVal = data.smokePpm.toDouble();
    final bool isHazard = data.smokeHazard || smokePpmVal >= 1000.0;
    final bool isWarning = !isHazard && (smokePpmVal >= 400.0 || data.smokeRaw >= 1400);

    final Color statusColor = isHazard
        ? const Color(0xFFE11D48)
        : (isWarning ? const Color(0xFFF59E0B) : const Color(0xFF10B981));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isHazard ? const Color(0xFFFDA4AF) : const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: isHazard ? const Color(0x18E11D48) : const Color(0x060F172A),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: isHazard ? const Color(0xFFFFE4E6) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.air_rounded,
                  size: 15,
                  color: isHazard ? const Color(0xFFE11D48) : const Color(0xFF475569),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'KUALITAS UDARA & ASAP',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF64748B),
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: _smokeAnimController,
            builder: (context, _) {
              final double currentVal = _smokeAnimController.isAnimating
                  ? _smokeAnimation.value
                  : smokePpmVal;

              final Color activeColor = currentVal >= 1000.0
                  ? const Color(0xFFE11D48)
                  : (currentVal >= 400.0 ? const Color(0xFFF59E0B) : const Color(0xFF10B981));

              return Center(
                child: SizedBox(
                  width: 175,
                  height: 156,
                  child: CustomPaint(
                    painter: PrecisionSpeedometerPainter(
                      value: currentVal,
                      min: 0.0,
                      max: 2000.0,
                      unit: 'PPM',
                      marks: const [0, 400, 800, 1200, 1600, 2000],
                      activeColor: activeColor,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed_rounded, size: 14, color: Color(0xFF64748B)),
                    const SizedBox(width: 5),
                    Text(
                      'ADC: ${data.smokeRaw}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                    boxShadow: [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.45),
                        blurRadius: 6,
                        spreadRadius: 1.5,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusSummaryRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x060F172A),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'STATUS KIPAS',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: data.relayState ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      data.relayState ? 'AKTIF' : 'STANDBY',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: data.relayState ? const Color(0xFF16A34A) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x060F172A),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MODE SISTEM',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: data.autoMode ? const Color(0xFF0F172A) : const Color(0xFF0284C7),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        data.autoMode ? 'OTOMATIS' : 'MANUAL',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x060F172A),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'KONTROL PENDINGIN',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: Color(0xFF64748B)),
              ),
              if (isLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0F172A)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 1. Tombol Mode Otomatis (Simpel: Logo + Tulisan Otomatis + Ket ON/OFF)
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                if (data.autoMode) {
                  _sendCommand('/auto_off');
                } else {
                  _sendCommand('/auto_on');
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: data.autoMode ? const Color(0xFF0284C7) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: data.autoMode ? const Color(0xFF0284C7) : const Color(0xFFCBD5E1),
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.autorenew_rounded,
                          size: 20,
                          color: data.autoMode ? Colors.white : const Color(0xFF475569),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Otomatis',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: data.autoMode ? Colors.white : const Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: data.autoMode ? Colors.white : const Color(0xFF64748B),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        data.autoMode ? 'ON' : 'OFF',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: data.autoMode ? const Color(0xFF0284C7) : Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 2. Tombol Kipas ON & Kipas OFF
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF059669),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _sendCommand('/on'),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.power_rounded, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Kipas ON',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE11D48),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _sendCommand('/off'),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.power_off_rounded, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Kipas OFF',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// PrecisionSpeedometerPainter: Desain dial spidometer presisi dengan jarum ramping & solid
class PrecisionSpeedometerPainter extends CustomPainter {
  final double value;
  final double min;
  final double max;
  final String unit;
  final List<double> marks;
  final Color activeColor;

  PrecisionSpeedometerPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.marks,
    required this.activeColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height * 0.48);
    final double radius = size.width * 0.38;

    const double startAngle = 140 * (math.pi / 180);
    const double sweepAngle = 260 * (math.pi / 180);

    // 1. Solid Neutral Track (Round stroke cap for elegant smooth ends)
    final Paint trackPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13.0
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    // 2. Solid Active Progress Arc (Tanpa Gradasi, Round stroke cap)
    final double clampedVal = value.clamp(min, max);
    final double progress = (clampedVal - min) / (max - min);
    final double activeSweep = sweepAngle * progress;

    if (activeSweep > 0.01) {
      final Paint activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 13.0
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        activeSweep,
        false,
        activePaint,
      );
    }

    // 3. Ticks dan Label Skala Angka
    final double labelRadius = radius - 16.0;

    for (final mark in marks) {
      final double markProgress = (mark - min) / (max - min);
      final double markAngle = startAngle + (sweepAngle * markProgress);

      final double lx = center.dx + labelRadius * math.cos(markAngle);
      final double ly = center.dy + labelRadius * math.sin(markAngle);

      final textSpan = TextSpan(
        text: mark.toInt().toString(),
        style: const TextStyle(
          color: Color(0xFF64748B),
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(lx - (textPainter.width / 2), ly - (textPainter.height / 2)),
      );
    }

    // 4. JARUM PENUNJUK RAMPING PRESISI (Sleek Needle Pointer dengan Counterbalance)
    final double needleAngle = startAngle + activeSweep;
    final double needleLength = radius - 3.0;

    // Ujung depan jarum (runcing tajam)
    final double tipX = center.dx + needleLength * math.cos(needleAngle);
    final double tipY = center.dy + needleLength * math.sin(needleAngle);

    // Ekor belakang jarum (counterbalance khas instrumen presisi)
    final double counterLength = radius * 0.16;
    final double tailX = center.dx - counterLength * math.cos(needleAngle);
    final double tailY = center.dy - counterLength * math.sin(needleAngle);

    // Sisi samping jarum (ramping: lebar 2.2 pixel)
    final double baseWidth = 2.2;
    final double perpAngle = needleAngle + (math.pi / 2);
    final double p1x = center.dx + baseWidth * math.cos(perpAngle);
    final double p1y = center.dy + baseWidth * math.sin(perpAngle);
    final double p2x = center.dx - baseWidth * math.cos(perpAngle);
    final double p2y = center.dy - baseWidth * math.sin(perpAngle);

    final Path needlePath = Path()
      ..moveTo(tailX, tailY)
      ..lineTo(p1x, p1y)
      ..lineTo(tipX, tipY)
      ..lineTo(p2x, p2y)
      ..close();

    final Paint needlePaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;

    canvas.drawPath(needlePath, needlePaint);

    // Titik Poros Tengah (3-Layered Precision Center Pin)
    final Paint centerOuter = Paint()..color = const Color(0xFF0F172A);
    canvas.drawCircle(center, 5.5, centerOuter);

    final Paint centerRing = Paint()..color = Colors.white;
    canvas.drawCircle(center, 3.2, centerRing);

    final Paint centerDot = Paint()..color = const Color(0xFF0F172A);
    canvas.drawCircle(center, 1.5, centerDot);

    // 5. Pembacaan Digital Nilai & Satuan di Tengah Bawah
    final String valString = (max > 100 && value >= 10)
        ? value.round().toString()
        : value.toStringAsFixed(1);
    final valueSpan = TextSpan(
      text: valString,
      style: const TextStyle(
        color: Color(0xFF0F172A),
        fontSize: 22,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.5,
      ),
    );
    final valuePainter = TextPainter(
      text: valueSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    final double valY = center.dy + 23;
    valuePainter.paint(
      canvas,
      Offset(center.dx - (valuePainter.width / 2), valY),
    );

    final unitSpan = TextSpan(
      text: unit,
      style: const TextStyle(
        color: Color(0xFF64748B),
        fontSize: 11.5,
        fontWeight: FontWeight.bold,
      ),
    );
    final unitPainter = TextPainter(
      text: unitSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    unitPainter.paint(
      canvas,
      Offset(center.dx - (unitPainter.width / 2), valY + valuePainter.height - 2),
    );
  }

  @override
  bool shouldRepaint(covariant PrecisionSpeedometerPainter oldDelegate) {
    return oldDelegate.value != value || oldDelegate.activeColor != activeColor;
  }
}
