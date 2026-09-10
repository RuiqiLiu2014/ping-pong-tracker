import 'dart:typed_data';

/// One finished logging session, held in memory (right-sized columnar arrays).
class SavedLog {
  final int id;
  final DateTime timestamp;
  final Float64List t; // seconds
  final List<Float32List> axes; // ax, ay, az, gx, gy, gz
  final int count;
  final double durationSec;
  String name; // user label; empty => display falls back to "Log #id"
  final List<double> hitTimes; // detected ball-hit times (s, rebased to log)
  final int droppedSamples; // samples lost to BLE drops during this capture
  // Face normal (board frame) from the calibration active when this log was
  // captured. Kept per-log so the ⟂/∥ split is stable — recalibrating later
  // doesn't rewrite old logs. Null for logs recorded before this was stored.
  final List<double>? faceNormal;
  // Sensor->tip lever direction (board frame) from the calibration active at
  // capture. Frozen alongside faceNormal so ω×r face/swing speed also stays
  // stable across later recalibration. Null for logs recorded before this.
  final List<double>? leverDir;

  SavedLog(
    this.id,
    this.timestamp,
    this.t,
    this.axes,
    this.count,
    this.durationSec, {
    this.name = "",
    this.hitTimes = const [],
    this.droppedSamples = 0,
    this.faceNormal,
    this.leverDir,
  });

  String get displayName => name.isEmpty ? "Log #$id" : name;
}
