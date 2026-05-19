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
  void ejectPlayer(Player p, Offset aimDir, {double? multiplier}) {
    if (p.isDead) return;
    final mag = aimDir.distance;
    final unit = mag > 0 ? aimDir / mag : const Offset(1, 0);
    final speedMult = GameSettings.instance.ejectSpeedMultiplier;
    final ejectedRadius = sqrt(GameConstants.ejectMass / pi) * 10;

    int cellIdx = 0;
    // Macro Logic: If feed speed is very high (> 20), fire multiple pellets
    // per cell in a single call to achieve insane speeds.
    final speed = multiplier ?? GameSettings.instance.feedSpeedMultiplier;
    final burstCount = (speed / 10).floor().clamp(1, 20);

    for (final c in p.cells) {
      if (c.mass < GameConstants.ejectMinMass) continue;
      
      for (int i = 0; i < burstCount; i++) {
        if (c.mass < GameConstants.ejectMinMass) break;
        c.mass -= GameConstants.ejectCost;

        final randomRad = (rng.nextDouble() * 12 - 6) * (pi / 180);
        final speedVar = 0.95 + rng.nextDouble() * 0.1;

        // Direction vector from cell position toward the targetPoint (or aimDir)
        final finalDir = Offset(
          unit.dx * cos(randomRad) - unit.dy * sin(randomRad),
          unit.dx * sin(randomRad) + unit.dy * cos(randomRad),
        );

        final launchPoint = _findClearLaunchPoint(
          p,
          sourceCell: c,
          dir: finalDir,
          ejectedRadius: ejectedRadius,
        );

        final ejectVelocity = finalDir *
              (GameConstants.ejectVelocityInitial * speedMult * speedVar);

        engine.ejectedMasses.add(EjectedMass(
          ownerId: p.id,
          position: launchPoint,
          velocity: ejectVelocity,
          color: _vivid(c.color),
        ));

        // --- Recoil Sticking Physics ---
        // Every eject applies a backward force (recoil) to the cell.
        // Wall-sticking: if the cell is at a boundary and feeding TOWARDS it, 
        // we cancel the recoil component that would push it away from the wall.
        const recoilScale = 0.35; 
        final recoilVelocity = finalDir * (GameConstants.ejectMass / c.mass) * 
                               (GameConstants.ejectVelocityInitial * speedMult) * recoilScale;
        
        final r = c.radius;
        final inset = r * 0.85; 
        final world = GameConstants.worldSize;
        double rx = recoilVelocity.dx;
        double ry = recoilVelocity.dy;

        if ((c.position.dx <= inset && finalDir.dx < -0.2) || (c.position.dx >= world - inset && finalDir.dx > 0.2)) rx = 0;
        if ((c.position.dy <= inset && finalDir.dy < -0.2) || (c.position.dy >= world - inset && finalDir.dy > 0.2)) ry = 0;

        c.velocity -= Offset(rx, ry);
      }
      cellIdx++;
    }
  }

  Color _vivid(Color c) {
    final hsl = HSLColor.fromColor(c);
    // Increase saturation and lightness slightly to make it pop.
    return hsl
        .withSaturation((hsl.saturation * 1.2).clamp(0.0, 1.0))
        .withLightness((hsl.lightness * 1.1).clamp(0.0, 1.0))
        .toColor();
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
    for (int iter = 0; iter < 60; iter++) {
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
      launch += dir * 3.0;
    }
    return launch;
  }

  /// Per-frame motion + friction decay + magnet effect.
  void update(double dt, {Iterable<Offset>? extraAttractors}) {
    final s = GameSettings.instance;
    // Decouple speed and distance:
    // Distance = v0 / (1 - friction).
    // We want Distance to scale by ejectDistanceMultiplier and v0 by ejectSpeedMultiplier.
    // So (1 - friction) = (1 - baseFriction) * speedMult / distMult.
    final baseFric = GameConstants.ejectFrictionPerFrame;
    final speedMult = s.ejectSpeedMultiplier;
    final distMult = s.ejectDistanceMultiplier;

    final derivedFric = (1.0 - (1.0 - baseFric) * speedMult / distMult).clamp(0.01, 0.99);
    final fric = pow(derivedFric, dt * 60).toDouble();

    final worldSize = GameConstants.worldSize;
    for (final e in engine.ejectedMasses) {
      if (e.velocity == Offset.zero) continue;

      // --- Subtle Magnet Effect for Ejected Feed ---
      Offset magnetForce = Offset.zero;
      
      // Attract toward known player cells in the engine.
      for (final p in engine.players) {
        if (p.isDead) continue;
        for (final c in p.cells) {
          final delta = c.position - e.position;
          final d = delta.distance;
          if (d < 150 && d > 10) {
            final strength = (1.0 - d / 150) * 800.0;
            magnetForce += (delta / d) * strength;
          }
        }
      }
      
      // Attract toward extra attractors (e.g. remote players in online mode).
      if (extraAttractors != null) {
        for (final pos in extraAttractors) {
          final delta = pos - e.position;
          final d = delta.distance;
          if (d < 150 && d > 10) {
            final strength = (1.0 - d / 150) * 800.0;
            magnetForce += (delta / d) * strength;
          }
        }
      }

      e.velocity += magnetForce * dt;

      e.position += e.velocity * dt;
      e.velocity = e.velocity * fric;
      if (e.velocity.distance < 1) e.velocity = Offset.zero;

      final r = e.radius;
      if (e.position.dx < r) {
        e.position = Offset(r, e.position.dy);
        e.velocity = Offset(0, e.velocity.dy);
      } else if (e.position.dx > worldSize - r) {
        e.position = Offset(worldSize - r, e.position.dy);
        e.velocity = Offset(0, e.velocity.dy);
      }
      if (e.position.dy < r) {
        e.position = Offset(e.position.dx, r);
        e.velocity = Offset(e.velocity.dx, 0);
      } else if (e.position.dy > worldSize - r) {
        e.position = Offset(e.position.dx, worldSize - r);
        e.velocity = Offset(e.velocity.dx, 0);
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
      // Shoot the new virus IN the direction of the feed, not opposite.
      final dir = v.lastFeedDir == Offset.zero
          ? const Offset(1, 0)
          : v.lastFeedDir;
      engine.viruses.add(Virus(
        id: 'v_shot_${DateTime.now().microsecondsSinceEpoch}_${rng.nextInt(99999)}',
        position: v.position + dir * (v.radius + 30),
        velocity: dir * GameConstants.virusShotInitial,
      ));
    }
  }
}
