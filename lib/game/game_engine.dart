import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import 'ai/bot_ai.dart';
import 'entities/cell.dart';
import 'entities/ejected_mass.dart';
import 'entities/pellet.dart';
import 'entities/virus.dart';
import 'game_settings.dart';
import 'mechanics/eject_handler.dart';
import 'mechanics/merge_handler.dart';
import 'mechanics/split_handler.dart';
import 'skin_registry.dart';
import 'skin_settings.dart';
import 'spatial_grid.dart';

class GameConstants {
  // ---------- World ----------
  static const double worldSize = 14142;
  static const double gridUnit = 50;
  static const int targetPellets = 8000;
  static const int targetViruses = 30;
  static const int targetBots = 30;

  // ---------- Cell limits ----------
  static const int maxCellsPerPlayer = 16;
  static const double maxCellMass = 22500;
  static const double splitMinMass = 35;
  static const double ejectMinMass = 35;

  // ---------- Mass decay ----------
  // 0.2% per second, applied only to cells over 35 mass.
  static const double massDecayRate = 0.002;
  static const double decayThreshold = 35;

  // ---------- Eject ----------
  static const double ejectCost = 13;         // mass removed from source cell
  static const double ejectMass = 13;         // mass of the spawned pellet
  static const double ejectConsumedMass = 13; // mass gained by eater
  // Eject travel target: ~6 grid spaces (300 world units).
  // distance = v0 / (60 * (1 - friction)) → 1500 / (60 * 0.09) ≈ 278 units.
  static const double ejectVelocityInitial = 1500;
  static const double ejectFrictionPerFrame = 0.91;

  // ---------- Split impulse ----------
  // Impulse-only travel ≈ 1500 / (60 * 0.09) ≈ 278 units (~5.5 grid).
  // Plus the joystick drift during the ~1s impulse decay adds ~120 units,
  // putting total split travel in the 7–9 grid-space range — agar.io mobile.
  static const double splitImpulseInitial = 1500;
  static const double splitFrictionPerFrame = 0.91;

  // ---------- Merge cooldown ----------
  // FLAT 30 seconds — mobile rule. Does NOT scale with mass.
  static const Duration mergeCooldown = Duration(seconds: 30);

  // (Replaced by cohesion/separation force model below.)

  // ---------- Virus ----------
  static const double virusMass = 100;
  static const double virusShotInitial = 1200;

  // ---------- Speed ----------
  // Legacy multiplier — kept for compatibility but no longer used since cell
  // motion is now velocity-based with explicit per-radius caps below.
  static const double speedScale = 6.0;

  // ---------- Velocity-based movement (patched in for multi-cell feel) ----------
  // Adjusted from the upstream default (520) so cells reach a usable terminal
  // velocity on our 14142 world: terminal ≈ inputMoveStrength / dampingPerSecond.
  // 1200 / 5.8 ≈ 207 u/s. World cross-time ≈ 68 s.
  static const double inputMoveStrength = 1200;
  static const double dampingPerSecond = 5.8;

  // Cohesion: each cell accelerates toward the weighted center of mass.
  static const double cohesionStrength = 4.5;
  static const double cohesionMaxDistance = 120.0;
  // While a cell is still inside its merge cooldown, cohesion is dialed back
  // so fresh splits don't get yanked back into the group immediately.
  static const double cohesionCooldownFactor = 0.35;

  // Separation: pairwise anti-overlap force scaled by inverse mass.
  static const double separationStrength = 34.0;
  static const double minGap = 3.0;

  // Attack spread: sideways/back push on cells blocking the main cell's
  // shooting lane while the player is aiming/ejecting.
  static const double attackSpreadStrength = 22.0;
  static const double launchOffset = 10.0;
  static const double projectileSpawnClearance = 6.0;
  static const double laneWidthBase = 18.0;
  static const double laneWidthRadiusFactor = 0.72;
  static const double laneForwardDepthFactor = 2.8;

