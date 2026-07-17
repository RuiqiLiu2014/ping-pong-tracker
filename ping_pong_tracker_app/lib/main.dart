import 'dart:async';
import 'dart:convert';
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

  DateTime? _lastPacketTime;
  double _totalDelayMs = 0;
  int _packetCount = 0;
  String _averageDelayStr = "0.0";

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
      // 1. Connect WITHOUT triggering the ArduinoBLE MTU crash
      await device.connect(
        license: License.nonprofit,
        autoConnect: false,
        mtu: null,
      );
      _targetDevice = device;

      setState(() {
        _connectionStatus = "Negotiating packet size...";
      });

      // 2. Give the board half a second to stabilize, then ask for a larger MTU
      await Future.delayed(const Duration(milliseconds: 500));
      await device.requestMtu(
        255,
      ); // 255 bytes is plenty for our 45-byte string
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
      DateTime now = DateTime.now();
      if (_lastPacketTime != null) {
        int delay = now.difference(_lastPacketTime!).inMilliseconds;
        _totalDelayMs += delay;
        _packetCount++;
        double avg = _totalDelayMs / _packetCount;
        _averageDelayStr = avg.toStringAsFixed(1);
      }
      _lastPacketTime = now;

      String incomingString = utf8.decode(value).trim();
      List<String> parsedValues = incomingString.split(',');

      // We now expect 8 values (ax, ay, az, gx, gy, gz, dt_ms, batt_pct)
      if (parsedValues.length >= 8) {
        setState(() {
          _imuData = parsedValues.sublist(0, 6);
          _batteryPct = parsedValues[7];
        });
      }
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
      _lastPacketTime = null;
      _totalDelayMs = 0;
      _packetCount = 0;
      _averageDelayStr = "0.0";
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
              "Running Avg Delay: $_averageDelayStr ms",
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
