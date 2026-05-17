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

  /// Returns true if this bot should split now toward its current target.
  bool decideSplit({
    required Offset center,
    required double mass,
    required String ownerId,
    required int cellCount,
    required SpatialGrid<Cell> cellGrid,
  }) {
    if (cellCount >= 8) return false; // don't over-split
    if (mass < 70) return false;      // need enough mass to split usefully

    final myRadius = sqrt(mass / pi) * 10;
    final near = cellGrid.queryRadius(center, 700);
    for (final c in near) {
      if (c.ownerId == ownerId) continue;
      final dist = (c.position - center).distance;
      // Prey is edible, in split-reach range (1.1x–2.6x radius), not already inside eating range.
      if (mass > c.mass * 1.35 &&
          dist > myRadius * 1.1 &&
          dist < myRadius * 2.6) {
        return true;
      }
    }
    return false;
  }

  /// Returns true if this bot should eject toward the current aim direction.
  /// Bots eject to feed a nearby virus in order to split a large enemy.
  bool decideEject({
    required Offset center,
    required double mass,
    required String ownerId,
    required SpatialGrid<Cell> cellGrid,
    required SpatialGrid<Virus> virusGrid,
    required Offset aimDir,
  }) {
    if (mass < 140) return false; // only big bots eject

    // Is there a large dangerous enemy nearby that we can't eat?
    bool hasLargeEnemy = false;
    final nearby = cellGrid.queryRadius(center, 500);
    for (final c in nearby) {
      if (c.ownerId == ownerId) continue;
      if (c.mass > mass * 1.4) {
        hasLargeEnemy = true;
        break;
      }
    }
    if (!hasLargeEnemy) return false;

    // Is there a virus roughly in the aim direction within 400 units?
    final viruses = virusGrid.queryRadius(center, 400);
    for (final v in viruses) {
      final d = v.position - center;
      final mag = d.distance;
      if (mag < 20) continue;
      final aligned = (d / mag).dx * aimDir.dx + (d / mag).dy * aimDir.dy;
      if (aligned > 0.5) return true; // virus is roughly in front
    }
    return false;
  }
}