  // Max-speed clamp (per radius). Smaller cells move faster.
  static const double referenceRadius = 35.0;
  static const double maxSmallCellSpeed = 360.0;
  static const double maxLargeCellSpeed = 95.0;
  static const double speedRadiusPower = 0.42;
  static const double speedScaleBase = 260.0;

  // Merge: trigger when centers are deeply inside each other.
  // Changed from 0.45 to 0.75 to make merging much easier and smoother.
  static const double mergeDistanceFactor = 0.75;

  // Radius-based merge cooldown (replaces the flat 30s).
  static const double mergeCooldownBase = 14.0;
  static const double mergeCooldownMax = 28.0;
  static const double mergeCooldownPerRadius = 0.12;

  // ---------- helpers ----------
  static double maxSpeedForRadius(double radius) {
    final s = speedScaleBase *
        pow(referenceRadius / (radius < 1 ? 1 : radius), speedRadiusPower);
    return s.clamp(maxLargeCellSpeed, maxSmallCellSpeed).toDouble();
  }

  static Duration mergeCooldownForRadius(double radius) {
    final secs = (mergeCooldownBase + radius * mergeCooldownPerRadius)
        .clamp(mergeCooldownBase, mergeCooldownMax);
    return Duration(milliseconds: (secs * 1000).round());
  }
}

class Player {
  Player({
    required this.id,
    required this.name,
    required this.color,
    required this.isHuman,
  });

  final String id;
  final String name;
  Color color;
  final bool isHuman;
  final List<Cell> cells = [];

  /// Pre-decoded skin image used by the painter. Human pulls this from
  /// [SkinSettings]; bots get a random one from [SkinRegistry] on init.
  ui.Image? skinImage;

  bool isDead = false;
  double deathTime = 0;
  double highestMass = 34;
  int eatenCount = 0;
  double aliveSince = 0;

  Offset aiTargetDir = Offset.zero;
  double aiNextDecideAt = 0;
  double aiNextSplitAt = 0;
  double aiNextEjectAt = 0;

  double get totalMass {
    double m = 0;
    for (final c in cells) {
      m += c.mass;
    }
    return m;
  }

  /// Returns the longest remaining merge cooldown among all cells.
  /// Used for the HUD timer.
  Duration get remainingMergeTime {
    if (cells.length < 2) return Duration.zero;
    final now = DateTime.now();
    DateTime latest = now;
    bool anyWaiting = false;
    for (final c in cells) {
      if (c.mergeReadyAt.isAfter(latest)) {
        latest = c.mergeReadyAt;
        anyWaiting = true;
      }
    }
    return anyWaiting ? latest.difference(now) : Duration.zero;
  }

  Offset get centerOfMass {
    if (cells.isEmpty) return Offset.zero;
    double cx = 0, cy = 0, tm = 0;
    for (final c in cells) {
      cx += c.position.dx * c.mass;
      cy += c.position.dy * c.mass;
      tm += c.mass;
    }
    return Offset(cx / tm, cy / tm);
  }
}

class Particle {
  Particle({
    required this.position,
    required this.velocity,
    required this.color,
    this.life = 1.0,
    this.radius = 4,
  });
  Offset position;
  Offset velocity;
  Color color;
  double life;
  double maxLife = 1.0;
  double radius;
}

class LeaderboardEntry {
  LeaderboardEntry(this.name, this.mass, this.isHuman);
  final String name;
  final double mass;
  final bool isHuman;
}

class GameEngine {
  GameEngine();

  final Random _rng = Random();
  late final BotAI _ai = BotAI(_rng);
  late final SplitHandler _split = SplitHandler(this, _rng);
  late final EjectHandler _eject = EjectHandler(this, _rng);
  late final MergeHandler _merge = MergeHandler(this);

  final List<Player> players = [];
  late Player humanPlayer;

