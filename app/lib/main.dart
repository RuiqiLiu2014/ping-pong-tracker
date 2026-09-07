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
const String kAppVersion = "1.3";

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
const String _kColorSwapKey = "colorSwap";
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
enum AppTheme {
  blue,
  gray,
  sage,
  lavender,
  yellow,
  red,
  brown,
  pink,
  orange,
  teal,
  navy,
  magenta,
}

// How each theme's two shades (a lighter and a darker tone of the same hue) map
// to the top bar and the accent (text / toggles / sliders). This is independent
// of light/dark brightness, so the user controls it separately.
//   normal   - bar = lighter, accent = darker  (the original arrangement)
//   reversed - bar = darker,  accent = lighter (swapped)
//   allLight - both use the lighter shade
//   allDark  - both use the darker shade
enum ColorSwap { normal, reversed, allLight, allDark }

// App-wide theme mode + colour theme + colour-swap, driven by the Settings
// controls. Loaded before runApp so there's no flash of the wrong theme, then
// updated live (the MaterialApp listens to all three notifiers).
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.system,
);
final ValueNotifier<AppTheme> appThemeNotifier = ValueNotifier(AppTheme.blue);
final ValueNotifier<ColorSwap> colorSwapNotifier = ValueNotifier(
  ColorSwap.normal,
);

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

AppTheme _parseAppTheme(String? s) {
  switch (s) {
    case 'gray':
      return AppTheme.gray;
    case 'sage':
      return AppTheme.sage;
    case 'lavender':
      return AppTheme.lavender;
    case 'yellow':
      return AppTheme.yellow;
    case 'red':
      return AppTheme.red;
    case 'brown':
      return AppTheme.brown;
    case 'pink':
      return AppTheme.pink;
    case 'orange':
      return AppTheme.orange;
    case 'teal':
      return AppTheme.teal;
    case 'navy':
      return AppTheme.navy;
    case 'magenta':
      return AppTheme.magenta;
    default:
      return AppTheme.blue;
  }
}

ColorSwap _parseColorSwap(String? s) {
  for (final v in ColorSwap.values) {
    if (v.name == s) return v;
  }
  return ColorSwap.normal;
}

// The two canonical shades for each theme: a lighter tone and a darker tone of
// the same hue, both independent of light/dark brightness. The colour-swap
// setting decides which shade goes to the top bar and which to the accent.
({Color light, Color dark}) _themeShades(AppTheme t) {
  switch (t) {
    case AppTheme.blue:
      return (light: const Color(0xFFA8D8F0), dark: const Color(0xFF3E6E8E));
    case AppTheme.gray:
      return (light: const Color(0xFFE4E4E6), dark: const Color(0xFF1F1F1F));
    case AppTheme.sage:
      return (light: const Color(0xFFA2EDBD), dark: const Color(0xFF3E7A5A));
    case AppTheme.lavender:
      return (light: const Color(0xFFCDBFF0), dark: const Color(0xFF6A5A9E));
    case AppTheme.yellow:
      return (light: const Color(0xFFEFE3A3), dark: const Color(0xFF7A6520));
    case AppTheme.red:
      return (light: const Color(0xFFF2B3AB), dark: const Color(0xFF8E3B34));
    case AppTheme.brown:
      return (light: const Color(0xFFE4C6A0), dark: const Color(0xFF5A4632));
    case AppTheme.pink:
      return (light: const Color(0xFFF4C4DB), dark: const Color(0xFF8E3C63));
    case AppTheme.orange:
      return (light: const Color(0xFFF8C69A), dark: const Color(0xFFA05A22));
    case AppTheme.teal:
      return (light: const Color(0xFFA6E1D9), dark: const Color(0xFF2D7D74));
    case AppTheme.navy:
      return (light: const Color(0xFFB2BEDE), dark: const Color(0xFF26356B));
    case AppTheme.magenta:
      return (light: const Color(0xFFF0AFE0), dark: const Color(0xFF9A2C82));
  }
}

// Resolve the (top-bar, accent) colour pair for a theme under a swap mode.
(Color, Color) _swapColors(AppTheme t, ColorSwap s) {
  final shades = _themeShades(t);
  switch (s) {
    case ColorSwap.normal:
      return (shades.light, shades.dark);
    case ColorSwap.reversed:
      return (shades.dark, shades.light);
    case ColorSwap.allLight:
      return (shades.light, shades.light);
    case ColorSwap.allDark:
      return (shades.dark, shades.dark);
  }
}

// Readable foreground (near-black or white) for text sitting on [c].
Color _onColor(Color c) =>
    c.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

// Build the ThemeData for a theme + swap + brightness. Brightness controls the
// canvas (background / surfaces / body text); the swap controls the bar and
// accent colours. Surfaces are seeded from the theme's darker (more saturated)
// shade for a consistent tint regardless of swap, then primary is forced to the
// chosen accent so sliders/toggles show it exactly. Gray stays monochrome.
ThemeData _buildTheme(AppTheme t, ColorSwap s, Brightness b) {
  final (bar, accent) = _swapColors(t, s);
  final Color seed = _themeShades(t).dark;
  final ColorScheme base = t == AppTheme.gray
      ? ColorScheme.fromSeed(
          seedColor: seed,
          brightness: b,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        )
      : ColorScheme.fromSeed(seedColor: seed, brightness: b);
  final ColorScheme scheme = base.copyWith(
    primary: accent,
    onPrimary: _onColor(accent),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: b == Brightness.dark
        ? const Color(0xFF0A0A0A) // near-black background
        : null,
    appBarTheme: AppBarTheme(
      backgroundColor: bar,
      foregroundColor: _onColor(bar),
    ),
  );
}

ThemeData _lightTheme(AppTheme t, ColorSwap s) =>
    _buildTheme(t, s, Brightness.light);

ThemeData _darkTheme(AppTheme t, ColorSwap s) =>
    _buildTheme(t, s, Brightness.dark);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.info, color: true);
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = _parseThemeMode(prefs.getString(_kThemeModeKey));
  appThemeNotifier.value = _parseAppTheme(prefs.getString(_kAppThemeKey));
  colorSwapNotifier.value = _parseColorSwap(prefs.getString(_kColorSwapKey));
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
        builder: (context, appTheme, _) => ValueListenableBuilder<ColorSwap>(
          valueListenable: colorSwapNotifier,
          builder: (context, swap, _) => MaterialApp(
            title: 'Paddle Tracker BLE Test',
            theme: _lightTheme(appTheme, swap),
            darkTheme: _darkTheme(appTheme, swap),
            themeMode: mode,
            home: const BLETestScreen(),
          ),
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
