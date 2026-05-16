import 'dart:math';

import 'package:flutter/material.dart';

class Pellet {
  Pellet({
    required this.position,
    required this.color,
    this.pulsePhase = 0,
  });

  Offset position;
  Color color;
  double pulsePhase;

  static const double mass = 1;
  // RADIUS_FORMULA at mass=1: sqrt(1/pi) * 10 ≈ 5.64 units.
  static final double radius = sqrt(1 / pi) * 10;
}
