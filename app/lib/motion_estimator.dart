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
  // sensor -> paddle-tip direction in the board frame. Defaults to board +Z
  // (empirically ~right: a pure handle twist showed up on gz), but can be
  // measured directly by a "tip up" calibration to correct the mounting tilt.
  List<double> _rDir = [0.0, 0.0, 1.0];
  double leverArmM = 0.185; // sensor -> face-center distance (m), fixed mount

  bool calibrating = false;
  bool calibrated = false;
  bool calibratingLever = false; // "tip up" pose capture in progress

  // Orientation quaternion (body -> world, world +Z = up)
  double _q0 = 1, _q1 = 0, _q2 = 0, _q3 = 0;
  final List<double> _bias = [0, 0, 0]; // gyro bias (deg/s)
  final List<double> _vel = [0, 0, 0]; // world velocity (m/s)
  // Gravity-removed acceleration in the world frame (m/s^2), updated each
  // sample — the raw input to velocity integration, exposed for offline
  // drift-correction experiments.
  final List<double> _linAccWorld = [0, 0, 0];
  List<double> get linAccWorld => _linAccWorld;
  // omega x r (face velocity from rotation) in the board frame and, after
  // rotating by the current orientation, in the world frame — so it can be
  // added to the world-frame translation velocity for a true face speed.
  final List<double> _faceVelBody = [0, 0, 0];
  final List<double> _faceVelWorld = [0, 0, 0];
  List<double> get faceVelWorld => _faceVelWorld;
  int _restCount = 0;

  // Calibration accumulators
  int _calN = 0;
  double _sgx = 0, _sgy = 0, _sgz = 0, _sax = 0, _say = 0, _saz = 0;
  // Lever ("tip up") calibration accumulators — accel only.
  int _levN = 0;
  double _lax = 0, _lay = 0, _laz = 0;
  void Function()? onLeverCalibrated;

  // Outputs for display
  double roll = 0, pitch = 0, tilt = 0, speed = 0;
  double faceSpeed = 0; // |omega x r|, drift-free paddle-face speed (m/s)
  double faceSpeedPerp = 0; // component along the face normal (closing), m/s
  double faceSpeedPar = 0; // component in the face plane (brushing), m/s

  // Unit face normal in the BOARD frame, captured by a face-up calibration
  // (with the face up, gravity points along the face normal). Both omega x r
  // and this vector live in the board frame, so the closing/brushing split is
  // orientation-independent — no world-orientation tracking needed. null until
  // a face-up calibration (or setFaceNormal) provides it.
  List<double>? _faceNormal;

  // Fired once when a live calibration completes, so the app can persist the
  // captured face normal. Not used by replay (computeSpeedSeries).
  void Function()? onCalibrated;

  double get calProgress => calibrating
      ? (_calN / _calTarget).clamp(0.0, 1.0)
      : (calibrated ? 1.0 : 0.0);

  bool get hasFaceNormal => _faceNormal != null;
  List<double>? get faceNormal =>
      _faceNormal == null ? null : List<double>.of(_faceNormal!);

  /// True when the flat ("forehand face up") pose looks right. The board is
  /// mounted flat against the paddle base with its +Z along the handle, so in
  /// the flat pose gravity lies in the face plane and the captured normal should
  /// have almost no Z component. The sensor's in-plane (X/Y) rotation is
  /// arbitrary per mounting, so we can only check that Z is near zero.
  bool get faceNormalValid {
    final n = _faceNormal;
    if (n == null) return false;
    return n[2].abs() < 0.4; // gravity ~perpendicular to board Z when flat
  }

  /// Set the face normal directly (restored from storage, or for log replay).
  void setFaceNormal(double x, double y, double z) {
    final double n = math.sqrt(x * x + y * y + z * z);
    if (n < 1e-6) return;
    _faceNormal = [x / n, y / n, z / n];
  }

  // ---- Lever direction (sensor -> tip), for ω×r ----
  List<double> get leverDir => List<double>.of(_rDir);

  /// Tilt of the calibrated lever direction from the default board +Z, in
  /// degrees — a "how far off is the mounting" readout (0 = perfectly aligned).
  double get leverTiltDeg => math.acos(_rDir[2].clamp(-1.0, 1.0)) * _rad2deg;

  /// True when the vertical ("tip up") pose looks right: the board's Z runs
  /// along the handle, and with the tip up gravity reads ~-Z (measured: Z≈-0.99).
  /// So the lever dir should point mostly along -Z. Catches an upside-down paddle
  /// (gravity would read +Z) and not-actually-vertical poses.
  bool get leverDirValid => _rDir[2] < -0.7;

  /// Set the sensor->tip direction directly (restored from storage or replay).
  void setLeverDir(double x, double y, double z) {
    final double n = math.sqrt(x * x + y * y + z * z);
    if (n < 1e-6) return;
    _rDir = [x / n, y / n, z / n];
  }

  double get leverCalProgress =>
      calibratingLever ? (_levN / _calTarget).clamp(0.0, 1.0) : 0.0;

  /// Begin a "tip up" capture: hold the paddle with the tip pointing straight
  /// up so gravity lies along the handle; the mean accel then IS the sensor->tip
  /// direction in the board frame.
  void startLeverCalibration() {
    calibratingLever = true;
    _levN = 0;
    _lax = _lay = _laz = 0;
  }

  /// Abort any in-progress pose capture (e.g. the calibration wizard closed
  /// before a step finished) so it doesn't silently complete later.
  void cancelCalibration() {
    calibrating = false;
    calibratingLever = false;
  }

  void _finishLeverCalibration() {
    final double inv = 1.0 / _levN;
    setLeverDir(_lax * inv, _lay * inv, _laz * inv);
    calibratingLever = false;
    onLeverCalibrated?.call();
  }

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
    faceSpeedPerp = faceSpeedPar = 0;
    // Keep _faceNormal: it's a mounting constant that survives reconnects.
  }

  /// Drift-free paddle-face speed |omega x r| and its closing/brushing split.
  /// v = omega x r is the tip velocity in the board frame; projecting it onto
  /// the face normal gives the closing (perpendicular-to-face) speed, and the
  /// remainder is the brushing (parallel-to-face) speed — so
  /// faceSpeed^2 = perp^2 + par^2. Uses only the gyro, so it's drift-free and
  /// valid even uncalibrated (bias is 0 then). The split is only produced once a
  /// face normal is available.
  void _updateFaceSpeeds(double gx, double gy, double gz) {
    final double wx = (gx - _bias[0]) * _deg2rad;
    final double wy = (gy - _bias[1]) * _deg2rad;
    final double wz = (gz - _bias[2]) * _deg2rad;
    final double rx = leverArmM * _rDir[0];
    final double ry = leverArmM * _rDir[1];
    final double rz = leverArmM * _rDir[2];
    final double vx = wy * rz - wz * ry;
    final double vy = wz * rx - wx * rz;
    final double vz = wx * ry - wy * rx;
    _faceVelBody[0] = vx;
    _faceVelBody[1] = vy;
    _faceVelBody[2] = vz;
    final double v2 = vx * vx + vy * vy + vz * vz;
    faceSpeed = math.sqrt(v2);
    final n = _faceNormal;
    if (n != null) {
      final double perp = vx * n[0] + vy * n[1] + vz * n[2];
      faceSpeedPerp = perp.abs();
      faceSpeedPar = math.sqrt(math.max(0.0, v2 - perp * perp));
    } else {
      faceSpeedPerp = 0;
      faceSpeedPar = 0;
    }
  }

  void startCalibration() {
    calibrating = true;
    calibrated = false;
    _calN = 0;
    _sgx = _sgy = _sgz = _sax = _say = _saz = 0;
    _vel[0] = _vel[1] = _vel[2] = 0;
  }

  /// ax,ay,az in g; gx,gy,gz in deg/s. Call once per IMU sample.
  void update(
    double ax,
    double ay,
    double az,
    double gx,
    double gy,
    double gz,
  ) {
    _updateFaceSpeeds(gx, gy, gz); // drift-free; valid regardless of state
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
    if (calibratingLever) {
      _lax += ax;
      _lay += ay;
      _laz += az;
      if (++_levN >= _calTarget) _finishLeverCalibration();
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
    final double qn = math.sqrt(_q0 * _q0 + _q1 * _q1 + _q2 * _q2 + _q3 * _q3);
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
    _linAccWorld[0] = fwx;
    _linAccWorld[1] = fwy;
    _linAccWorld[2] = fwz - _g;
    // Rotate omega x r (body frame) into the world frame with the same R.
    _faceVelWorld[0] =
        r00 * _faceVelBody[0] + r01 * _faceVelBody[1] + r02 * _faceVelBody[2];
    _faceVelWorld[1] =
        r10 * _faceVelBody[0] + r11 * _faceVelBody[1] + r12 * _faceVelBody[2];
    _faceVelWorld[2] =
        r20 * _faceVelBody[0] + r21 * _faceVelBody[1] + r22 * _faceVelBody[2];
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
    final double ax = _sax * inv, ay = _say * inv, az = _saz * inv;
    // Face-up pose: gravity points along the paddle-face normal, so the mean
    // accel direction IS the face normal in the board frame.
    setFaceNormal(ax, ay, az);
    initFromRest(ax, ay, az, _sgx * inv, _sgy * inv, _sgz * inv);
    onCalibrated?.call();
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
  final Float32List
  speed; // accel-integrated |velocity| per sample, m/s (raw, drifts)
  final double maxSpeed;
  // Drift-corrected swing speed: the integrated velocity high-passed to strip
  // the slow drift ramp, leaving the transient swing. This is the good one.
  final Float32List swingSpeed;
  final double maxSwingSpeed;
  // True face speed: |v_sensor + omega x r| — swing translation plus rotation.
  final Float32List trueFaceSpeed;
  final double maxTrueFaceSpeed;
  final Float32List faceSpeed; // |omega x r| per sample, m/s (drift-free)
  final double maxFaceSpeed;
  final Float32List facePerp; // closing (perpendicular to face), m/s
  final double maxFacePerp;
  final Float32List facePar; // brushing (parallel to face), m/s
  final double maxFacePar;
  final bool hasComponents; // whether a face normal was supplied to split
  const SpeedSeries(
    this.speed,
    this.maxSpeed,
    this.swingSpeed,
    this.maxSwingSpeed,
    this.trueFaceSpeed,
    this.maxTrueFaceSpeed,
    this.faceSpeed,
    this.maxFaceSpeed,
    this.facePerp,
    this.maxFacePerp,
    this.facePar,
    this.maxFacePar,
    this.hasComponents,
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
  double leverArmM = 0.185,
  double swingHpSec = 0.35,
  List<double>? faceNormal,
  List<double>? leverDir,
}) {
  final speed = Float32List(count);
  final swingSpeed = Float32List(count);
  final trueFaceSpeed = Float32List(count);
  final faceSpeed = Float32List(count);
  final facePerp = Float32List(count);
  final facePar = Float32List(count);
  final bool hasComp = faceNormal != null && faceNormal.length >= 3;
  if (count == 0 || axes.length < 6) {
    return SpeedSeries(
      speed,
      0,
      swingSpeed,
      0,
      trueFaceSpeed,
      0,
      faceSpeed,
      0,
      facePerp,
      0,
      facePar,
      0,
      hasComp,
    );
  }

  final m = MotionEstimator();
  m.leverArmM = leverArmM;
  // Supply the (persisted) mounting normal so the log can be split; the log's
  // own start pose is not face-up, so the normal can't come from the log.
  if (hasComp) m.setFaceNormal(faceNormal[0], faceNormal[1], faceNormal[2]);
  // Supply the (persisted) calibrated sensor->tip direction, if any.
  if (leverDir != null && leverDir.length >= 3) {
    m.setLeverDir(leverDir[0], leverDir[1], leverDir[2]);
  }
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

  // Gravity-removed world acceleration per sample, kept for the swing-speed
  // integration below (the estimator's own `speed` still drifts). Also the
  // world-frame omega x r, added to the swing velocity for a true face speed.
  final lax = Float64List(count);
  final lay = Float64List(count);
  final laz = Float64List(count);
  final fvx = Float64List(count);
  final fvy = Float64List(count);
  final fvz = Float64List(count);

  double maxS = 0, maxF = 0, maxP = 0, maxA = 0;
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
    final la = m.linAccWorld;
    lax[i] = la[0];
    lay[i] = la[1];
    laz[i] = la[2];
    final fv = m.faceVelWorld;
    fvx[i] = fv[0];
    fvy[i] = fv[1];
    fvz[i] = fv[2];
    faceSpeed[i] = m.faceSpeed;
    facePerp[i] = m.faceSpeedPerp;
    facePar[i] = m.faceSpeedPar;
    if (m.speed > maxS) maxS = m.speed;
    if (m.faceSpeed > maxF) maxF = m.faceSpeed;
    if (m.faceSpeedPerp > maxP) maxP = m.faceSpeedPerp;
    if (m.faceSpeedPar > maxA) maxA = m.faceSpeedPar;
  }

  // Swing speed: integrate the world accel to velocity, then remove the slow
  // drift by subtracting a centered moving-average baseline (a high-pass). The
  // drift is near-DC; the swing is a fast transient, so this keeps the swing
  // and discards the ramp. Acausal, but fine — the whole log is in hand.
  const double dt = 1.0 / 1660.0;
  final vx = Float64List(count);
  final vy = Float64List(count);
  final vz = Float64List(count);
  for (int i = 1; i < count; i++) {
    vx[i] = vx[i - 1] + 0.5 * (lax[i] + lax[i - 1]) * dt;
    vy[i] = vy[i - 1] + 0.5 * (lay[i] + lay[i - 1]) * dt;
    vz[i] = vz[i - 1] + 0.5 * (laz[i] + laz[i - 1]) * dt;
  }
  final px = Float64List(count + 1);
  final py = Float64List(count + 1);
  final pz = Float64List(count + 1);
  for (int i = 0; i < count; i++) {
    px[i + 1] = px[i] + vx[i];
    py[i + 1] = py[i] + vy[i];
    pz[i + 1] = pz[i] + vz[i];
  }
  final int hw = (swingHpSec / dt).round().clamp(1, count);
  double maxSw = 0, maxTf = 0;
  for (int i = 0; i < count; i++) {
    final int lo = i - hw < 0 ? 0 : i - hw;
    final int hi = i + hw + 1 > count ? count : i + hw + 1;
    final int cnt = hi - lo;
    final double dvx = vx[i] - (px[hi] - px[lo]) / cnt;
    final double dvy = vy[i] - (py[hi] - py[lo]) / cnt;
    final double dvz = vz[i] - (pz[hi] - pz[lo]) / cnt;
    final double s = math.sqrt(dvx * dvx + dvy * dvy + dvz * dvz);
    swingSpeed[i] = s;
    if (s > maxSw) maxSw = s;
    // True face speed: swing translation + rotation, both in world frame.
    final double tx = dvx + fvx[i];
    final double ty = dvy + fvy[i];
    final double tz = dvz + fvz[i];
    final double tf = math.sqrt(tx * tx + ty * ty + tz * tz);
    trueFaceSpeed[i] = tf;
    if (tf > maxTf) maxTf = tf;
  }

  return SpeedSeries(
    speed,
    maxS,
    swingSpeed,
    maxSw,
    trueFaceSpeed,
    maxTf,
    faceSpeed,
    maxF,
    facePerp,
    maxP,
    facePar,
    maxA,
    hasComp,
  );
}
