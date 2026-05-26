/// Local-player physics simulator for Online Classic V2.
///
/// Wraps a bare-bones [GameEngine] instance so we can reuse the offline
/// [SplitHandler] / [EjectHandler] / [MergeHandler] verbatim. The engine's
/// own `update()` is NOT called — it would spawn 8000 local pellets, 70 bots
/// and run a full classic simulation against ghosts. Instead we drive a
/// trimmed step that mirrors the relevant pieces of [GameEngine.update]:
/// input force → cohesion/separation/spread → integrate → eject update →
/// process merges → enforce auto-split cap.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/entities/cell.dart';
import '../game/entities/ejected_mass.dart';
import '../game/game_engine.dart';
import '../game/game_mode_type.dart';
import '../game/mechanics/eject_handler.dart';
import '../game/mechanics/merge_handler.dart';
import '../game/mechanics/split_handler.dart';
import 'v2_world.dart';

/// Public surface the controller uses. All physics goes through this class so
/// the controller doesn't have to know about [GameEngine] internals.
class V2LocalSim {
  V2LocalSim() {
    engine.mode = GameMode.classic;
    engine.modeConfig = ModeConfig.forMode(GameMode.classic);
  }

  final GameEngine engine = GameEngine();
  final math.Random _rng = math.Random();

  late final SplitHandler _split = SplitHandler(engine, _rng);
  /// Public access for virus-pop prediction in the controller — avoids
  /// constructing a throwaway SplitHandler (and a fresh Random) on every pop.
  SplitHandler get splitHandler => _split;
  late final EjectHandler _eject = EjectHandler(engine, _rng);
  late final MergeHandler _merge = MergeHandler(engine);

  bool _initialized = false;
  bool get isInitialized => _initialized;

  // All getters that touch `engine.humanPlayer` MUST be safe to call before
  // [spawn] runs — the screen's ticker starts firing immediately on mount
  // and the welcome packet only arrives one network round-trip later.
  Player get player => engine.humanPlayer;
  List<Cell> get cells => _initialized ? engine.humanPlayer.cells : const [];
  List<EjectedMass> get localEjected => engine.ejectedMasses;

  Offset moveDir = Offset.zero;
  Offset lastNonZeroDir = const Offset(1, 0);
  bool attackMode = false;

  /// Spawn the local human with the given identity at a given world position.
  void spawn({
    required String playerId,
    required String name,
    required Color color,
    required Offset position,
    required double mass,
    ui.Image? skinImage,
  }) {
    final p = Player(
      id: playerId,
      name: name.trim().isEmpty ? 'Player' : name,
      color: color,
      isHuman: true,
    )..skinImage = skinImage;
    engine.players.clear();
    engine.players.add(p);
    engine.humanPlayer = p;
    engine.ejectedMasses.clear();
    engine.elapsed = 0;
    engine.moveDir = Offset.zero;
    engine.lastNonZeroDir = const Offset(1, 0);
    p.cells.add(Cell(
      id: '${playerId}_c0_${DateTime.now().microsecondsSinceEpoch}',
      ownerId: playerId,
      position: position,
      mass: mass,
      color: color,
      name: p.name,
      mergeReadyAt: DateTime.now(),
      isFreshSplit: false,
    ));
    p.highestMass = mass;
    p.aliveSince = 0;
    _initialized = true;
  }

  /// Public actions — instant locally, server is told via the socket.
  void doSplit(Offset aimDir) {
    if (!_initialized || player.isDead) return;
    _split.splitPlayer(player, aimDir);
  }

  void doEject(Offset aimDir) {
    if (!_initialized || player.isDead) return;
    // Local-rendered feed (the "VIP" baseline). Own pieces are spawned
    // in sim.localEjected and rendered straight from there, the
    // server-mirrored copy is filtered out of the painter, and the
    // local sim runs the magnet + eat-prediction so the player gets
    // instant feedback on every eject and recapture.
    _eject.ejectPlayer(player, aimDir, spawnPieces: true);
  }

  /// Drop every cell — used when the server confirms our death.
  void killSelf() {
    if (!_initialized) return;
    player.cells.clear();
    player.isDead = true;
  }

  /// Reset to a fresh spawn at the given position+mass (server respawn).
  void respawn({required Offset position, required double mass}) {
    if (!_initialized) return;
    player.cells
      ..clear()
      ..add(Cell(
        id: '${player.id}_c0_${DateTime.now().microsecondsSinceEpoch}',
        ownerId: player.id,
        position: position,
        mass: mass,
        color: player.color,
        name: player.name,
        mergeReadyAt: DateTime.now(),
        isFreshSplit: false,
      ));
    player.isDead = false;
    player.highestMass = mass;
    engine.ejectedMasses.clear();
  }

