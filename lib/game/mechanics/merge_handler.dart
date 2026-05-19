import 'dart:math';

import 'package:flutter/material.dart';

import '../entities/cell.dart';
import '../game_engine.dart';

/// Same-owner cell behaviour: cohesion (soft magnetic attraction to the
/// player's weighted center), separation (anti-overlap force), attack spread
/// (open a launch lane when aiming), and merging once the cooldown has elapsed.
///
/// This module operates on velocity. The engine integrates velocity into
/// position after [applyForces] has run, so the merge handler should never
/// teleport cells.
class MergeHandler {
  MergeHandler(this.engine);
  final GameEngine engine;

  /// Apply the three force-based behaviours (cohesion, separation, attack
  /// spread). Called BEFORE position integration in the engine update loop.
  void applyForces(
    Player p,
    double dt, {
    required bool attackMode,
    required Offset aimDir,
  }) {
    if (p.isDead || p.cells.length < 2) return;
    final now = DateTime.now();

    _applyCohesion(p, now, dt);
    _applySeparation(p, dt);
    if (attackMode) _applyAttackSpread(p, aimDir, dt);
  }

  /// Perform the merge step + clear stale isFreshSplit flags. Called AFTER
  /// position integration so overlaps reflect the new positions.
  void processMerges(Player p) {
    if (p.isDead || p.cells.isEmpty) return;
    final now = DateTime.now();
    if (p.cells.length >= 2) _mergeOverlapping(p, now);
    _clearStaleFreshSplit(p, now);
  }

  // ------------------------------------------------------------------ cohesion
  void _applyCohesion(Player p, DateTime now, double dt) {
    final center = p.centerOfMass;
    
    // Find the largest cell to determine its influence
    double maxMass = 0;
    for (final c in p.cells) {
      if (c.mass > maxMass) maxMass = c.mass;
    }

    for (final c in p.cells) {
      // Fresh splits still riding their burst impulse don't get magnetised.
      if (c.splitImpulse.distance >= 1) continue;
      
      final dir = center - c.position;
      final dist = dir.distance;
      if (dist == 0) continue;
      final unit = dir / dist;
      
      double cohesionFactor = c.canMerge(now)
          ? 1.0
          : GameConstants.cohesionCooldownFactor;
          
      // Agar.io Mobile logic: Small cells have much weaker cohesion when 
      // the player has large cells, allowing them to "float" further out 
      // for attacking or scouting.
      if (maxMass > 500 && c.mass < maxMass * 0.2) {
        // Reduce cohesion for small satellite cells (down to 30% of normal)
        cohesionFactor *= 0.3;
      }
      
      final accelMag = GameConstants.cohesionStrength *
          min(dist, GameConstants.cohesionMaxDistance) *
          cohesionFactor;
      c.velocity += unit * accelMag * dt;
    }
  }

  // --------------------------------------------------------------- separation
  void _applySeparation(Player p, double dt) {
    final cells = p.cells;
    final now = DateTime.now();
    for (int i = 0; i < cells.length; i++) {
      final a = cells[i];
      for (int j = i + 1; j < cells.length; j++) {
        final b = cells[j];
        
        // Agar.io Logic: If BOTH cells are ready to merge, do NOT apply 
        // separation force. This allows them to overlap and trigger the merge.
        if (a.canMerge(now) && b.canMerge(now)) continue;

        final delta = a.position - b.position;
        final dist = delta.distance;
        final minDist = a.radius + b.radius + GameConstants.minGap;
        if (dist >= minDist) continue;
        if (dist == 0) {
          // Co-located: nudge sideways slightly so next frame can compute a
          // normal. This is the only non-velocity move in the system and only
          // fires when cells perfectly overlap (very rare).
          a.position = a.position + const Offset(0.5, 0);
          continue;
        }
        final overlap = minDist - dist;
        final n = delta / dist;
        final totalMass = a.mass + b.mass;
        // Velocity force — smooth, mass-weighted push.
        final force = n * (overlap * GameConstants.separationStrength);
        a.velocity += force * (b.mass / totalMass) * dt;
        b.velocity -= force * (a.mass / totalMass) * dt;
        // Hard position correction: cells not yet allowed to merge MUST NOT
        // overlap (Agar.io feel). Velocity-only separation can't outrun a
        // fast split impulse in one frame, so we resolve the overlap
        // directly here, mass-weighted so big cells barely move.
        a.position = a.position + n * (overlap * (b.mass / totalMass));
        b.position = b.position - n * (overlap * (a.mass / totalMass));
      }
    }
  }

