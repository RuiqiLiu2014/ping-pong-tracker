import 'dart:math' as math;

/// Orientation + velocity estimator from a 6-axis IMU (accel + gyro).
///
/// Orientation: a Mahony complementary filter fuses gyro integration (good for
/// fast motion) with the accelerometer as a slow gravity reference. The accel
/// correction is faded out when |accel| departs from 1 g (i.e. the board is
/// accelerating), so the "down" direction stays valid during motion. Heading
/// (yaw about vertical) is NOT observable without a magnetometer, but that is
/// irrelevant for orientation relative to down.
///
/// Velocity: gravity is removed using the orientation and the remaining linear
/// acceleration is integrated. Pure inertial velocity drifts, so a Zero-Velocity
/// Update (ZUPT) resets it to zero whenever the board is briefly at rest, plus a
/// gentle leak bounds residual drift. Good for per-stroke speed, not absolute.
class MotionEstimator {
  static const double _dt = 1.0 / 1660.0; // fixed sensor ODR
  static const double _g = 9.80665; // m/s^2
  static const double _deg2rad = math.pi / 180.0;
  static const double _rad2deg = 180.0 / math.pi;

  // Tuning
  static const double _kp = 1.5; // Mahony proportional gain
  static const int _calTarget = 2400; // ~1.5 s at 1660 Hz
  static const double _restGyroDps = 8.0; // rest if |gyro| below this
  static const double _restAccTol = 0.06; // rest if abs(|a|-1g) below this
  static const int _restNeeded = 160; // ~0.1 s sustained before ZUPT
  static const double _velDecay = 0.9999; // gentle leak (~6 s) to bound drift

  bool calibrating = false;
  bool calibrated = false;

  // Orientation quaternion (body -> world, world +Z = up)
  double _q0 = 1, _q1 = 0, _q2 = 0, _q3 = 0;
  final List<double> _bias = [0, 0, 0]; // gyro bias (deg/s)
  final List<double> _vel = [0, 0, 0]; // world velocity (m/s)
  int _restCount = 0;

  // Calibration accumulators
  int _calN = 0;
  double _sgx = 0, _sgy = 0, _sgz = 0, _sax = 0, _say = 0, _saz = 0;

  // Outputs for display
  double roll = 0, pitch = 0, tilt = 0, speed = 0;

  double get calProgress => calibrating
      ? (_calN / _calTarget).clamp(0.0, 1.0)
      : (calibrated ? 1.0 : 0.0);

  void reset() {
    calibrating = false;
    calibrated = false;
    _q0 = 1;
    _q1 = 0;
    _q2 = 0;
    _q3 = 0;
    _bias[0] = _bias[1] = _bias[2] = 0;
    _vel[0] = _vel[1] = _vel[2] = 0;
    _restCount = 0;
    roll = pitch = tilt = speed = 0;
  }

  void startCalibration() {
    calibrating = true;
    calibrated = false;
    _calN = 0;
    _sgx = _sgy = _sgz = _sax = _say = _saz = 0;
    _vel[0] = _vel[1] = _vel[2] = 0;
  }

