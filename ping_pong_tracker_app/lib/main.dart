import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'motion_estimator.dart';
import 'hit_detector.dart';

// App version, shown top-right. Bump on app changes (1.0, 1.1, ...).
const String kAppVersion = "1.1";

/// Where the value readout appears when hovering a graph.
/// follow = tracks the hovered point; left/right = pinned corner;
/// adaptive = opposite the finger.
enum HoverReadoutPos { follow, left, right, adaptive }

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.info, color: true);
  runApp(const PingPongTrackerApp());
}

class PingPongTrackerApp extends StatelessWidget {
  const PingPongTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Paddle Tracker BLE Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const BLETestScreen(),
    );
  }
}

/// One finished logging session, held in memory (right-sized columnar arrays).
class SavedLog {
  final int id;
  final DateTime timestamp;
  final Float64List t; // seconds
  final List<Float32List> axes; // ax, ay, az, gx, gy, gz
  final int count;
  final double durationSec;
  String name; // user label; empty => display falls back to "Log #id"
  final List<double> hitTimes; // detected ball-hit times (s, rebased to log)

  SavedLog(
    this.id,
    this.timestamp,
    this.t,
    this.axes,
    this.count,
    this.durationSec, {
    this.name = "",
    this.hitTimes = const [],
  });

  String get displayName => name.isEmpty ? "Log #$id" : name;
}

class BLETestScreen extends StatefulWidget {
  const BLETestScreen({super.key});

  @override
  State<BLETestScreen> createState() => _BLETestScreenState();
}