  /// One simulation step. Mirrors the offline engine sequence for the local
  /// player only — no bot AI, no global collision pass, no pellet spawner.
  ///
  /// [replay] tells the step it's being re-run inside the controller's
  /// input-replay reconciliation pass. In replay we must NOT re-integrate
  /// local ejected mass (it was already advanced to the current wall-clock
  /// time during the original real-time tick — replaying it would over-
  /// advance it by the entire replay window), and we skip the auto-split
  /// enforcement (it's already been applied historically).
  void step(double dt, {V2World? world, bool replay = false}) {
    if (!_initialized || player.isDead || dt <= 0) return;
    engine.elapsed += dt;

    if (moveDir.distance > 0.05) lastNonZeroDir = moveDir;
    engine.moveDir = moveDir;
    engine.lastNonZeroDir = lastNonZeroDir;

    _applyInputForce(player, moveDir, dt);
    _merge.applyForces(
      player,
      dt,
      attackMode: attackMode,
      aimDir: lastNonZeroDir,
    );
    _integrate(player, dt);

    if (!replay) {
      // Feed magnet ON — matches Offline Classic exactly. Pieces within
      // ~150 u of any of the player's cells get pulled back so most of
      // a micro burst is recovered as it slows. The server runs the
      // same magnet logic in `updateEjected` so the two views agree on
      // where each piece ends up.
      _eject.update(dt, enableMagnet: true);
    }

    _merge.processMerges(player);
    if (!replay) {
      _split.enforceAutoSplit(player);
    }
  }

  // ────────────────────────── ported from GameEngine ──────────────────────

  void _applyInputForce(Player p, Offset rawDir, double dt) {
    final mag = rawDir.distance;
    if (mag < 0.05) return;
    final intensity = mag > 1.0 ? 1.0 : mag;
    final com = p.centerOfMass;
    final targetPoint = com + (rawDir / mag) * 1000.0;
    for (final c in p.cells) {
      final toTarget = targetPoint - c.position;
      final dist = toTarget.distance;
      if (dist < 0.1) continue;
      final dir = toTarget / dist;
      final maxSpeed = GameConstants.maxSpeedForRadius(c.radius);
      final agility =
          math.pow(150.0 / (c.mass + 50.0), 0.15).clamp(0.7, 1.5).toDouble();
      final accel = maxSpeed * GameConstants.dampingPerSecond * agility;
      c.velocity += dir * accel * intensity * dt;
    }
  }

  void _integrate(Player p, double dt) {
    final dampingFactor = math.exp(-GameConstants.dampingPerSecond * dt);
    final splitFric =
        math.pow(GameConstants.splitFrictionPerFrame, dt * 60).toDouble();
    for (final c in p.cells) {
      if (c.splitImpulse.distance >= 1) {
        c.position += c.splitImpulse * dt;
        c.splitImpulse = c.splitImpulse * splitFric;
        if (c.splitImpulse.distance < 1) c.splitImpulse = Offset.zero;
      }
      c.velocity = c.velocity * dampingFactor;
      final maxSpeed = GameConstants.maxSpeedForRadius(c.radius);
      final vMag = c.velocity.distance;
      if (vMag > maxSpeed) {
        c.velocity = c.velocity * (maxSpeed / vMag);
      }
      c.position += c.velocity * dt;
      if (c.mass > GameConstants.decayThreshold) {
        final nm =
            c.mass * math.pow(1 - GameConstants.massDecayRate, dt).toDouble();
        c.mass = nm < GameConstants.decayThreshold
            ? GameConstants.decayThreshold
            : nm;
      }
      c.wobblePhase += dt * 4;
      if (c.bumps.isNotEmpty) {
        final decay = math.exp(-6.0 * dt);
        for (int i = c.bumps.length - 1; i >= 0; i--) {
          c.bumps[i].magnitude *= decay;
          if (c.bumps[i].magnitude < 0.005) c.bumps.removeAt(i);
        }
      }
      final r = c.radius;
      final inset = r * 0.75;
      final world = GameConstants.worldSize;
      final atLeft = c.position.dx <= inset;
      final atRight = c.position.dx >= world - inset;
      final atTop = c.position.dy <= inset;
      final atBottom = c.position.dy >= world - inset;
      if ((atLeft && c.velocity.dx < 0) || (atRight && c.velocity.dx > 0)) {
        c.velocity = Offset(0, c.velocity.dy);
      }
      if ((atTop && c.velocity.dy < 0) || (atBottom && c.velocity.dy > 0)) {
        c.velocity = Offset(c.velocity.dx, 0);
      }
      c.position = Offset(
        c.position.dx.clamp(inset, world - inset),
        c.position.dy.clamp(inset, world - inset),
      );
    }
  }

  /// Aggregate stats — used by the controller to detect divergence vs. the
  /// server's view of self and decide whether to reconcile. Safe to call
  /// before [spawn]; return zeros / origin in that case.
  Offset get centerOfMass =>
      _initialized ? player.centerOfMass : Offset.zero;
  double get totalMass => _initialized ? player.totalMass : 0;
  int get cellCount => _initialized ? player.cells.length : 0;
}
