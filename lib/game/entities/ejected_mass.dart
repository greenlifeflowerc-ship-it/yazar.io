import 'dart:math';

import 'package:flutter/material.dart';

class EjectedMass {
  EjectedMass({
    required this.ownerId,
    required this.position,
    required this.velocity,
    required this.color,
    this.mass = 13,
  }) : spawnTime = DateTime.now();

  String ownerId;
  Offset position;
  Offset velocity;
  Color color;
  double mass;
  final DateTime spawnTime;

  // RADIUS_FORMULA: radius = sqrt(mass / pi) * 10 → mass=13 ≈ 20.3 units.
  double get radius => sqrt(mass / pi) * 10;
}
