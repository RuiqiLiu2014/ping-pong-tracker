part of 'main.dart';

// All widget builders for the paddle screen (Connection / Logs / Settings
// tabs, log detail, dialogs). State + logic live in ble_screen_core.dart.
mixin _BleScreenUi on _BleScreenCore {
  // Foreground colour of the top bar for the current theme (drives the tabs).
  Color get _barFg =>
      Theme.of(context).appBarTheme.foregroundColor ?? Colors.white;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Only let the system back button exit the app from the "root" — the
      // Connection tab with no log open. Everything else navigates in-app.
      canPop: _selectedLog == null && _tabController.index == 0 && !_selectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_selectMode) {
          _exitSelectMode(); // leave multi-select first
        } else if (_selectedLog != null) {
          setState(() => _selectedLog = null); // log detail -> list
        } else if (_tabController.index != 0) {
          _tabController.animateTo(0); // other tab -> Connection tab
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ping Pong Tracker'),
          // Colours come from appBarTheme, so the bar follows the chosen theme
          // (bright blue for Blue; adaptive grey for Gray).
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
                    if (_connectionStatus == "Streaming Data" ||
                        _charging ||
                        _notCharging)
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
            labelColor: _barFg,
            indicatorColor: _barFg,
            unselectedLabelColor: _barFg.withAlpha(150),
            tabs: const [
              Tab(icon: Icon(Icons.bluetooth), text: "Connection"),
              Tab(icon: Icon(Icons.show_chart), text: "Logs"),
              Tab(icon: Icon(Icons.settings), text: "Settings"),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildConnectionTab(),
            _buildLogsTab(),
            _buildSettingsTab(),
          ],
        ),
      ),
    );
  }

  // Shown on the Connection tab when the paddle's firmware is older than this
  // app supports. The Logs/Settings tabs stay usable; here only Connect and
  // Disconnect work (Calibrate and the logging controls are disabled).
  Widget _firmwareUpdateBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withAlpha(38),
        border: Border.all(color: Colors.orange, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.system_update, color: Colors.orange),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Firmware update required",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "This paddle is running v$_firmwareVersion, but the app needs "
                  "v$_kReqFwMajor.$_kReqFwMinor or newer. Update the firmware to "
                  "stream data.",
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Compact iPhone-style battery gauge: percentage in front of a small
  // horizontal cell. Fill and text are tinted by level for at-a-glance reading
  // (a darker text shade keeps the number legible over the tab background).
  Widget _batteryIndicator(int pct, {bool charging = false}) {
    final p = pct.clamp(0, 100);
    final Color fill = p <= 20
        ? Colors.red
        : (p <= 50 ? Colors.orange : Colors.green);
    final Color textColor = p <= 20
        ? Colors.red.shade700
        : (p <= 50 ? Colors.orange.shade800 : Colors.green.shade700);
    final Color outline = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "$p%",
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(width: 5),
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 32,
              height: 15,
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                border: Border.all(color: outline, width: 1.2),
                borderRadius: BorderRadius.circular(3),
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
            // Charging bolt, centred over the cell, with a shadow so it reads
            // over both the coloured fill and the empty background.
            if (charging)
              const Icon(
                Icons.bolt,
                size: 13,
                color: Colors.white,
                shadows: [Shadow(color: Colors.black87, blurRadius: 2)],
              ),
          ],
        ),
        // terminal nub
        Container(
          width: 2.5,
          height: 6,
          decoration: BoxDecoration(
            color: outline,
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(2),
              bottomRight: Radius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionTab() {
    final streaming = _connectionStatus == "Streaming Data";
    final charging = _charging;
    final notCharging = _notCharging;
    // Connected (so Connect flips to Disconnect) whenever a BLE link is held —
    // streaming, charging, plugged-but-not-charging, or firmware-too-old.
    final connected = streaming || charging || notCharging || _fwOutdated;
    // Neutral black/white for button text instead of the theme accent colour.
    final btnText = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final m = _motion;
    final String orientationText = m.calibrated
        ? "Roll: ${m.roll.toStringAsFixed(0)}°   Pitch: ${m.pitch.toStringAsFixed(0)}°"
        : (m.calibrating
              ? "Calibrating… forehand face up, hold still "
                    "(${(m.calProgress * 100).toStringAsFixed(0)}%)"
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
              color: (streaming || charging) ? Colors.green : Colors.red,
            ),
          ),
          if (_fwOutdated) _firmwareUpdateBanner(),
          const SizedBox(height: 10),
          Text(
            "Sample Rate: $_sampleRateStr Hz",
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          if (streaming || charging || notCharging) ...[
            const SizedBox(height: 10),
            _batteryIndicator(
              int.tryParse(_batteryPct) ?? 0,
              charging: charging, // bolt only while actually charging
            ),
          ],
          const SizedBox(height: 28),
          const Text(
            "Accelerometer (g)",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            "X: ${_imuData[0]}   Y: ${_imuData[1]}   Z: ${_imuData[2]}",
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 16),
          const Text(
            "Gyroscope (°/s)",
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
          Text(
            orientationText,
            style: TextStyle(
              fontSize: 18,
              // Bright orange when uncalibrated, to nudge calibration.
              color: (!m.calibrated && !m.calibrating) ? Colors.orange : null,
            ),
          ),
          if (m.calibrated)
            Text(
              "Tilt from vertical: ${m.tilt.toStringAsFixed(0)}°",
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
          const SizedBox(height: 16),
          const Text(
            "Paddle rotation",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            streaming ? "${m.faceSpeed.toStringAsFixed(2)} m/s" : "—",
            style: const TextStyle(fontSize: 20),
          ),
          if (streaming && m.hasFaceNormal)
            Text(
              "⟂ ${m.faceSpeedPerp.toStringAsFixed(2)}   "
              "∥ ${m.faceSpeedPar.toStringAsFixed(2)}",
              style: const TextStyle(fontSize: 15, color: Colors.grey),
            ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            // Calibration reads live IMU data, so it's only available while
            // streaming (disabled when disconnected, plugged in, or fw-outdated).
            onPressed: streaming ? _openCalibration : null,
            style: OutlinedButton.styleFrom(foregroundColor: btnText),
            icon: const Icon(Icons.explore),
            label: const Text("Recalibrate"),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _isConnecting || connected
                ? _disconnect
                : _startScanAndConnect,
            style: ElevatedButton.styleFrom(
              foregroundColor: btnText,
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
            ),
            child: Text(
              connected ? "Disconnect" : "Connect to Paddle",
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
      // Arm it, then any swing that crosses the accel threshold is recorded
      // automatically. Only meaningful while streaming.
      return ElevatedButton.icon(
        onPressed: streaming ? _toggleArmed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: _armed ? Colors.red : Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
        ),
        icon: Icon(_armed ? Icons.motion_photos_off : Icons.motion_photos_on),
        label: Text(
          _armed ? "Disarm Auto-Capture" : "Arm Auto-Capture",
          style: const TextStyle(fontSize: 16),
        ),
      );
    }
    // Manual mode: Start/Stop button (auto-stops after the timeout). While
    // logging, the icon is a square stop symbol wrapped in a ring that sweeps
    // around as the auto-stop timeout approaches.
    return ElevatedButton.icon(
      onPressed: streaming
          ? (_isManualLogging ? _stopLogging : _startLogging)
          : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: _isManualLogging ? Colors.red : Colors.green,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
      ),
      icon: _isManualLogging
          ? SizedBox(
              width: 22,
              height: 22,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: _manualProgress,
                    strokeWidth: 2.5,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Colors.white,
                    ),
                    backgroundColor: Colors.white24,
                  ),
                  const Icon(Icons.stop, size: 11, color: Colors.white),
                ],
              ),
            )
          : const Icon(Icons.fiber_manual_record),
      label: Text(
        _isManualLogging ? "Stop Logging" : "Start Logging",
        style: const TextStyle(fontSize: 16),
      ),
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
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: _selectMode
              ? Row(
                  children: [
                    // Select-all checkbox, sitting above the rows' checkboxes.
                    Checkbox(
                      value: _selectedLogIds.isEmpty
                          ? false
                          : (_selectedLogIds.length >= _logs.length
                                ? true
                                : null), // partial -> indeterminate
                      tristate: true,
                      onChanged: (_) => _toggleSelectAll(),
                    ),
                    Text(
                      "${_selectedLogIds.length} log(s) selected",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: "Share selected",
                      icon: const Icon(Icons.share),
                      onPressed: () => _shareLogs(_selectedLogs()),
                    ),
                    IconButton(
                      tooltip: "Delete selected",
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmAndDeleteLogs(_selectedLogs()),
                    ),
                    IconButton(
                      tooltip: "Done",
                      icon: const Icon(Icons.close),
                      onPressed: _exitSelectMode,
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Text(
                        "${_logs.length} log(s)",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _enterSelectMode,
                      icon: const Icon(Icons.checklist),
                      label: const Text("Select"),
                    ),
                  ],
                ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              _buildLogsList(),
              // Floating "jump to top", shown once scrolled down far enough.
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_showLogsTop,
                  child: AnimatedOpacity(
                    opacity: _showLogsTop ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    child: Center(
                      child: _jumpButton(
                        Icons.arrow_upward,
                        "Jump to top",
                        () => _logsScroll.animateTo(
                          0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Floating "jump to bottom", shown until near the end.
              Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  ignoring: !_showLogsBottom,
                  child: AnimatedOpacity(
                    opacity: _showLogsBottom ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    child: Center(
                      child: _jumpButton(
                        Icons.arrow_downward,
                        "Jump to bottom",
                        () => _logsScroll.animateTo(
                          _logsScroll.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Fixed row height lets the list position/recycle rows without measuring each
  // one (itemExtent below), which keeps scrolling smooth with many logs.
  static const double _logRowHeight = 64;

  Widget _buildLogsList() {
    // Recompute jump-button visibility after layout — covers first open,
    // returning from a detail view, and logs being added or removed (none of
    // which fire a scroll event on their own).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onLogsScroll();
    });
    return ListView.builder(
      // PageStorageKey persists the scroll offset when we open a log's detail
      // view and come back, so the list stays where you left it.
      key: const PageStorageKey('logsList'),
      controller: _logsScroll,
      itemCount: _logs.length,
      itemExtent: _logRowHeight,
      itemBuilder: (context, i) => _logRow(_logs[i]),
    );
  }

  // A lightweight log row: cheaper to build than ListTile + a separate Divider
  // child, so long lists fling without jank. The divider is drawn as a bottom
  // border instead of a separate widget.
  Widget _logRow(SavedLog log) {
    final bool selected = _selectedLogIds.contains(log.id);
    final scheme = Theme.of(context).colorScheme;
    // In select mode the leading graph/error icon becomes a checkbox.
    final Widget leading = _selectMode
        ? Icon(
            selected ? Icons.check_box : Icons.check_box_outline_blank,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          )
        : (log.droppedSamples > 0
              ? const Icon(Icons.error, color: Colors.red)
              : Icon(Icons.show_chart, color: scheme.primary));
    return InkWell(
      onTap: () => _selectMode ? _toggleLogSelected(log.id) : _openLog(log),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
          ),
        ),
        child: Row(
          children: [
            leading,
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
                    "#${log.id}  •  ${log.durationSec.toStringAsFixed(1)} s",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!_selectMode) _logActionsMenu(log),
          ],
        ),
      ),
    );
  }

  // Per-log overflow menu: rename / details / export / delete (compact dropdown).
  Widget _logActionsMenu(SavedLog log) {
    return PopupMenuButton<String>(
      tooltip: "Actions",
      onSelected: (v) {
        if (v == 'rename') _renameLog(log);
        if (v == 'details') _showLogDetails(log);
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
          value: 'details',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.info_outline),
            title: Text("Details"),
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

  // Read-only "Details" popup: name + number, plus recording metadata.
  void _showLogDetails(SavedLog log) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(log.displayName, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Text(
              "#${log.id}",
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow("Recorded", _fmtDateTime(log.timestamp)),
            _detailRow("Length", "${log.durationSec.toStringAsFixed(2)} s"),
            _detailRow("Samples", "${log.count}"),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  // Red "dropped N sample(s)" badge for a log that lost BLE data mid-capture.
  Widget _dropBadge(int n) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error, color: Colors.red, size: 18),
          const SizedBox(width: 4),
          Text(
            "dropped $n sample${n == 1 ? '' : 's'}",
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // Open a log's detail view. It always starts at the top: the detail list has
  // a different key from the logs list, so it gets a fresh ScrollPosition rather
  // than inheriting the list's offset. We also measure the charts' height so the
  // jump-to-top button can appear once they've scrolled out of view.

  Widget _jumpToTopButton() => _jumpButton(
    Icons.arrow_upward,
    "Jump to top",
    () => _detailScroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    ),
  );

  // A floating pill button used by the scroll jump-to-top/bottom overlays.
  Widget _jumpButton(IconData icon, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: scheme.onPrimary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
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
        swingHpSec: _swingHpSec,
        // Each log carries its own captured calibration, so its speeds/split
        // stay frozen and never shift when the paddle is recalibrated later.
        faceNormal: log.faceNormal,
        leverDir: log.leverDir,
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
                    "${log.displayName}  •  "
                    "${log.durationSec.toStringAsFixed(1)} s",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              if (log.droppedSamples > 0) _dropBadge(log.droppedSamples),
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
    // Brushing % series = ∥ ÷ total overall paddle speed (translation +
    // rotation), gated to 0 while the paddle is slow so a still paddle reads 0.
    Float32List? spin;
    if (ss.hasComponents) {
      const double gate =
          0.5; // m/s of paddle speed below which brushing % is unreliable
      spin = Float32List(log.count);
      for (int i = 0; i < log.count; i++) {
        final double f = ss.trueFaceSpeed[i];
        spin[i] = f > gate ? 100.0 * math.min(1.0, ss.trueFacePar[i] / f) : 0.0;
      }
    }
    // Hit sample(s) to annotate: the central hit for an auto-capture log, or
    // every hit for a manual log. Corner stats + the timing line read the graph
    // values AT these samples; empty => no corner text and no timing line.
    final List<int> hitIdxs = _hitSampleIdxs(log);
    // Fastest point = sample of peak overall paddle speed, for the timing stat.
    int peakIdx = 0;
    double peakVal = 0;
    for (int i = 0; i < log.count; i++) {
      if (ss.trueFaceSpeed[i] > peakVal) {
        peakVal = ss.trueFaceSpeed[i];
        peakIdx = i;
      }
    }
    // Corner = the graph's value(s) at each hit sample, one line per hit; null
    // (no corner) when the log has no hits.
    String? cornerAt(String Function(int i) fmt) =>
        hitIdxs.isEmpty ? null : hitIdxs.map(fmt).join("\n");

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._hitStatLines(log, ss, hitIdxs, peakIdx),
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
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFE91E63),
                  ),
                ),
              ],
            ),
          ),
        // 1. Overall paddle speed = hand translation + ω×r rotation at the face
        // (headline). Split into closing/brushing once face-up calibrated.
        if (_showFaceSpeed)
          ss.hasComponents
              ? _chartSection(
                  "Overall paddle speed",
                  log,
                  [ss.trueFaceSpeed, ss.trueFacePerp, ss.trueFacePar],
                  const [Colors.indigo, Colors.deepOrange, Colors.teal],
                  const ["total", "⟂", "∥"],
                  forcedMin: 0,
                  minTop: _minScaleMps,
                  cornerText: cornerAt(
                    (i) =>
                        "${ss.trueFaceSpeed[i].toStringAsFixed(1)} · "
                        "⟂ ${ss.trueFacePerp[i].toStringAsFixed(1)} · "
                        "∥ ${ss.trueFacePar[i].toStringAsFixed(1)} m/s",
                  ),
                  unit: "m/s",
                  decimals: 2,
                  info:
                      "Overall speed of the paddle face — your hand's motion "
                      "plus the paddle's rotation, split into perpendicular and "
                      "parallel to the face.",
                )
              : _chartSection(
                  "Overall paddle speed",
                  log,
                  [ss.trueFaceSpeed],
                  const [Colors.indigo],
                  const ["paddle speed"],
                  forcedMin: 0,
                  minTop: _minScaleMps,
                  cornerText: cornerAt(
                    (i) => "${ss.trueFaceSpeed[i].toStringAsFixed(1)} m/s",
                  ),
                  unit: "m/s",
                  decimals: 2,
                  info:
                      "Overall speed of the paddle face — your hand's motion "
                      "plus the paddle's rotation.",
                ),
        // 2. Hand speed = drift-corrected translation + ω×r at the hand lever.
        // Split into closing/brushing once face-up calibrated.
        if (_showSwingSpeed)
          ss.hasComponents
              ? _chartSection(
                  "Hand speed",
                  log,
                  [ss.swingSpeed, ss.swingPerp, ss.swingPar],
                  const [Colors.blue, Colors.deepOrange, Colors.teal],
                  const ["total", "⟂", "∥"],
                  forcedMin: 0,
                  minTop: _minScaleMps,
                  cornerText: cornerAt(
                    (i) =>
                        "${ss.swingSpeed[i].toStringAsFixed(1)} · "
                        "⟂ ${ss.swingPerp[i].toStringAsFixed(1)} · "
                        "∥ ${ss.swingPar[i].toStringAsFixed(1)} m/s",
                  ),
                  unit: "m/s",
                  decimals: 2,
                  info:
                      "Speed of your hand, split into perpendicular and "
                      "parallel to the face.",
                )
              : _chartSection(
                  "Hand speed",
                  log,
                  [ss.swingSpeed],
                  const [Colors.blue],
                  const ["hand speed"],
                  forcedMin: 0,
                  minTop: _minScaleMps,
                  cornerText: cornerAt(
                    (i) => "${ss.swingSpeed[i].toStringAsFixed(1)} m/s",
                  ),
                  unit: "m/s",
                  decimals: 2,
                  info: "Speed of your hand.",
                ),
        // 3. Face rotation (ω×r) — the rotational component, with the
        // closing/brushing split when a face-up calibration exists.
        if (ss.hasComponents) ...[
          if (_showFaceRotation)
            _chartSection(
              "Paddle rotation",
              log,
              [ss.faceSpeed, ss.facePerp, ss.facePar],
              const [Colors.indigo, Colors.deepOrange, Colors.teal],
              const ["total", "⟂", "∥"],
              forcedMin: 0,
              minTop: _minScaleMps,
              cornerText: cornerAt(
                (i) =>
                    "${ss.faceSpeed[i].toStringAsFixed(1)} · "
                    "⟂ ${ss.facePerp[i].toStringAsFixed(1)} · "
                    "∥ ${ss.facePar[i].toStringAsFixed(1)} m/s",
              ),
              unit: "m/s",
              decimals: 2,
              info:
                  "Rotation of the paddle face, split into perpendicular and "
                  "parallel to the face.",
            ),
          // 4. Spin ratio — brushing fraction of that rotation.
          if (_showSpinRatio)
            _chartSection(
              "Brushing %",
              log,
              [spin!],
              const [Colors.purple],
              const ["brushing %"],
              forcedMin: 0,
              forcedMax: 100,
              cornerText: cornerAt((i) => "${spin![i].toStringAsFixed(0)}%"),
              unit: "%",
              decimals: 0,
              info:
                  "Percentage of the paddle's motion that contributes to spin.",
            ),
          // 5. Face angle — paddle-face tilt vs vertical through the swing.
          if (_showFaceAngle)
            _chartSection(
              "Face angle",
              log,
              [ss.faceAngle],
              const [Colors.brown],
              const ["face angle"],
              forcedMin: -90,
              forcedMax: 90,
              cornerText: cornerAt(
                (i) => "${ss.faceAngle[i].toStringAsFixed(0)}°",
              ),
              unit: "°",
              decimals: 0,
              info:
                  "Tilt of the paddle face vs vertical through the swing. "
                  "+ = open / facing up (e.g. a push from below), "
                  "− = closed / facing down (e.g. a drive).",
            ),
        ] else if (_showFaceRotation) ...[
          _chartSection(
            "Paddle rotation",
            log,
            [ss.faceSpeed],
            const [Colors.indigo],
            const ["rotation"],
            forcedMin: 0,
            minTop: _minScaleMps,
            cornerText: cornerAt(
              (i) => "${ss.faceSpeed[i].toStringAsFixed(1)} m/s",
            ),
            unit: "m/s",
            decimals: 2,
            info:
                "Rotation of the paddle face, split into perpendicular and "
                "parallel to the face.",
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              "Calibrate face-up on the Connection tab to split paddle rotation "
              "into closing (⟂ to face) and brushing (∥ to face) components.",
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ],
        // 6. Raw accelerometer (toggle in Settings).
        if (_showAccelGraph)
          _chartSection(
            "Accelerometer (g)",
            log,
            [log.axes[0], log.axes[1], log.axes[2]],
            _accelColors,
            _accelLabels,
            centerZero: true,
            unit: "g",
            decimals: 3,
            info:
                "Raw accelerometer reading along each board axis (g), "
                "before any processing.",
          ),
        // 7. Raw gyroscope (toggle in Settings).
        if (_showGyroGraph)
          _chartSection(
            "Gyroscope (°/s)",
            log,
            [log.axes[3], log.axes[4], log.axes[5]],
            _gyroColors,
            _gyroLabels,
            centerZero: true,
            unit: "°/s",
            decimals: 1,
            info:
                "Raw gyroscope reading about each board axis (°/s), "
                "before any processing.",
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
              fontSize: 9,
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
      TextSpan(
        text: _fmtTimeValue(log.t[i]).padLeft(_timeColWidth),
        // Theme-aware so the time column stays readable in dark mode.
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      for (int c = 1; c < 7; c++)
        TextSpan(
          text: log.axes[c - 1][i]
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
      TextSpan(
        text: _timeColHeader.padLeft(_timeColWidth),
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      for (int c = 1; c < 7; c++)
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
          style: const TextStyle(fontFamily: "monospace", fontSize: 9),
        ),
      ),
    );
  }

  // Sample indices of the hit(s) to annotate: the central hit for an auto-
  // capture log (the trigger, nearest the window's middle), or every hit in
  // time order for a manual log. Empty when the log has no detected hits.
  List<int> _hitSampleIdxs(SavedLog log) {
    if (log.hitTimes.isEmpty || log.count == 0) return const [];
    int nearest(double ht) {
      int hi = 0;
      double best = double.infinity;
      for (int i = 0; i < log.count; i++) {
        final double d = (log.t[i] - ht).abs();
        if (d < best) {
          best = d;
          hi = i;
        }
      }
      return hi;
    }

    if (log.autoCaptured) {
      // Central hit = the one nearest the middle of the window (the trigger).
      final double mid = log.durationSec / 2;
      double best = double.infinity;
      double central = log.hitTimes.first;
      for (final h in log.hitTimes) {
        final double d = (h - mid).abs();
        if (d < best) {
          best = d;
          central = h;
        }
      }
      return [nearest(central)];
    }
    return [for (final h in log.hitTimes) nearest(h)];
  }

  // One line per annotated hit, shown at the top of a log: how the hit compares
  // to the fastest point of the swing (peak overall paddle speed).
  List<Widget> _hitStatLines(
    SavedLog log,
    SpeedSeries ss,
    List<int> hitIdxs,
    int peakIdx,
  ) {
    if (hitIdxs.isEmpty || ss.maxTrueFaceSpeed <= 0) return const [];
    final double peakT = log.t[peakIdx];
    return [
      for (final hi in hitIdxs)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text(
            _hitTimingText(
              log.t[hi],
              ss.trueFaceSpeed[hi],
              ss.maxTrueFaceSpeed,
              peakT,
            ),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
    ];
  }

  // "hit was 90% of peak speed, 18 ms before fastest point".
  String _hitTimingText(
    double hitT,
    double hitSpeed,
    double peakSpeed,
    double peakT,
  ) {
    final int pct = (hitSpeed / peakSpeed * 100).clamp(0.0, 100.0).round();
    final double dtMs = (hitT - peakT) * 1000; // < 0 => hit before the peak
    final int ms = dtMs.abs().round();
    final String rel = ms == 0
        ? "at fastest point"
        : "$ms ms ${dtMs < 0 ? 'before' : 'after'} fastest point";
    return "hit was $pct% of peak speed, $rel";
  }

  Widget _chartSection(
    String title,
    SavedLog log,
    List<Float32List> series,
    List<Color> colors,
    List<String>? labels, {
    double? forcedMin,
    double? forcedMax,
    double? minTop,
    String? cornerText,
    bool centerZero = false,
    String unit = "",
    int decimals = 2,
    String? info,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (info != null) _infoIcon(info),
            ],
          ),
        ),
        SizedBox(
          height: 150,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: InteractiveChart(
              t: log.t,
              series: series,
              count: log.count,
              colors: colors,
              labels: labels,
              unit: unit,
              decimals: decimals,
              forcedMin: forcedMin,
              forcedMax: forcedMax,
              minTop: minTop,
              cornerText: cornerText,
              centerZero: centerZero,
              hitTimes: log.hitTimes,
              persist: _hoverPersists,
              pos: _hoverPos,
              timeLabel: _fmtTimeLabel,
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
          ),
        ),
        if (labels != null) _legend(colors, labels),
      ],
    );
  }

  // Small "ⓘ" next to a graph title. Tapping shows a non-modal speech bubble to
  // the right of the icon (triangle pointing back at it), styled like the graph
  // hover readout; tapping anywhere else dismisses it.
  Widget _infoIcon(String info) {
    return Builder(
      builder: (iconCtx) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleInfoBubble(iconCtx, info),
        child: const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Icon(Icons.info_outline, size: 16, color: Colors.grey),
        ),
      ),
    );
  }

  void _toggleInfoBubble(BuildContext iconCtx, String info) {
    // Re-tapping the icon that opened the bubble closes it.
    final bool sameOwner = identical(_infoBubbleOwner, iconCtx);
    _removeInfoBubble();
    if (sameOwner) return;

    final box = iconCtx.findRenderObject() as RenderBox?;
    final overlayState = Overlay.of(iconCtx);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null || !box.attached) return;
    // Right-centre of the icon, in the overlay's coordinate space.
    final Offset anchor = box.localToGlobal(
      box.size.centerRight(Offset.zero),
      ancestor: overlayBox,
    );
    final Size overlaySize = overlayBox.size;
    final bool dark = Theme.of(iconCtx).brightness == Brightness.dark;
    final Color bg = dark ? const Color(0xF21E1E1E) : const Color(0xF2FFFFFF);
    final Color border = dark ? Colors.white24 : Colors.black26;
    final Color ink = dark ? Colors.white : Colors.black87;
    final double maxW = (overlaySize.width - anchor.dx - 24).clamp(
      120.0,
      280.0,
    );

    _infoBubbleOwner = iconCtx;
    _infoBubble = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Transparent full-screen dismiss layer (no tint -> non-blocking look).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeInfoBubble,
            ),
          ),
          Positioned(
            left: anchor.dx + 2,
            top: anchor.dy,
            child: FractionalTranslation(
              translation: const Offset(
                0,
                -0.5,
              ), // centre the bubble on the icon
              child: Material(
                color: Colors.transparent,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(7, 13),
                      painter: _BubbleArrowPainter(bg, border),
                    ),
                    Transform.translate(
                      offset: const Offset(-1, 0), // tuck under the arrow base
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxW),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                          decoration: BoxDecoration(
                            color: bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: border),
                          ),
                          child: Text(
                            info,
                            style: TextStyle(fontSize: 12, color: ink),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlayState.insert(_infoBubble!);
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

  // A split-circle swatch for one colour theme: left half shows that theme's
  // top-bar colour, right half its accent (sliders/toggles/text), per the
  // current colour-swap arrangement. When both halves are the same shade
  // (all-light / all-dark) the circle looks solid. The selected swatch gets a
  // ring.
  Widget _themeSwatch(AppTheme t) {
    final (bar, accent) = _swapColors(t, colorSwapNotifier.value);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool selected = appThemeNotifier.value == t;
    return GestureDetector(
      onTap: () {
        appThemeNotifier.value = t; // repaints the whole app
        _prefs?.setString(_kAppThemeKey, t.name);
        setState(() {});
      },
      child: Container(
        width: 54,
        height: 54,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 3 : 1.5,
          ),
        ),
        child: ClipOval(
          child: Row(
            children: [
              Expanded(child: Container(color: bar)),
              Expanded(child: Container(color: accent)),
            ],
          ),
        ),
      ),
    );
  }

  // The double-arrow button that cycles the four colour-swap arrangements. All
  // swatches and the live app update together (they read colorSwapNotifier).
  Widget _colorSwapButton() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: _cycleColorSwap,
          icon: const Icon(Icons.autorenew),
          tooltip: "Cycle colour arrangement",
        ),
        const SizedBox(height: 4),
        Text(
          _swapLabel(colorSwapNotifier.value),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  void _cycleColorSwap() {
    final next = ColorSwap
        .values[(colorSwapNotifier.value.index + 1) % ColorSwap.values.length];
    colorSwapNotifier.value = next; // repaints the whole app
    _prefs?.setString(_kColorSwapKey, next.name);
    setState(() {}); // update the swatches + label
  }

  String _swapLabel(ColorSwap s) {
    switch (s) {
      case ColorSwap.normal:
        return "Normal";
      case ColorSwap.reversed:
        return "Swapped";
      case ColorSwap.allLight:
        return "Lighter";
      case ColorSwap.allDark:
        return "Darker";
    }
  }

  // ---- Settings tab ----
  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          "Appearance",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text("System")),
              ButtonSegment(value: ThemeMode.light, label: Text("Light")),
              ButtonSegment(value: ThemeMode.dark, label: Text("Dark")),
            ],
            selected: {themeModeNotifier.value},
            onSelectionChanged: (s) {
              final mode = s.first;
              themeModeNotifier.value = mode; // repaints the whole app
              _prefs?.setString(_kThemeModeKey, mode.name);
              setState(() {}); // update the segmented selection
            },
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          "Theme",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Grid of split-circle swatches, four per row, spread across the
            // width so the swap button sits alongside rather than stranded.
            Expanded(
              child: Column(
                children: [
                  for (int i = 0; i < AppTheme.values.length; i += 4)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final t in AppTheme.values.skip(i).take(4))
                            _themeSwatch(t),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // Cycles the colour arrangement across every theme at once.
            _colorSwapButton(),
          ],
        ),
        const Divider(height: 24),
        // Graphs to display (per-log chart checklist) + min y-axis floor
        ..._graphsToDisplaySettings(),
        const Divider(height: 24),
        // Automatic logging — sits just above its capture-window setting.
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
            "Keep the value readout on the graph after you lift your finger.",
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
          "Where the value box sits when you hover a graph.",
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
        const Divider(height: 24),
        // 8. Hit detection
        ..._hitDetectionSettings(),
        const Divider(height: 24),
        // 9. Swing-speed smoothing (drift removal)
        ..._swingSmoothingSettings(),
        const Divider(height: 24),
        // 10. Storage (always last)
        const Text(
          "Storage",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          "${_logs.length} log${_logs.length == 1 ? '' : 's'} using "
          "${_formatStorage(_logStorageBytes)} of phone storage.",
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    );
  }

  // Human-readable log storage size. Bytes shown in KB below 1 MB, MB above.
  String _formatStorage(int bytes) {
    final double kb = bytes / 1024.0;
    if (kb < 1024) return "${kb.toStringAsFixed(1)} KB";
    return "${(kb / 1024).toStringAsFixed(1)} MB";
  }

  // "Graphs to display" — checklist of which charts each log shows, followed by
  // the single global minimum y-axis floor for the speed graphs.
  List<Widget> _graphsToDisplaySettings() {
    return [
      const Text(
        "Graphs to display",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      _graphToggle(
        "Overall paddle speed",
        _showFaceSpeed,
        _kShowFaceSpeedKey,
        (v) => _showFaceSpeed = v,
      ),
      _graphToggle(
        "Hand speed",
        _showSwingSpeed,
        _kShowSwingSpeedKey,
        (v) => _showSwingSpeed = v,
      ),
      _graphToggle(
        "Paddle rotation",
        _showFaceRotation,
        _kShowFaceRotationKey,
        (v) => _showFaceRotation = v,
      ),
      _graphToggle(
        "Brushing %",
        _showSpinRatio,
        _kShowSpinRatioKey,
        (v) => _showSpinRatio = v,
      ),
      _graphToggle(
        "Face angle",
        _showFaceAngle,
        _kShowFaceAngleKey,
        (v) => _showFaceAngle = v,
      ),
      _graphToggle(
        "Raw acceleration",
        _showAccelGraph,
        _kShowAccelKey,
        (v) => _showAccelGraph = v,
      ),
      _graphToggle(
        "Raw gyroscope",
        _showGyroGraph,
        _kShowGyroKey,
        (v) => _showGyroGraph = v,
      ),
      const SizedBox(height: 12),
      const Text(
        "Minimum graph scale — floors the top of the speed-graph y-axis so a "
        "slow or still paddle can't autoscale up to look fast. 0 = off.",
        style: TextStyle(color: Colors.grey),
      ),
      _settingSlider(
        label: "Minimum y-axis scale",
        value: _minScaleMps,
        min: 0.0,
        max: 20.0,
        divisions: 40, // 0.5 m/s steps
        unit: "m/s",
        decimals: 1,
        onChanged: (v) => setState(() => _minScaleMps = v),
        onChangeEnd: (v) => _prefs?.setDouble(_kMinScaleKey, v),
      ),
    ];
  }

  // One checklist row (leading checkbox + graph name) in "Graphs to display".
  Widget _graphToggle(
    String name,
    bool value,
    String prefKey,
    void Function(bool) apply,
  ) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(name, style: const TextStyle(fontSize: 15)),
      value: value,
      onChanged: (v) {
        final nv = v ?? false;
        setState(() => apply(nv));
        _prefs?.setBool(prefKey, nv);
      },
    );
  }

  // Swing-speed drift-removal (high-pass) window, in plainer language.
  List<Widget> _swingSmoothingSettings() {
    return [
      const Text(
        "Swing-speed smoothing",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "Swing speed comes from integrating acceleration, which slowly drifts. "
        "This window sets how much of that drift is removed: a shorter window "
        "removes more (best for quick, sharp swings), a longer one removes less "
        "(best for slower, smoother swings).",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      _settingSlider(
        label: "Smoothing window",
        value: _swingHpSec,
        min: 0.2,
        max: 0.7,
        divisions: 10, // 0.05 s steps
        unit: "s",
        decimals: 2,
        onChanged: (v) => setState(() => _swingHpSec = v),
        onChangeEnd: (v) {
          _prefs?.setDouble(_kSwingHpKey, v);
          setState(() => _speedCache.clear()); // recompute logs at new window
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
        "Lower threshold catches weaker hits, but risks false triggers. The "
        "cooldown ignores repeat triggers within its window, so one impact's "
        "ring isn't counted as a second hit.",
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
      _settingSlider(
        label: "Hit cooldown",
        value: _hitCooldownMs,
        min: 0,
        max: 500,
        divisions: 50, // 10 ms steps
        unit: "ms",
        decimals: 0,
        onChanged: (v) => setState(() {
          _hitCooldownMs = v;
          _hitDetector.refractory = v / 1000.0;
        }),
        onChangeEnd: (v) => _prefs?.setDouble(_kHitCooldownKey, v),
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
              Text(
                fmt(value),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
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
            Text(
              fmt(min),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            Text(
              fmt(max),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}

// Left-pointing triangle for the graph-info speech bubble: filled to match the
// bubble, with only the two slanted edges stroked (the base meets the bubble).
class _BubbleArrowPainter extends CustomPainter {
  final Color fill;
  final Color border;
  _BubbleArrowPainter(this.fill, this.border);

  @override
  void paint(Canvas canvas, Size size) {
    final tip = Offset(0, size.height / 2);
    final top = Offset(size.width, 0);
    final bot = Offset(size.width, size.height);
    canvas.drawPath(
      Path()
        ..moveTo(top.dx, top.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(bot.dx, bot.dy)
        ..close(),
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(top.dx, top.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(bot.dx, bot.dy),
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _BubbleArrowPainter old) =>
      old.fill != fill || old.border != border;
}