  final List<Pellet> pellets = [];
  final List<Virus> viruses = [];
  final List<EjectedMass> ejectedMasses = [];
  final List<Particle> particles = [];

  final SpatialGrid<Cell> cellGrid = SpatialGrid<Cell>(500);
  final SpatialGrid<Pellet> pelletGrid = SpatialGrid<Pellet>(250);
  final SpatialGrid<Virus> virusGrid = SpatialGrid<Virus>(500);
  final SpatialGrid<EjectedMass> ejectGrid = SpatialGrid<EjectedMass>(300);

  Offset moveDir = Offset.zero;
  Offset lastNonZeroDir = const Offset(1, 0);

  /// True while the player is aiming/attacking (eject button held, or split
  /// has just been pressed). Drives the attack-spread force in MergeHandler
  /// so cells move out of the main cell's launch lane.
  bool attackMode = false;

  Offset cameraPos =
      const Offset(GameConstants.worldSize / 2, GameConstants.worldSize / 2);
  double cameraZoom = 1.0;
  Size viewportSize = const Size(800, 400);

  double elapsed = 0;

  List<LeaderboardEntry> leaderboard = [];
  int humanRank = 1;
  double _lastLeaderboardAt = -1;

  bool gameOver = false;
  double timeSurvived = 0;

  static const List<String> _botNames = [
    'Bot_Killer', 'Doge', 'Ninja', 'Slayer42', 'Cookie', 'AgarKing',
    'TacoCat', 'PixelPro', 'Nyan', 'Mario', 'Sonic', 'Pikachu', 'Yoshi',
    'Bart', 'Donut', 'Bender', 'Sponge', 'Kirby', 'Link', 'Zelda', 'Samus',
    'Ezio', 'Solid', 'Master', 'Sneaky', 'Wraith', 'Reaper', 'Phantom',
    'Bandit', 'Viper', 'Hawk',
  ];

  static const List<Color> _palette = [
    Color(0xFFFF0000), // Pure Red
    Color(0xFF00FF00), // Pure Green
    Color(0xFF0091FF), // Bright Blue
    Color(0xFFFFD700), // Vivid Gold
    Color(0xFFFF00FF), // Neon Magenta
    Color(0xFF00FFFF), // Cyan
    Color(0xFFFF6600), // Bright Orange
    Color(0xFF9D00FF), // Electric Purple
    Color(0xFF39FF14), // Neon Green
    Color(0xFFFF1493), // Deep Pink
  ];

  // -------------------------------------------------------- public actions
  bool get canSplit {
    if (humanPlayer.isDead) return false;
    if (humanPlayer.cells.length >= GameConstants.maxCellsPerPlayer) {
      return false;
    }
    for (final c in humanPlayer.cells) {
      if (c.mass >= GameConstants.splitMinMass) return true;
    }
    return false;
  }

  bool get canEject {
    if (humanPlayer.isDead) return false;
    for (final c in humanPlayer.cells) {
      if (c.mass >= GameConstants.ejectMinMass) return true;
    }
    return false;
  }

  void doSplit() {
    debugPrint(
      'SPLIT tapped — dead=${humanPlayer.isDead} cells=${humanPlayer.cells.length} totalMass=${humanPlayer.totalMass.toStringAsFixed(0)}',
    );
    _split.splitPlayer(humanPlayer, aimDir());
  }

  void doEject() {
    debugPrint(
      'EJECT tapped — dead=${humanPlayer.isDead} cells=${humanPlayer.cells.length} totalMass=${humanPlayer.totalMass.toStringAsFixed(0)}',
    );
    _eject.ejectPlayer(humanPlayer, aimDir());
  }

  Offset aimDir() {
    return moveDir.distance > 0.05 ? moveDir : lastNonZeroDir;
  }

