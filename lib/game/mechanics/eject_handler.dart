import 'dart:math';

import 'package:flutter/material.dart';

import '../entities/cell.dart';
import '../entities/ejected_mass.dart';
import '../entities/virus.dart';
import '../game_engine.dart';
import '../game_settings.dart';

class EjectHandler {
  EjectHandler(this.engine, this.rng);
  final GameEngine engine;
  final Random rng;

  /// Spawn one EjectedMass per eligible cell.
  ///
  /// Launch point is `cell.position + dir * (radius + launchOffset)`, then
  /// nudged forward in 2-unit increments (max 30 iterations) until it's no
  /// longer inside any friendly cell — projectiles never spawn inside the
  /// player's own body.
  void ejectPlayer(Player p, Offset aimDir) {
    if (p.isDead) return;
    final mag = aimDir.distance;
    final unit = mag > 0 ? aimDir / mag : const Offset(1, 0);
    final speedMult = GameSettings.instance.ejectSpeedMultiplier;
    final ejectedRadius = sqrt(GameConstants.ejectMass / pi) * 10;

    for (final c in p.cells) {
      if (c.mass < GameConstants.ejectMinMass) continue;
      c.mass -= GameConstants.ejectCost;
      final launchPoint = _findClearLaunchPoint(
        p,
        sourceCell: c,
        dir: unit,
        ejectedRadius: ejectedRadius,
      );
      engine.ejectedMasses.add(EjectedMass(
        ownerId: p.id,
        position: launchPoint,
        velocity: unit * GameConstants.ejectVelocityInitial * speedMult,
        color: _darken(c.color, 0.10),
      ));
    }
  }

  Offset _findClearLaunchPoint(
    Player p, {
    required Cell sourceCell,
    required Offset dir,
    required double ejectedRadius,
  }) {
    // Launch the ejected mass so its INNER edge sits `launchOffset` units
    // outside the source cell's edge. Without including ejectedRadius here the
    // pellet's centre is at `cellRadius + launchOffset`, which means half of it
    // (radius ~20) spawns inside the cell — invisible behind the cell sprite
    // and instantly self-eaten when its immunity window expires.
    Offset launch = sourceCell.position +
        dir * (sourceCell.radius + ejectedRadius + GameConstants.launchOffset);
    for (int iter = 0; iter < 30; iter++) {
      bool blocked = false;
      for (final other in p.cells) {
        if (identical(other, sourceCell)) continue;
        final d = (launch - other.position).distance;
        if (d <
            other.radius +
                ejectedRadius +
                GameConstants.projectileSpawnClearance) {
          blocked = true;
          break;
        }
      }
      if (!blocked) break;
      launch += dir * 2.0;
    }
    return launch;
  }

  /// Per-frame motion + friction decay. Ejected mass persists forever once it
  /// comes to rest — it never expires, only disappears when eaten or absorbed
  /// by a virus.
  void update(double dt) {
    final fric =
        pow(GameConstants.ejectFrictionPerFrame, dt * 60).toDouble();
    final worldSize = GameConstants.worldSize;
    for (final e in engine.ejectedMasses) {
      if (e.velocity == Offset.zero) continue;
      e.position += e.velocity * dt;
      e.velocity = e.velocity * fric;
      if (e.velocity.distance < 1) e.velocity = Offset.zero;

      final r = e.radius;
      if (e.position.dx < r) {
        e.position = Offset(r, e.position.dy);
        e.velocity = Offset(-e.velocity.dx * 0.5, e.velocity.dy);
      } else if (e.position.dx > worldSize - r) {
        e.position = Offset(worldSize - r, e.position.dy);
        e.velocity = Offset(-e.velocity.dx * 0.5, e.velocity.dy);
      }
      if (e.position.dy < r) {
        e.position = Offset(e.position.dx, r);
        e.velocity = Offset(e.velocity.dx, -e.velocity.dy * 0.5);
      } else if (e.position.dy > worldSize - r) {
        e.position = Offset(e.position.dx, worldSize - r);
        e.velocity = Offset(e.velocity.dx, -e.velocity.dy * 0.5);
      }
    }
  }

  /// Called when an ejected mass collides with a virus.
  ///
  /// Mass-based trigger: every feed grows the virus (so it visibly inflates),
  /// and once it crosses 200 it shoots a new virus opposite the last feed
  /// and resets to base mass. This matches Agar.io mobile: starting at 100,
  /// 7 feeds of mass-13 land it just over 200.
  void handleHitVirus(EjectedMass e, Virus v) {
    v.mass += e.mass;
    v.feedCount++;
    final mag = e.velocity.distance;
    if (mag > 0) v.lastFeedDir = e.velocity / mag;

    if (v.mass >= 200) {
      v.feedCount = 0;
      v.mass = GameConstants.virusMass;
      final dir = v.lastFeedDir == Offset.zero
          ? const Offset(1, 0)
          : -v.lastFeedDir;
      engine.viruses.add(Virus(
        id: 'v_shot_${DateTime.now().microsecondsSinceEpoch}_${rng.nextInt(99999)}',
        position: v.position + dir * (v.radius + 30),
        velocity: dir * GameConstants.virusShotInitial,
      ));
    }
  }

  Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * (1 - amount)).clamp(0.0, 1.0))
        .toColor();
  }
}
