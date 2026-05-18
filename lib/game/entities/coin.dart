import 'package:flutter/material.dart';

/// Coin Rush pickup. Behaves like a pellet but is tracked separately so the
/// engine can award per-coin score and so the painter can render it as gold.
class Coin {
  Coin({
    required this.position,
    this.pulsePhase = 0,
  });

  Offset position;
  double pulsePhase;

  static const double radius = 8.0;
  static const double mass = 5.0; // small mass boost when picked up
  static const int scoreValue = 1;
}