  // ------------------------------------------------------------- lifecycle
  void init({required String nickname}) {
    players.clear();
    pellets.clear();
    viruses.clear();
    ejectedMasses.clear();
    particles.clear();
    leaderboard.clear();
    elapsed = 0;
    gameOver = false;
    moveDir = Offset.zero;
    lastNonZeroDir = const Offset(1, 0);

    humanPlayer = Player(
      id: 'human',
      name: nickname.trim().isEmpty ? 'Player' : nickname.trim(),
      color: _palette[_rng.nextInt(_palette.length)],
      isHuman: true,
    )..skinImage = SkinSettings.instance.skinImage;
    players.add(humanPlayer);
    _spawnPlayer(humanPlayer);

    for (int i = 0; i < GameConstants.targetBots; i++) {
      final bot = Player(
        id: 'bot$i',
        name: _botNames[i % _botNames.length],
        color: _palette[_rng.nextInt(_palette.length)],
        isHuman: false,
      )..skinImage = SkinRegistry.instance.randomSkin(_rng);
      players.add(bot);
      _spawnPlayer(bot);
    }

    while (pellets.length < GameConstants.targetPellets) {
      pellets.add(_spawnPellet());
    }
    for (int i = 0; i < GameConstants.targetViruses; i++) {
      viruses.add(Virus(id: 'v$i', position: _randomWorldPos()));
    }

    cameraPos = humanPlayer.centerOfMass;
    cameraZoom = _targetZoom();
  }

  Offset _randomWorldPos({double margin = 200}) {
    return Offset(
      margin + _rng.nextDouble() * (GameConstants.worldSize - 2 * margin),
      margin + _rng.nextDouble() * (GameConstants.worldSize - 2 * margin),
    );
  }

  Pellet _spawnPellet() {
    return Pellet(
      position: _randomWorldPos(),
      color: _palette[_rng.nextInt(_palette.length)],
      pulsePhase: _rng.nextDouble() * pi * 2,
    );
  }

  void _spawnPlayer(Player p) {
    Offset pos = _randomWorldPos(margin: 600);
    int tries = 20;
    while (tries-- > 0) {
      bool safe = true;
      for (final other in players) {
        if (identical(other, p)) continue;
        for (final c in other.cells) {
          if ((c.position - pos).distance < 800) {
            safe = false;
            break;
          }
        }
        if (!safe) break;
      }
      if (safe) break;
      pos = _randomWorldPos(margin: 600);
    }
    // Mass Boost: only the human player gets the multiplier; bots spawn at
    // baseline. The multiplier is read fresh on every spawn so a boost that
    // expires between matches won't keep applying.
    // TEMPORARY: Starting mass set to 1000 for testing as requested.
    final startingMass = p.isHuman
        ? (1000 * AuthService.instance.activeMassMultiplier).clamp(1000, 1e9).toDouble()
        : 34.0;

    p.cells.clear();
    p.cells.add(Cell(
      id: '${p.id}_c0_${elapsed.toStringAsFixed(2)}',
      ownerId: p.id,
      position: pos,
      mass: startingMass,
      color: p.color,
      name: p.name,
      // A spawn cell is immediately merge-ready — it has nothing to merge with
      // yet, and we don't want a 30s wait before the player's first split is
      // useful.
      mergeReadyAt: DateTime.now(),
      isFreshSplit: false,
    ));
    p.isDead = false;
    p.highestMass = startingMass;
    p.eatenCount = 0;
    p.aliveSince = elapsed;
  }

  double _targetZoom() {
    final m = humanPlayer.totalMass.clamp(10, 1e9).toDouble();
    final z = pow(64 / m, 0.25).toDouble();
    // Inverse Logic: more multiplier = lower scale (see more world)
    final mult = 1.0 / GameSettings.instance.zoomMultiplier;
    return (z * mult).clamp(0.01, 4.0);
  }

