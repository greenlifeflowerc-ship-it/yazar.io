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
    bool Function(String otherOwnerId)? isAlly,
    bool canHunt = true,
    double aggression = 1.0,
  }) {
    Cell? biggestThreat;
    double threatDistSq = double.infinity;
    Cell? closestPrey;
    double preyDistSq = double.infinity;

    // Search radius scales mildly with aggression — more aggressive bots scan
    // farther for prey.
    final scanR = 900.0 * (1.0 + (aggression - 1.0) * 0.25);
    final near = cellGrid.queryRadius(center, scanR);
    for (final c in near) {
      if (c.ownerId == ownerId) continue;
      // Teams / role allies: skip for both threat and prey targeting.
      if (isAlly != null && isAlly(c.ownerId)) continue;
      final dsq = (c.position - center).distanceSquared;
      // Bot is more cautious: considers threats farther away.
      if (c.mass > mass * 1.25 && dsq < 750 * 750 && dsq < threatDistSq) { // from 600*600
        biggestThreat = c;
        threatDistSq = dsq;
        // More aggressive bots hunt prey from farther away. canHunt=false
        // (hider role) disables prey targeting entirely.
      } else if (canHunt &&
          mass > c.mass * 1.25 &&
          dsq < (700 * aggression) * (700 * aggression) &&
          dsq < preyDistSq) {
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
      // Increased pellet search radius.
      Pellet? best;
      double bd = double.infinity;
      final pellets = pelletGrid.queryRadius(center, 600); // from 400
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

    // Slightly reduced virus avoidance so they can navigate tighter spaces.
    if (mass > 130 && cellCount < 16) {
      final nv = virusGrid.queryRadius(center, 250); // from 280
      for (final v in nv) {
        final d = center - v.position;
        final mag = d.distance;
        if (mag > 0 && mag < 250) { // from 280
          dir = dir + d / mag * 0.7; // from 0.8
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
    bool Function(String otherOwnerId)? isAlly,
  }) {
    if (cellCount >= 6) return false; // More conservative about over-splitting
    if (mass < 60) return false;      // Lowered mass requirement for splitting

    final myRadius = sqrt(mass / pi) * 10;
    final near = cellGrid.queryRadius(center, 800); // Increased search radius
    for (final c in near) {
      if (c.ownerId == ownerId) continue;
      if (isAlly != null && isAlly(c.ownerId)) continue;
      final dist = (c.position - center).distance;
      // More aggressive split condition: will split for smaller advantages and at greater distances.
      if (mass > c.mass * 1.3 &&
          dist > myRadius * 1.1 &&
          dist < myRadius * 2.8) { // Increased max split distance
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
    bool Function(String otherOwnerId)? isAlly,
  }) {
    if (mass < 140) return false; // only big bots eject

    // Is there a large dangerous enemy nearby that we can't eat?
    bool hasLargeEnemy = false;
    // Increased detection range for large enemies.
    final nearby = cellGrid.queryRadius(center, 600); // from 500
    for (final c in nearby) {
      if (c.ownerId == ownerId) continue;
      if (isAlly != null && isAlly(c.ownerId)) continue;
      if (c.mass > mass * 1.4) {
        hasLargeEnemy = true;
        break;
      }
    }
    if (!hasLargeEnemy) return false;

    // Is there a virus roughly in the aim direction within 450 units?
    final viruses = virusGrid.queryRadius(center, 450); // from 400
    for (final v in viruses) {
      final d = v.position - center;
      final mag = d.distance;
      if (mag < 20) continue;
      final aligned = (d / mag).dx * aimDir.dx + (d / mag).dy * aimDir.dy;
      // Increased alignment tolerance, making it easier to decide to shoot.
      if (aligned > 0.45) return true; // from 0.5
    }
    return false;
  }
}
