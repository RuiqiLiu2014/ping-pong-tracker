import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:app/motion_estimator.dart';

const int kOdr = 1660;

// Feed `n` identical samples.
void feed(MotionEstimator m, int n, List<double> a, List<double> g) {
  for (int i = 0; i < n; i++) {
    m.update(a[0], a[1], a[2], g[0], g[1], g[2]);
  }
}

// Run a full calibration (holds still) with the given resting accel/gyro.
void calibrate(MotionEstimator m, List<double> a, List<double> g) {
  m.startCalibration();
  // _calTarget is ~2400; feed generously so calibration completes.
  feed(m, 3000, a, g);
  expect(m.calibrated, isTrue, reason: 'calibration should complete');
}

void main() {
  test('does nothing before calibration', () {
    final m = MotionEstimator();
    m.update(0, 0, 1, 0, 0, 0);
    expect(m.calibrated, isFalse);
    expect(m.speed, 0);
    expect(m.tilt, 0);
  });

  test('flat & still -> ~0 tilt and ~0 speed', () {
    final m = MotionEstimator();
    calibrate(m, [0, 0, 1], [0, 0, 0]);
    feed(m, 2000, [0, 0, 1], [0, 0, 0]);
    expect(m.tilt.abs(), lessThan(1.0));
    expect(m.roll.abs(), lessThan(1.0));
    expect(m.pitch.abs(), lessThan(1.0));
    expect(m.speed, lessThan(0.02));
  });

  test('calibrating tilted -> reports that tilt', () {
    final m = MotionEstimator();
    final double th = 30 * math.pi / 180;
    // resting gravity direction tilted 30 deg from vertical (in x-z plane)
    calibrate(m, [math.sin(th), 0, math.cos(th)], [0, 0, 0]);
    feed(m, 100, [math.sin(th), 0, math.cos(th)], [0, 0, 0]);
    expect((m.tilt - 30).abs(), lessThan(2.0),
        reason: 'tilt should track the ~30 deg resting orientation');
  });

  test('gyro bias is removed -> orientation does not drift', () {
    final m = MotionEstimator();
    // Constant 5 dps bias on x while flat & still.
    calibrate(m, [0, 0, 1], [5, 0, 0]);
    // 3 s of the same biased-but-still data; without bias removal this would
    // integrate to ~15 deg of false tilt.
    feed(m, 3 * kOdr, [0, 0, 1], [5, 0, 0]);
    expect(m.tilt.abs(), lessThan(2.0),
        reason: 'calibrated gyro bias should keep orientation steady');
  });

  test('velocity integrates during acceleration, ZUPT zeroes it at rest', () {
    final m = MotionEstimator();
    calibrate(m, [0, 0, 1], [0, 0, 0]);

    // Accelerate along body/world +X: extra 0.4 g for 0.1 s (still + gravity Z).
    final int burst = (0.1 * kOdr).round();
    feed(m, burst, [0.4, 0, 1], [0, 0, 0]);
    // Expected dv ~ 0.4 * 9.80665 * 0.1 ~= 0.39 m/s (allow for accel gating).
    expect(m.speed, greaterThan(0.15),
        reason: 'speed should build up while accelerating');

    // Now hold still (1 g, no rotation) -> ZUPT should reset velocity.
    feed(m, kOdr, [0, 0, 1], [0, 0, 0]);
    expect(m.speed, lessThan(0.02),
        reason: 'ZUPT should zero velocity once at rest');
  });

  test('reset clears state', () {
    final m = MotionEstimator();
    calibrate(m, [0, 0, 1], [0, 0, 0]);
    feed(m, 100, [0.3, 0, 1], [0, 0, 0]);
    m.reset();
    expect(m.calibrated, isFalse);
    expect(m.speed, 0);
    expect(m.tilt, 0);
  });
}