  // ---------------------------------------------------------- main update
  void update(double dt) {
    if (dt <= 0) return;
    elapsed += dt;
    final now = elapsed;

    if (moveDir.distance > 0.05) lastNonZeroDir = moveDir;

    // AI decisions
    for (final p in players) {
      if (p.isHuman || p.isDead) continue;
      if (now >= p.aiNextDecideAt) {
        p.aiTargetDir = _ai.decide(
          center: p.centerOfMass,
          mass: p.totalMass,
          ownerId: p.id,
          cellCount: p.cells.length,
          cellGrid: cellGrid,
          pelletGrid: pelletGrid,
          virusGrid: virusGrid,
          currentDir: p.aiTargetDir,
          worldSize: GameConstants.worldSize,
        );
        p.aiNextDecideAt = now + 0.2 + _rng.nextDouble() * 0.2;
      }

      // Bot split: occasionally split toward prey.
      if (now >= p.aiNextSplitAt) {
        final doSplit = _ai.decideSplit(
          center: p.centerOfMass,
          mass: p.totalMass,
          ownerId: p.id,
          cellCount: p.cells.length,
          cellGrid: cellGrid,
        );
        if (doSplit) {
          _split.splitPlayer(p, p.aiTargetDir);
          p.aiNextSplitAt = now + 3.0 + _rng.nextDouble() * 5.0;
        } else {
          p.aiNextSplitAt = now + 0.8 + _rng.nextDouble() * 0.4;
        }
      }

      // Bot eject: feed nearby viruses when a large enemy is present.
      if (now >= p.aiNextEjectAt) {
        final doEject = _ai.decideEject(
          center: p.centerOfMass,
          mass: p.totalMass,
          ownerId: p.id,
          cellGrid: cellGrid,
          virusGrid: virusGrid,
          aimDir: p.aiTargetDir,
        );
        if (doEject) {
          _eject.ejectPlayer(p, p.aiTargetDir);
          p.aiNextEjectAt = now + 1.0 + _rng.nextDouble() * 2.0;
        } else {
          p.aiNextEjectAt = now + 0.5 + _rng.nextDouble() * 0.3;
        }
      }
    }

    // 1. Input force per cell + 2. cohesion/separation/spread (merge_handler
    // applies these to .velocity). Then per-cell integration: split impulse,
    // damping, max-speed clamp, position += velocity * dt, mass decay, world
    // clamp.
    final stopOnRelease = GameSettings.instance.stopOnRelease;
    final splitFric =
        pow(GameConstants.splitFrictionPerFrame, dt * 60).toDouble();
    for (final p in players) {
      if (p.isDead) continue;
      final dir = p.isHuman
          ? (moveDir.distance > 0.05
              ? moveDir
              : (stopOnRelease ? Offset.zero : lastNonZeroDir))
          : p.aiTargetDir;
      _applyInputForce(p, dir, dt);
      _merge.applyForces(
        p,
        dt,
        attackMode: p.isHuman && attackMode,
        aimDir: lastNonZeroDir,
      );
      _integrateCells(p, dt, splitFric);
    }

    // 4. Ejected mass move + decay.
    _eject.update(dt);

    // Viruses (drift after being shot). Static visual — no rotation.
    final virusFric = pow(0.96, dt * 60).toDouble();
    for (final v in viruses) {
      if (v.velocity.distance > 1) {
        v.position += v.velocity * dt;
        v.velocity = v.velocity * virusFric;
      }
      v.position = Offset(
        v.position.dx.clamp(v.radius, GameConstants.worldSize - v.radius),
        v.position.dy.clamp(v.radius, GameConstants.worldSize - v.radius),
      );
    }

    // Pellet pulse & particles.
    for (final p in pellets) {
      p.pulsePhase += dt * 3;
    }
    final partFric = pow(0.92, dt * 60).toDouble();
    for (final p in particles) {
      p.position += p.velocity * dt;
      p.velocity = p.velocity * partFric;
      p.life -= dt;
    }
    particles.removeWhere((p) => p.life <= 0);

    _rebuildGrids();

    // 5. Eating.
    _resolveCollisions(now);

    // 6+7. Same-owner merge step (cohesion/separation/spread already applied
    // before integration via _merge.applyForces).
    for (final p in players) {
      _merge.processMerges(p);
    }

    // 9. Auto-split when above 22,500 mass.
    for (final p in players) {
      _split.enforceAutoSplit(p);
    }

    // Maintain world: pellet count, bot respawn.
    while (pellets.length < GameConstants.targetPellets) {
      pellets.add(_spawnPellet());
    }
    for (final p in players) {
      if (!p.isHuman && p.isDead && now - p.deathTime > 3) {
        _spawnPlayer(p);
      }
    }

    // Game over flag.
    if (humanPlayer.isDead && !gameOver) {
      gameOver = true;
      timeSurvived = now - humanPlayer.aliveSince;
    }

    if (!humanPlayer.isDead) {
      final m = humanPlayer.totalMass;
      if (m > humanPlayer.highestMass) humanPlayer.highestMass = m;
    }

    if (now - _lastLeaderboardAt >= 0.5) {
      _lastLeaderboardAt = now;
      _rebuildLeaderboard();
    }

    if (!humanPlayer.isDead && humanPlayer.cells.isNotEmpty) {
      cameraPos = Offset.lerp(cameraPos, humanPlayer.centerOfMass, 0.1)!;
      final tz = _targetZoom();
      cameraZoom = cameraZoom + (tz - cameraZoom) * 0.1;
    }
  }

