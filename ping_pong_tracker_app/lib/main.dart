import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  SavedLog(
    this.id,
    this.timestamp,
    this.t,
    this.axes,
    this.count,
    this.durationSec,
  );
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
  String _connectionStatus = "Disconnected";
  bool _isConnecting = false;

  final String targetDeviceName = "PaddleTrack";
  final Guid uartServiceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Guid txCharacteristicUuid = Guid(
    "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
  );

  // ---- Live display ----
  List<String> _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
  // Battery % from packet byte 1 (not accurate without a battery attached).
  String _batteryPct = "--";

  int _samplesInWindow = 0;
  DateTime? _windowStart;
  String _sampleRateStr = "0";

  static const double _accelScaleG = 0.488 / 1000.0; // +/-16 g  -> G per count
  static const double _gyroScaleDps = 70.0 / 1000.0; // 2000 dps -> dps per count

  // ---- Logging ----
  // Auto-timeout caps a session, so a working buffer of 20k samples (~12 s at
  // 1660 Hz) is plenty of headroom above the 5 s max.
  static const int kMaxLogSamples = 20000;
  bool _isLogging = false;
  final Stopwatch _logStopwatch = Stopwatch();
  int _lastLogPacketUs = 0;
  Timer? _autoStopTimer;

  // Reused capture buffers for the in-progress session.
  Float64List? _capT;
  List<Float32List>? _capAxes;
  int _capCount = 0;

  // Finished logs (newest first) and the one currently open for viewing.
  final List<SavedLog> _logs = [];
  int _logSeq = 0;
  SavedLog? _selectedLog;

  // ---- Settings (persisted) ----
  static const String _kAutoTimeoutKey = "autoTimeoutSec";
  double _autoTimeoutSec = 4.0; // 1.0 - 5.0, 0.1 steps
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

  late final TabController _tabController;
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    // Repaint at ~10 Hz rather than on every BLE packet (~80 Hz).
    _uiTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
    _loadSettings();
    _loadLogs();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final v = prefs.getDouble(_kAutoTimeoutKey);
    if (v != null && mounted) {
      setState(() => _autoTimeoutSec = v.clamp(1.0, 5.0));
    }
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
      final bd = ByteData(4 + n * 8 + 6 * n * 4);
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
      await _logFile(dir, log).writeAsBytes(bd.buffer.asUint8List(), flush: true);
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
        loaded.add(SavedLog(id, ts, t, axes, n, t[n - 1]));
        if (id > maxId) maxId = id;
      }
      loaded.sort((a, b) => b.id.compareTo(a.id)); // newest first
      if (mounted) {
        setState(() {
          _logs
            ..clear()
            ..addAll(loaded);
          if (maxId > _logSeq) _logSeq = maxId;
        });
      }
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
    _charSubscription?.cancel();
    _scanResultsSubscription?.cancel();
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
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid == txCharacteristicUuid) {
              _subscribeToCharacteristic(char);
              return;
            }
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

    final int startUs = _lastLogPacketUs;
    final int nowUs = _isLogging ? _logStopwatch.elapsedMicroseconds : 0;

    double ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
    for (int s = 0; s < count; s++) {
      final int b = 2 + s * 12;
      ax = bd.getInt16(b + 0, Endian.little) * _accelScaleG;
      ay = bd.getInt16(b + 2, Endian.little) * _accelScaleG;
      az = bd.getInt16(b + 4, Endian.little) * _accelScaleG;
      gx = bd.getInt16(b + 6, Endian.little) * _gyroScaleDps;
      gy = bd.getInt16(b + 8, Endian.little) * _gyroScaleDps;
      gz = bd.getInt16(b + 10, Endian.little) * _gyroScaleDps;

      if (_isLogging && _capCount < kMaxLogSamples) {
        final double tSec =
            (startUs + (nowUs - startUs) * (s + 1) / count) / 1e6;
        _capT![_capCount] = tSec;
        _capAxes![0][_capCount] = ax;
        _capAxes![1][_capCount] = ay;
        _capAxes![2][_capCount] = az;
        _capAxes![3][_capCount] = gx;
        _capAxes![4][_capCount] = gy;
        _capAxes![5][_capCount] = gz;
        _capCount++;
        if (_capCount >= kMaxLogSamples) _stopLogging(); // safety cap
      }
    }
    if (_isLogging) _lastLogPacketUs = nowUs;

    _imuData = [
      ax.toStringAsFixed(3),
      ay.toStringAsFixed(3),
      az.toStringAsFixed(3),
      gx.toStringAsFixed(1),
      gy.toStringAsFixed(1),
      gz.toStringAsFixed(1),
    ];
  }

  void _disconnect() async {
    if (_isLogging) _stopLogging();
    await _charSubscription?.cancel();
    await _scanResultsSubscription?.cancel();
    await _targetDevice?.disconnect();
    setState(() {
      _targetDevice = null;
      _isConnecting = false;
      _connectionStatus = "Disconnected";
      _windowStart = null;
      _samplesInWindow = 0;
      _sampleRateStr = "0";
      _batteryPct = "--";
      _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
    });
  }

  // =========================================================================
  // Logging control
  // =========================================================================
  void _startLogging() {
    _capT ??= Float64List(kMaxLogSamples);
    _capAxes ??= List.generate(6, (_) => Float32List(kMaxLogSamples));
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(
      Duration(milliseconds: (_autoTimeoutSec * 1000).round()),
      () {
        if (_isLogging) _stopLogging();
      },
    );
    setState(() {
      _capCount = 0;
      _lastLogPacketUs = 0;
      _logStopwatch
        ..reset()
        ..start();
      _isLogging = true;
    });
  }

  void _stopLogging() {
    _autoStopTimer?.cancel();
    _logStopwatch.stop();
    // Snapshot the captured portion into a right-sized SavedLog.
    SavedLog? created;
    if (_capCount > 0) {
      final int n = _capCount;
      final t = Float64List(n)..setRange(0, n, _capT!);
      final axes = List.generate(
        6,
        (a) => Float32List(n)..setRange(0, n, _capAxes![a]),
      );
      created = SavedLog(++_logSeq, DateTime.now(), t, axes, n, t[n - 1]);
      _logs.insert(0, created);
    }
    setState(() => _isLogging = false);
    if (created != null) _persistLog(created); // survive restarts
  }

  void _deleteLog(SavedLog log) {
    _deleteLogFile(log);
    setState(() {
      _logs.remove(log);
      if (_selectedLog == log) _selectedLog = null;
    });
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

  // Export via the system share sheet (handles any size, unlike the clipboard).
  void _exportLog(SavedLog log) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/paddle_log_${log.id}.csv');
      await file.writeAsString(_csvFor(log));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'Paddle log #${log.id}',
          text:
              'Paddle IMU log #${log.id}: ${log.count} samples, '
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.battery_full, size: 20),
                  const SizedBox(width: 4),
                  Text(
                    "$_batteryPct%",
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
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

  Widget _buildConnectionTab() {
    final streaming = _connectionStatus == "Streaming Data";
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
          const SizedBox(height: 40),
          const Text(
            "Accelerometer (G)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            "X: ${_imuData[0]}   Y: ${_imuData[1]}   Z: ${_imuData[2]}",
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 20),
          const Text(
            "Gyroscope (deg/s)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            "X: ${_imuData[3]}   Y: ${_imuData[4]}   Z: ${_imuData[5]}",
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 40),
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
          ElevatedButton.icon(
            // Only allow logging while actually streaming from the paddle.
            onPressed: streaming
                ? (_isLogging ? _stopLogging : _startLogging)
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _isLogging ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
            ),
            icon: Icon(_isLogging ? Icons.stop : Icons.fiber_manual_record),
            label: Text(
              _isLogging ? "Stop Logging" : "Start Logging",
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isLogging
                ? "Logging... $_capCount samples "
                      "(auto-stops at ${_autoTimeoutSec.toStringAsFixed(1)} s)"
                : (_logs.isNotEmpty
                      ? "${_logs.length} log(s) saved - see Logs tab"
                      : "Not logging"),
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // ---- Logs tab: list of logs, or a detail view with a back button ----
  Widget _buildLogsTab() {
    if (_selectedLog != null) return _buildLogDetail(_selectedLog!);

    if (_logs.isEmpty) {
      return const Center(
        child: Text(
          "No logs yet.\nConnect, then tap Start Logging.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      itemCount: _logs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final log = _logs[i];
        return ListTile(
          leading: const Icon(Icons.show_chart, color: Colors.blueAccent),
          title: Text("Log #${log.id}  •  ${_fmtTime(log.timestamp)}"),
          subtitle: Text(
            "${log.count} samples  •  ${log.durationSec.toStringAsFixed(1)} s",
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: "Export CSV",
                icon: const Icon(Icons.share),
                onPressed: () => _exportLog(log),
              ),
              IconButton(
                tooltip: "Delete",
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteLog(log),
              ),
            ],
          ),
          onTap: () => setState(() => _selectedLog = log),
        );
      },
    );
  }

  Widget _buildLogDetail(SavedLog log) {
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
                child: Text(
                  "Log #${log.id}  •  ${log.count} samples  •  "
                  "${log.durationSec.toStringAsFixed(1)} s",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: "Export CSV",
                icon: const Icon(Icons.share),
                onPressed: () => _exportLog(log),
              ),
              IconButton(
                tooltip: "Delete",
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteLog(log),
              ),
            ],
          ),
        ),
        _chartSection(
          "Accelerometer (G)",
          log,
          [log.axes[0], log.axes[1], log.axes[2]],
          _accelColors,
          _accelLabels,
        ),
        _chartSection(
          "Gyroscope (deg/s)",
          log,
          [log.axes[3], log.axes[4], log.axes[5]],
          _gyroColors,
          _gyroLabels,
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Text(
            "time_s, ax_g, ay_g, az_g, gx_dps, gy_dps, gz_dps",
            style: TextStyle(
              fontFamily: "monospace",
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(child: _buildCsvList(log)),
      ],
    );
  }

  Widget _chartSection(
    String title,
    SavedLog log,
    List<Float32List> series,
    List<Color> colors,
    List<String> labels,
  ) {
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
            child: CustomPaint(
              painter: _ChartPainter(log.t, series, log.count, colors),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        _legend(colors, labels),
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

  Widget _buildCsvList(SavedLog log) {
    return ListView.builder(
      itemCount: log.count,
      itemExtent: 18,
      itemBuilder: (context, i) {
        final row = StringBuffer(log.t[i].toStringAsFixed(4));
        for (int a = 0; a < 6; a++) {
          row.write(', ');
          row.write(log.axes[a][i].toStringAsFixed(a < 3 ? 4 : 2));
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            row.toString(),
            style: const TextStyle(fontFamily: "monospace", fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  // ---- Settings tab ----
  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          "Auto-stop logging",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        const Text(
          "Logging stops automatically after this duration.",
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text("Timeout"),
            Expanded(
              child: Slider(
                value: _autoTimeoutSec,
                min: 1.0,
                max: 5.0,
                divisions: 40, // 0.1 s steps
                label: "${_autoTimeoutSec.toStringAsFixed(1)} s",
                onChanged: (v) => setState(
                  () => _autoTimeoutSec = double.parse(v.toStringAsFixed(1)),
                ),
                onChangeEnd: (v) => _prefs?.setDouble(
                  _kAutoTimeoutKey,
                  double.parse(v.toStringAsFixed(1)),
                ),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(
                "${_autoTimeoutSec.toStringAsFixed(1)} s",
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("1.0 s", style: TextStyle(color: Colors.grey, fontSize: 12)),
            Text("5.0 s", style: TextStyle(color: Colors.grey, fontSize: 12)),
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

  _ChartPainter(this.t, this.series, this.count, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFAFAFA),
    );

    const double padL = 46, padR = 10, padT = 10, padB = 22;
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
    if (vMax <= vMin) vMax = vMin + 1;
    final vpad = (vMax - vMin) * 0.05;
    vMin -= vpad;
    vMax += vpad;

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

    hline(vMax);
    if (vMin < 0 && vMax > 0) hline(0);
    hline(vMin);

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
      old.count != count || old.t != t || old.colors != colors;
}