  /// ax,ay,az in g; gx,gy,gz in deg/s. Call once per IMU sample.
  void update(double ax, double ay, double az, double gx, double gy, double gz) {
    if (calibrating) {
      _sgx += gx;
      _sgy += gy;
      _sgz += gz;
      _sax += ax;
      _say += ay;
      _saz += az;
      if (++_calN >= _calTarget) _finishCalibration();
      return;
    }
    if (!calibrated) return;

    // ---- Orientation: Mahony complementary filter ----
    double wx = (gx - _bias[0]) * _deg2rad;
    double wy = (gy - _bias[1]) * _deg2rad;
    double wz = (gz - _bias[2]) * _deg2rad;

    final double amag = math.sqrt(ax * ax + ay * ay + az * az);
    if (amag > 1e-6) {
      // Full trust at 1 g, fading to zero by 1.25 g / 0.75 g (dynamic motion).
      final double w = (1.0 - (amag - 1.0).abs() * 4.0).clamp(0.0, 1.0);
      if (w > 0) {
        final double nax = ax / amag, nay = ay / amag, naz = az / amag;
        // estimated "up" in body frame from q
        final double vx = 2 * (_q1 * _q3 - _q0 * _q2);
        final double vy = 2 * (_q0 * _q1 + _q2 * _q3);
        final double vz = _q0 * _q0 - _q1 * _q1 - _q2 * _q2 + _q3 * _q3;
        // error = measured x estimated
        wx += _kp * w * (nay * vz - naz * vy);
        wy += _kp * w * (naz * vx - nax * vz);
        wz += _kp * w * (nax * vy - nay * vx);
      }
    }

    // integrate quaternion: qdot = 0.5 * q (x) (0, w)
    final double dq0 = 0.5 * (-_q1 * wx - _q2 * wy - _q3 * wz);
    final double dq1 = 0.5 * (_q0 * wx + _q2 * wz - _q3 * wy);
    final double dq2 = 0.5 * (_q0 * wy - _q1 * wz + _q3 * wx);
    final double dq3 = 0.5 * (_q0 * wz + _q1 * wy - _q2 * wx);
    _q0 += dq0 * _dt;
    _q1 += dq1 * _dt;
    _q2 += dq2 * _dt;
    _q3 += dq3 * _dt;
    final double qn = math.sqrt(
      _q0 * _q0 + _q1 * _q1 + _q2 * _q2 + _q3 * _q3,
    );
    if (qn > 1e-9) {
      _q0 /= qn;
      _q1 /= qn;
      _q2 /= qn;
      _q3 /= qn;
    }

    // world "up" expressed in body frame
    final double ux = 2 * (_q1 * _q3 - _q0 * _q2);
    final double uy = 2 * (_q0 * _q1 + _q2 * _q3);
    final double uz = _q0 * _q0 - _q1 * _q1 - _q2 * _q2 + _q3 * _q3;
    roll = math.atan2(uy, uz) * _rad2deg;
    pitch = math.atan2(-ux, math.sqrt(uy * uy + uz * uz)) * _rad2deg;
    tilt = math.acos(uz.clamp(-1.0, 1.0)) * _rad2deg;

    // ---- Velocity: rotate specific force to world, remove gravity, integrate ----
    final double fx = ax * _g, fy = ay * _g, fz = az * _g;
    // R(q): body -> world
    final double r00 = _q0 * _q0 + _q1 * _q1 - _q2 * _q2 - _q3 * _q3;
    final double r01 = 2 * (_q1 * _q2 - _q0 * _q3);
    final double r02 = 2 * (_q1 * _q3 + _q0 * _q2);
    final double r10 = 2 * (_q1 * _q2 + _q0 * _q3);
    final double r11 = _q0 * _q0 - _q1 * _q1 + _q2 * _q2 - _q3 * _q3;
    final double r12 = 2 * (_q2 * _q3 - _q0 * _q1);
    final double r20 = 2 * (_q1 * _q3 - _q0 * _q2);
    final double r21 = 2 * (_q2 * _q3 + _q0 * _q1);
    final double r22 = _q0 * _q0 - _q1 * _q1 - _q2 * _q2 + _q3 * _q3;
    final double fwx = r00 * fx + r01 * fy + r02 * fz;
    final double fwy = r10 * fx + r11 * fy + r12 * fz;
    final double fwz = r20 * fx + r21 * fy + r22 * fz;
    // at rest f_world = (0,0,+g); subtract gravity to get linear accel
    _vel[0] += fwx * _dt;
    _vel[1] += fwy * _dt;
    _vel[2] += (fwz - _g) * _dt;

    // ZUPT: zero velocity when momentarily at rest
    final double gmag = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (gmag < _restGyroDps && (amag - 1.0).abs() < _restAccTol) {
      if (++_restCount >= _restNeeded) {
        _vel[0] = 0;
        _vel[1] = 0;
        _vel[2] = 0;
      }
    } else {
      _restCount = 0;
    }

    _vel[0] *= _velDecay;
    _vel[1] *= _velDecay;
    _vel[2] *= _velDecay;
    speed = math.sqrt(
      _vel[0] * _vel[0] + _vel[1] * _vel[1] + _vel[2] * _vel[2],
    );
  }

  void _finishCalibration() {
    final double inv = 1.0 / _calN;
    _bias[0] = _sgx * inv;
    _bias[1] = _sgy * inv;
    _bias[2] = _sgz * inv;
    double mx = _sax * inv, my = _say * inv, mz = _saz * inv;
    final double n = math.sqrt(mx * mx + my * my + mz * mz);
    if (n > 1e-6) {
      mx /= n;
      my /= n;
      mz /= n;
    } else {
      mz = 1;
    }
    // initial q: rotate measured "up" (mx,my,mz) onto world +Z, yaw = 0
    final double dot = mz.clamp(-1.0, 1.0); // u . z
    final double cx = my, cy = -mx; // u x z  (z=(0,0,1))
    final double s = math.sqrt(cx * cx + cy * cy);
    if (s < 1e-6) {
      _q0 = dot > 0 ? 1 : 0;
      _q1 = dot > 0 ? 0 : 1; // 180 deg flip about x if upside down
      _q2 = 0;
      _q3 = 0;
    } else {
      final double h = math.atan2(s, dot) / 2;
      final double sh = math.sin(h);
      _q0 = math.cos(h);
      _q1 = (cx / s) * sh;
      _q2 = (cy / s) * sh;
      _q3 = 0;
    }
    _vel[0] = _vel[1] = _vel[2] = 0;
    _restCount = 0;
    calibrating = false;
    calibrated = true;
  }
}
