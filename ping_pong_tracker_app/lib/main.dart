import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

class BLETestScreen extends StatefulWidget {
  const BLETestScreen({super.key});

  @override
  State<BLETestScreen> createState() => _BLETestScreenState();
}

class _BLETestScreenState extends State<BLETestScreen> {
  BluetoothDevice? _targetDevice;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<int>>? _charSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  String _connectionStatus = "Disconnected";
  bool _isConnecting = false;

  final String targetDeviceName = "PaddleTrack";
  final Guid uartServiceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Guid txCharacteristicUuid = Guid(
    "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
  );

  List<String> _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
  String _batteryPct = "--";

  // Achieved sample rate, measured over a rolling 1-second window.
  int _samplesInWindow = 0;
  DateTime? _windowStart;
  String _sampleRateStr = "0";

  // LSM6DS3 sensitivities for the ranges configured in firmware.
  static const double _accelScaleG = 0.488 / 1000.0; // +/-16 g  -> G per count
  static const double _gyroScaleDps = 70.0 / 1000.0; // 2000 dps -> dps per count

  @override
  void dispose() {
    _charSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _targetDevice?.disconnect();
    super.dispose();
  }

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

          // ADD THIS DELAY: Give the Android Bluetooth hardware a moment to reset
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

      // Request a large MTU so the firmware can pack many IMU samples into
      // each notification (the key to streaming well above 100 Hz).
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

    _charSubscription = char.onValueReceived.listen((value) {
      // Batched binary packet from the firmware:
      //   byte 0 : sample count N
      //   byte 1 : battery %
      //   then N * 12 bytes: int16 LE  ax, ay, az, gx, gy, gz  (raw counts)
      if (value.length < 2) return;

      int count = value[0];
      int batt = value[1];
      if (count < 1 || value.length < 2 + count * 12) return;

      var byteData = ByteData.view(Uint8List.fromList(value).buffer);

      // Measure the achieved sample rate over a rolling 1-second window.
      DateTime now = DateTime.now();
      _windowStart ??= now;
      _samplesInWindow += count;
      int elapsedMs = now.difference(_windowStart!).inMilliseconds;
      if (elapsedMs >= 1000) {
        _sampleRateStr = (_samplesInWindow * 1000 / elapsedMs).round().toString();
        _samplesInWindow = 0;
        _windowStart = now;
      }

      // Display the most recent sample in the batch.
      int base = 2 + (count - 1) * 12;
      double ax = byteData.getInt16(base + 0, Endian.little) * _accelScaleG;
      double ay = byteData.getInt16(base + 2, Endian.little) * _accelScaleG;
      double az = byteData.getInt16(base + 4, Endian.little) * _accelScaleG;
      double gx = byteData.getInt16(base + 6, Endian.little) * _gyroScaleDps;
      double gy = byteData.getInt16(base + 8, Endian.little) * _gyroScaleDps;
      double gz = byteData.getInt16(base + 10, Endian.little) * _gyroScaleDps;

      setState(() {
        _imuData = [
          ax.toStringAsFixed(3),
          ay.toStringAsFixed(3),
          az.toStringAsFixed(3),
          gx.toStringAsFixed(1),
          gy.toStringAsFixed(1),
          gz.toStringAsFixed(1),
        ];
        _batteryPct = batt.toString();
      });
    });
  }

  void _disconnect() async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paddle Prototype Bench'),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _connectionStatus,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _connectionStatus == "Streaming Data"
                    ? Colors.green
                    : Colors.red,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Sample Rate: $_sampleRateStr Hz",
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),

            // New Battery Display
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.battery_charging_full, color: Colors.green),
                const SizedBox(width: 5),
                Text(
                  "Battery: $_batteryPct%",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
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

            const SizedBox(height: 60),

            ElevatedButton(
              onPressed: _isConnecting || _connectionStatus == "Streaming Data"
                  ? _disconnect
                  : _startScanAndConnect,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 15,
                ),
              ),
              child: Text(
                _connectionStatus == "Streaming Data"
                    ? "Disconnect"
                    : "Connect to Paddle",
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
