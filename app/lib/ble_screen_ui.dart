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
          title: const Text('Paddle Prototype Bench'),
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
                    if (_connectionStatus == "Streaming Data" || _charging)
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
    // Connected (so Connect flips to Disconnect) whenever a BLE link is held —
    // streaming, charging, or firmware-too-old-to-stream.
    final connected = streaming || charging || _fwOutdated;
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
          if (streaming || charging) ...[
            const SizedBox(height: 10),
            _batteryIndicator(
              int.tryParse(_batteryPct) ?? 0,
              charging: charging,
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
          if (streaming && m.hasFaceNormal)
            Text(
              "⟂ ${m.faceSpeedPerp.toStringAsFixed(2)}   "
              "∥ ${m.faceSpeedPar.toStringAsFixed(2)}",
              style: const TextStyle(fontSize: 15, color: Colors.grey),
            ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: (charging || _fwOutdated) ? null : _openCalibration,
            icon: const Icon(Icons.explore),
            label: const Text("Calibrate"),
          ),
          if (m.hasFaceNormal && !m.faceNormalValid)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                "Face-up pose looks off — recalibrate with the forehand face "
                "pointing straight up.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ),
          if (streaming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Builder(
                builder: (_) {
                  final d = m.leverDir;
                  return Text(
                    "Lever dir (${d[0].toStringAsFixed(2)}, "
                    "${d[1].toStringAsFixed(2)}, ${d[2].toStringAsFixed(2)})"
                    "  •  ${m.leverTiltDeg.toStringAsFixed(0)}° off board Z",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  );
                },
              ),
            ),
          const SizedBox(height: 18),
          ElevatedButton(
            onPressed: _isConnecting || connected
                ? _disconnect
                : _startScanAndConnect,
            style: ElevatedButton.styleFrom(
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
        // The log's own captured normal keeps its split stable; older logs
        // without one fall back to the current calibration.
        faceNormal: log.faceNormal ?? _faceNormal,
        leverDir: _leverDir,
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
    // Spin index = brushing fraction of the face motion (∥ ÷ total ω×r) as a
    // percentage: how grazing the contact is (0% = flat drive, 100% = pure
    // brush). Gated to 0 while the paddle is slow so a still paddle reads 0.
    Float32List? spin;
    double peakSpin = 0; // spin % at the fastest instant
    double? hitSpin; // spin % at the first ball hit, if the log has one
    if (ss.hasComponents) {
      const double gate =
          0.5; // m/s of face speed below which spin is unreliable
      spin = Float32List(log.count);
      double fastest = 0;
      for (int i = 0; i < log.count; i++) {
        final double f = ss.faceSpeed[i];
        final double s = f > gate
            ? 100.0 * math.min(1.0, ss.facePar[i] / f)
            : 0.0;
        spin[i] = s;
        if (f > fastest) {
          fastest = f;
          peakSpin = s; // spin at the fastest instant = the meaningful one
        }
      }
      if (log.hitTimes.isNotEmpty) {
        // Spin at the sample nearest the first ball hit.
        final double ht = log.hitTimes.first;
        int hi = 0;
        double best = double.infinity;
        for (int i = 0; i < log.count; i++) {
          final double d = (log.t[i] - ht).abs();
          if (d < best) {
            best = d;
            hi = i;
          }
        }
        hitSpin = spin[hi];
      }
    }
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
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFE91E63),
                  ),
                ),
              ],
            ),
          ),
        // 1. True face speed = swing translation + ω×r rotation (headline).
        _chartSection(
          "Face speed",
          log,
          [ss.trueFaceSpeed],
          const [Colors.indigo],
          const ["face speed"],
          forcedMin: 0,
          minTop: _minScaleMps,
          cornerText: "max ${ss.maxTrueFaceSpeed.toStringAsFixed(1)} m/s",
          unit: "m/s",
          decimals: 2,
        ),
        // 2. Swing speed (translation only, drift-corrected accel).
        _chartSection(
          "Swing speed (drift-corrected)",
          log,
          [ss.swingSpeed],
          const [Colors.blue],
          const ["swing speed"],
          forcedMin: 0,
          minTop: _minScaleMps,
          cornerText: "max ${ss.maxSwingSpeed.toStringAsFixed(1)} m/s",
          unit: "m/s",
          decimals: 2,
        ),
        // 3. Face rotation (ω×r) — the rotational component, with the
        // closing/brushing split when a face-up calibration exists.
        if (ss.hasComponents) ...[
          _chartSection(
            "Face rotation (ω×r)",
            log,
            [ss.faceSpeed, ss.facePerp, ss.facePar],
            const [Colors.indigo, Colors.deepOrange, Colors.teal],
            const ["total", "⟂", "∥"],
            forcedMin: 0,
            minTop: _minScaleMps,
            cornerText:
                "max ${ss.maxFaceSpeed.toStringAsFixed(1)} · "
                "⟂ ${ss.maxFacePerp.toStringAsFixed(1)} · "
                "∥ ${ss.maxFacePar.toStringAsFixed(1)} m/s",
            unit: "m/s",
            decimals: 2,
          ),
          // 4. Spin index — brushing fraction of that rotation.
          _chartSection(
            "Spin index (∥ brushing ÷ total)",
            log,
            [spin!],
            const [Colors.purple],
            const ["spin index"],
            forcedMin: 0,
            forcedMax: 100,
            cornerText: hitSpin == null
                ? "at peak ω×r: ${peakSpin.toStringAsFixed(0)}%"
                : "at peak ω×r: ${peakSpin.toStringAsFixed(0)}%\n"
                      "at hit: ${hitSpin.toStringAsFixed(0)}%",
            unit: "%",
            decimals: 0,
          ),
        ] else ...[
          _chartSection(
            "Face rotation (ω×r)",
            log,
            [ss.faceSpeed],
            const [Colors.indigo],
            const ["rotation"],
            forcedMin: 0,
            minTop: _minScaleMps,
            cornerText: "max ${ss.maxFaceSpeed.toStringAsFixed(1)} m/s",
            unit: "m/s",
            decimals: 2,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              "Calibrate face-up on the Connection tab to split face rotation "
              "into closing (⟂ to face) and brushing (∥ to face) components.",
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ],
        // 5. Raw accelerometer (toggle in Settings).
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
          ),
        // 6. Raw gyroscope (toggle in Settings).
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
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Show accelerometer graph",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          subtitle: const Text("The raw accelerometer (g) trace in each log."),
          value: _showAccelGraph,
          onChanged: (v) {
            setState(() => _showAccelGraph = v);
            _prefs?.setBool(_kShowAccelKey, v);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Show gyroscope graph",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          subtitle: const Text("The raw gyroscope (°/s) trace in each log."),
          value: _showGyroGraph,
          onChanged: (v) {
            setState(() => _showGyroGraph = v);
            _prefs?.setBool(_kShowGyroKey, v);
          },
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
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Display time in microseconds",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          value: _timeMicros,
          onChanged: (v) {
            setState(() => _timeMicros = v);
            _prefs?.setBool(_kTimeMicrosKey, v);
          },
        ),
        if (!_timeMicros) ...[
          const SizedBox(height: 8),
          const Text(
            "Millisecond decimals",
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text("0")),
                ButtonSegment(value: 1, label: Text("1")),
                ButtonSegment(value: 2, label: Text("2")),
                ButtonSegment(value: 3, label: Text("3")),
              ],
              selected: {_timeDecimals},
              onSelectionChanged: (s) {
                setState(() => _timeDecimals = s.first);
                _prefs?.setInt(_kTimeDecimalsKey, s.first);
              },
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _paddleSpeedSettings() {
    return [
      const Text(
        "Swing speed",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "Swing speed integrates acceleration and high-passes out the slow drift, "
        "keeping the swing. This window sets the high-pass: shorter reads lower "
        "(sharp strokes), longer reads higher (slower strokes).",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
      _settingSlider(
        label: "Drift-removal window",
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
      const SizedBox(height: 8),
      const Text(
        "Minimum graph scale — floors the top of the speed-graph y-axis so a "
        "slow or still paddle can't autoscale up to look fast. 0 = off.",
        style: TextStyle(color: Colors.grey),
      ),
      const SizedBox(height: 8),
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

  List<Widget> _hitDetectionSettings() {
    return [
      const Text(
        "Hit detection",
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        "Lower threshold catches weaker hits, but risks false triggers.",
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
