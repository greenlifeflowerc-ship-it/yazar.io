import 'dart:math';

import 'package:flutter/material.dart';

import '../entities/cell.dart';
import '../entities/virus.dart';
import '../game_engine.dart';
import '../skin_settings.dart';

class SplitHandler {
  SplitHandler(this.engine, this.rng);
  final GameEngine engine;
  final Random rng;

  /// Player tap split: every cell with mass >= 35 splits, largest first,
  /// until the player hits the 16-cell cap.
  void splitPlayer(Player p, Offset aimDir) {
    if (p.isDead) return;
    final mag = aimDir.distance;
    final unit = mag > 0 ? aimDir / mag : const Offset(1, 0);

    final candidates = List<Cell>.from(p.cells)
      ..sort((a, b) => b.mass.compareTo(a.mass));
    for (final c in candidates) {
      if (p.cells.length >= GameConstants.maxCellsPerPlayer) break;
      if (c.mass < GameConstants.splitMinMass) continue;
      _doSplit(p, c, unit);
    }
  }

  /// Hard-cap any cell at maxCellMass. No auto-split.
  void enforceAutoSplit(Player p) {
    if (p.isDead) return;
    for (final c in p.cells) {
      if (c.mass > GameConstants.maxCellMass) {
        c.mass = GameConstants.maxCellMass;
      }
    }
  }

  /// Virus pop: explode the eater into N fragments.
  /// If total mass > 350, use non-equal pieces: one large, a few medium, many small.
  /// Otherwise, distribute evenly.
  void popVirus(Player p, Cell eater, Virus v) {
    // If already at 16 cells, just absorb the mass.
    // Requirement 1: Do not reset or increase merge cooldown if already at max cells.
    if (p.cells.length >= GameConstants.maxCellsPerPlayer) {
      eater.mass = (eater.mass + GameConstants.virusMass)
          .clamp(0.0, GameConstants.maxCellMass);
      return;
    }

    final available = GameConstants.maxCellsPerPlayer - p.cells.length;
    final totalMass = eater.mass + GameConstants.virusMass;
    
    // Requirement: If mass > 350, explode to the maximum possible number of pieces (up to 16 total).
    final desired = totalMass > 350 ? 16 : (8 + rng.nextInt(5)); 
    final n = min(desired, available + 1).clamp(2, 16);

    final now = DateTime.now();

    List<double> fragmentMasses = [];
    if (totalMass > 350) {
      // Requirement 2: Non-equal pieces for mass > 350.
      // 1 Large (45-55%), 2-3 Medium (8-12% each), rest Small.
      double remainingMass = totalMass;
      
      // The "main" piece
      double mainMass = totalMass * (0.45 + rng.nextDouble() * 0.1);
      fragmentMasses.add(mainMass);
      remainingMass -= mainMass;

      // 2 or 3 medium pieces
      int medCount = 2 + rng.nextInt(2);
      for (int i = 0; i < medCount && fragmentMasses.length < n; i++) {
        double m = totalMass * (0.08 + rng.nextDouble() * 0.04);
        fragmentMasses.add(m);
        remainingMass -= m;
      }

      // Distribute the rest among small pieces
      int smallCount = n - fragmentMasses.length;
      if (smallCount > 0) {
        double mSmall = remainingMass / smallCount;
        for (int i = 0; i < smallCount; i++) {
          fragmentMasses.add(mSmall);
        }
      } else {
        // If no small pieces left to add, put remaining into the main piece
        fragmentMasses[0] += remainingMass;
      }
    } else {
      // Even distribution for smaller explosions
      double pieceMass = totalMass / n;
      for (int i = 0; i < n; i++) fragmentMasses.add(pieceMass);
    }

    // Apply masses to cells
    eater.mass = fragmentMasses[0];
    _setSplitCooldown(eater, now);

    final baseAngle = rng.nextDouble() * pi * 2;
    for (int i = 1; i < fragmentMasses.length; i++) {
      // Spread them in a circle with some noise
      final ang = baseAngle + (i / n) * 2 * pi + (rng.nextDouble() - 0.5) * 0.3;
      final dir = Offset(cos(ang), sin(ang));
      _spawnSplitCell(p, eater, fragmentMasses[i], dir, now: now);
    }
  }

  void _doSplit(Player p, Cell source, Offset dir) {
    final newMass = source.mass / 2;
    final now = DateTime.now();
    source.mass = newMass;
    _setSplitCooldown(source, now);
    _spawnSplitCell(p, source, newMass, dir, now: now);

    // Notify SkinSettings so L2/L3 split effects can fire.
    if (identical(p, engine.humanPlayer)) {
      SkinSettings.instance.onPlayerSplit();
    }
  }

  void _spawnSplitCell(
    Player p,
    Cell source,
    double mass,
    Offset dir, {
    required DateTime now,
  }) {
    final radius = sqrt(mass / pi) * 10;
    final mult = engine.modeConfig.splitCooldownMultiplier.clamp(0.1, 5.0);
    final baseCooldown = GameConstants.mergeCooldownForRadius(radius);
    final cooldown = Duration(
      milliseconds: (baseCooldown.inMilliseconds * mult).round(),
    );
    
    // Scale split impulse by radius so larger cells split further. Tuned for
    // Agar.io mobile feel: at reference radius scale=1.0, at max-mass cell
    // (~268 r) scale~2.77, beyond that grows up to cap 5.0. This lets a big
    // player double/triple-split onto distant targets.
    final radiusScale = pow(source.radius / GameConstants.referenceRadius, 0.5)
        .clamp(1.0, 5.0);
    final impulse = dir * (GameConstants.splitImpulseInitial * radiusScale);

    final cell = Cell(
      id: '${p.id}_sp_${now.microsecondsSinceEpoch}_${rng.nextInt(99999)}',
      ownerId: p.id,
      position: source.position,
      mass: mass,
      color: source.color,
      name: source.name,
      mergeReadyAt: now.add(cooldown),
      isFreshSplit: true,
      splitImpulse: impulse,
    );
    
    p.cells.add(cell);
  }

  void _setSplitCooldown(Cell c, DateTime now) {
    final base = GameConstants.mergeCooldownForRadius(c.radius);
    final mult = engine.modeConfig.splitCooldownMultiplier.clamp(0.1, 5.0);
    c.mergeReadyAt = now.add(Duration(
      milliseconds: (base.inMilliseconds * mult).round(),
    ));
    c.isFreshSplit = true;
  }
}
