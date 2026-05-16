import 'dart:math';

import 'package:flutter/material.dart';

class Virus {
  Virus({
    required this.id,
    required this.position,
    this.velocity = Offset.zero,
    this.mass = 100,
  });

  final String id;
  Offset position;
  Offset velocity;
  double mass;
  int feedCount = 0;
  Offset lastFeedDir = Offset.zero;
  double rotation = 0;

  // RADIUS_FORMULA: radius = sqrt(mass / pi) * 10
  double get radius => sqrt(mass / pi) * 10;
}
