import 'dart:math';

import 'package:flutter/material.dart';

/// Neutral gravitational hazard for [GameMode.blackHole].
///
/// Cells inside `pullRadius` get tugged toward `position`. Cells whose center
/// crosses `dangerRadius` take continuous mass damage. Bots see the same
/// constants and steer away.
class BlackHole {
  BlackHole({
    required this.id,
    required this.position,
    required this.pullRadius,
    required this.dangerRadius,
    this.phase = 0,
  });

  final String id;
  Offset position;
  final double pullRadius;
  final double dangerRadius;
  double phase;

  /// Strength constant used by the engine to scale the inward pull force.
  /// Tuned so it nudges play without instantly trapping cells.
  static const double pullStrength = 380;

  /// Per-second mass drain when a cell is inside [dangerRadius].
  static const double damagePerSecond = 14.0;

  /// Returns a unit-length vector pointing from `from` toward the hole's
  /// center, and the distance. Returns (zero, 0) when at the exact center.
  ({Offset dir, double dist}) pullVector(Offset from) {
    final d = position - from;
    final dist = d.distance;
    if (dist <= 0.001) return (dir: Offset.zero, dist: 0);
    return (dir: d / dist, dist: dist);
  }

  void advance(double dt) {
    phase += dt * 1.3;
    if (phase > pi * 4) phase -= pi * 4;
  }
}
