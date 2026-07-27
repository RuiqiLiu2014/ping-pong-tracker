import 'dart:math' as math;

/// Real-time ball-hit detector from the accelerometer.
///
/// A ball impact rings the paddle's wood at high frequency (energy spread
/// ~80–830 Hz), while swing/hand motion is low frequency (< ~80 Hz). This runs
/// a causal 2-pole high-pass (subtract a one-pole low-pass, twice) at ~120 Hz
/// to isolate the impact vibration, follows its energy with a short envelope,
/// and fires on the rising edge past a threshold (with hysteresis + a
/// refractory time so one impact = one detection).
///
/// Tuned against hit_data/: fc=120 Hz, tau=6 ms, threshold≈0.5 g gives zero
/// false positives on the no-hit swings and catches every real impact.
class HitDetector {
  static const double _dt = 1.0 / 1660.0; // fixed IMU ODR (matches estimator)
  static const double _fcHp = 120.0; // high-pass corner (Hz)
  static const double _tauEnv = 0.006; // envelope time constant (s)
  static const double _refractory = 0.05; // min spacing between hits (s)
  static const double _hystRatio = 0.4; // re-arm when env falls below thr*ratio

  // Filter coefficients derived from the constants above.
  final double _aLp = 1.0 - math.exp(-2.0 * math.pi * _fcHp * _dt);
  final double _aEnv = 1.0 - math.exp(-_dt / _tauEnv);

  /// Envelope threshold in g. Lower = more sensitive (catches weaker hits).
  double threshold;

  double _lp1 = 0, _lp2 = 0, _env = 0;
  bool _triggered = false;
  bool _seeded = false;
  double _lastHit = -1e9;

  HitDetector({this.threshold = 0.5});

  void reset() {
    _lp1 = 0;
    _lp2 = 0;
    _env = 0;
    _triggered = false;
    _seeded = false;
    _lastHit = -1e9;
  }

  /// Feed one sample: `t` = absolute time (s), `amag` = |accel| in g.
  /// Returns true on the sample where a hit onset is detected.
  bool update(double t, double amag) {
    if (!_seeded) {
      _lp1 = amag; // seed the baseline so there's no startup transient
      _lp2 = 0;
      _seeded = true;
    }
    // 2-pole high-pass: signal minus a one-pole low-pass, applied twice.
    double s = amag;
    _lp1 += _aLp * (s - _lp1);
    s -= _lp1;
    _lp2 += _aLp * (s - _lp2);
    s -= _lp2;
    // Mean-square envelope follower, then RMS.
    _env += _aEnv * (s * s - _env);
    final double rms = math.sqrt(_env);

    bool hit = false;
    if (!_triggered) {
      if (rms >= threshold && (t - _lastHit) > _refractory) {
        hit = true;
        _lastHit = t;
        _triggered = true;
      }
    } else if (rms < threshold * _hystRatio) {
      _triggered = false; // re-arm once the ring has decayed
    }
    return hit;
  }
}