class _BLETestScreenState extends State<BLETestScreen>
    with SingleTickerProviderStateMixin {
  // ---- Connection state ----
  BluetoothDevice? _targetDevice;
  StreamSubscription<List<int>>? _charSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  String _connectionStatus = "Disconnected";
  bool _isConnecting = false;

  final String targetDeviceName = "PaddleTrack";
  final Guid uartServiceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Guid txCharacteristicUuid = Guid(
    "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
  );
  // Firmware version characteristic (read once on connect).
  final Guid versionCharacteristicUuid = Guid(
    "6E400004-B5A3-F393-E0A9-E50E24DCCA9E",
  );
  // Firmware version reported by the board; "?" until read on connect.
  String _firmwareVersion = "?";

  // ---- Live display ----
  List<String> _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
  // Battery % from packet byte 1 (not accurate without a battery attached).
  String _batteryPct = "--";

  // Orientation + velocity estimator (sensor fusion), fed every sample.
  final MotionEstimator _motion = MotionEstimator();

  // Ball-hit detector, fed every sample; detected hit times (absolute stream
  // seconds) are buffered so a finalized log can mark the hits inside its window.
  final HitDetector _hitDetector = HitDetector();
  final List<double> _recentHits = [];

  int _samplesInWindow = 0;
  DateTime? _windowStart;
  String _sampleRateStr = "0";

  static const double _accelScaleG = 0.488 / 1000.0; // +/-16 g  -> G per count
  static const double _gyroScaleDps = 70.0 / 1000.0; // 2000 dps -> dps per count
  static const double _odrHz = 1660.0; // fixed IMU output data rate

  // ---- Auto-capture (motion-triggered logging) ----
  // Instead of a manual start/stop button, we continuously watch the incoming
  // stream and auto-record a fixed window around any strong motion (a swing).
  // Trigger: each detected BALL HIT (from the vibration hit detector) starts a
  // capture. A ring buffer supplies the "before" history; recording then
  // continues for the same amount AFTER the hit. So every hit becomes its own
  // log with `_hitWindowSec` of data on each side (default 1 s).
  static const int kMaxLogSamples = 20000; // ~12 s headroom at 1660 Hz
  static const int _kRingCap = 3400; // ~2 s of pre-hit history (max window)

  bool _armed = false; // auto-capture enabled (watching for a hit)
  bool _recording = false; // currently capturing a window around a hit

  // Manual logging (used when automatic logging is turned off): a Start/Stop
  // button records straight into the capture buffer until stopped or a timeout.
  bool _isManualLogging = false;
  Timer? _autoStopTimer;

  // Free-running clock + last-packet time, for continuous per-sample timestamps
  // (kept running the whole session so ring/capture times are consistent).
  final Stopwatch _streamStopwatch = Stopwatch();
  int _lastStreamPacketUs = 0;

  // Ring buffer of recent samples (absolute stream time + 6 axes).
  Float64List? _ringT;
  List<Float32List>? _ringAxes;
  int _ringHead = 0; // next write slot
  int _ringLen = 0; // valid samples held

  // In-progress capture; times are absolute stream seconds (rebased on finalize).
  Float64List? _capT;
  List<Float32List>? _capAxes;
  int _capCount = 0;
  double _triggerSec = 0; // absolute time the current capture triggered

  // Finished logs (newest first) and the one currently open for viewing.
  final List<SavedLog> _logs = [];
  int _logSeq = 0;
  SavedLog? _selectedLog;
  // Velocity magnitude recomputed from each log's raw data (cached by log id).
  final Map<int, SpeedSeries> _speedCache = {};

  // ---- Log detail view: scroll + jump-to-top ----
  final ScrollController _detailScroll = ScrollController();
  final GlobalKey _chartsKey = GlobalKey(); // measures the charts block height
  double _chartsHeight = 0; // charts (item 0) height in px; 0 until measured
  bool _showJumpTop = false; // show jump-to-top once the charts scroll off

  // ---- Settings (persisted) ----
  static const String _kAutoLoggingKey = "autoLoggingEnabled";
  static const String _kHitWindowKey = "hitWindowSec";
  static const String _kManualTimeoutKey = "manualTimeoutSec";
  static const String _kHitThreshKey = "hitThreshG";
  static const String _kLeverArmKey = "leverArmCm";
  static const String _kResetLogsKey = "resetLogsOnLeave";
  static const String _kHoverPersistKey = "hoverPersists";
  static const String _kHoverPosKey = "hoverReadoutPos";
  static const String _kLogSeqKey = "logSeq"; // last issued log number
  bool _autoLoggingEnabled = true; // false => manual Start/Stop button
  bool _resetLogsOnLeave = true; // leaving Logs tab returns to the list
  bool _hoverPersists = false; // graph hover readout stays after lifting finger
  HoverReadoutPos _hoverPos = HoverReadoutPos.follow; // hover readout side
  double _hitWindowSec = 1.0; // data captured before AND after each hit (s)
  double _manualTimeoutSec = 4.0; // manual logging auto-stop (0.1 - 5.0 s)
  double _hitThreshG = 0.5; // ball-hit vibration threshold (lower = sensitive)
  double _leverArmCm = 12.0; // sensor -> paddle-face distance for omega x r
  SharedPreferences? _prefs;

  // Accelerometer and gyroscope are drawn on separate, independently-scaled
  // charts (their value ranges differ by orders of magnitude).
  static const List<Color> _accelColors = [
    Colors.red,
    Colors.green,
    Colors.blue,
  ];
  static const List<Color> _gyroColors = [
    Colors.orange,
    Colors.purple,
    Colors.teal,
  ];
  static const List<String> _accelLabels = ["ax", "ay", "az"];
  static const List<String> _gyroLabels = ["gx", "gy", "gz"];

  // CSV table columns (time + 6 axes): per-column color (matching the charts),
  // field width in monospace chars (right-aligned so columns line up), decimal
  // places, and header label. Shared by the header and the data rows.
  static const List<Color> _csvColColors = [
    Colors.black54, // time
    Colors.red, Colors.green, Colors.blue, // ax, ay, az  (match accel chart)
    Colors.orange, Colors.purple, Colors.teal, // gx, gy, gz  (match gyro chart)
  ];
  static const List<int> _csvColWidth = [7, 9, 9, 9, 9, 9, 9];
  static const List<int> _csvColDecimals = [4, 4, 4, 4, 2, 2, 2];
  static const List<String> _csvColLabels = [
    "time_s", "ax_g", "ay_g", "az_g", "gx_dps", "gy_dps", "gz_dps",
  ];

  late final TabController _tabController;
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    // The ~10 Hz repaint timer is started/stopped by tab: it only needs to run
    // on the Connection tab (see _syncUiTimer).
    _syncUiTimer();
    _detailScroll.addListener(_onDetailScroll);
    _loadSettings();
    _loadLogs();
  }

  // Tab changes: (1) when enabled, leaving the Logs tab (index 1) clears the
  // open log so returning shows the full list, and (2) start/stop the live
  // repaint timer, which is only needed on the Connection tab.
  void _onTabChanged() {
    if (_resetLogsOnLeave &&
        _tabController.index != 1 &&
        _selectedLog != null) {
      setState(() => _selectedLog = null);
    }
    _syncUiTimer();
  }

  // Repaint at ~10 Hz (rather than on every ~80 Hz BLE packet) to refresh the
  // live streaming readouts — but ONLY while the Connection tab is showing.
  // That tab is the only one with live data; on the Logs/Settings tabs this
  // timer would otherwise rebuild the whole screen 10x/second and make long
  // lists (and log-detail charts + CSV rows) janky to scroll.
  void _syncUiTimer() {
    if (_tabController.index == 0) {
      _uiTimer ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _uiTimer?.cancel();
      _uiTimer = null;
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final autoLog = prefs.getBool(_kAutoLoggingKey);
    final win = prefs.getDouble(_kHitWindowKey);
    final timeout = prefs.getDouble(_kManualTimeoutKey);
    final hitThr = prefs.getDouble(_kHitThreshKey);
    final lever = prefs.getDouble(_kLeverArmKey);
    final resetLogs = prefs.getBool(_kResetLogsKey);
    final hoverPersist = prefs.getBool(_kHoverPersistKey);
    final hoverPosStr = prefs.getString(_kHoverPosKey);
    if (!mounted) return;
    setState(() {
      if (autoLog != null) _autoLoggingEnabled = autoLog;
      if (resetLogs != null) _resetLogsOnLeave = resetLogs;
      if (hoverPersist != null) _hoverPersists = hoverPersist;
      if (hoverPosStr != null) {
        _hoverPos = HoverReadoutPos.values.firstWhere(
          (e) => e.name == hoverPosStr,
          orElse: () => HoverReadoutPos.follow,
        );
      }
      if (win != null) _hitWindowSec = win.clamp(0.25, 2.0);
      if (timeout != null) _manualTimeoutSec = timeout.clamp(0.1, 5.0);
      if (hitThr != null) _hitThreshG = hitThr.clamp(0.1, 1.5);
      if (lever != null) _leverArmCm = lever.clamp(2.0, 30.0);
      _hitDetector.threshold = _hitThreshG;
      _motion.leverArmM = _leverArmCm / 100.0;
    });
  }

  // ---- Persistent log store (binary files in the app documents dir) ----
  Future<Directory> _logsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/logs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  File _logFile(Directory dir, SavedLog log) => File(
    '${dir.path}/log_${log.id}_${log.timestamp.millisecondsSinceEpoch}.bin',
  );

  Future<void> _persistLog(SavedLog log) async {
    try {
      final dir = await _logsDir();
      final n = log.count;
      // Name and hit-times are appended at the end so older files without them
      // still load, and a rename only rewrites this small file.
      final nameBytes = utf8.encode(log.name);
      final hits = log.hitTimes;
      final bd = ByteData(
        4 + n * 8 + 6 * n * 4 + 4 + nameBytes.length + 4 + hits.length * 8,
      );
      int off = 0;
      bd.setInt32(off, n, Endian.little);
      off += 4;
      for (int i = 0; i < n; i++) {
        bd.setFloat64(off, log.t[i], Endian.little);
        off += 8;
      }
      for (int a = 0; a < 6; a++) {
        final col = log.axes[a];
        for (int i = 0; i < n; i++) {
          bd.setFloat32(off, col[i], Endian.little);
          off += 4;
        }
      }
      bd.setInt32(off, nameBytes.length, Endian.little);
      off += 4;
      final u8 = bd.buffer.asUint8List();
      u8.setRange(off, off + nameBytes.length, nameBytes);
      off += nameBytes.length;
      bd.setInt32(off, hits.length, Endian.little);
      off += 4;
      for (final h in hits) {
        bd.setFloat64(off, h, Endian.little);
        off += 8;
      }
      await _logFile(dir, log).writeAsBytes(u8, flush: true);
    } catch (_) {
      // best-effort; a failed persist just means it won't survive restart
    }
  }

  Future<void> _loadLogs() async {
    try {
      final dir = await _logsDir();
      final loaded = <SavedLog>[];
      int maxId = 0;
      final re = RegExp(r'log_(\d+)_(\d+)\.bin$');
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final m = re.firstMatch(entity.path.split('/').last);
        if (m == null) continue;
        final id = int.parse(m.group(1)!);
        final ts = DateTime.fromMillisecondsSinceEpoch(int.parse(m.group(2)!));
        final bytes = await entity.readAsBytes();
        final bd = ByteData.sublistView(bytes);
        int off = 0;
        final n = bd.getInt32(off, Endian.little);
        off += 4;
        if (n <= 0 || bytes.length < 4 + n * 8 + 6 * n * 4) continue;
        final t = Float64List(n);
        for (int i = 0; i < n; i++) {
          t[i] = bd.getFloat64(off, Endian.little);
          off += 8;
        }
        final axes = List.generate(6, (a) {
          final col = Float32List(n);
          for (int i = 0; i < n; i++) {
            col[i] = bd.getFloat32(off, Endian.little);
            off += 4;
          }
          return col;
        });
        // Optional trailing name (absent in older files).
        String name = "";
        if (bytes.length >= off + 4) {
          final nameLen = bd.getInt32(off, Endian.little);
          off += 4;
          if (nameLen > 0 && bytes.length >= off + nameLen) {
            name = utf8.decode(bytes.sublist(off, off + nameLen));
            off += nameLen;
          }
        }
        // Optional trailing hit times (absent in older files).
        final hitTimes = <double>[];
        if (bytes.length >= off + 4) {
          final hitCount = bd.getInt32(off, Endian.little);
          off += 4;
          if (hitCount > 0 && bytes.length >= off + hitCount * 8) {
            for (int i = 0; i < hitCount; i++) {
              hitTimes.add(bd.getFloat64(off, Endian.little));
              off += 8;
            }
          }
        }
        loaded.add(
          SavedLog(id, ts, t, axes, n, t[n - 1], name: name, hitTimes: hitTimes),
        );
        if (id > maxId) maxId = id;
      }
      loaded.sort((a, b) => b.id.compareTo(a.id)); // newest first
      // Numbering: if no logs remain, restart at 1; otherwise continue from the
      // last issued number (persisted, so deleting the newest doesn't reuse it).
      final prefs = await SharedPreferences.getInstance();
      final int persistedSeq = prefs.getInt(_kLogSeqKey) ?? 0;
      final int nextBase = loaded.isEmpty ? 0 : math.max(persistedSeq, maxId);
      if (mounted) {
        setState(() {
          _logs
            ..clear()
            ..addAll(loaded);
          _logSeq = nextBase;
        });
      }
      await prefs.setInt(_kLogSeqKey, nextBase);
    } catch (_) {
      // no persisted logs / unreadable store
    }
  }

  Future<void> _deleteLogFile(SavedLog log) async {
    try {
      final dir = await _logsDir();
      final f = _logFile(dir, log);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _autoStopTimer?.cancel();
    _tabController.dispose();
    _detailScroll.dispose();
    _charSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _connStateSub?.cancel();
    _targetDevice?.disconnect();
    super.dispose();
  }

  // =========================================================================
  // BLE connection
  // =========================================================================
  void _startScanAndConnect() async {
    setState(() {
      _isConnecting = true;
      _connectionStatus = "Scanning...";
    });

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      setState(() {
        _connectionStatus = "Turn on Bluetooth!";
        _isConnecting = false;
      });
      return;
    }

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 5),
      androidUsesFineLocation: true,
    );

    await _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((
      results,
    ) async {
      for (ScanResult r in results) {
        if (r.device.platformName == targetDeviceName) {
          await _scanResultsSubscription?.cancel();
          await FlutterBluePlus.stopScan();
          await Future.delayed(const Duration(milliseconds: 500));
          _connectToDevice(r.device);
          break;
        }
      }
    });
  }

  void _connectToDevice(BluetoothDevice device) async {
    setState(() {
      _connectionStatus = "Connecting to PaddleTrack...";
    });

    try {
      await device.connect(
        license: License.nonprofit,
        autoConnect: false,
        mtu: null,
      );
      _targetDevice = device;

      // Auto-clean up if the peripheral vanishes (powered off / out of range).
      _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            _connectionStatus != "Disconnected") {
          _handleDisconnected();
        }
      });

      setState(() {
        _connectionStatus = "Negotiating packet size...";
      });
      await Future.delayed(const Duration(milliseconds: 500));
      await device.requestMtu(247);
      await Future.delayed(const Duration(milliseconds: 500));

      setState(() {
        _connectionStatus = "Discovering Services...";
      });

      List<BluetoothService> services = await device.discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid == uartServiceUuid) {
          BluetoothCharacteristic? tx;
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid == txCharacteristicUuid) tx = char;
            if (char.uuid == versionCharacteristicUuid) {
              try {
                final v = await char.read();
                if (v.isNotEmpty) _firmwareVersion = utf8.decode(v).trim();
              } catch (_) {
                // older firmware without the version characteristic
              }
            }
          }
          if (tx != null) {
            _subscribeToCharacteristic(tx);
            return;
          }
        }
      }
    } catch (e) {
      setState(() {
        _connectionStatus = "Connection Failed: $e";
        _isConnecting = false;
      });
    }
  }

  void _subscribeToCharacteristic(BluetoothCharacteristic char) async {
    await char.setNotifyValue(true);
    // Allocate the ring + capture buffers and start a free-running clock so the
    // ring stays warm (auto-capture history is ready the moment we arm).
    _ensureCaptureBuffers();
    _ringLen = 0;
    _ringHead = 0;
    _lastStreamPacketUs = 0;
    _hitDetector.reset();
    _recentHits.clear();
    _streamStopwatch
      ..reset()
      ..start();
    setState(() {
      _connectionStatus = "Streaming Data";
      _isConnecting = false;
    });
    _charSubscription = char.onValueReceived.listen(_onPacket);
  }

  // Batched binary packet:
  //   byte 0 : sample count N
  //   byte 1 : battery % (ignored)
  //   then N * 12 bytes: int16 LE ax, ay, az, gx, gy, gz (raw counts)
  void _onPacket(List<int> value) {
    if (value.length < 2) return;
    final int count = value[0];
    if (count < 1 || value.length < 2 + count * 12) return;
    _batteryPct = value[1].toString(); // byte 1 = battery %
    final bd = ByteData.view(Uint8List.fromList(value).buffer);

    final now = DateTime.now();
    _windowStart ??= now;
    _samplesInWindow += count;
    final elapsedMs = now.difference(_windowStart!).inMilliseconds;
    if (elapsedMs >= 1000) {
      _sampleRateStr = (_samplesInWindow * 1000 / elapsedMs).round().toString();
      _samplesInWindow = 0;
      _windowStart = now;
    }

    // Per-sample timestamps interpolated across the packet using the
    // free-running clock, so ring/capture times are continuous regardless of
    // whether we're currently recording.
    final int prevUs = _lastStreamPacketUs;
    final int nowUs = _streamStopwatch.elapsedMicroseconds;

    // Orientation/velocity fusion feeds only the live Connection-tab readouts,
    // so run its heavy per-sample math (trig + quaternion + matrix) only while
    // that tab is showing. On the Logs/Settings tabs it's skipped, so streaming
    // can't jank log scrolling. Hit detection + capture below always run, so no
    // hits are missed; ω×r has no integration state, so nothing to keep warm.
    final bool liveTab = _tabController.index == 0;

    double ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
    for (int s = 0; s < count; s++) {
      final int b = 2 + s * 12;
      ax = bd.getInt16(b + 0, Endian.little) * _accelScaleG;
      ay = bd.getInt16(b + 2, Endian.little) * _accelScaleG;
      az = bd.getInt16(b + 4, Endian.little) * _accelScaleG;
      gx = bd.getInt16(b + 6, Endian.little) * _gyroScaleDps;
      gy = bd.getInt16(b + 8, Endian.little) * _gyroScaleDps;
      gz = bd.getInt16(b + 10, Endian.little) * _gyroScaleDps;

      // Run the fusion filter at the true per-sample rate (fixed ODR).
      if (liveTab) _motion.update(ax, ay, az, gx, gy, gz);

      final double tSec = (prevUs + (nowUs - prevUs) * (s + 1) / count) / 1e6;
      final double amag = math.sqrt(ax * ax + ay * ay + az * az);

      // Ball-hit detection runs continuously; a hit both marks the log and (in
      // auto mode) triggers a capture centered on it.
      final bool isHit = _hitDetector.update(tSec, amag);
      if (isHit) _recordHit(tSec);

      if (_autoLoggingEnabled) {
        _processAutoCapture(tSec, isHit, ax, ay, az, gx, gy, gz);
      } else if (_isManualLogging) {
        _appendManualSample(tSec, ax, ay, az, gx, gy, gz);
      }
    }
    _lastStreamPacketUs = nowUs;

    _imuData = [
      ax.toStringAsFixed(3),
      ay.toStringAsFixed(3),
      az.toStringAsFixed(3),
      gx.toStringAsFixed(1),
      gy.toStringAsFixed(1),
      gz.toStringAsFixed(1),
    ];
  }

  // User-initiated disconnect.
  void _disconnect() async {
    _finalizeInFlight();
    await _charSubscription?.cancel();
    await _scanResultsSubscription?.cancel();
    await _connStateSub?.cancel();
    await _targetDevice?.disconnect();
    _resetConnectionUi();
  }

  // Peripheral dropped on its own (powered off / out of range).
  void _handleDisconnected() {
    _finalizeInFlight();
    _charSubscription?.cancel();
    _connStateSub?.cancel();
    _resetConnectionUi();
  }

  // Save any in-progress capture (auto window or manual session) before teardown.
  void _finalizeInFlight() {
    _autoStopTimer?.cancel();
    if (_recording || _isManualLogging) {
      _isManualLogging = false;
      _finalizeCapture();
    }
  }

  void _resetConnectionUi() {
    if (!mounted) return;
    setState(() {
      _targetDevice = null;
      _isConnecting = false;
      _connectionStatus = "Disconnected";
      _windowStart = null;
      _samplesInWindow = 0;
      _sampleRateStr = "0";
      _batteryPct = "--";
      _firmwareVersion = "?";
      _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
      _armed = false;
      _recording = false;
      _isManualLogging = false;
      _streamStopwatch
        ..stop()
        ..reset();
      _lastStreamPacketUs = 0;
      _ringLen = 0;
      _ringHead = 0;
      _hitDetector.reset();
      _recentHits.clear();
      _motion.reset();
    });
  }

  void _calibrateMotion() {
    setState(() => _motion.startCalibration());
  }

  // =========================================================================
  // Auto-capture (motion-triggered logging)
  // =========================================================================
  void _ensureCaptureBuffers() {
    _capT ??= Float64List(kMaxLogSamples);
    _capAxes ??= List.generate(6, (_) => Float32List(kMaxLogSamples));
    _ringT ??= Float64List(_kRingCap);
    _ringAxes ??= List.generate(6, (_) => Float32List(_kRingCap));
  }

  // Arm/disarm the hit-capture watcher (only meaningful while streaming).
  void _toggleArmed() {
    setState(() {
      if (_armed) {
        if (_recording) _finalizeCapture(); // flush any in-flight window
        _armed = false;
      } else {
        _ensureCaptureBuffers();
        _armed = true;
      }
    });
  }

  // Ring-buffer + hit-trigger state machine, run once per IMU sample. The ring
  // is always kept warm; when armed, a detected ball hit starts a capture
  // seeded with the "before" history, then records the same amount AFTER the
  // hit before finalizing — so each hit becomes its own log. Called from the
  // packet loop; the 10 Hz UI timer reflects state changes.
  void _processAutoCapture(
    double t,
    bool isHit,
    double ax,
    double ay,
    double az,
    double gx,
    double gy,
    double gz,
  ) {
    if (_ringAxes == null) return; // buffers not allocated yet

    // Always push into the ring so the "before-hit" history is fresh.
    _ringT![_ringHead] = t;
    _ringAxes![0][_ringHead] = ax;
    _ringAxes![1][_ringHead] = ay;
    _ringAxes![2][_ringHead] = az;
    _ringAxes![3][_ringHead] = gx;
    _ringAxes![4][_ringHead] = gy;
    _ringAxes![5][_ringHead] = gz;
    _ringHead = (_ringHead + 1) % _kRingCap;
    if (_ringLen < _kRingCap) _ringLen++;

    if (_recording) {
      if (_capCount < kMaxLogSamples) {
        _capT![_capCount] = t;
        _capAxes![0][_capCount] = ax;
        _capAxes![1][_capCount] = ay;
        _capAxes![2][_capCount] = az;
        _capAxes![3][_capCount] = gx;
        _capAxes![4][_capCount] = gy;
        _capAxes![5][_capCount] = gz;
        _capCount++;
      }
      // Stop once we've recorded the "after" window past the hit (further hits
      // inside the window stay in this log and are marked, not split out).
      final bool done = (t - _triggerSec) >= _hitWindowSec;
      final bool full = _capCount >= kMaxLogSamples;
      if (done || full) {
        _finalizeCapture();
        // A new log just landed. Refresh explicitly so it appears even when the
        // repaint timer is paused (e.g. watching captures roll in on the Logs
        // tab); on the Connection tab the timer would catch it anyway.
        if (mounted) setState(() {});
      }
    } else if (_armed && isHit) {
      _startHitCapture(t); // a hit → new log centered on it
    }
  }

  // Begin a capture on a hit: copy the most recent `_hitWindowSec` of history
  // from the ring (which already includes the hit sample) as the "before" part.
  void _startHitCapture(double hitT) {
    final int pre = math.min(_ringLen, (_hitWindowSec * _odrHz).round());
    int idx = (_ringHead - pre + _kRingCap) % _kRingCap;
    for (int j = 0; j < pre; j++) {
      _capT![j] = _ringT![idx];
      for (int a = 0; a < 6; a++) {
        _capAxes![a][j] = _ringAxes![a][idx];
      }
      idx = (idx + 1) % _kRingCap;
    }
    _capCount = pre;
    _triggerSec = hitT;
    _recording = true;
  }

  // Record a detected ball-hit (absolute stream time); keep a bounded history
  // so a capture that reaches back through the ring buffer still sees its hits.
  void _recordHit(double t) {
    _recentHits.add(t);
    while (_recentHits.isNotEmpty && _recentHits.first < t - 13.0) {
      _recentHits.removeAt(0); // ~13 s covers the max capture length
    }
  }

  // Snapshot the captured window into a right-sized SavedLog (times rebased so
  // the log starts at t = 0), keeping it armed for the next swing.
  void _finalizeCapture() {
    _recording = false;
    if (_capCount > 1) {
      final int n = _capCount;
      final double t0 = _capT![0];
      final double tEnd = _capT![n - 1];
      final t = Float64List(n);
      for (int i = 0; i < n; i++) {
        t[i] = _capT![i] - t0;
      }
      final axes = List.generate(
        6,
        (a) => Float32List(n)..setRange(0, n, _capAxes![a]),
      );
      // Ball-hits that fall inside this window, rebased to the log start.
      final hits = <double>[
        for (final h in _recentHits)
          if (h >= t0 && h <= tEnd) h - t0,
      ];
      final created = SavedLog(
        ++_logSeq,
        DateTime.now(),
        t,
        axes,
        n,
        t[n - 1],
        hitTimes: hits,
      );
      _logs.insert(0, created);
      _prefs?.setInt(_kLogSeqKey, _logSeq); // remember the last issued number
      _persistLog(created); // survive restarts
    }
    _capCount = 0;
  }

  // =========================================================================
  // Manual logging (used when automatic logging is turned off)
  // =========================================================================
  void _setAutoLogging(bool enabled) {
    setState(() {
      // Stop whichever mode was active before switching.
      _autoStopTimer?.cancel();
      if (_isManualLogging) {
        _isManualLogging = false;
        _finalizeCapture();
      }
      if (_recording) _finalizeCapture();
      _armed = false;
      _autoLoggingEnabled = enabled;
    });
    _prefs?.setBool(_kAutoLoggingKey, enabled);
  }

  void _startLogging() {
    _ensureCaptureBuffers();
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(
      Duration(milliseconds: (_manualTimeoutSec * 1000).round()),
      () {
        if (_isManualLogging) _stopLogging();
      },
    );
    setState(() {
      _capCount = 0;
      _isManualLogging = true;
    });
  }

  void _stopLogging() {
    _autoStopTimer?.cancel();
    setState(() {
      _isManualLogging = false;
      _finalizeCapture(); // snapshot + persist (times rebased to start at 0)
    });
  }

  // Append one live sample to the manual capture buffer (times rebased on stop).
  void _appendManualSample(
    double t,
    double ax,
    double ay,
    double az,
    double gx,
    double gy,
    double gz,
  ) {
    if (_capCount >= kMaxLogSamples) {
      _stopLogging(); // safety cap
      return;
    }
    _capT![_capCount] = t;
    _capAxes![0][_capCount] = ax;
    _capAxes![1][_capCount] = ay;
    _capAxes![2][_capCount] = az;
    _capAxes![3][_capCount] = gx;
    _capAxes![4][_capCount] = gy;
    _capAxes![5][_capCount] = gz;
    _capCount++;
  }

  void _deleteLog(SavedLog log) {
    _deleteLogFile(log);
    setState(() {
      _logs.remove(log);
      _speedCache.remove(log.id);
      if (_selectedLog == log) _selectedLog = null;
      // Once the last log is gone, restart numbering at 1 next capture.
      if (_logs.isEmpty) {
        _logSeq = 0;
        _prefs?.setInt(_kLogSeqKey, 0);
      }
    });
  }

  // Delete every log (with confirmation, since it's irreversible).
  Future<void> _deleteAllLogs() async {
    if (_logs.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete all logs?"),
        content: Text(
          "This permanently deletes all ${_logs.length} log(s). "
          "This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("Delete all"),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final toDelete = List<SavedLog>.of(_logs);
    for (final log in toDelete) {
      await _deleteLogFile(log);
    }
    setState(() {
      _logs.clear();
      _speedCache.clear();
      _selectedLog = null;
      _logSeq = 0; // empty -> next capture restarts at 1
      _prefs?.setInt(_kLogSeqKey, 0);
    });
  }

  // Make `base` unique among the other logs' names. If it collides, append
  // " (1)", " (2)", … starting from the first duplicate.
  String _uniqueName(String base, {required int excludeId}) {
    final taken = _logs
        .where((l) => l.id != excludeId)
        .map((l) => l.name)
        .toSet();
    if (!taken.contains(base)) return base;
    int k = 1;
    while (taken.contains("$base ($k)")) {
      k++;
    }
    return "$base ($k)";
  }

  Future<void> _renameLog(SavedLog log) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameDialog(initial: log.name, hint: "Log #${log.id}"),
    );
    if (result == null || !mounted) return; // cancelled / navigated away
    final desired = result.trim();
    final newName = desired.isEmpty
        ? "" // cleared → falls back to "Log #id"
        : _uniqueName(desired, excludeId: log.id);
    setState(() => log.name = newName);
    _persistLog(log); // rewrite the file with the new name
  }

  String _csvFor(SavedLog log) {
    final sb = StringBuffer("time_s,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps\n");
    for (int i = 0; i < log.count; i++) {
      sb.write(log.t[i].toStringAsFixed(4));
      for (int a = 0; a < 6; a++) {
        sb.write(',');
        sb.write(log.axes[a][i].toStringAsFixed(a < 3 ? 4 : 2));
      }
      sb.write('\n');
    }
    return sb.toString();
  }

  // Filesystem-safe base name for a log's export file (from its display name).
  String _safeName(SavedLog log) {
    final base = log.displayName
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_')
        .trim();
    return base.isEmpty ? 'log_${log.id}' : base;
  }

  // Export via the system share sheet (handles any size, unlike the clipboard).
  void _exportLog(SavedLog log) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${_safeName(log)}.csv');
      await file.writeAsString(_csvFor(log));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'Paddle log: ${log.displayName}',
          text:
              '${log.displayName}: ${log.count} samples, '
              '${log.durationSec.toStringAsFixed(1)} s',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Export failed: $e")));
      }
    }
  }

  // Bundle every log's CSV into a single .zip ("folder") and share that, so all
  // logs can be exported at once instead of one file at a time.
  void _exportAllLogs() async {
    if (_logs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("No logs to share")));
      return;
    }
    try {
      final archive = Archive();
      final used = <String>{};
      for (final log in _logs) {
        // Entry name from the log's (unique) display name; guard against any
        // collision after sanitizing by appending the id.
        var name = '${_safeName(log)}.csv';
        if (!used.add(name)) name = '${_safeName(log)}_${log.id}.csv';
        used.add(name);
        final bytes = utf8.encode(_csvFor(log));
        archive.addFile(ArchiveFile.bytes(name, bytes));
      }
      final zipped = ZipEncoder().encode(archive);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/paddle_logs.zip');
      await file.writeAsBytes(zipped, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          subject: 'Paddle logs (${_logs.length})',
          text: 'All ${_logs.length} paddle IMU logs (one CSV each).',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Export failed: $e")));
      }
    }
  }

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';

  // =========================================================================
  // UI
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paddle Prototype Bench'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    "app v$kAppVersion",
                    style: const TextStyle(fontSize: 11),
                  ),
                  if (_connectionStatus == "Streaming Data")
                    Text(
                      "fw v$_firmwareVersion",
                      style: const TextStyle(fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(icon: Icon(Icons.bluetooth), text: "Connection"),
            Tab(icon: Icon(Icons.show_chart), text: "Logs"),
            Tab(icon: Icon(Icons.settings), text: "Settings"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildConnectionTab(), _buildLogsTab(), _buildSettingsTab()],
      ),
    );
  }

  // Horizontal rectangular battery gauge with the percentage beside it.
  Widget _batteryIndicator(int pct) {
    final p = pct.clamp(0, 100);
    final Color fill = p <= 20
        ? Colors.red
        : (p <= 50 ? Colors.orange : Colors.green);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 46,
          height: 20,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black54, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: p / 100.0,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        ),
        // terminal nub
        Container(
          width: 3,
          height: 8,
          decoration: const BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.only(
              topRight: Radius.circular(2),
              bottomRight: Radius.circular(2),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          "$p%",
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildConnectionTab() {
    final streaming = _connectionStatus == "Streaming Data";
    final m = _motion;
    final String orientationText = m.calibrated
        ? "Roll: ${m.roll.toStringAsFixed(0)}°   Pitch: ${m.pitch.toStringAsFixed(0)}°"
        : (m.calibrating
              ? "Calibrating… hold still (${(m.calProgress * 100).toStringAsFixed(0)}%)"
              : "Not calibrated");
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: Column(
        children: [
          Text(
            _connectionStatus,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: streaming ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "Sample Rate: $_sampleRateStr Hz",
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          if (streaming) ...[
            const SizedBox(height: 10),
            _batteryIndicator(int.tryParse(_batteryPct) ?? 0),
          ],
          const SizedBox(height: 28),
          const Text(
            "Accelerometer (G)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            "X: ${_imuData[0]}   Y: ${_imuData[1]}   Z: ${_imuData[2]}",
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 16),
          const Text(
            "Gyroscope (deg/s)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            "X: ${_imuData[3]}   Y: ${_imuData[4]}   Z: ${_imuData[5]}",
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 24),
          const Text(
            "Orientation (relative to down)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(orientationText, style: const TextStyle(fontSize: 18)),
          if (m.calibrated)
            Text(
              "Tilt from vertical: ${m.tilt.toStringAsFixed(0)}°",
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
          const SizedBox(height: 16),
          const Text(
            "Face speed (ω×r)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            streaming ? "${m.faceSpeed.toStringAsFixed(2)} m/s" : "—",
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: (streaming && !m.calibrating) ? _calibrateMotion : null,
            icon: const Icon(Icons.explore),
            label: Text(
              m.calibrated ? "Recalibrate (hold still)" : "Calibrate (hold still)",
            ),
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: _isConnecting || streaming
                ? _disconnect
                : _startScanAndConnect,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
            ),
            child: Text(
              streaming ? "Disconnect" : "Connect to Paddle",
              style: const TextStyle(fontSize: 18),
            ),
          ),
          const SizedBox(height: 16),
          _loggingControl(streaming),
        ],
      ),
    );
  }

  // The logging control switches with the "Automatic logging" setting: an
  // Arm/Disarm toggle for motion-triggered capture, or a manual Start/Stop.
  Widget _loggingControl(bool streaming) {
    if (_autoLoggingEnabled) {
      return Column(
        children: [
          ElevatedButton.icon(
            // Arm it, then any swing that crosses the accel threshold is
            // recorded automatically. Only meaningful while streaming.
            onPressed: streaming ? _toggleArmed : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _armed ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
            ),
            icon: Icon(
              _armed ? Icons.motion_photos_off : Icons.motion_photos_on,
            ),
            label: Text(
              _armed ? "Disarm Auto-Capture" : "Arm Auto-Capture",
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _recording
                ? "● Capturing hit… $_capCount samples"
                : _armed
                ? "Armed — a log is saved on each ball hit "
                      "(±${_hitWindowSec.toStringAsFixed(2)} s)"
                : (_logs.isNotEmpty
                      ? "${_logs.length} log(s) saved — see Logs tab"
                      : "Disarmed"),
            style: TextStyle(
              fontSize: 13,
              color: _recording ? Colors.red : Colors.grey,
            ),
          ),
        ],
      );
    }
    // Manual mode: Start/Stop button (auto-stops after the timeout).
    return Column(
      children: [
        ElevatedButton.icon(
          onPressed: streaming
              ? (_isManualLogging ? _stopLogging : _startLogging)
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _isManualLogging ? Colors.red : Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
          ),
          icon: Icon(_isManualLogging ? Icons.stop : Icons.fiber_manual_record),
          label: Text(
            _isManualLogging ? "Stop Logging" : "Start Logging",
            style: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _isManualLogging
              ? "Logging… $_capCount samples "
                    "(auto-stops at ${_manualTimeoutSec.toStringAsFixed(1)} s)"
              : (_logs.isNotEmpty
                    ? "${_logs.length} log(s) saved — see Logs tab"
                    : "Not logging"),
          style: TextStyle(
            fontSize: 13,
            color: _isManualLogging ? Colors.red : Colors.grey,
          ),
        ),
      ],
    );
  }

  // ---- Logs tab: list of logs, or a detail view with a back button ----
  Widget _buildLogsTab() {
    if (_selectedLog != null) return _buildLogDetail(_selectedLog!);

    if (_logs.isEmpty) {
      return Center(
        child: Text(
          _autoLoggingEnabled
              ? "No logs yet.\nConnect, Arm Auto-Capture, then hit a ball."
              : "No logs yet.\nConnect, then tap Start Logging.",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  "${_logs.length} log(s)",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              TextButton.icon(
                onPressed: _exportAllLogs,
                icon: const Icon(Icons.folder_zip),
                label: const Text("Share all"),
              ),
              TextButton.icon(
                onPressed: _deleteAllLogs,
                icon: const Icon(Icons.delete_sweep),
                label: const Text("Delete all"),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildLogsList()),
      ],
    );
  }

  // Fixed row height lets the list position/recycle rows without measuring each
  // one (itemExtent below), which keeps scrolling smooth with many logs.
  static const double _logRowHeight = 64;

  Widget _buildLogsList() {
    return ListView.builder(
      // PageStorageKey persists the scroll offset when we open a log's detail
      // view and come back, so the list stays where you left it.
      key: const PageStorageKey('logsList'),
      itemCount: _logs.length,
      itemExtent: _logRowHeight,
      itemBuilder: (context, i) => _logRow(_logs[i]),
    );
  }

  // A lightweight log row: cheaper to build than ListTile + a separate Divider
  // child, so long lists fling without jank. The divider is drawn as a bottom
  // border instead of a separate widget.
  Widget _logRow(SavedLog log) {
    return InkWell(
      onTap: () => _openLog(log),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.black12, width: 1)),
        ),
        child: Row(
          children: [
            const Icon(Icons.show_chart, color: Colors.blueAccent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    log.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "#${log.id}  •  ${_fmtTime(log.timestamp)}"
                    "  •  ${log.durationSec.toStringAsFixed(1)} s",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ],
              ),
            ),
            _logActionsMenu(log),
          ],
        ),
      ),
    );
  }

  // Per-log overflow menu: rename / export / delete (compact dropdown).
  Widget _logActionsMenu(SavedLog log) {
    return PopupMenuButton<String>(
      tooltip: "Actions",
      onSelected: (v) {
        if (v == 'rename') _renameLog(log);
        if (v == 'export') _exportLog(log);
        if (v == 'delete') _deleteLog(log);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text("Rename"),
          ),
        ),
        PopupMenuItem(
          value: 'export',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.share),
            title: Text("Export CSV"),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline),
            title: Text("Delete"),
          ),
        ),
      ],
    );
  }

  // Open a log's detail view. It always starts at the top: the detail list has
  // a different key from the logs list, so it gets a fresh ScrollPosition rather
  // than inheriting the list's offset. We also measure the charts' height so the
  // jump-to-top button can appear once they've scrolled out of view.
  void _openLog(SavedLog log) {
    setState(() {
      _selectedLog = log;
      _showJumpTop = false;
      _chartsHeight = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureCharts());
  }

  // Cache the rendered height of the charts block (item 0) while it's on screen.
  void _measureCharts() {
    final h = _chartsKey.currentContext?.size?.height ?? 0;
    if (h > 0) _chartsHeight = h;
  }

  // Show the jump-to-top button once the charts have scrolled fully out of view.
  void _onDetailScroll() {
    if (!_detailScroll.hasClients) return;
    final double threshold = _chartsHeight > 0 ? _chartsHeight : 600;
    final bool show = _detailScroll.offset > threshold;
    if (show != _showJumpTop && mounted) setState(() => _showJumpTop = show);
  }

  Widget _jumpToTopButton() {
    return Material(
      color: Colors.blueAccent,
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _detailScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward, size: 18, color: Colors.white),
              SizedBox(width: 6),
              Text(
                "Jump to top",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogDetail(SavedLog log) {
    final ss = _speedCache.putIfAbsent(
      log.id,
      () => computeSpeedSeries(
        log.axes,
        log.count,
        leverArmM: _leverArmCm / 100.0,
      ),
    );
    // Fixed back/title/actions bar, then one lazy list holding the charts
    // (velocity on top) followed by the CSV rows, so everything scrolls
    // together while the rows stay lazily built.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 2),
          child: Row(
            children: [
              IconButton(
                tooltip: "Back to logs",
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selectedLog = null),
              ),
              Expanded(
                // Tap the title to rename.
                child: InkWell(
                  onTap: () => _renameLog(log),
                  child: Text(
                    "${log.displayName}  •  ${log.count} samples  •  "
                    "${log.durationSec.toStringAsFixed(1)} s",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              _logActionsMenu(log),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              ListView.builder(
                // A distinct key (vs the list's PageStorageKey) gives the detail
                // list its own fresh ScrollPosition, so opening a log always
                // starts at the top instead of inheriting the list's offset.
                key: const ValueKey('logDetail'),
                controller: _detailScroll,
                itemCount: 1 + log.count,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return KeyedSubtree(
                      key: _chartsKey,
                      child: _logCharts(log, ss),
                    );
                  }
                  return _csvRow(log, i - 1);
                },
              ),
              // Floating "jump to top", shown once the charts scroll off-screen.
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_showJumpTop,
                  child: AnimatedOpacity(
                    opacity: _showJumpTop ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    child: Center(child: _jumpToTopButton()),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logCharts(SavedLog log, SpeedSeries ss) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (log.hitTimes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 14, height: 3, color: const Color(0xFFE91E63)),
                const SizedBox(width: 6),
                Text(
                  "ball hit (${log.hitTimes.length})",
                  style: const TextStyle(fontSize: 12, color: Color(0xFFE91E63)),
                ),
              ],
            ),
          ),
        _chartSection(
          "Face speed (ω×r)",
          log,
          [ss.faceSpeed],
          const [Colors.indigo],
          const ["face ω×r"],
          forcedMin: 0,
          cornerText: "max ${ss.maxFaceSpeed.toStringAsFixed(1)} m/s",
          unit: "m/s",
          decimals: 2,
        ),
        _chartSection(
          "Speed (accel — old)",
          log,
          [ss.speed],
          const [Colors.grey],
          const ["accel (old)"],
          forcedMin: 0,
          cornerText: "max ${ss.maxSpeed.toStringAsFixed(1)} m/s",
          unit: "m/s",
          decimals: 2,
        ),
        _chartSection(
          "Accelerometer (G)",
          log,
          [log.axes[0], log.axes[1], log.axes[2]],
          _accelColors,
          _accelLabels,
          centerZero: true,
          unit: "G",
          decimals: 3,
        ),
        _chartSection(
          "Gyroscope (deg/s)",
          log,
          [log.axes[3], log.axes[4], log.axes[5]],
          _gyroColors,
          _gyroLabels,
          centerZero: true,
          unit: "°/s",
          decimals: 1,
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
          child: Text.rich(
            TextSpan(children: _csvHeaderSpans()),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              fontFamily: "monospace",
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  // One colored, right-aligned span per column so the table lines up (monospace)
  // and each column matches its chart color.
  List<InlineSpan> _csvSpans(SavedLog log, int i) {
    return [
      for (int c = 0; c < 7; c++)
        TextSpan(
          text: (c == 0 ? log.t[i] : log.axes[c - 1][i])
              .toStringAsFixed(_csvColDecimals[c])
              .padLeft(_csvColWidth[c]),
          style: TextStyle(color: _csvColColors[c]),
        ),
    ];
  }

  // Header spans padded to the same column widths as the data, so each label
  // sits above its numbers.
  List<InlineSpan> _csvHeaderSpans() {
    return [
      for (int c = 0; c < 7; c++)
        TextSpan(
          text: _csvColLabels[c].padLeft(_csvColWidth[c]),
          style: TextStyle(color: _csvColColors[c]),
        ),
    ];
  }

  Widget _csvRow(SavedLog log, int i) {
    return SizedBox(
      height: 18,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text.rich(
          TextSpan(children: _csvSpans(log, i)),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: const TextStyle(fontFamily: "monospace", fontSize: 10),
        ),
      ),
    );
  }

  Widget _chartSection(
    String title,
    SavedLog log,
    List<Float32List> series,
    List<Color> colors,
    List<String>? labels, {
    double? forcedMin,
    String? cornerText,
    bool centerZero = false,
    String unit = "",
    int decimals = 2,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: 150,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _InteractiveChart(
              t: log.t,
              series: series,
              count: log.count,
              colors: colors,
              labels: labels,
              unit: unit,
              decimals: decimals,
              forcedMin: forcedMin,
              cornerText: cornerText,
              centerZero: centerZero,
              hitTimes: log.hitTimes,
              persist: _hoverPersists,
              pos: _hoverPos,
            ),
          ),
        ),
        if (labels != null) _legend(colors, labels),
      ],
    );
  }

  Widget _legend(List<Color> colors, List<String> labels) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: List.generate(colors.length, (i) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 12, height: 3, color: colors[i]),
              const SizedBox(width: 4),
              Text(labels[i], style: const TextStyle(fontSize: 12)),
            ],
          );
        }),
      ),
    );
  }

  // ---- Settings tab ----
  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Automatic logging",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          subtitle: const Text("Each hit is auto-detected and recorded."),
          value: _autoLoggingEnabled,
          onChanged: _setAutoLogging,
        ),
        const Divider(height: 24),
        ..._hitDetectionSettings(),
        const Divider(height: 24),
        ..._paddleSpeedSettings(),
        const Divider(height: 24),
        if (_autoLoggingEnabled)
          ..._autoCaptureSettings()
        else
          ..._manualLoggingSettings(),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Always show logs list",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          subtitle: const Text(
            "Returning to the Logs tab shows the full list instead of the "
            "last-opened log.",
          ),
          value: _resetLogsOnLeave,
          onChanged: (v) {
            setState(() => _resetLogsOnLeave = v);
            _prefs?.setBool(_kResetLogsKey, v);
          },
        ),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Persist graph hover",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          subtitle: const Text(
            "Keep the value readout on the graph after you lift your finger. "
            "Off: it shows only while you're touching.",
          ),
          value: _hoverPersists,
          onChanged: (v) {
            setState(() => _hoverPersists = v);
            _prefs?.setBool(_kHoverPersistKey, v);
          },
        ),
        const SizedBox(height: 16),
        const Text(
          "Hover readout position",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          "Where the value box sits when you hover a graph. Follow tracks the "
          "point you're touching; Adaptive keeps it opposite your finger.",
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<HoverReadoutPos>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: HoverReadoutPos.follow,
                label: Text("Follow"),
              ),
              ButtonSegment(value: HoverReadoutPos.left, label: Text("Left")),
              ButtonSegment(value: HoverReadoutPos.right, label: Text("Right")),
              ButtonSegment(
                value: HoverReadoutPos.adaptive,
                label: Text("Adaptive"),
              ),
            ],
            selected: {_hoverPos},
            onSelectionChanged: (s) {
              setState(() => _hoverPos = s.first);
              _prefs?.setString(_kHoverPosKey, _hoverPos.name);
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _paddleSpeedSettings() {
    return [
      const Text(
        "Paddle speed",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "Face speed is computed drift-free as ω×r (gyro × lever arm). The lever "
        "arm is the distance from the sensor to the paddle-face contact point; "
        "it sets the m/s scale (timing is unaffected).",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      _settingSlider(
        label: "Lever arm",
        value: _leverArmCm,
        min: 2.0,
        max: 30.0,
        divisions: 56, // 0.5 cm steps
        unit: "cm",
        decimals: 1,
        onChanged: (v) => setState(() {
          _leverArmCm = v;
          _motion.leverArmM = v / 100.0;
        }),
        onChangeEnd: (v) {
          _prefs?.setDouble(_kLeverArmKey, v);
          setState(() => _speedCache.clear()); // recompute logs at new scale
        },
      ),
    ];
  }

  List<Widget> _hitDetectionSettings() {
    return [
      const Text(
        "Hit detection",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "Ball hits are found from the high-frequency vibration in the wood "
        "(runs always). Lower threshold = more sensitive (catches weaker hits, "
        "but risks false triggers on hard swings). Hits are marked on the log "
        "graphs.",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      _settingSlider(
        label: "Hit threshold",
        value: _hitThreshG,
        min: 0.1,
        max: 1.5,
        divisions: 28, // 0.05 g steps
        unit: "g",
        decimals: 2,
        onChanged: (v) => setState(() {
          _hitThreshG = v;
          _hitDetector.threshold = v;
        }),
        onChangeEnd: (v) => _prefs?.setDouble(_kHitThreshKey, v),
      ),
    ];
  }

  List<Widget> _autoCaptureSettings() {
    return [
      const Text(
        "Auto-capture (per hit)",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "When armed, every detected ball hit is saved as its own log. The window "
        "sets how much data is kept before AND after each hit (so total length is "
        "twice this). Hit detection uses the Hit threshold above.",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      _settingSlider(
        label: "Window (before & after hit)",
        value: _hitWindowSec,
        min: 0.25,
        max: 2.0,
        divisions: 35, // 0.05 s steps
        unit: "s",
        decimals: 2,
        onChanged: (v) => setState(() => _hitWindowSec = v),
        onChangeEnd: (v) => _prefs?.setDouble(_kHitWindowKey, v),
      ),
    ];
  }

  List<Widget> _manualLoggingSettings() {
    return [
      const Text(
        "Manual logging",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "Recording starts and stops with the Start/Stop button on the "
        "Connection tab, and stops automatically after this timeout.",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      _settingSlider(
        label: "Auto-stop timeout",
        value: _manualTimeoutSec,
        min: 0.1,
        max: 5.0,
        divisions: 49, // 0.1 s steps
        unit: "s",
        decimals: 1,
        onChanged: (v) => setState(() => _manualTimeoutSec = v),
        onChangeEnd: (v) => _prefs?.setDouble(_kManualTimeoutKey, v),
      ),
    ];
  }

  // A labelled slider with a live value readout and min/max end labels; steps
  // are snapped to `decimals` places and persisted on release.
  Widget _settingSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unit,
    required int decimals,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    String fmt(double v) => "${v.toStringAsFixed(decimals)} $unit";
    double snap(double v) => double.parse(v.toStringAsFixed(decimals));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(fmt(value), style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: fmt(value),
          onChanged: (v) => onChanged(snap(v)),
          onChangeEnd: (v) => onChangeEnd(snap(v)),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(fmt(min), style: const TextStyle(color: Colors.grey, fontSize: 12)),
            Text(fmt(max), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ],
    );
  }
}

/// Dependency-free line chart: the given series plotted against a shared time
/// axis, with an auto-scaled y-axis covering just those series.
class _ChartPainter extends CustomPainter {
  final Float64List t;
  final List<Float32List> series;
  final int count;
  final List<Color> colors;
  final double? forcedMin; // if set, pin the y-axis bottom here (no auto-scale)
  final String? cornerText; // optional label drawn in the top-right corner
  final bool centerZero; // if true, y-axis is symmetric about 0 (0 centered)
  final List<double> hitTimes; // detected ball-hit times (s) -> vertical lines
  final int? touchIndex; // sample under the finger -> crosshair + dots

  // Plot insets, shared with _InteractiveChart so a touch x maps to the same
  // axis the painter draws.
  static const double padL = 46, padR = 10, padT = 10, padB = 22;

  _ChartPainter(
    this.t,
    this.series,
    this.count,
    this.colors, {
    this.forcedMin,
    this.cornerText,
    this.centerZero = false,
    this.hitTimes = const [],
    this.touchIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFAFAFA),
    );

    final plot = Rect.fromLTRB(
      padL,
      padT,
      size.width - padR,
      size.height - padB,
    );
    canvas.drawRect(
      plot,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black26
        ..strokeWidth = 1,
    );

    if (count < 2 || series.isEmpty) {
      _text(
        canvas,
        "No data",
        plot.center - const Offset(24, 8),
        Colors.black45,
      );
      return;
    }

    double tMin = t[0];
    double tMax = t[count - 1];
    if (tMax <= tMin) tMax = tMin + 1e-3;

    const int maxPts = 800;
    final int step = (count / maxPts).ceil().clamp(1, count);

    double vMin = double.infinity, vMax = -double.infinity;
    for (int a = 0; a < series.length; a++) {
      final col = series[a];
      for (int i = 0; i < count; i += step) {
        final v = col[i];
        if (v < vMin) vMin = v;
        if (v > vMax) vMax = v;
      }
    }
    if (!vMin.isFinite || !vMax.isFinite) {
      vMin = -1;
      vMax = 1;
    }
    if (forcedMin != null) {
      // Pin the bottom (e.g. 0 for speed); only pad/auto-scale the top.
      vMin = forcedMin!;
      if (vMax <= vMin) vMax = vMin + 1;
      vMax += (vMax - vMin) * 0.08;
    } else if (centerZero) {
      // Symmetric about 0 so 0.0 sits exactly in the middle; autoscale extent.
      final double av = vMin.abs(), bv = vMax.abs();
      double mag = av > bv ? av : bv;
      if (mag <= 0) mag = 1;
      mag *= 1.05; // padding
      vMin = -mag;
      vMax = mag;
    } else {
      if (vMax <= vMin) vMax = vMin + 1;
      final vpad = (vMax - vMin) * 0.05;
      vMin -= vpad;
      vMax += vpad;
    }

    double xOf(double tt) =>
        plot.left + (tt - tMin) / (tMax - tMin) * plot.width;
    double yOf(double vv) =>
        plot.bottom - (vv - vMin) / (vMax - vMin) * plot.height;

    final gridPaint = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;

    void hline(double v) {
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _text(
        canvas,
        v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
        Offset(2, y - 6),
        Colors.black54,
        size: 9,
      );
    }

    // Horizontal grid lines with value labels (4 even divisions).
    for (int k = 0; k <= 4; k++) {
      hline(vMin + (vMax - vMin) * k / 4);
    }
    // Emphasize the zero line when the range crosses it.
    if (vMin < 0 && vMax > 0) {
      final y = yOf(0);
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        Paint()
          ..color = Colors.black38
          ..strokeWidth = 1,
      );
    }

    for (int k = 0; k <= 4; k++) {
      final tt = tMin + (tMax - tMin) * k / 4;
      final x = xOf(tt);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      _text(
        canvas,
        tt.toStringAsFixed(1),
        Offset(x - 8, plot.bottom + 4),
        Colors.black54,
        size: 9,
      );
    }

    for (int a = 0; a < series.length; a++) {
      final col = series[a];
      final paint = Paint()
        ..color = colors[a]
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final path = Path();
      bool first = true;
      for (int i = 0; i < count; i += step) {
        final x = xOf(t[i]);
        final y = yOf(col[i]);
        if (first) {
          path.moveTo(x, y);
          first = false;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    // Ball-hit markers: a clear vertical line at each detected hit time.
    if (hitTimes.isNotEmpty) {
      final hitPaint = Paint()
        ..color = const Color(0xFFE91E63) // magenta — distinct from all traces
        ..strokeWidth = 2.0
        ..isAntiAlias = true;
      for (final ht in hitTimes) {
        if (ht < tMin || ht > tMax) continue;
        final x = xOf(ht);
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), hitPaint);
      }
    }

    // Touch crosshair + a dot on each trace at the hovered sample.
    if (touchIndex != null && touchIndex! >= 0 && touchIndex! < count) {
      final int ti = touchIndex!;
      final double cx = xOf(t[ti]);
      canvas.drawLine(
        Offset(cx, plot.top),
        Offset(cx, plot.bottom),
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1,
      );
      for (int a = 0; a < series.length; a++) {
        final double cy = yOf(series[a][ti]);
        canvas.drawCircle(Offset(cx, cy), 3.5, Paint()..color = colors[a]);
        canvas.drawCircle(
          Offset(cx, cy),
          3.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.white
            ..strokeWidth = 1.2,
        );
      }
    }

    // Optional corner label (e.g. max speed), top-right inside the plot.
    if (cornerText != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: cornerText,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.right - tp.width - 6, plot.top + 4));
    }
  }

  void _text(Canvas c, String s, Offset o, Color color, {double size = 10}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.count != count ||
      old.t != t ||
      old.colors != colors ||
      old.forcedMin != forcedMin ||
      old.cornerText != cornerText ||
      old.centerZero != centerZero ||
      old.hitTimes != hitTimes ||
      old.touchIndex != touchIndex;
}

/// Wraps a [_ChartPainter] with touch tracking: dragging horizontally (or
/// pressing and holding) shows a crosshair at the nearest sample plus a readout
/// of the exact value(s). Vertical drags fall through to the enclosing scroll
/// view, so the detail page still scrolls normally.
class _InteractiveChart extends StatefulWidget {
  final Float64List t;
  final List<Float32List> series;
  final int count;
  final List<Color> colors;
  final List<String>? labels;
  final String unit;
  final int decimals;
  final double? forcedMin;
  final String? cornerText;
  final bool centerZero;
  final List<double> hitTimes;
  final bool persist; // keep the readout after the finger lifts
  final HoverReadoutPos pos; // which side the readout box sits on

  const _InteractiveChart({
    required this.t,
    required this.series,
    required this.count,
    required this.colors,
    required this.labels,
    required this.unit,
    required this.decimals,
    required this.forcedMin,
    required this.cornerText,
    required this.centerZero,
    required this.hitTimes,
    required this.persist,
    required this.pos,
  });

  @override
  State<_InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<_InteractiveChart> {
  int? _touchIndex;

  // Map an x within the plot to the nearest sample index (samples are ~uniform).
  void _updateFromX(double dx, double width) {
    final int n = widget.count;
    if (n < 2) return;
    final double plotLeft = _ChartPainter.padL;
    final double plotW = width - _ChartPainter.padR - plotLeft;
    if (plotW <= 0) return;
    final double frac = ((dx - plotLeft) / plotW).clamp(0.0, 1.0);
    final int idx = (frac * (n - 1)).round().clamp(0, n - 1);
    if (idx != _touchIndex) setState(() => _touchIndex = idx);
  }

  void _clear() {
    if (_touchIndex != null) setState(() => _touchIndex = null);
  }

  // On finger-lift: keep the readout when "persist" is on, else clear it.
  void _onEnd() {
    if (!widget.persist) _clear();
  }

  @override
  void didUpdateWidget(_InteractiveChart old) {
    super.didUpdateWidget(old);
    // Turning persist off drops any pinned crosshair on the next rebuild.
    if (old.persist && !widget.persist) _touchIndex = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Horizontal drag = scrub; long-press = pin. Vertical drags are left
          // to the scroll view (neither recognizer claims them).
          onHorizontalDragStart: (d) => _updateFromX(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) => _updateFromX(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _onEnd(),
          onHorizontalDragCancel: _onEnd,
          onLongPressStart: (d) => _updateFromX(d.localPosition.dx, width),
          onLongPressMoveUpdate: (d) =>
              _updateFromX(d.localPosition.dx, width),
          onLongPressEnd: (_) => _onEnd(),
          child: Stack(
            children: [
              CustomPaint(
                painter: _ChartPainter(
                  widget.t,
                  widget.series,
                  widget.count,
                  widget.colors,
                  forcedMin: widget.forcedMin,
                  cornerText: widget.cornerText,
                  centerZero: widget.centerZero,
                  hitTimes: widget.hitTimes,
                  touchIndex: _touchIndex,
                ),
                child: const SizedBox.expand(),
              ),
              if (_touchIndex != null) _readout(width),
            ],
          ),
        );
      },
    );
  }

  Widget _readout(double width) {
    final int ti = _touchIndex!;
    // A dismiss control only makes sense for a pinned (persistent) readout.
    final bool showClose = widget.persist;
    final children = <Widget>[
      Text(
        "t = ${widget.t[ti].toStringAsFixed(3)} s",
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
      for (int a = 0; a < widget.series.length; a++)
        Text(
          "${_label(a)}: "
          "${widget.series[a][ti].toStringAsFixed(widget.decimals)}"
          "${widget.unit.isEmpty ? "" : " ${widget.unit}"}",
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: widget.colors[a],
          ),
        ),
    ];
    final Widget box = Stack(
      clipBehavior: Clip.none,
      children: [
        // The box passes touches through, so you can keep scrubbing under it…
        IgnorePointer(
          child: Container(
            // Reserve room on the right for the close button so it never sits
            // over a value.
            padding: EdgeInsets.fromLTRB(8, 6, showClose ? 26 : 8, 6),
            decoration: BoxDecoration(
              color: const Color(0xF2FFFFFF),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black26),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
        // …except the close button, which stays tappable to clear the pin.
        if (showClose)
          Positioned(
            top: 2,
            right: 2,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _clear,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );

    // Follow mode: the box tracks the crosshair's x, centered above it and
    // clamped to the chart by Align (it never runs off either edge).
    if (widget.pos == HoverReadoutPos.follow) {
      final double tMin = widget.t[0];
      final double tMax =
          widget.count > 1 ? widget.t[widget.count - 1] : tMin + 1e-3;
      final double denom = (tMax - tMin).abs() < 1e-9 ? 1e-3 : (tMax - tMin);
      final double plotLeft = _ChartPainter.padL;
      final double plotW = width - _ChartPainter.padR - plotLeft;
      double alignX = 0;
      if (plotW > 0) {
        final double cx =
            plotLeft + ((widget.t[ti] - tMin) / denom).clamp(0.0, 1.0) * plotW;
        alignX = ((cx / width) * 2 - 1).clamp(-1.0, 1.0);
      }
      return Positioned(
        top: 6,
        left: 0,
        right: 0,
        child: Align(alignment: Alignment(alignX, -1), child: box),
      );
    }

    // Fixed corner (left/right) or adaptive (opposite the finger).
    final bool boxOnLeft;
    switch (widget.pos) {
      case HoverReadoutPos.left:
        boxOnLeft = true;
        break;
      case HoverReadoutPos.right:
        boxOnLeft = false;
        break;
      case HoverReadoutPos.adaptive:
        final double frac = widget.count > 1 ? ti / (widget.count - 1) : 0.0;
        boxOnLeft = frac >= 0.5; // finger on the right -> box on the left
        break;
      case HoverReadoutPos.follow:
        boxOnLeft = false; // handled above
        break;
    }
    return Positioned(
      top: 6,
      left: boxOnLeft ? 6 : null,
      right: boxOnLeft ? null : 6,
      child: box,
    );
  }

  String _label(int a) {
    final labels = widget.labels;
    if (labels != null && a < labels.length) return labels[a];
    return "v$a";
  }
}

/// Rename dialog that owns its text controller, so the controller is disposed
/// only when the dialog's element is (after the dismiss animation finishes) —
/// disposing it in the caller's async gap would crash the still-animating
/// TextField ("controller used after being disposed").
class _RenameDialog extends StatefulWidget {
  final String initial;
  final String hint;
  const _RenameDialog({required this.initial, required this.hint});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Rename log"),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          // Show the default "Log #id" faded in the field until a name is typed.
          hintText: widget.hint,
          hintStyle: TextStyle(color: Colors.grey.shade400),
          labelText: "Name (blank to clear)",
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text("Save"),
        ),
      ],
    );
  }
}

