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

  // RADIUS_FORMULA: radius = sqrt(mass / pi) * 10
  double get radius => sqrt(mass / pi) * 10;
  // SPEED_FORMULA: speed = 2.2 * pow(mass, -0.439) * 50
  double get baseSpeed => 2.2 * pow(mass, -0.439) * 50.0;

  bool canMerge(DateTime now) => !now.isBefore(mergeReadyAt);
}
