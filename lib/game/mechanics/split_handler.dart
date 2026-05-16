import 'dart:math';

import 'package:flutter/material.dart';

import '../entities/cell.dart';
import '../entities/virus.dart';
import '../game_engine.dart';

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

  /// Force-split any cell whose mass exceeds 22,500. Direction is RANDOM
  /// per the spec, NOT joystick direction. If 16 cells are already out,
  /// hard-cap the mass at 22,500.
  void enforceAutoSplit(Player p) {
    if (p.isDead) return;
    for (final c in List<Cell>.from(p.cells)) {
      if (c.mass <= GameConstants.maxCellMass) continue;
      if (p.cells.length >= GameConstants.maxCellsPerPlayer) {
        c.mass = GameConstants.maxCellMass;
        continue;
      }
      final ang = rng.nextDouble() * pi * 2;
      _doSplit(p, c, Offset(cos(ang), sin(ang)));
    }
  }

  /// Virus pop: explode the eater into N fragments (8–12, capped by 16-cell
  /// limit), evenly distributed around 360°. +100 mass distributed across
  /// fragments. If already at 16 cells, no split — just +100 to the eater.
  void popVirus(Player p, Cell eater, Virus v) {
    if (p.cells.length >= GameConstants.maxCellsPerPlayer) {
      eater.mass = (eater.mass + GameConstants.virusMass)
          .clamp(0.0, GameConstants.maxCellMass);
      return;
    }

    final available = GameConstants.maxCellsPerPlayer - p.cells.length;
    final desired = 8 + rng.nextInt(5); // 8..12 inclusive
    final n = min(desired, available + 1).clamp(2, 16);

    final totalMass = eater.mass + GameConstants.virusMass;
    final pieceMass = totalMass / n;
    final now = DateTime.now();

    eater.mass = pieceMass;
    _setSplitCooldown(eater, now);

    final baseAngle = rng.nextDouble() * pi * 2;
    for (int i = 1; i < n; i++) {
      final ang = baseAngle + (i / n) * 2 * pi + (rng.nextDouble() - 0.5) * 0.2;
      final dir = Offset(cos(ang), sin(ang));
      _spawnSplitCell(p, eater, pieceMass, dir, now: now);
    }
  }

  void _doSplit(Player p, Cell source, Offset dir) {
    final newMass = source.mass / 2;
    final now = DateTime.now();
    source.mass = newMass;
    _setSplitCooldown(source, now);
    _spawnSplitCell(p, source, newMass, dir, now: now);
  }

  void _spawnSplitCell(
    Player p,
    Cell source,
    double mass,
    Offset dir, {
    required DateTime now,
  }) {
    final radius = sqrt(mass / pi) * 10;
    final cooldown = GameConstants.mergeCooldownForRadius(radius);
    p.cells.add(Cell(
      id: '${p.id}_sp_${now.microsecondsSinceEpoch}_${rng.nextInt(99999)}',
      ownerId: p.id,
      position: source.position,
      mass: mass,
      color: source.color,
      name: source.name,
      mergeReadyAt: now.add(cooldown),
      isFreshSplit: true,
      splitImpulse: dir * GameConstants.splitImpulseInitial,
    ));
  }

  void _setSplitCooldown(Cell c, DateTime now) {
    c.mergeReadyAt = now.add(GameConstants.mergeCooldownForRadius(c.radius));
    c.isFreshSplit = true;
  }
}
