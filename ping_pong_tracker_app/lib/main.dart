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
import 'models/saved_log.dart';
import 'widgets/interactive_chart.dart';
import 'widgets/rename_dialog.dart';
import 'widgets/calibration_wizard.dart';

part 'ble_screen_core.dart';
part 'ble_screen_ui.dart';

// App version, shown top-right. Bump on app changes (1.0, 1.1, ...).
const String kAppVersion = "1.2";

// Shared constants (top-level so both part-file mixins can see them).
const double _batteryAlpha = 0.02; // EMA weight (~0.6 s at ~80 pkt/s)
const double _accelScaleG = 0.488 / 1000.0; // +/-16 g  -> G per count
const double _gyroScaleDps = 70.0 / 1000.0; // 2000 dps -> dps per count
const double _odrHz = 1660.0; // fixed IMU output data rate
const int kMaxLogSamples = 20000; // ~12 s headroom at 1660 Hz
const int _kRingCap = 3400; // ~2 s of pre-hit history (max window)
const String _kAutoLoggingKey = "autoLoggingEnabled";
const String _kHitWindowKey = "hitWindowSec";
const String _kManualTimeoutKey = "manualTimeoutSec";
const String _kHitThreshKey = "hitThreshG";
const String _kSwingHpKey = "swingHpSec";
const String _kMinScaleKey = "minScaleMps";
const String _kShowAccelKey = "showAccelGraph";
const String _kShowGyroKey = "showGyroGraph";
const String _kThemeModeKey = "themeMode";
const String _kAppThemeKey = "appTheme";
const String _kResetLogsKey = "resetLogsOnLeave";
// Sensor -> paddle-face-centre distance for the ω×r face speed. A fixed
// mounting constant (not user-tunable), measured ~18.5 cm.
const double kLeverArmM = 0.185;
const String _kHoverPersistKey = "hoverPersists";
const String _kHoverPosKey = "hoverReadoutPos";
const String _kTimeMicrosKey = "timeMicros";
const String _kTimeDecimalsKey = "timeDecimals";
const String _kFaceNormXKey = "faceNormalX";
const String _kFaceNormYKey = "faceNormalY";
const String _kFaceNormZKey = "faceNormalZ";
const String _kLeverDirXKey = "leverDirX";
const String _kLeverDirYKey = "leverDirY";
const String _kLeverDirZKey = "leverDirZ";
const String _kLogSeqKey = "logSeq"; // last issued log number
const List<Color> _accelColors = [Colors.red, Colors.green, Colors.blue];
const List<Color> _gyroColors = [Colors.orange, Colors.purple, Colors.teal];
const List<String> _accelLabels = ["ax", "ay", "az"];
const List<String> _gyroLabels = ["gx", "gy", "gz"];
const List<Color> _csvColColors = [
  Colors.black54, // time
  Colors.red, Colors.green, Colors.blue, // ax, ay, az  (match accel chart)
  Colors.orange, Colors.purple, Colors.teal, // gx, gy, gz  (match gyro chart)
];
const List<int> _csvColWidth = [7, 9, 9, 9, 9, 9, 9];
const List<int> _csvColDecimals = [4, 4, 4, 4, 2, 2, 2];
const List<String> _csvColLabels = [
  "time_s",
  "ax_g",
  "ay_g",
  "az_g",
  "gx_dps",
  "gy_dps",
  "gz_dps",
];

// Colour theme, separate from the light/dark brightness.
enum AppTheme { blue, gray }

// App-wide theme mode + colour theme, driven by the Settings controls. Loaded
// before runApp so there's no flash of the wrong theme, then updated live (the
// MaterialApp listens to both notifiers).
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.system,
);
final ValueNotifier<AppTheme> appThemeNotifier = ValueNotifier(AppTheme.blue);

ThemeMode _parseThemeMode(String? s) {
  switch (s) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

AppTheme _parseAppTheme(String? s) =>
    s == 'gray' ? AppTheme.gray : AppTheme.blue;

Color _seedFor(AppTheme t) =>
    t == AppTheme.gray ? Colors.blueGrey : Colors.blue;

// Blue keeps a bright-blue top bar in both modes; Gray uses a light-grey bar in
// light mode and a dark-grey bar in dark mode, so it follows the theme.
AppBarTheme _appBarTheme(AppTheme t, Brightness b) {
  if (t == AppTheme.blue) {
    return const AppBarTheme(
      backgroundColor: Colors.blueAccent,
      foregroundColor: Colors.white,
    );
  }
  final bool dark = b == Brightness.dark;
  return AppBarTheme(
    backgroundColor: dark ? const Color(0xFF1F1F1F) : const Color(0xFFE4E4E6),
    foregroundColor: dark ? Colors.white : Colors.black87,
  );
}

ThemeData _lightTheme(AppTheme t) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _seedFor(t)),
  useMaterial3: true,
  appBarTheme: _appBarTheme(t, Brightness.light),
);

ThemeData _darkTheme(AppTheme t) => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _seedFor(t),
    brightness: Brightness.dark,
  ),
  scaffoldBackgroundColor: const Color(0xFF0A0A0A), // near-black background
  appBarTheme: _appBarTheme(t, Brightness.dark),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.info, color: true);
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = _parseThemeMode(prefs.getString(_kThemeModeKey));
  appThemeNotifier.value = _parseAppTheme(prefs.getString(_kAppThemeKey));
  runApp(const PingPongTrackerApp());
}

class PingPongTrackerApp extends StatelessWidget {
  const PingPongTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => ValueListenableBuilder<AppTheme>(
        valueListenable: appThemeNotifier,
        builder: (context, appTheme, _) => MaterialApp(
          title: 'Paddle Tracker BLE Test',
          theme: _lightTheme(appTheme),
          darkTheme: _darkTheme(appTheme),
          themeMode: mode,
          home: const BLETestScreen(),
        ),
      ),
    );
  }
}

class BLETestScreen extends StatefulWidget {
  const BLETestScreen({super.key});

  @override
  State<BLETestScreen> createState() => _BLETestScreenState();
}

class _BLETestScreenState extends State<BLETestScreen>
    with SingleTickerProviderStateMixin, _BleScreenCore, _BleScreenUi {}