  /// Step 1 of the new force-based cell update: add input force to velocity.
  void _applyInputForce(Player p, Offset rawDir, double dt) {
    final mag = rawDir.distance;
    if (mag < 0.05) return;
    final unit = rawDir / mag;
    final f = unit * GameConstants.inputMoveStrength * dt;
    for (final c in p.cells) {
      c.velocity += f;
    }
  }

  /// Step 3 of the force-based update: split-impulse decay, damping, speed
  /// clamp, position += velocity * dt, mass decay, world clamp.
  void _integrateCells(Player p, double dt, double splitFric) {
    final dampingFactor = exp(-GameConstants.dampingPerSecond * dt);

    for (final c in p.cells) {
      // Split impulse: separate vector that decays faster than damping so the
      // post-split burst still has the Agar.io "shoot then stop" feel.
      if (c.splitImpulse.distance >= 1) {
        c.position += c.splitImpulse * dt;
        c.splitImpulse = c.splitImpulse * splitFric;
        if (c.splitImpulse.distance < 1) c.splitImpulse = Offset.zero;
      }

      // Frame-rate-independent damping on velocity (input/cohesion/separation/
      // spread were all integrated into velocity earlier this frame).
      c.velocity = c.velocity * dampingFactor;

      // Clamp max speed per radius (small cells fast, big cells slow).
      final maxSpeed = GameConstants.maxSpeedForRadius(c.radius);
      final vMag = c.velocity.distance;
      if (vMag > maxSpeed) {
        c.velocity = c.velocity * (maxSpeed / vMag);
      }

      // Position integration.
      c.position += c.velocity * dt;

      // Mass decay (above 35 threshold).
      if (c.mass > GameConstants.decayThreshold) {
        final newMass =
            c.mass * pow(1 - GameConstants.massDecayRate, dt).toDouble();
        c.mass = newMass < GameConstants.decayThreshold
            ? GameConstants.decayThreshold
            : newMass;
      }

      // Wobble phase.
      c.wobblePhase += dt * 4;

      // Decay jelly bumps
      if (c.bumps.isNotEmpty) {
        final decay = exp(-6.0 * dt);
        for (int i = c.bumps.length - 1; i >= 0; i--) {
          c.bumps[i].magnitude *= decay;
          if (c.bumps[i].magnitude < 0.005) {
            c.bumps.removeAt(i);
          }
        }
      }

      // World clamp.
      final r = c.radius;
      c.position = Offset(
        c.position.dx.clamp(r, GameConstants.worldSize - r),
        c.position.dy.clamp(r, GameConstants.worldSize - r),
      );
    }
  }

