import 'dart:math' as math;
import 'dart:typed_data';

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

  // ---- Paddle-face speed from rigid-body rotation:  v = omega x r ----
  // r is the fixed board-frame vector from the sensor to the paddle-face
  // contact point. Because omega (gyro) is a direct measurement and r is
  // constant, this speed has NO integration and therefore NO drift. Direction
  // encodes the mounting (which board axis points handle->tip); magnitude
  // (lever arm, m) is tunable from Settings.
  // Handle axis = board Z (confirmed by a pure handle-twist capture: gz
  // dominated). r points sensor->tip along the handle, so omega x r excludes
  // the twist/spin component and keeps the swing.
  static const List<double> _rDir = [0.0, 0.0, 1.0]; // board +Z -> paddle tip
  double leverArmM = 0.12; // sensor -> face-center distance (m)

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
  double faceSpeed = 0; // |omega x r|, drift-free paddle-face speed (m/s)

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
    roll = pitch = tilt = speed = faceSpeed = 0;
  }

  /// Drift-free paddle-face speed |omega x r| (m/s) from bias-corrected gyro.
  /// Independent of orientation/integration, so it's valid even uncalibrated
  /// (bias is 0 then) and always returns to 0 at rest.
  double _faceSpeed(double gx, double gy, double gz) {
    final double wx = (gx - _bias[0]) * _deg2rad;
    final double wy = (gy - _bias[1]) * _deg2rad;
    final double wz = (gz - _bias[2]) * _deg2rad;
    final double rx = leverArmM * _rDir[0];
    final double ry = leverArmM * _rDir[1];
    final double rz = leverArmM * _rDir[2];
    final double vx = wy * rz - wz * ry;
    final double vy = wz * rx - wx * rz;
    final double vz = wx * ry - wy * rx;
    return math.sqrt(vx * vx + vy * vy + vz * vz);
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
    faceSpeed = _faceSpeed(gx, gy, gz); // drift-free; valid regardless of state
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
    initFromRest(
      _sax * inv,
      _say * inv,
      _saz * inv,
      _sgx * inv,
      _sgy * inv,
      _sgz * inv,
    );
  }

  /// Initialize directly from a known resting sample (mean accel in g, mean
  /// gyro in deg/s). Sets gyro bias and the initial gravity-aligned orientation.
  void initFromRest(
    double ax,
    double ay,
    double az,
    double gx,
    double gy,
    double gz,
  ) {
    _bias[0] = gx;
    _bias[1] = gy;
    _bias[2] = gz;
    double mx = ax, my = ay, mz = az;
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

/// Result of replaying a recorded log through the estimator.
class SpeedSeries {
  final Float32List speed; // accel-integrated |velocity| per sample, m/s (drifts)
  final double maxSpeed;
  final Float32List faceSpeed; // |omega x r| per sample, m/s (drift-free)
  final double maxFaceSpeed;
  const SpeedSeries(
    this.speed,
    this.maxSpeed,
    this.faceSpeed,
    this.maxFaceSpeed,
  );
}

/// Recompute the velocity magnitude over a recorded log from its raw IMU data.
/// `axes` = [ax, ay, az, gx, gy, gz] (g and deg/s). Assumes the log begins with
/// the board roughly at rest (a short initial window seeds bias + gravity).
/// Returns both the accel-integrated speed (drifts) and the omega x r face
/// speed (drift-free); `leverArmM` scales the latter.
SpeedSeries computeSpeedSeries(
  List<Float32List> axes,
  int count, {
  double leverArmM = 0.12,
}) {
  final speed = Float32List(count);
  final faceSpeed = Float32List(count);
  if (count == 0 || axes.length < 6) {
    return SpeedSeries(speed, 0, faceSpeed, 0);
  }

  final m = MotionEstimator();
  m.leverArmM = leverArmM;
  // Seed calibration from a short resting window at the start of the log.
  final int k = math.min(415, math.max(1, count ~/ 4)); // ~0.25 s at 1660 Hz
  double sax = 0, say = 0, saz = 0, sgx = 0, sgy = 0, sgz = 0;
  for (int i = 0; i < k; i++) {
    sax += axes[0][i];
    say += axes[1][i];
    saz += axes[2][i];
    sgx += axes[3][i];
    sgy += axes[4][i];
    sgz += axes[5][i];
  }
  final double inv = 1.0 / k;
  m.initFromRest(
    sax * inv,
    say * inv,
    saz * inv,
    sgx * inv,
    sgy * inv,
    sgz * inv,
  );

  double maxS = 0, maxF = 0;
  for (int i = 0; i < count; i++) {
    m.update(
      axes[0][i],
      axes[1][i],
      axes[2][i],
      axes[3][i],
      axes[4][i],
      axes[5][i],
    );
    speed[i] = m.speed;
    faceSpeed[i] = m.faceSpeed;
    if (m.speed > maxS) maxS = m.speed;
    if (m.faceSpeed > maxF) maxF = m.faceSpeed;
  }
  return SpeedSeries(speed, maxS, faceSpeed, maxF);
}
