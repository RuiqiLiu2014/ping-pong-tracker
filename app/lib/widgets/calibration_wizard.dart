import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../motion_estimator.dart';

/// Full-screen, two-step calibration flow: forehand-face-up (face normal) then
/// paddle-vertical (sensor->tip direction). The centre area is a placeholder
/// for a demonstration video/image to be added later; the bottom holds the
/// Calibrate button and a progress bar.
///
/// It drives the shared [MotionEstimator] directly (start each pose capture and
/// poll its progress); the app's existing onCalibrated / onLeverCalibrated
/// callbacks still fire to persist each result.
class CalibrationWizard extends StatefulWidget {
  final MotionEstimator motion;
  final bool canCalibrate; // false when the paddle isn't streaming
  const CalibrationWizard({
    super.key,
    required this.motion,
    this.canCalibrate = true,
  });

  @override
  State<CalibrationWizard> createState() => _CalibrationWizardState();
}

enum _Step { faceUp, faceUpRunning, lever, leverRunning, done }

class _CalibrationWizardState extends State<CalibrationWizard> {
  _Step _step = _Step.faceUp;
  Timer? _poll;
  bool _closeScheduled = false;

  @override
  void initState() {
    super.initState();
    // Poll the estimator so the progress bar tracks the capture and we can
    // advance when each step finishes (progress is fed by the BLE stream).
    _poll = Timer.periodic(const Duration(milliseconds: 60), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    // If we're leaving mid-capture, don't let it complete in the background.
    if (widget.motion.calibrating || widget.motion.calibratingLever) {
      widget.motion.cancelCalibration();
    }
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    setState(() {
      if (_step == _Step.faceUpRunning && !widget.motion.calibrating) {
        _step = _Step.lever; // face-up finished -> next pose
      } else if (_step == _Step.leverRunning &&
          !widget.motion.calibratingLever) {
        _step = _Step.done;
      }
    });
    if (_step == _Step.done && !_closeScheduled) {
      _closeScheduled = true;
      Timer(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  void _onCalibrate() {
    setState(() {
      if (_step == _Step.faceUp) {
        widget.motion.startCalibration();
        _step = _Step.faceUpRunning;
      } else if (_step == _Step.lever) {
        widget.motion.startLeverCalibration();
        _step = _Step.leverRunning;
      }
    });
  }

  void _close() {
    widget.motion.cancelCalibration();
    Navigator.of(context).maybePop();
  }

  bool get _running =>
      _step == _Step.faceUpRunning || _step == _Step.leverRunning;

  double? get _progress {
    if (_step == _Step.faceUpRunning) return widget.motion.calProgress;
    if (_step == _Step.leverRunning) return widget.motion.leverCalProgress;
    return null;
  }

  String get _centerText {
    switch (_step) {
      case _Step.faceUp:
      case _Step.faceUpRunning:
        return "Place flat on table, forehand face up";
      case _Step.lever:
      case _Step.leverRunning:
        return "Stand paddle vertically";
      case _Step.done:
        return "Done calibrating!";
    }
  }

  int get _stepNumber =>
      (_step == _Step.faceUp || _step == _Step.faceUpRunning) ? 1 : 2;

  // Illustration for the current step (sketch of the required paddle pose).
  String get _stepAsset => _stepNumber == 1
      ? 'assets/calibration_faceup.svg'
      : 'assets/calibration_vertical.svg';

  @override
  Widget build(BuildContext context) {
    final bool done = _step == _Step.done;
    // Neutral black/white for the button text instead of the theme accent.
    final btnText = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: "Close",
                icon: const Icon(Icons.close),
                onPressed: _close,
              ),
            ),
            // Centre stage — a placeholder for the demo video/image to come.
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (done)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Icon(
                            Icons.check_circle,
                            size: 64,
                            color: Colors.green,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: SvgPicture.asset(
                            _stepAsset,
                            height: 230,
                            fit: BoxFit.contain,
                            colorFilter: ColorFilter.mode(
                              Theme.of(context).colorScheme.onSurface,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      Text(
                        _centerText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Bottom controls.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!done)
                    Text(
                      widget.canCalibrate
                          ? "Step $_stepNumber of 2"
                          : "Connect the paddle to calibrate",
                      style: TextStyle(
                        color: widget.canCalibrate
                            ? Colors.grey
                            : Colors.orange,
                      ),
                    ),
                  const SizedBox(height: 10),
                  // Reserve space so the layout doesn't jump when the bar shows.
                  SizedBox(
                    height: 6,
                    child: _running
                        ? LinearProgressIndicator(value: _progress)
                        : null,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: (_running || done || !widget.canCalibrate)
                          ? null
                          : _onCalibrate,
                      style: ElevatedButton.styleFrom(
                        foregroundColor: btnText,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(
                        _running ? "Calibrating…" : "Calibrate",
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
