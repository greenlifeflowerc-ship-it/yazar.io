import 'dart:math';

import 'package:flutter/material.dart';

class Cell {
  Cell({
    required this.id,
    required this.ownerId,
    required this.position,
    required this.mass,
    required this.color,
    required this.name,
    required this.mergeReadyAt,
    this.velocity = Offset.zero,
    this.splitImpulse = Offset.zero,
    this.isFreshSplit = false,
  }) : wobblePhase = Random().nextDouble() * pi * 2;

  final String id;
  final String ownerId;
  Offset position;
  Offset velocity;       // base movement (joystick)
  Offset splitImpulse;   // separate impulse from split, decays per frame
  double mass;
  Color color;
  String name;
  DateTime mergeReadyAt; // set once at creation; flat +30s for splits
  bool isFreshSplit;     // true while inside merge cooldown
  double wobblePhase;
  
  /// Recent eating/impact events that cause a jelly-like "bump" on the border.
  final List<CellBump> bumps = [];

  // RADIUS_FORMULA: radius = sqrt(mass / pi) * 10
  double get radius => sqrt(mass / pi) * 10;
  // SPEED_FORMULA: speed = 2.2 * pow(mass, -0.439) * 50
  double get baseSpeed => 2.2 * pow(mass, -0.439) * 50.0;

  bool canMerge(DateTime now) => !now.isBefore(mergeReadyAt);

  void addBump(double angle, double intensity) {
    // Extremely subtle intensity for a "visual only" hint of impact.
    // Base intensity is reduced significantly, and further scaled by mass.
    final stiffnessScale = pow(100.0 / max(100.0, mass), 0.2).toDouble();
    final scaledIntensity = (intensity * 0.2 * stiffnessScale).clamp(0.0, 0.015);

    if (bumps.length > 4) bumps.removeAt(0);
    bumps.add(CellBump(angle, scaledIntensity));
  }
}

class CellBump {
  CellBump(this.angle, this.magnitude);
  final double angle;
  double magnitude;
}
