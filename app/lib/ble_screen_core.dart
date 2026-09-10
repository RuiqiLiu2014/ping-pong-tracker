part of 'main.dart';

// Minimum paddle firmware this app can talk to. The app speaks only the current
// packet format (no back-compat), so an older board is rejected on connect with
// an "update firmware" note. Bump these when the firmware packet format changes.
const int _kReqFwMajor = 1;
const int _kReqFwMinor = 3;

// All connection, packet, capture/logging, persistence and estimator glue
// for the paddle screen. UI builders live in ble_screen_ui.dart.
mixin _BleScreenCore
    on State<BLETestScreen>, SingleTickerProviderStateMixin<BLETestScreen> {
  // ---- Connection state ----
  BluetoothDevice? _targetDevice;
  StreamSubscription<List<int>>? _charSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  Timer? _scanTimeoutTimer; // gives up on scanning after a while
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
  // Connected board's firmware is older than this app supports: we stay
  // connected but don't stream, and the Connection tab shows an update warning.
  bool _fwOutdated = false;

  // ---- Live display ----
  List<String> _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
  // Battery % from packet byte 1 (not accurate without a battery attached).
  // Raw reading is jumpy (ADC noise + voltage sag during BLE TX), so we show a
  // smoothed value that is clamped to never rise during a session (batteries
  // only discharge; any bounce-up is noise). No deadband — it steps 1% at a
  // time as the smoothed value crosses each integer.
  String _batteryPct = "--";
  double _batterySmoothed = -1; // EMA of the raw byte (-1 = no reading yet)
  int _batteryShown = -1; // displayed %, monotonically non-increasing
  // Board reports it is charging (fw >= 1.3). While set, the paddle stops
  // streaming IMU data and the % is allowed to rise (the never-rise clamp off).
  bool _charging = false;

  // Orientation + velocity estimator (sensor fusion), fed every sample.
  final MotionEstimator _motion = MotionEstimator();

  // Ball-hit detector, fed every sample; detected hit times (absolute stream
  // seconds) are buffered so a finalized log can mark the hits inside its window.
  final HitDetector _hitDetector = HitDetector();
  final List<double> _recentHits = [];

  int _samplesInWindow = 0;
  DateTime? _windowStart;
  String _sampleRateStr = "0";

  // ---- Auto-capture (motion-triggered logging) ----
  // Instead of a manual start/stop button, we continuously watch the incoming
  // stream and auto-record a fixed window around every detected BALL HIT. A ring
  // buffer holds enough history that, once a hit's after-window has streamed in,
  // we cut [hit - _hitWindowSec, hit + _hitWindowSec] out as its own log. EVERY
  // hit gets its own log even if nearby windows overlap (duplication by design).

  bool _armed = false; // auto-capture enabled (watching for a hit)
  final List<double> _pendingHits = []; // hit times awaiting their after-window

  // Manual logging (used when automatic logging is turned off): a Start/Stop
  // button records straight into the capture buffer until stopped or a timeout.
  bool _isManualLogging = false;
  Timer? _autoStopTimer;
  // Drives the Stop-button progress ring that fills over the auto-stop timeout.
  DateTime? _manualLogStart;
  Timer? _manualProgressTimer;

  // Free-running clock, for continuous per-sample timestamps (kept running the
  // whole session so ring/capture times are consistent).
  final Stopwatch _streamStopwatch = Stopwatch();

  // ---- Chip-clock timestamping (firmware >= 1.1) ----
  // The packet header carries the first sample's chip micros() + a cumulative
  // sample index, so we reconstruct exact per-sample times and detect drops.
  bool _haveChipRef = false;
  int _chipBaseUs = 0; // absolute µs of this packet's first sample (from 0)
  int _prevChipMicros = 0; // prev packet's first-sample chip micros (uint32)
  int _prevChipIndex = 0; // prev packet's first-sample index (uint32)
  int _prevChipN = 0; // prev packet's sample count
  int _chipFirstIndex = 0; // session's first sample index (for the timeline)
  double _lastChipTsec = 0; // last emitted chip time (s); monotonic guard
  int _dropCount = 0; // total dropped samples this session
  int _capDropStart = 0; // _dropCount snapshot when the current capture began

  // Ring buffer of recent samples (absolute stream time + 6 axes). _ringIdx
  // holds each sample's chip index (relative to session start) so a capture cut
  // from the ring can count drops inside its window from the index gaps.
  Float64List? _ringT;
  Float64List? _ringIdx;
  List<Float32List>? _ringAxes;
  int _ringHead = 0; // next write slot
  int _ringLen = 0; // valid samples held

  // Capture scratch buffer; times are absolute stream seconds (rebased on
  // finalize). Filled live by manual logging, or per-window by an auto extract.
  Float64List? _capT;
  List<Float32List>? _capAxes;
  int _capCount = 0;

  // Finished logs (newest first) and the one currently open for viewing.
  final List<SavedLog> _logs = [];
  int _logSeq = 0;
  SavedLog? _selectedLog;
  // Total on-disk size (bytes) of the persisted log files; shown at the bottom
  // of Settings. Refreshed whenever logs are loaded, added, or deleted.
  int _logStorageBytes = 0;
  // Non-modal graph-info speech bubble (built in the UI mixin): a lightweight
  // overlay anchored to the tapped ⓘ, dismissed by tapping anywhere.
  // _infoBubbleOwner tracks which icon opened it so re-tapping toggles it shut.
  OverlayEntry? _infoBubble;
  BuildContext? _infoBubbleOwner;
  // Logs-list multi-select: when active, rows show checkboxes and the top-right
  // share/delete icons act on the checked set.
  bool _selectMode = false;
  final Set<int> _selectedLogIds = {};
  // Velocity magnitude recomputed from each log's raw data (cached by log id).
  final Map<int, SpeedSeries> _speedCache = {};

  // ---- Log detail view: scroll + jump-to-top ----
  final ScrollController _detailScroll = ScrollController();
  final GlobalKey _chartsKey = GlobalKey(); // measures the charts block height
  double _chartsHeight = 0; // charts (item 0) height in px; 0 until measured
  bool _showJumpTop = false; // show jump-to-top once the charts scroll off
  // Logs-list scrolling: jump-to-top/bottom buttons, shown only when far
  // enough from each end (so short lists never show them).
  final ScrollController _logsScroll = ScrollController();
  bool _showLogsTop = false;
  bool _showLogsBottom = false;

  // ---- Settings (persisted) ----
  bool _autoLoggingEnabled = true; // false => manual Start/Stop button
  bool _resetLogsOnLeave = true; // leaving Logs tab returns to the list
  bool _hoverPersists = false; // graph hover readout stays after lifting finger
  HoverReadoutPos _hoverPos = HoverReadoutPos.follow; // hover readout side
  bool _timeMicros = false; // show time in µs (else ms with _timeDecimals)
  int _timeDecimals = 3; // ms decimal places (0-3) when not showing µs
  // Data captured before AND after each hit (s). Default 0.9 s: just under the
  // ~1.1 s between a single player's own hits in a rally, so a log typically
  // holds one hit. User-adjustable in Settings (0.25–2.0 s).
  double _hitWindowSec = 0.9;
  double _manualTimeoutSec = 4.0; // manual logging auto-stop (0.1 - 5.0 s)
  double _hitThreshG = 0.5; // ball-hit vibration threshold (lower = sensitive)
  double _swingHpSec = 0.35; // swing-speed high-pass window (0.2 - 0.7 s)
  double _minScaleMps = 5.0; // min top of the speed-graph y-axis (0 = off)
  bool _showAccelGraph = true; // show the raw accelerometer graph in log detail
  bool _showGyroGraph = true; // show the raw gyroscope graph in log detail
  // Paddle-face normal in the board frame from the last face-up calibration
  // (persisted). Used live and to split recorded logs into closing/brushing.
  List<double>? _faceNormal;
  // Calibrated sensor->tip direction (board frame) from the "tip up" pose,
  // persisted. Sets the ω×r direction for the true face speed. Null = default.
  List<double>? _leverDir;
  // Hits + swings since the last calibration (persisted). Drives a recalibrate
  // nudge; _calReminderDue is snapshotted at connect so it can't pop mid-session.
  int _useSinceCal = 0;
  bool _calReminderDue = false;
  SharedPreferences? _prefs;

  // Accelerometer and gyroscope are drawn on separate, independently-scaled
  // charts (their value ranges differ by orders of magnitude).

  // CSV table columns (time + 6 axes): per-column color (matching the charts),
  // field width in monospace chars (right-aligned so columns line up), decimal
  // places, and header label. Shared by the header and the data rows.

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
    _logsScroll.addListener(_onLogsScroll);
    _motion.onCalibrated = _onMotionCalibrated;
    _motion.onLeverCalibrated = _onLeverCalibrated;
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
      _selectedLog = null;
    }
    _syncUiTimer();
    // Rebuild so PopScope.canPop tracks the current tab (a swipe alone doesn't
    // rebuild this widget).
    if (mounted) setState(() {});
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
    final swingHp = prefs.getDouble(_kSwingHpKey);
    final minScale = prefs.getDouble(_kMinScaleKey);
    final showAccel = prefs.getBool(_kShowAccelKey);
    final showGyro = prefs.getBool(_kShowGyroKey);
    final resetLogs = prefs.getBool(_kResetLogsKey);
    final hoverPersist = prefs.getBool(_kHoverPersistKey);
    final hoverPosStr = prefs.getString(_kHoverPosKey);
    final timeMicros = prefs.getBool(_kTimeMicrosKey);
    final timeDec = prefs.getInt(_kTimeDecimalsKey);
    final fnx = prefs.getDouble(_kFaceNormXKey);
    final fny = prefs.getDouble(_kFaceNormYKey);
    final fnz = prefs.getDouble(_kFaceNormZKey);
    final ldx = prefs.getDouble(_kLeverDirXKey);
    final ldy = prefs.getDouble(_kLeverDirYKey);
    final ldz = prefs.getDouble(_kLeverDirZKey);
    final usc = prefs.getInt(_kUseSinceCalKey);
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
      if (timeMicros != null) _timeMicros = timeMicros;
      if (timeDec != null) _timeDecimals = timeDec.clamp(0, 3);
      if (win != null) _hitWindowSec = win.clamp(0.25, 2.0);
      if (timeout != null) _manualTimeoutSec = timeout.clamp(0.1, 5.0);
      if (hitThr != null) _hitThreshG = hitThr.clamp(0.1, 1.5);
      if (swingHp != null) _swingHpSec = swingHp.clamp(0.2, 0.7);
      if (minScale != null) _minScaleMps = minScale.clamp(0.0, 20.0);
      if (showAccel != null) _showAccelGraph = showAccel;
      if (showGyro != null) _showGyroGraph = showGyro;
      if (fnx != null && fny != null && fnz != null) {
        _faceNormal = [fnx, fny, fnz];
        _motion.setFaceNormal(fnx, fny, fnz);
      }
      if (ldx != null && ldy != null && ldz != null) {
        _leverDir = [ldx, ldy, ldz];
        _motion.setLeverDir(ldx, ldy, ldz);
      }
      if (usc != null) _useSinceCal = usc;
      _hitDetector.threshold = _hitThreshG;
      _motion.leverArmM = kLeverArmM;
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
      // Fixed layout: count, times, 6 axes, then name, hit-times, dropped count,
      // face normal, and lever direction. Face normal / lever dir write a count
      // of 3 (present) or 0 (no calibration when captured).
      final nameBytes = utf8.encode(log.name);
      final hits = log.hitTimes;
      final fn = log.faceNormal;
      final bool hasFn = fn != null && fn.length >= 3;
      final ld = log.leverDir;
      final bool hasLd = ld != null && ld.length >= 3;
      final bd = ByteData(
        4 +
            n * 8 +
            6 * n * 4 +
            4 +
            nameBytes.length +
            4 +
            hits.length * 8 +
            4 + // dropped-sample count
            4 + // face-normal presence/count
            (hasFn ? 24 : 0) + // 3 x float64
            4 + // lever-dir presence/count
            (hasLd ? 24 : 0), // 3 x float64
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
      bd.setInt32(off, log.droppedSamples, Endian.little);
      off += 4;
      // Face normal: count 3 + 3 doubles, or count 0 when uncalibrated.
      bd.setInt32(off, hasFn ? 3 : 0, Endian.little);
      off += 4;
      if (hasFn) {
        bd.setFloat64(off, fn[0], Endian.little);
        bd.setFloat64(off + 8, fn[1], Endian.little);
        bd.setFloat64(off + 16, fn[2], Endian.little);
        off += 24;
      }
      // Lever direction: count 3 + 3 doubles, or count 0 when uncalibrated.
      bd.setInt32(off, hasLd ? 3 : 0, Endian.little);
      off += 4;
      if (hasLd) {
        bd.setFloat64(off, ld[0], Endian.little);
        bd.setFloat64(off + 8, ld[1], Endian.little);
        bd.setFloat64(off + 16, ld[2], Endian.little);
        off += 24;
      }
      await _logFile(dir, log).writeAsBytes(u8, flush: true);
      _refreshLogStorage();
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
        // Name.
        String name = "";
        final nameLen = bd.getInt32(off, Endian.little);
        off += 4;
        if (nameLen > 0) {
          name = utf8.decode(bytes.sublist(off, off + nameLen));
          off += nameLen;
        }
        // Hit times.
        final hitTimes = <double>[];
        final hitCount = bd.getInt32(off, Endian.little);
        off += 4;
        for (int i = 0; i < hitCount; i++) {
          hitTimes.add(bd.getFloat64(off, Endian.little));
          off += 8;
        }
        // Dropped-sample count.
        final dropped = bd.getInt32(off, Endian.little);
        off += 4;
        // Face normal (count 3 when a face-up calibration was active, else 0).
        List<double>? faceNormal;
        final fnCount = bd.getInt32(off, Endian.little);
        off += 4;
        if (fnCount == 3) {
          faceNormal = [
            bd.getFloat64(off, Endian.little),
            bd.getFloat64(off + 8, Endian.little),
            bd.getFloat64(off + 16, Endian.little),
          ];
          off += 24;
        }
        // Lever direction (count 3 when a lever calibration was active, else 0).
        List<double>? leverDir;
        final ldCount = bd.getInt32(off, Endian.little);
        off += 4;
        if (ldCount == 3) {
          leverDir = [
            bd.getFloat64(off, Endian.little),
            bd.getFloat64(off + 8, Endian.little),
            bd.getFloat64(off + 16, Endian.little),
          ];
          off += 24;
        }
        loaded.add(
          SavedLog(
            id,
            ts,
            t,
            axes,
            n,
            t[n - 1],
            name: name,
            hitTimes: hitTimes,
            droppedSamples: dropped,
            faceNormal: faceNormal,
            leverDir: leverDir,
          ),
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
    _refreshLogStorage();
  }

  Future<void> _deleteLogFile(SavedLog log) async {
    try {
      final dir = await _logsDir();
      final f = _logFile(dir, log);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // Dismiss the graph-info speech bubble overlay, if one is open.
  void _removeInfoBubble() {
    _infoBubble?.remove();
    _infoBubble = null;
    _infoBubbleOwner = null;
  }

  // Sum the on-disk size of every persisted log file and update the Settings
  // readout. Best-effort: unreadable entries are skipped.
  Future<void> _refreshLogStorage() async {
    int total = 0;
    try {
      final dir = await _logsDir();
      for (final e in dir.listSync()) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (mounted && total != _logStorageBytes) {
      setState(() => _logStorageBytes = total);
    }
  }

  @override
  void dispose() {
    _removeInfoBubble(); // drop any open graph-info popover
    _uiTimer?.cancel();
    _autoStopTimer?.cancel();
    _manualProgressTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    _tabController.dispose();
    _detailScroll.dispose();
    _logsScroll.dispose();
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

    // Subscribe BEFORE scanning so a result that arrives during the scan isn't
    // missed. (Previously the listener was attached only after an awaited
    // startScan that doesn't return until scanning has already stopped, so the
    // paddle was never seen — turning it on mid-scan never connected and it
    // hung on "Scanning…" forever.)
    // One shared latch so the "found" path and the timeout path can't both run
    // when the paddle appears right at the deadline (which showed "Could not
    // connect" and THEN "Streaming Data"). Whichever fires first sets it
    // synchronously before any await, so the other becomes a no-op.
    bool resolved = false;
    await _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((
      results,
    ) async {
      if (resolved) return;
      for (final r in results) {
        if (r.device.platformName == targetDeviceName) {
          resolved = true;
          _scanTimeoutTimer?.cancel();
          await _scanResultsSubscription?.cancel();
          _scanResultsSubscription = null;
          await FlutterBluePlus.stopScan();
          await Future.delayed(const Duration(milliseconds: 500));
          _connectToDevice(r.device);
          return;
        }
      }
    });

    // Scan for a fixed window; because we're already listening, turning the
    // paddle on any time during it connects. If it never shows, give up cleanly
    // with an error instead of hanging.
    const scanWindow = Duration(seconds: 10);
    _scanTimeoutTimer?.cancel();
    _scanTimeoutTimer = Timer(scanWindow, () async {
      if (resolved) return;
      resolved = true;
      await _scanResultsSubscription?.cancel();
      _scanResultsSubscription = null;
      await FlutterBluePlus.stopScan();
      if (mounted) {
        setState(() {
          _connectionStatus = "Could not connect to paddle.";
          _isConnecting = false;
        });
      }
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: scanWindow,
        androidUsesFineLocation: true,
      );
    } catch (_) {
      // startScan can throw if BLE is momentarily unavailable; the timeout
      // timer surfaces the failure to the user.
    }
  }

  void _connectToDevice(BluetoothDevice device) async {
    // Android's direct connect intermittently fails with GATT_ERROR (status
    // 133), leaving a half-open link. Retry a couple of times — disconnecting
    // first to free the cached GATT client — before giving up with a clean
    // message instead of dumping the raw platform exception.
    const int maxAttempts = 3; // initial try + 2 retries
    bool connected = false;

    // Clear any stale/half-open GATT client up front — after the board is
    // power-cycled Android often still holds the old link, and the first
    // connect would otherwise stall on it until the timeout.
    try {
      await device.disconnect();
    } catch (_) {}

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      setState(() {
        _connectionStatus = attempt == 1
            ? "Connecting to PaddleTrack..."
            : "Connecting to PaddleTrack… (retry ${attempt - 1})";
      });
      try {
        await device.connect(
          license: License.nonprofit,
          autoConnect: false,
          mtu: null,
          // Fail fast instead of waiting out the ~35 s default, so retries are
          // quick.
          timeout: const Duration(seconds: 6),
        );
        connected = true;
        break;
      } catch (_) {
        // Clear the stale/half-open link, then back off before retrying.
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt < maxAttempts) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    }

    if (!connected) {
      setState(() {
        _connectionStatus = "Could not connect. Try again.";
        _isConnecting = false;
      });
      return;
    }

    // Connected — negotiate the link, discover the service, and subscribe.
    try {
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
      // Connected, but the expected UART service/characteristic wasn't found.
      setState(() {
        _connectionStatus = "Could not connect. Try again.";
        _isConnecting = false;
      });
    } catch (_) {
      setState(() {
        _connectionStatus = "Could not connect. Try again.";
        _isConnecting = false;
      });
    }
  }

  void _subscribeToCharacteristic(BluetoothCharacteristic char) async {
    // Back-compat dropped: this app speaks only the fw >= 1.3 packet format. If
    // the paddle is older, stay connected but don't subscribe — its packets
    // would misparse. The Connection tab shows an update warning and only
    // Connect/Disconnect work.
    if (!_fwAtLeast(_kReqFwMajor, _kReqFwMinor)) {
      setState(() {
        _fwOutdated = true;
        _connectionStatus = "Firmware update required";
        _isConnecting = false;
      });
      return;
    }
    _fwOutdated = false;
    await char.setNotifyValue(true);
    // Allocate the ring + capture buffers and start a free-running clock so the
    // ring stays warm (auto-capture history is ready the moment we arm).
    _ensureCaptureBuffers();
    _ringLen = 0;
    _ringHead = 0;
    _haveChipRef = false;
    _chipBaseUs = 0;
    _lastChipTsec = 0;
    _dropCount = 0;
    _hitDetector.reset();
    _recentHits.clear();
    _streamStopwatch
      ..reset()
      ..start();
    setState(() {
      _connectionStatus = "Streaming Data";
      _isConnecting = false;
      // Snapshot the recalibrate nudge for this session (only if calibrated), so
      // it shows at connect and never pops up mid-use.
      _calReminderDue = _faceNormal != null && _useSinceCal >= kCalReminderUses;
    });
    _charSubscription = char.onValueReceived.listen(_onPacket);
  }

  // True if the connected firmware is at least major.minor (picks packet format).
  bool _fwAtLeast(int major, int minor) {
    final parts = _firmwareVersion.split('.');
    if (parts.length < 2) return false;
    final maj = int.tryParse(parts[0]) ?? 0;
    final min = int.tryParse(parts[1]) ?? 0;
    return maj > major || (maj == major && min >= minor);
  }

  // Batched binary packet (fw >= 1.3 — the only format this app supports; older
  // firmware is rejected on connect). 12-byte header:
  //   [u32 firstSampleIndex][u32 firstSampleMicros][battery][N][u16 batteryMv]
  // then N*12 bytes of int16 LE ax, ay, az, gx, gy, gz (raw sensor counts).
  void _onPacket(List<int> value) {
    const int hdr = 12;
    if (value.length < hdr) return;
    final bd = ByteData.view(Uint8List.fromList(value).buffer);
    final int count = value[9];
    final int battByte = value[8];
    // Bit 7 of the battery byte marks "charging"; while charging the board sends
    // header-only status packets (N = 0, no IMU stream).
    final bool charging = (battByte & 0x80) != 0;
    // Raw cell millivolts -> SoC on a real LiPo curve at sub-1% resolution. An
    // unread mV is 0 (e.g. a packet in the first ~2 s before the board's ADC
    // block runs), which would map to a spurious 0% and get pinned by the
    // never-rise clamp — so fall back to the coarse % byte (firmware seeds it
    // high) whenever the mV field isn't a real reading.
    final int battMv = bd.getUint16(10, Endian.little);
    final double battPct = battMv > 0
        ? _lipoPercentFromMv(battMv)
        : (battByte & 0x7F).toDouble();

    // A charging-status packet always sets the charging bit; streaming packets
    // never carry N == 0, so the charging bit alone selects this branch.
    if (charging) {
      if (!_charging) {
        // Entering the charging state.
        _charging = true;
        _connectionStatus = "Charging";
        _sampleRateStr = "0";
      }
      _updateBattery(battPct, charging: true);
      return; // no IMU samples to process while charging
    }

    // Left the charging state (unplugged mid-connection): resume streaming and
    // re-seed the chip-time base so the gap doesn't skew the timeline/rate.
    if (_charging) {
      _charging = false;
      _connectionStatus = "Streaming Data";
      _haveChipRef = false;
      _windowStart = null;
      _lastChipTsec = 0;
    }

    if (count < 1 || value.length < hdr + count * 12) return;
    _updateBattery(battPct, charging: false);

    final now = DateTime.now();
    _windowStart ??= now;
    _samplesInWindow += count;
    final elapsedMs = now.difference(_windowStart!).inMilliseconds;
    if (elapsedMs >= 1000) {
      _sampleRateStr = (_samplesInWindow * 1000 / elapsedMs).round().toString();
      _samplesInWindow = 0;
      _windowStart = now;
    }

    // Packet time base: the chip's exact timestamps let us rebuild an absolute
    // µs timeline (wrap-safe) and detect dropped samples from a jump in the
    // sample index.
    double baseIndex =
        0; // this packet's first sample index (from session start)
    double dtUs = 1e6 / _odrHz; // µs per sample used to space the timeline
    {
      final int firstIndex = bd.getUint32(0, Endian.little);
      final int firstMicros = bd.getUint32(4, Endian.little);
      if (_haveChipRef) {
        final int dMicros = (firstMicros - _prevChipMicros) & 0xFFFFFFFF;
        _chipBaseUs += dMicros; // absolute µs of this packet's first sample
        final int expected = (_prevChipIndex + _prevChipN) & 0xFFFFFFFF;
        final int dropped = (firstIndex - expected) & 0xFFFFFFFF;
        if (dropped > 0 && dropped < 100000) _dropCount += dropped;
      } else {
        _haveChipRef = true;
        _chipBaseUs = 0;
        _chipFirstIndex = firstIndex;
      }
      _prevChipMicros = firstMicros;
      _prevChipIndex = firstIndex;
      _prevChipN = count;
      final int relFirst = (firstIndex - _chipFirstIndex) & 0xFFFFFFFF;
      baseIndex = relFirst.toDouble();
      // Space samples by index at the chip's LONG-baseline average rate (total
      // µs / total samples), not a per-packet estimate: the per-packet micros
      // stamp jitters, so extrapolating it overshoots the next packet and makes
      // times run backwards. This is monotonic and drop-aware (an index gap
      // becomes a time gap). Fall back to nominal ODR until the baseline is long.
      dtUs = relFirst > 200 ? _chipBaseUs / relFirst : (1e6 / _odrHz);
    }

    // Orientation/velocity fusion feeds only the live Connection-tab readouts,
    // so run its heavy per-sample math (trig + quaternion + matrix) only while
    // that tab is showing. On the Logs/Settings tabs it's skipped, so streaming
    // can't jank log scrolling. Hit detection + capture below always run, so no
    // hits are missed; ω×r has no integration state, so nothing to keep warm.
    final bool liveTab = _tabController.index == 0;

    double ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
    for (int s = 0; s < count; s++) {
      final int b = hdr + s * 12;
      ax = bd.getInt16(b + 0, Endian.little) * _accelScaleG;
      ay = bd.getInt16(b + 2, Endian.little) * _accelScaleG;
      az = bd.getInt16(b + 4, Endian.little) * _accelScaleG;
      gx = bd.getInt16(b + 6, Endian.little) * _gyroScaleDps;
      gy = bd.getInt16(b + 8, Endian.little) * _gyroScaleDps;
      gz = bd.getInt16(b + 10, Endian.little) * _gyroScaleDps;

      // Run the fusion filter at the true per-sample rate (fixed ODR).
      if (liveTab) _motion.update(ax, ay, az, gx, gy, gz);

      double tSec = (baseIndex + s) * dtUs / 1e6;
      if (tSec < _lastChipTsec) tSec = _lastChipTsec; // guarantee monotonic
      _lastChipTsec = tSec;
      final double amag = math.sqrt(ax * ax + ay * ay + az * az);

      // Ball-hit detection runs continuously; a hit both marks the log and (in
      // auto mode) triggers a capture centered on it.
      final bool isHit = _hitDetector.update(tSec, amag);
      if (isHit) _recordHit(tSec);

      if (_autoLoggingEnabled) {
        _processAutoCapture(tSec, baseIndex + s, isHit, ax, ay, az, gx, gy, gz);
      } else if (_isManualLogging) {
        _appendManualSample(tSec, ax, ay, az, gx, gy, gz);
      }
    }

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
    _scanTimeoutTimer?.cancel();
    await _charSubscription?.cancel();
    await _scanResultsSubscription?.cancel();
    await FlutterBluePlus.stopScan(); // stop an in-progress scan, if any
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
    _flushPendingHits(); // cut logs for any auto hits captured so far
    if (_isManualLogging) {
      _isManualLogging = false;
      _finalizeCapture();
    }
  }

  // Resting open-circuit-voltage -> state-of-charge for a single LiPo cell.
  // The mid-SoC region is inherently flat so this is approximate, but far
  // better than a straight 3.2-4.2 V line. Linear-interpolates a standard SoC
  // table by millivolts (charging elevates the reading, load depresses it).
  double _lipoPercentFromMv(int mv) {
    const List<int> mvs = [
      3270, 3610, 3690, 3710, 3730, 3750, 3770, 3790, 3800, 3820, 3840, //
      3850, 3870, 3910, 3950, 3980, 4020, 4080, 4110, 4150, 4200,
    ];
    const List<double> pcts = [
      0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, //
      55, 60, 65, 70, 75, 80, 85, 90, 95, 100,
    ];
    double raw;
    if (mv <= mvs.first) {
      raw = 0;
    } else if (mv >= mvs.last) {
      raw = 100;
    } else {
      raw = 100;
      for (int i = 1; i < mvs.length; i++) {
        if (mv < mvs[i]) {
          final double t = (mv - mvs[i - 1]) / (mvs[i] - mvs[i - 1]);
          raw = pcts[i - 1] + t * (pcts[i] - pcts[i - 1]);
          break;
        }
      }
    }
    // The charger reports "full" (and the board stops charging) at ~92% on the
    // raw curve, so stretch the scale so a full cell reads 100%.
    return (raw * (100.0 / 92.0)).clamp(0.0, 100.0);
  }

  // Smooth the raw battery reading and clamp the shown value so it only ever
  // decreases within a session. Seeds on the first reading, then EMA + a
  // non-increasing gate (no deadband, so it still steps down 1% at a time).
  // While [charging] the gate is lifted so the % can track the real rise.
  void _updateBattery(double raw, {bool charging = false}) {
    final double r = raw.clamp(0.0, 100.0);
    if (_batterySmoothed < 0) {
      _batterySmoothed = r; // first reading seeds the filter
      _batteryShown = r.round();
    } else {
      _batterySmoothed =
          _batteryAlpha * r + (1 - _batteryAlpha) * _batterySmoothed;
      final int cand = _batterySmoothed.round();
      // Normally batteries only discharge, so a bounce-up is noise -> clamp.
      // Charging is the one time a rise is real, so allow it then.
      if (charging || cand < _batteryShown) _batteryShown = cand;
    }
    _batteryPct = _batteryShown.toString();
  }

  void _resetConnectionUi() {
    _scanTimeoutTimer?.cancel();
    if (!mounted) return;
    _prefs?.setInt(_kUseSinceCalKey, _useSinceCal); // flush hits since last save
    setState(() {
      _targetDevice = null;
      _isConnecting = false;
      _connectionStatus = "Disconnected";
      _windowStart = null;
      _samplesInWindow = 0;
      _sampleRateStr = "0";
      _batteryPct = "--";
      _batterySmoothed = -1; // fresh session -> re-seed the smoother
      _batteryShown = -1;
      _charging = false;
      _firmwareVersion = "?";
      _fwOutdated = false;
      _calReminderDue = false;
      _imuData = ["0.00", "0.00", "0.00", "0.00", "0.00", "0.00"];
      _armed = false;
      _pendingHits.clear();
      _isManualLogging = false;
      _streamStopwatch
        ..stop()
        ..reset();
      _ringLen = 0;
      _ringHead = 0;
      _hitDetector.reset();
      _recentHits.clear();
      _motion.reset();
    });
  }

  // Open the full-screen two-step calibration wizard (face-up, then tip-up).
  void _openCalibration() {
    final streaming = _connectionStatus == "Streaming Data";
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            CalibrationWizard(motion: _motion, canCalibrate: streaming),
      ),
    );
  }

  // Called when a "tip up" lever calibration completes: persist the measured
  // sensor->tip direction and recompute open logs at the new ω×r direction.
  void _onLeverCalibrated() {
    final d = _motion.leverDir;
    _leverDir = d;
    _prefs?.setDouble(_kLeverDirXKey, d[0]);
    _prefs?.setDouble(_kLeverDirYKey, d[1]);
    _prefs?.setDouble(_kLeverDirZKey, d[2]);
    // Full calibration just finished (lever is the last step): clear the nudge.
    _useSinceCal = 0;
    _prefs?.setInt(_kUseSinceCalKey, 0);
    _calReminderDue = false;
    _speedCache.clear(); // ω×r direction changed -> recompute
    if (mounted) setState(() {});
  }

  // Called when a live face-up calibration completes: persist the captured face
  // normal (a mounting constant). Existing logs keep the normal they were
  // captured with, so their ⟂/∥ split stays stable across recalibration; only
  // the live readout and future logs use the new normal.
  void _onMotionCalibrated() {
    final n = _motion.faceNormal;
    if (n == null) return;
    _faceNormal = n;
    _prefs?.setDouble(_kFaceNormXKey, n[0]);
    _prefs?.setDouble(_kFaceNormYKey, n[1]);
    _prefs?.setDouble(_kFaceNormZKey, n[2]);
    if (mounted) setState(() {});
  }

  // =========================================================================
  // Auto-capture (motion-triggered logging)
  // =========================================================================
  void _ensureCaptureBuffers() {
    _capT ??= Float64List(kMaxLogSamples);
    _capAxes ??= List.generate(6, (_) => Float32List(kMaxLogSamples));
    _ringT ??= Float64List(_kRingCap);
    _ringIdx ??= Float64List(_kRingCap);
    _ringAxes ??= List.generate(6, (_) => Float32List(_kRingCap));
  }

  // Arm/disarm the hit-capture watcher (only meaningful while streaming).
  void _toggleArmed() {
    setState(() {
      if (_armed) {
        _flushPendingHits(); // cut logs for any hits still pending
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
    double sampleIdx,
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
    _ringIdx![_ringHead] = sampleIdx;
    _ringAxes![0][_ringHead] = ax;
    _ringAxes![1][_ringHead] = ay;
    _ringAxes![2][_ringHead] = az;
    _ringAxes![3][_ringHead] = gx;
    _ringAxes![4][_ringHead] = gy;
    _ringAxes![5][_ringHead] = gz;
    _ringHead = (_ringHead + 1) % _kRingCap;
    if (_ringLen < _kRingCap) _ringLen++;

    if (_armed && isHit) _pendingHits.add(t);

    // Once a hit's after-window has fully streamed in, cut it its own log. Nearby
    // hits' windows overlap and each still gets a log (that duplication is fine).
    while (_pendingHits.isNotEmpty && (t - _pendingHits.first) >= _hitWindowSec) {
      _extractHitLog(_pendingHits.removeAt(0));
      // A new log just landed; refresh so it appears even if the repaint timer is
      // paused (e.g. watching captures roll in on the Logs tab).
      if (mounted) setState(() {});
    }
  }

  // Cut one hit's window [hit ± _hitWindowSec] out of the ring into its own log.
  // Collects whatever samples exist in that span (partial at session start or on
  // teardown) and hands them to _finalizeCapture, which rebases + persists.
  void _extractHitLog(double hitT) {
    final double lo = hitT - _hitWindowSec;
    final double hi = hitT + _hitWindowSec;
    int idx = (_ringHead - _ringLen + _kRingCap) % _kRingCap; // oldest sample
    int n = 0;
    double firstSampleIdx = 0, lastSampleIdx = 0; // chip indices of the window
    for (int k = 0; k < _ringLen; k++) {
      final double ts = _ringT![idx];
      if (ts >= lo && ts <= hi && n < kMaxLogSamples) {
        _capT![n] = ts;
        for (int a = 0; a < 6; a++) {
          _capAxes![a][n] = _ringAxes![a][idx];
        }
        final double sIdx = _ringIdx?[idx] ?? 0;
        if (n == 0) firstSampleIdx = sIdx;
        lastSampleIdx = sIdx;
        n++;
      }
      idx = (idx + 1) % _kRingCap;
    }
    _capCount = n;
    // Drops inside this window = indices that should span it minus samples kept.
    // The ring only holds received samples, so a lost run leaves an index gap.
    final int windowDrops = n > 1
        ? ((lastSampleIdx - firstSampleIdx + 1) - n).round().clamp(0, 1 << 30)
        : 0;
    // Feed it through _finalizeCapture's (_dropCount - _capDropStart) formula.
    _capDropStart = _dropCount - windowDrops;
    _finalizeCapture();
  }

  // Cut logs for every hit still awaiting its window (on disarm / disconnect).
  void _flushPendingHits() {
    while (_pendingHits.isNotEmpty) {
      _extractHitLog(_pendingHits.removeAt(0));
    }
  }

  // Record a detected ball-hit (absolute stream time); keep a bounded history
  // so a capture that reaches back through the ring buffer still sees its hits.
  void _recordHit(double t) {
    _useSinceCal++; // a ball hit jostles the mounting (persisted on next flush)
    _recentHits.add(t);
    while (_recentHits.isNotEmpty && _recentHits.first < t - 13.0) {
      _recentHits.removeAt(0); // ~13 s covers the max capture length
    }
  }

  // Snapshot the captured window into a right-sized SavedLog (times rebased so
  // the log starts at t = 0), keeping it armed for the next swing.
  void _finalizeCapture() {
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
      final int dropped = (_dropCount - _capDropStart).clamp(0, 1 << 30);
      final created = SavedLog(
        ++_logSeq,
        DateTime.now(),
        t,
        axes,
        n,
        t[n - 1],
        hitTimes: hits,
        droppedSamples: dropped,
        // Freeze the mounting normal so this log's ⟂/∥ split never shifts.
        faceNormal: _faceNormal == null ? null : List<double>.of(_faceNormal!),
        // Freeze the lever direction too, so ω×r face/swing speed stays stable.
        leverDir: _leverDir == null ? null : List<double>.of(_leverDir!),
      );
      _logs.insert(0, created);
      _prefs?.setInt(_kLogSeqKey, _logSeq); // remember the last issued number
      _persistLog(created); // survive restarts
      _useSinceCal++; // this swing; the write also flushes hits since last save
      _prefs?.setInt(_kUseSinceCalKey, _useSinceCal);
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
      _manualProgressTimer?.cancel();
      _manualProgressTimer = null;
      _manualLogStart = null;
      if (_isManualLogging) {
        _isManualLogging = false;
        _finalizeCapture();
      }
      _flushPendingHits();
      _armed = false;
      _autoLoggingEnabled = enabled;
    });
    _prefs?.setBool(_kAutoLoggingKey, enabled);
  }

  // 0..1 fraction of the way to the manual auto-stop timeout (for the ring).
  double get _manualProgress {
    final start = _manualLogStart;
    if (start == null || _manualTimeoutSec <= 0) return 0;
    final elapsed = DateTime.now().difference(start).inMicroseconds / 1e6;
    return (elapsed / _manualTimeoutSec).clamp(0.0, 1.0);
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
    _manualLogStart = DateTime.now();
    // Repaint the Stop button often enough that its progress ring sweeps
    // smoothly toward the auto-stop timeout.
    _manualProgressTimer?.cancel();
    _manualProgressTimer = Timer.periodic(const Duration(milliseconds: 33), (
      t,
    ) {
      if (!mounted || !_isManualLogging) {
        t.cancel();
        return;
      }
      setState(() {});
    });
    setState(() {
      _capCount = 0;
      _capDropStart = _dropCount;
      _isManualLogging = true;
    });
  }

  void _stopLogging() {
    _autoStopTimer?.cancel();
    _manualProgressTimer?.cancel();
    _manualProgressTimer = null;
    _manualLogStart = null;
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
    _deleteLogFile(log).then((_) => _refreshLogStorage());
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

  // ---- Multi-select ----
  List<SavedLog> _selectedLogs() =>
      _logs.where((l) => _selectedLogIds.contains(l.id)).toList();

  void _enterSelectMode() => setState(() {
    _selectMode = true;
    _selectedLogIds.clear();
  });

  void _exitSelectMode() => setState(() {
    _selectMode = false;
    _selectedLogIds.clear();
  });

  void _toggleLogSelected(int id) => setState(() {
    if (!_selectedLogIds.remove(id)) _selectedLogIds.add(id);
  });

  // Header "select all" checkbox: checks every log, or clears if all are
  // already checked.
  void _toggleSelectAll() => setState(() {
    if (_selectedLogIds.length >= _logs.length) {
      _selectedLogIds.clear();
    } else {
      _selectedLogIds
        ..clear()
        ..addAll(_logs.map((l) => l.id));
    }
  });

  // Confirm, then permanently delete `logs` (used by both "delete all" and the
  // multi-select delete). Exits select mode afterward.
  Future<void> _confirmAndDeleteLogs(List<SavedLog> logs) async {
    if (logs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("No logs selected")));
      }
      return;
    }
    final n = logs.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Delete $n log${n == 1 ? '' : 's'}?"),
        content: Text(
          "Are you sure you want to delete $n log${n == 1 ? '' : 's'}? "
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
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    for (final log in logs) {
      await _deleteLogFile(log);
    }
    _refreshLogStorage();
    setState(() {
      final ids = logs.map((l) => l.id).toSet();
      _logs.removeWhere((l) => ids.contains(l.id));
      for (final id in ids) {
        _speedCache.remove(id);
      }
      if (_selectedLog != null && ids.contains(_selectedLog!.id)) {
        _selectedLog = null;
      }
      _selectMode = false;
      _selectedLogIds.clear();
      if (_logs.isEmpty) {
        _logSeq = 0; // empty -> next capture restarts at 1
        _prefs?.setInt(_kLogSeqKey, 0);
      }
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
      builder: (ctx) => RenameDialog(initial: log.name, hint: "Log #${log.id}"),
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
    final sb = StringBuffer(
      "$_timeColHeader,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps\n",
    );
    for (int i = 0; i < log.count; i++) {
      sb.write(_fmtTimeValue(log.t[i]));
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

  // Share `logs`: a single CSV when there's one, else all their CSVs bundled
  // into one .zip. Used by "share all" and the multi-select share.
  void _shareLogs(List<SavedLog> logs) async {
    if (logs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("No logs selected")));
      }
      return;
    }
    if (logs.length == 1) {
      _exportLog(logs.first);
      return;
    }
    try {
      final archive = Archive();
      final used = <String>{};
      for (final log in logs) {
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
          subject: 'Paddle logs (${logs.length})',
          text: '${logs.length} paddle IMU logs (one CSV each).',
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

  // Per-sample time (stored in seconds) formatted for display, per settings:
  // microseconds (integer) or milliseconds with 0–3 decimals.
  String _fmtTimeValue(double tSec) => _timeMicros
      ? (tSec * 1e6).round().toString()
      : (tSec * 1000).toStringAsFixed(_timeDecimals);
  String _fmtTimeLabel(double tSec) =>
      _timeMicros ? "${_fmtTimeValue(tSec)} µs" : "${_fmtTimeValue(tSec)} ms";
  String get _timeColHeader => _timeMicros ? "time_us" : "time_ms";
  int get _timeColWidth =>
      _timeMicros ? 9 : (6 + (_timeDecimals > 0 ? _timeDecimals + 1 : 0));

  String _fmtDateTime(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, '0')}-"
      "${d.day.toString().padLeft(2, '0')} ${_fmtTime(d)}";

  String _fmtTime(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';

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

  // Update the logs-list jump buttons: each shows only when the list is scrolled
  // more than `margin` px from that end (so a short, unscrollable list shows
  // neither). Also called after layout so a long list shows "jump to bottom"
  // right away.
  void _onLogsScroll() {
    if (!_logsScroll.hasClients) return;
    const double margin = 200;
    final double max = _logsScroll.position.maxScrollExtent;
    final double off = _logsScroll.offset;
    final bool top = off > margin;
    final bool bottom = (max - off) > margin;
    if ((top != _showLogsTop || bottom != _showLogsBottom) && mounted) {
      setState(() {
        _showLogsTop = top;
        _showLogsBottom = bottom;
      });
    }
  }
}