  // ------------------------------------------------------------- collisions
  void _rebuildGrids() {
    cellGrid.clear();
    pelletGrid.clear();
    virusGrid.clear();
    ejectGrid.clear();
    for (final p in players) {
      if (p.isDead) continue;
      for (final c in p.cells) {
        cellGrid.insert(c, c.position);
      }
    }
    for (final p in pellets) {
      pelletGrid.insert(p, p.position);
    }
    for (final v in viruses) {
      virusGrid.insert(v, v.position);
    }
    for (final e in ejectedMasses) {
      ejectGrid.insert(e, e.position);
    }
  }

  void _resolveCollisions(double now) {
    final toRemoveCells = <Cell>{};
    final eatenEjected = <EjectedMass>{};

    // Cells eat pellets.
    for (final p in players) {
      if (p.isDead) continue;
      for (final c in p.cells) {
        final near = pelletGrid.queryRadius(c.position, c.radius + 20);
        final rSq = c.radius * c.radius;
        for (final pellet in near) {
          if ((pellet.position - c.position).distanceSquared < rSq) {
            c.addBump(atan2(pellet.position.dy - c.position.dy, pellet.position.dx - c.position.dx), 0.04);
            pellet.position = _randomWorldPos();
            pellet.color = _palette[_rng.nextInt(_palette.length)];
            if (c.mass < GameConstants.maxCellMass) c.mass += Pellet.mass;
          }
        }
      }
    }

    // Cells (mass >= 22) eat ejected mass. Eater gains 12, not 13.
    // A projectile is immune to its own owner's cells for the first 150ms
    // after spawn so it doesn't self-collide instantly.
    final nowDt = DateTime.now();
    for (final p in players) {
      if (p.isDead) continue;
      for (final c in p.cells) {
        if (c.mass < 22) continue;
        final near = ejectGrid.queryRadius(c.position, c.radius + 40);
        for (final e in near) {
          if (eatenEjected.contains(e)) continue;
          final ageMs = nowDt.difference(e.spawnTime).inMilliseconds;
          // Reduced immunity window from 500ms to 200ms to prevent "lost" mass
          // that doesn't get eaten when intended, while still preventing
          // instant self-consumption upon spawn.
          if (ageMs < 200 && e.ownerId == c.ownerId) continue;
          final eatRadius = c.radius - e.radius * 0.4;
          if ((e.position - c.position).distanceSquared <
              eatRadius * eatRadius) {
            c.addBump(atan2(e.position.dy - c.position.dy, e.position.dx - c.position.dx), 0.08);
            eatenEjected.add(e);
            if (c.mass < GameConstants.maxCellMass) {
              c.mass += GameConstants.ejectConsumedMass;
            }
          }
        }
      }
    }

    // Ejected mass feeds viruses.
    for (final e in ejectedMasses) {
      if (eatenEjected.contains(e)) continue;
      // Removed the 500ms immunity window for viruses. Ejected mass should
      // be able to feed viruses immediately to ensure they don't just pass
      // through or "disappear" without effect.
      final near = virusGrid.queryRadius(e.position, 200);
      for (final v in near) {
        final d = (e.position - v.position).distance;
        if (d < v.radius + e.radius * 0.5) {
          eatenEjected.add(e);
          _eject.handleHitVirus(e, v);
          break;
        }
      }
    }

    // Cell-vs-cell.
    final allCells = <Cell>[];
    for (final p in players) {
      if (p.isDead) continue;
      allCells.addAll(p.cells);
    }
    for (final a in allCells) {
      if (toRemoveCells.contains(a)) continue;
      final near = cellGrid.queryRadius(a.position, a.radius + 200);
      for (final b in near) {
        if (identical(a, b)) continue;
        if (toRemoveCells.contains(b)) continue;
        if (a.ownerId == b.ownerId) continue;
        if (a.radius <= b.radius) continue;
        // Split cells need 33% bigger; whole cells need only 25% bigger.
        final ratio = a.isFreshSplit ? 1.33 : 1.25;
        if (a.radius < b.radius * ratio) continue;
        final eatRadius = a.radius - b.radius * 0.4;
        if ((b.position - a.position).distanceSquared <
            eatRadius * eatRadius) {
          a.addBump(atan2(b.position.dy - a.position.dy, b.position.dx - a.position.dx), 0.12);
          if (a.mass < GameConstants.maxCellMass) a.mass += b.mass;
          toRemoveCells.add(b);
          final eater = _findOwner(a.ownerId);
          if (eater != null) eater.eatenCount++;
        }
      }
    }

    // Cell-vs-virus pop.
    final virusesConsumed = <Virus>{};
    for (final a in allCells) {
      if (toRemoveCells.contains(a)) continue;
      final near = virusGrid.queryRadius(a.position, a.radius + 150);
      for (final v in near) {
        if (virusesConsumed.contains(v)) continue;
        // Requirement 3: Explosion happens as soon as the cell "touches" the virus.
        // We use a more sensitive distance check (virus center entering cell radius).
        if (a.radius <= v.radius * 1.15) continue;
        final triggerDistance = a.radius + v.radius * 0.2;
        if ((v.position - a.position).distanceSquared <
            triggerDistance * triggerDistance) {
          virusesConsumed.add(v);
          _spawnPopParticles(v.position);
          final owner = _findOwner(a.ownerId);
          if (owner != null) _split.popVirus(owner, a, v);
          break;
        }
      }
    }

    // Apply removals.
    for (final p in players) {
      p.cells.removeWhere((c) => toRemoveCells.contains(c));
      if (p.cells.isEmpty && !p.isDead) {
        p.isDead = true;
        p.deathTime = elapsed;
      }
    }
    for (final em in eatenEjected) {
      ejectedMasses.remove(em);
    }
    for (final v in virusesConsumed) {
      viruses.remove(v);
      viruses.add(Virus(
        id: 'v_re_${now.toStringAsFixed(3)}_${_rng.nextDouble()}',
        position: _randomWorldPos(),
      ));
    }
  }

