import 'dart:math';

import 'package:flutter/material.dart';

import '../entities/cell.dart';
import '../entities/pellet.dart';
import '../entities/virus.dart';
import '../spatial_grid.dart';

class BotAI {
  BotAI(this.rng);
  final Random rng;

  Offset decide({
    required Offset center,
    required double mass,
    required String ownerId,
    required int cellCount,
    required SpatialGrid<Cell> cellGrid,
    required SpatialGrid<Pellet> pelletGrid,
    required SpatialGrid<Virus> virusGrid,
    required Offset currentDir,
    required double worldSize,
  }) {
    Cell? biggestThreat;
    double threatDistSq = double.infinity;
    Cell? closestPrey;
    double preyDistSq = double.infinity;

    final near = cellGrid.queryRadius(center, 700);
    for (final c in near) {
      if (c.ownerId == ownerId) continue;
      final dsq = (c.position - center).distanceSquared;
      if (c.mass > mass * 1.25 && dsq < 600 * 600 && dsq < threatDistSq) {
        biggestThreat = c;
        threatDistSq = dsq;
      } else if (mass > c.mass * 1.25 && dsq < 500 * 500 && dsq < preyDistSq) {
        closestPrey = c;
        preyDistSq = dsq;
      }
    }

    Offset dir;
    if (biggestThreat != null) {
      final d = center - biggestThreat.position;
      final mag = d.distance;
      dir = mag > 0
          ? d / mag
          : Offset(rng.nextDouble() - 0.5, rng.nextDouble() - 0.5);
    } else if (closestPrey != null) {
      final d = closestPrey.position - center;
      final mag = d.distance;
      dir = mag > 0 ? d / mag : currentDir;
    } else {
      Pellet? best;
      double bd = double.infinity;
      final pellets = pelletGrid.queryRadius(center, 400);
      for (final p in pellets) {
        final dd = (p.position - center).distanceSquared;
        if (dd < bd) {
          best = p;
          bd = dd;
        }
      }
      if (best != null) {
        final d = best.position - center;
        final mag = d.distance;
        dir = mag > 0 ? d / mag : currentDir;
      } else if (currentDir.distance > 0.1) {
        dir = currentDir;
      } else {
        dir = Offset(rng.nextDouble() * 2 - 1, rng.nextDouble() * 2 - 1);
      }
    }

    // Avoid viruses when big and not full of cells
    if (mass > 130 && cellCount < 16) {
      final nv = virusGrid.queryRadius(center, 280);
      for (final v in nv) {
        final d = center - v.position;
        final mag = d.distance;
        if (mag > 0 && mag < 280) {
          dir = dir + d / mag * 0.8;
        }
      }
    }

    // Steer away from world edge
    const edgeMargin = 400.0;
    if (center.dx < edgeMargin) dir = Offset(dir.dx + 0.5, dir.dy);
    if (center.dx > worldSize - edgeMargin) {
      dir = Offset(dir.dx - 0.5, dir.dy);
    }
    if (center.dy < edgeMargin) dir = Offset(dir.dx, dir.dy + 0.5);
    if (center.dy > worldSize - edgeMargin) {
      dir = Offset(dir.dx, dir.dy - 0.5);
    }

    final mag = dir.distance;
    return mag > 0 ? dir / mag : Offset.zero;
  }
}