  // ------------------------------------------------------------ attack spread
  /// Push non-main cells out of the launch lane in front of the largest cell
  /// when the player is aiming/attacking, so projectiles don't spawn inside
  /// the player's own body.
  void _applyAttackSpread(Player p, Offset aimDir, double dt) {
    final amag = aimDir.distance;
    if (amag == 0 || p.cells.length < 2) return;
    final unit = aimDir / amag;
    final perp = Offset(-unit.dy, unit.dx);

    Cell mainCell = p.cells.first;
    for (final c in p.cells) {
      if (c.mass > mainCell.mass) mainCell = c;
    }

    final laneWidth = GameConstants.laneWidthBase +
        mainCell.radius * GameConstants.laneWidthRadiusFactor;
    final laneDepth =
        mainCell.radius * GameConstants.laneForwardDepthFactor;

    for (final c in p.cells) {
      if (identical(c, mainCell)) continue;
      if (c.splitImpulse.distance >= 1) continue;
      final rel = c.position - mainCell.position;
      final forwardDist = rel.dx * unit.dx + rel.dy * unit.dy;
      final sideDist = rel.dx * perp.dx + rel.dy * perp.dy;
      if (forwardDist <= 0 || forwardDist >= laneDepth) continue;
      if (sideDist.abs() >= laneWidth) continue;

      // If the cell sits dead-centre in the lane, deterministically bias one
      // side based on the cell id hash to avoid frame-to-frame jitter.
      final sideSign = sideDist.abs() < 1.0
          ? (c.id.hashCode.isEven ? 1.0 : -1.0)
          : (sideDist >= 0 ? 1.0 : -1.0);
      final sidePush = perp *
          sideSign *
          GameConstants.attackSpreadStrength *
          (laneWidth - sideDist.abs());
      final backPush = -unit * GameConstants.attackSpreadStrength * 0.25;
      c.velocity += (sidePush + backPush) * dt;
    }
  }

  // ------------------------------------------------------------------- merge
  void _mergeOverlapping(Player p, DateTime now) {
    final cells = p.cells;
    for (int i = 0; i < cells.length; i++) {
      for (int j = i + 1; j < cells.length; j++) {
        final a = cells[i];
        final b = cells[j];
        if (!a.canMerge(now) || !b.canMerge(now)) continue;

        final dist = (b.position - a.position).distance;
        final rSum = a.radius + b.radius;
        if (dist >= rSum * GameConstants.mergeDistanceFactor) continue;

        final keeper = a.mass >= b.mass ? a : b;
        final consumed = identical(keeper, a) ? b : a;
        final consumedIndex = identical(keeper, a) ? j : i;

        final totalMass = keeper.mass + consumed.mass;
        keeper.position = Offset(
          (keeper.position.dx * keeper.mass +
                  consumed.position.dx * consumed.mass) /
              totalMass,
          (keeper.position.dy * keeper.mass +
                  consumed.position.dy * consumed.mass) /
              totalMass,
        );
        keeper.velocity = Offset(
          (keeper.velocity.dx * keeper.mass +
                  consumed.velocity.dx * consumed.mass) /
              totalMass,
          (keeper.velocity.dy * keeper.mass +
                  consumed.velocity.dy * consumed.mass) /
              totalMass,
        );
        keeper.mass = totalMass;
        cells.removeAt(consumedIndex);
        return _mergeOverlapping(p, now);
      }
    }
  }

  // -------------------------------------------------------------- stale flag
  void _clearStaleFreshSplit(Player p, DateTime now) {
    for (final c in p.cells) {
      if (c.isFreshSplit && !now.isBefore(c.mergeReadyAt)) {
        c.isFreshSplit = false;
      }
    }
  }
}