  void _spawnPopParticles(Offset at) {
    for (int i = 0; i < 14; i++) {
      final ang = _rng.nextDouble() * pi * 2;
      final spd = 150 + _rng.nextDouble() * 250;
      particles.add(Particle(
        position: at,
        velocity: Offset(cos(ang) * spd, sin(ang) * spd),
        color: _palette[_rng.nextInt(_palette.length)],
        life: 0.6 + _rng.nextDouble() * 0.4,
        radius: 3 + _rng.nextDouble() * 3,
      )..maxLife = 1.0);
    }
  }

  Player? _findOwner(String ownerId) {
    for (final p in players) {
      if (p.id == ownerId) return p;
    }
    return null;
  }

  // -------------------------------------------------------- leaderboard
  void _rebuildLeaderboard() {
    final entries = <LeaderboardEntry>[];
    for (final p in players) {
      if (p.isDead) continue;
      entries.add(LeaderboardEntry(p.name, p.totalMass, p.isHuman));
    }
    entries.sort((a, b) => b.mass.compareTo(a.mass));
    leaderboard = entries.take(10).toList();
    int rank = 1;
    bool found = false;
    for (final e in entries) {
      if (e.isHuman) {
        humanRank = rank;
        found = true;
        break;
      }
      rank++;
    }
    if (!found) humanRank = -1;
  }

  // -------------------------------------------------------- public reset
  void respawnHuman() {
    _spawnPlayer(humanPlayer);
    gameOver = false;
    timeSurvived = 0;
  }
}
