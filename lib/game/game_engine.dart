import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import 'ai/bot_ai.dart';
import 'chaos_events.dart';
import 'entities/black_hole.dart';
import 'entities/cell.dart';
import 'entities/coin.dart';
import 'entities/ejected_mass.dart';
import 'entities/pellet.dart';
import 'entities/virus.dart';
import 'game_mode_type.dart';
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
  static const int targetBots = 70;

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
    this.team = Team.none,
    this.role = PlayerRole.none,
  });

  final String id;
  final String name;
  Color color;
  final bool isHuman;
  Team team;
  PlayerRole role;
  int coinScore = 0;
  int rankedPoints = 0;
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

  /// Active game mode for the running session. Set by [init].
  GameMode mode = GameMode.classic;

  /// Per-mode tunables resolved once in [init].
  ModeConfig modeConfig = const ModeConfig();

  /// Owner-id → team lookup, rebuilt on init. Empty when not in teams mode.
  /// Kept as a hot map so collision/AI checks stay O(1).
  final Map<String, Team> _teamByOwner = {};

  // ── Mode-specific live state ──────────────────────────────────────────────
  /// Coins on the field (Coin Rush only).
  final List<Coin> coins = [];
  final SpatialGrid<Coin> coinGrid = SpatialGrid<Coin>(300);

  /// Black holes on the field (Black Hole mode only).
  final List<BlackHole> blackHoles = [];

  /// Battle Royale safe-zone state. Center stays at world center; radius
  /// shrinks linearly from `initial` to `final` across the match timer.
  double safeZoneRadius = GameConstants.worldSize;
  final Offset safeZoneCenter =
      const Offset(GameConstants.worldSize / 2, GameConstants.worldSize / 2);

  /// Remaining match time in seconds (modes with timers). -1 = no timer.
  double matchTimeRemaining = -1;

  /// True once a winning condition has been met. The HUD reads this; the
  /// engine itself just stops respawning, etc.
  bool matchEnded = false;
  String matchEndMessage = '';

  /// Counts kept for HUD use, updated in collision phase.
  int aliveBotCount = 0;
  int aliveSurvivorCount = 0;
  int aliveZombieCount = 0;
  int aliveHiderCount = 0;
  int aliveSeekerCount = 0;

  /// Chaos scheduler state. Initialised lazily so non-chaos modes carry zero
  /// overhead.
  ChaosState? _chaos;
  ChaosState? get chaos => _chaos;

  bool get isTeamsMode => mode == GameMode.teams;

  Team teamOf(String ownerId) =>
      _teamByOwner[ownerId] ?? Team.none;

  /// Role of the player owning [ownerId]. `PlayerRole.none` when unknown or
  /// when the active mode doesn't use roles — cheap to call every frame.
  PlayerRole roleOf(String ownerId) {
    if (!modeConfig.zombieMode && !modeConfig.hideSeekMode) {
      return PlayerRole.none;
    }
    for (final p in players) {
      if (p.id == ownerId) return p.role;
    }
    return PlayerRole.none;
  }

  /// True when both owners are on the same non-none team. Always false in
  /// non-teams modes — Classic stays identical.
  bool isSameTeam(String ownerA, String ownerB) {
    if (!isTeamsMode) return false;
    final ta = _teamByOwner[ownerA];
    if (ta == null || ta == Team.none) return false;
    return ta == _teamByOwner[ownerB];
  }

  /// True if `eater` is allowed to consume `prey` under current mode rules.
  /// Classic: always true. Teams: false for teammates. Zombie: zombies can't
  /// eat zombies. Hide & Seek: only seekers can eat hiders (and vice versa
  /// is blocked).
  bool canEat(String eaterOwner, String preyOwner) {
    if (eaterOwner == preyOwner) return false;
    if (isSameTeam(eaterOwner, preyOwner)) return false;
    if (modeConfig.zombieMode) {
      final ea = _findOwner(eaterOwner);
      final pr = _findOwner(preyOwner);
      if (ea != null && pr != null) {
        // Zombies don't infect other zombies (no eating between zombies).
        if (ea.role == PlayerRole.zombie && pr.role == PlayerRole.zombie) {
          return false;
        }
      }
    }
    if (modeConfig.hideSeekMode) {
      final ea = _findOwner(eaterOwner);
      final pr = _findOwner(preyOwner);
      if (ea != null && pr != null) {
        // Hiders cannot eat anyone (only collect pellets).
        if (ea.role == PlayerRole.hider) return false;
        // Seekers cannot eat seekers.
        if (ea.role == PlayerRole.seeker && pr.role == PlayerRole.seeker) {
          return false;
        }
      }
    }
    return true;
  }

  /// Sum of every alive cell's mass for the given team.
  double getTeamMass(Team team) {
    double total = 0;
    for (final p in players) {
      if (p.team != team || p.isDead) continue;
      total += p.totalMass;
    }
    return total;
  }

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
  void init({
    required String nickname,
    GameMode mode = GameMode.classic,
  }) {
    this.mode = mode;
    modeConfig = ModeConfig.forMode(mode);
    _teamByOwner.clear();
    players.clear();
    pellets.clear();
    viruses.clear();
    ejectedMasses.clear();
    particles.clear();
    coins.clear();
    coinGrid.clear();
    blackHoles.clear();
    leaderboard.clear();
    elapsed = 0;
    gameOver = false;
    matchEnded = false;
    matchEndMessage = '';
    matchTimeRemaining =
        modeConfig.matchTimerSeconds?.toDouble() ?? -1;
    safeZoneRadius = GameConstants.worldSize;
    _chaos = modeConfig.chaosMode ? ChaosState(_rng) : null;
    _chaos?.scheduleNext(0);
    moveDir = Offset.zero;
    lastNonZeroDir = const Offset(1, 0);

    // Human's team: random pick in teams mode so the player gets variety.
    final humanTeam = isTeamsMode
        ? TeamConfig.playable[_rng.nextInt(TeamConfig.playable.length)]
        : Team.none;
    final humanColor = isTeamsMode
        ? TeamConfig.color(humanTeam)
        : _palette[_rng.nextInt(_palette.length)];

    humanPlayer = Player(
      id: 'human',
      name: nickname.trim().isEmpty ? 'Player' : nickname.trim(),
      color: humanColor,
      isHuman: true,
      team: humanTeam,
    )..skinImage = SkinSettings.instance.skinImage;
    players.add(humanPlayer);
    if (isTeamsMode) _teamByOwner[humanPlayer.id] = humanTeam;
    _spawnPlayer(humanPlayer);

    for (int i = 0; i < GameConstants.targetBots; i++) {
      // Distribute bots evenly across the three teams in teams mode.
      final botTeam = isTeamsMode
          ? TeamConfig.playable[i % TeamConfig.playable.length]
          : Team.none;
      final botColor = isTeamsMode
          ? TeamConfig.color(botTeam)
          : _palette[_rng.nextInt(_palette.length)];
      final bot = Player(
        id: 'bot$i',
        name: _botNames[i % _botNames.length],
        color: botColor,
        isHuman: false,
        team: botTeam,
      )..skinImage = SkinRegistry.instance.randomSkin(_rng);
      players.add(bot);
      if (isTeamsMode) _teamByOwner[bot.id] = botTeam;
      _spawnPlayer(bot);
    }

    final targetPellets =
        (GameConstants.targetPellets * modeConfig.pelletMultiplier).round();
    while (pellets.length < targetPellets) {
      pellets.add(_spawnPellet());
    }
    final targetViruses =
        (GameConstants.targetViruses * modeConfig.virusMultiplier).round();
    for (int i = 0; i < targetViruses; i++) {
      viruses.add(Virus(id: 'v$i', position: _randomWorldPos()));
    }

    if (modeConfig.coinMode) _spawnInitialCoins();
    if (modeConfig.blackHoleMode) _spawnBlackHoles();
    if (modeConfig.zombieMode) _assignZombieRoles();
    if (modeConfig.hideSeekMode) _assignHideSeekRoles();

    cameraPos = humanPlayer.centerOfMass;
    cameraZoom = _targetZoom();
  }

  void _spawnInitialCoins() {
    for (int i = 0; i < modeConfig.coinCount; i++) {
      coins.add(Coin(
        position: _randomWorldPos(),
        pulsePhase: _rng.nextDouble() * pi * 2,
      ));
    }
  }

  void _spawnBlackHoles() {
    const margin = 1500.0;
    for (int i = 0; i < modeConfig.blackHoleCount; i++) {
      blackHoles.add(BlackHole(
        id: 'bh$i',
        position: _randomWorldPos(margin: margin),
        pullRadius: 900,
        dangerRadius: 160,
        phase: _rng.nextDouble() * pi * 2,
      ));
    }
  }

  /// Zombie Infection seed roles: every player starts Survivor, then N of the
  /// bots are flipped to Zombie. The human starts as Survivor every match.
  void _assignZombieRoles() {
    humanPlayer.role = PlayerRole.survivor;
    final bots = players.where((p) => !p.isHuman).toList();
    bots.shuffle(_rng);
    final n = modeConfig.initialZombieCount.clamp(0, bots.length);
    for (int i = 0; i < bots.length; i++) {
      bots[i].role = i < n ? PlayerRole.zombie : PlayerRole.survivor;
      if (bots[i].role == PlayerRole.zombie) {
        bots[i].color = RoleConfig.color(PlayerRole.zombie)!;
      }
    }
  }

  /// Hide & Seek seed roles: human is always Hider; N bots are flipped to
  /// Seeker, the rest are Hiders.
  void _assignHideSeekRoles() {
    humanPlayer.role = PlayerRole.hider;
    final bots = players.where((p) => !p.isHuman).toList();
    bots.shuffle(_rng);
    final n = modeConfig.seekerCount.clamp(0, bots.length);
    for (int i = 0; i < bots.length; i++) {
      final isSeeker = i < n;
      bots[i].role = isSeeker ? PlayerRole.seeker : PlayerRole.hider;
      final c = RoleConfig.color(bots[i].role);
      if (c != null) bots[i].color = c;
    }
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
    // BOTS now start at 100 mass as requested.
    final startingMass = p.isHuman
        ? (76   * AuthService.instance.activeMassMultiplier).clamp(76, 1e9).toDouble()
        : 100.0;

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
        // Hiders in Hide & Seek can't eat — disable prey targeting so they
        // focus on pellets + threat avoidance.
        final canHunt = !(modeConfig.hideSeekMode && p.role == PlayerRole.hider);
        var dir = _ai.decide(
          center: p.centerOfMass,
          mass: p.totalMass,
          ownerId: p.id,
          cellCount: p.cells.length,
          cellGrid: cellGrid,
          pelletGrid: pelletGrid,
          virusGrid: virusGrid,
          currentDir: p.aiTargetDir,
          worldSize: GameConstants.worldSize,
          isAlly: _isAllyOf(p.id),
          canHunt: canHunt,
          aggression: modeConfig.botAggression,
        );
        // Battle Royale: steer bots back toward the safe zone center if
        // they're outside (or close to the edge).
        if (modeConfig.shrinkingZone) {
          final toCenter = safeZoneCenter - p.centerOfMass;
          final d = toCenter.distance;
          if (d > safeZoneRadius - 200) {
            final pull = d > 0 ? toCenter / d : Offset.zero;
            // Heavier blend the further out the bot is.
            final weight = ((d - (safeZoneRadius - 200)) / 400).clamp(0.2, 1.4);
            dir = (dir + pull * weight);
            final m = dir.distance;
            if (m > 0) dir = dir / m;
          }
        }
        // Black Hole: nudge bots away from any pull-radius they're inside.
        if (modeConfig.blackHoleMode) {
          for (final bh in blackHoles) {
            final away = p.centerOfMass - bh.position;
            final d = away.distance;
            if (d > 0 && d < bh.pullRadius * 0.85) {
              final weight = 1.0 - (d / bh.pullRadius);
              dir = dir + (away / d) * weight * 1.2;
              final m = dir.distance;
              if (m > 0) dir = dir / m;
            }
          }
        }
        p.aiTargetDir = dir;
        // More aggressive → more frequent decisions.
        final cadence = 0.2 / modeConfig.botAggression;
        p.aiNextDecideAt = now + cadence + _rng.nextDouble() * cadence;
      }

      // Bot split: occasionally split toward prey.
      if (now >= p.aiNextSplitAt) {
        final doSplit = _ai.decideSplit(
          center: p.centerOfMass,
          mass: p.totalMass,
          ownerId: p.id,
          cellCount: p.cells.length,
          cellGrid: cellGrid,
          isAlly: _isAllyOf(p.id),
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
          isAlly: _isAllyOf(p.id),
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
      // Virus wall clamp: Agar.io Mobile style (partial overlap)
      final r = v.radius;
      final inset = r * 0.5; // allow 50% overlap
      v.position = Offset(
        v.position.dx.clamp(inset, GameConstants.worldSize - inset),
        v.position.dy.clamp(inset, GameConstants.worldSize - inset),
      );
    }

    // Pellet pulse & particles.
    for (final p in pellets) {
      p.pulsePhase += dt * 3;
    }
    for (final c in coins) {
      c.pulsePhase += dt * 4;
    }
    final partFric = pow(0.92, dt * 60).toDouble();
    for (final p in particles) {
      p.position += p.velocity * dt;
      p.velocity = p.velocity * partFric;
      p.life -= dt;
    }
    particles.removeWhere((p) => p.life <= 0);

    // Mode tick: match timer, shrinking zone, black-hole forces, chaos.
    _tickModeSystems(dt);

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
    final pelletTarget =
        (GameConstants.targetPellets * modeConfig.pelletMultiplier).round() +
            ((_chaos?.active == ChaosEvent.pelletFlood &&
                    _chaos!.isActiveAt(elapsed))
                ? 4000
                : 0);
    while (pellets.length < pelletTarget) {
      pellets.add(_spawnPellet());
    }
    // Maintain coin count in Coin Rush.
    if (modeConfig.coinMode) {
      while (coins.length < modeConfig.coinCount) {
        coins.add(Coin(
          position: _safeCoinPosition(),
          pulsePhase: _rng.nextDouble() * pi * 2,
        ));
      }
    }
    for (final p in players) {
      // Bots respawn faster: delay reduced from 3s to 0.5s.
      if (!p.isHuman && p.isDead && now - p.deathTime > 0.5) {
        if (!modeConfig.canBotsRespawn) continue;
        _spawnPlayer(p);
        // Reapply role colour so respawned bots keep their identity.
        if (p.role == PlayerRole.zombie ||
            p.role == PlayerRole.seeker ||
            p.role == PlayerRole.hider) {
          final c = RoleConfig.color(p.role);
          if (c != null) p.color = c;
        }
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
    final f = unit *
        GameConstants.inputMoveStrength *
        _activeSpeedMultiplier() *
        dt;
    for (final c in p.cells) {
      c.velocity += f;
    }
  }

  /// Composite multiplier applied to movement force + speed clamp.
  /// Bakes in mode config + transient chaos modifiers.
  double _activeSpeedMultiplier() {
    double m = modeConfig.speedMultiplier;
    final c = _chaos;
    if (c != null && c.isActiveAt(elapsed)) {
      if (c.active == ChaosEvent.speedBoost) m *= 1.6;
      if (c.active == ChaosEvent.slowMotion) m *= 0.55;
    }
    return m;
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
      final maxSpeed =
          GameConstants.maxSpeedForRadius(c.radius) * _activeSpeedMultiplier();
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
      // Agar.io Mobile style: Allow cells to "sink" slightly into the wall.
      // We allow ~25% of the cell radius to be outside the playable area.
      final r = c.radius;
      final inset = r * 0.75; 
      c.position = Offset(
        c.position.dx.clamp(inset, GameConstants.worldSize - inset),
        c.position.dy.clamp(inset, GameConstants.worldSize - inset),
      );
    }
  }

  // ------------------------------------------------------------- collisions
  void _rebuildGrids() {
    cellGrid.clear();
    pelletGrid.clear();
    virusGrid.clear();
    ejectGrid.clear();
    coinGrid.clear();
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
    for (final c in coins) {
      coinGrid.insert(c, c.position);
    }
  }

  // ---------------------------------------------------------- mode tick
  /// Single entry point for every mode-specific per-frame system. Keeps the
  /// main `update()` loop clean and lets early-outs (when a flag is off) cost
  /// effectively nothing for Classic / Teams.
  void _tickModeSystems(double dt) {
    if (matchTimeRemaining > 0) {
      matchTimeRemaining -= dt;
      if (matchTimeRemaining <= 0) {
        matchTimeRemaining = 0;
        _evaluateTimerEnd();
      }
    }
    if (modeConfig.shrinkingZone) _tickShrinkingZone(dt);
    if (modeConfig.blackHoleMode) _tickBlackHoles(dt);
    if (modeConfig.chaosMode) _tickChaos(dt);
    if (modeConfig.coinMode ||
        modeConfig.zombieMode ||
        modeConfig.hideSeekMode ||
        mode == GameMode.battleRoyale) {
      _recomputeAliveCounts();
    }
    if (mode == GameMode.battleRoyale) _checkBattleRoyaleEnd();
    if (modeConfig.zombieMode) _checkZombieEnd();
    if (modeConfig.hideSeekMode) _checkHideSeekEnd();
  }

  void _tickShrinkingZone(double dt) {
    final total = (modeConfig.matchTimerSeconds ?? 240).toDouble();
    final elapsedMatch = total - matchTimeRemaining.clamp(0, total);
    // Shrink from full world diagonal radius to ~700u.
    const initial = GameConstants.worldSize * 0.55;
    const finalR = 700.0;
    final t = (elapsedMatch / total).clamp(0.0, 1.0);
    safeZoneRadius = initial + (finalR - initial) * t;

    // Apply edge damage to anyone outside the zone.
    for (final p in players) {
      if (p.isDead) continue;
      for (final c in p.cells) {
        final d = (c.position - safeZoneCenter).distance;
        if (d > safeZoneRadius) {
          final over = (d - safeZoneRadius);
          final dps = 6.0 + over * 0.02; // ramps with distance outside
          c.mass = max(GameConstants.decayThreshold, c.mass - dps * dt);
        }
      }
    }
  }

  void _tickBlackHoles(double dt) {
    for (final bh in blackHoles) {
      bh.advance(dt);
      for (final p in players) {
        if (p.isDead) continue;
        for (final c in p.cells) {
          final r = bh.pullVector(c.position);
          if (r.dist > bh.pullRadius || r.dist <= 0) continue;
          // Pull force falls off linearly with distance.
          final strength =
              BlackHole.pullStrength * (1 - r.dist / bh.pullRadius);
          c.velocity += r.dir * strength * dt;
          if (r.dist < bh.dangerRadius) {
            c.mass = max(
              GameConstants.decayThreshold,
              c.mass - BlackHole.damagePerSecond * dt,
            );
          }
        }
      }
    }
  }

  void _tickChaos(double dt) {
    final c = _chaos;
    if (c == null) return;
    if (c.active != null && !c.isActiveAt(elapsed)) {
      _endChaosEvent();
    }
    if (c.active == null && elapsed >= c.nextEventAt) {
      _startChaosEvent(c.pickRandom());
    }
  }

  void _startChaosEvent(ChaosEvent e) {
    final c = _chaos!;
    c.start(e, elapsed);
    if (e == ChaosEvent.virusStorm) {
      // Add ~10 temporary viruses; tagged so we can remove them on end.
      for (int i = 0; i < 10; i++) {
        final id = 'chaos_v_${elapsed.toStringAsFixed(3)}_$i';
        viruses.add(Virus(id: id, position: _randomWorldPos()));
        c.tempVirusIds.add(id);
      }
    } else if (e == ChaosEvent.massRain) {
      // Sprinkle ejected-mass projectiles around the human's screen so the
      // effect is visible to the player.
      final center = humanPlayer.cells.isNotEmpty
          ? humanPlayer.centerOfMass
          : cameraPos;
      for (int i = 0; i < 60; i++) {
        final ang = _rng.nextDouble() * pi * 2;
        final dist = 200 + _rng.nextDouble() * 800;
        final pos = center + Offset(cos(ang) * dist, sin(ang) * dist);
        ejectedMasses.add(EjectedMass(
          ownerId: 'world',
          position: Offset(
            pos.dx.clamp(50, GameConstants.worldSize - 50),
            pos.dy.clamp(50, GameConstants.worldSize - 50),
          ),
          velocity: Offset.zero,
          color: const Color(0xFFFFD600),
        ));
      }
    }
  }

  void _endChaosEvent() {
    final c = _chaos!;
    if (c.active == ChaosEvent.virusStorm) {
      viruses.removeWhere((v) => c.tempVirusIds.contains(v.id));
    }
    c.clear();
    c.scheduleNext(elapsed);
  }

  void _recomputeAliveCounts() {
    aliveBotCount = 0;
    aliveSurvivorCount = 0;
    aliveZombieCount = 0;
    aliveHiderCount = 0;
    aliveSeekerCount = 0;
    for (final p in players) {
      if (p.isDead) continue;
      if (!p.isHuman) aliveBotCount++;
      switch (p.role) {
        case PlayerRole.survivor:
          aliveSurvivorCount++;
          break;
        case PlayerRole.zombie:
          aliveZombieCount++;
          break;
        case PlayerRole.hider:
          aliveHiderCount++;
          break;
        case PlayerRole.seeker:
          aliveSeekerCount++;
          break;
        case PlayerRole.none:
          break;
      }
    }
  }

  void _checkBattleRoyaleEnd() {
    if (matchEnded) return;
    int alive = 0;
    Player? lastAlive;
    for (final p in players) {
      if (!p.isDead) {
        alive++;
        lastAlive = p;
      }
    }
    if (alive <= 1) {
      matchEnded = true;
      matchEndMessage = lastAlive != null
          ? (lastAlive.isHuman ? 'Victory Royale!' : '${lastAlive.name} wins')
          : 'No survivors';
    }
  }

  void _checkZombieEnd() {
    if (matchEnded) return;
    // Zombies win if no survivors remain.
    if (aliveSurvivorCount == 0) {
      matchEnded = true;
      matchEndMessage = 'Zombies win — all infected';
    }
  }

  void _checkHideSeekEnd() {
    if (matchEnded) return;
    if (aliveHiderCount == 0) {
      matchEnded = true;
      matchEndMessage = 'Seekers win';
    }
  }

  /// Called once when [matchTimeRemaining] crosses zero. Mode decides the
  /// winning message; the engine doesn't force-kill anyone — players keep
  /// roaming, but `matchEnded` is set so the HUD can show the result.
  void _evaluateTimerEnd() {
    if (matchEnded) return;
    if (modeConfig.zombieMode) {
      matchEnded = true;
      matchEndMessage =
          'Survivors win ($aliveSurvivorCount alive)';
    } else if (modeConfig.hideSeekMode) {
      matchEnded = true;
      matchEndMessage = 'Hiders win ($aliveHiderCount alive)';
    } else if (modeConfig.coinMode) {
      matchEnded = true;
      // Winner = highest coin score.
      Player? top;
      for (final p in players) {
        if (top == null || p.coinScore > top.coinScore) top = p;
      }
      matchEndMessage = top != null
          ? '${top.isHuman ? "You" : top.name} wins with ${top.coinScore} coins'
          : 'Time up';
    } else if (mode == GameMode.battleRoyale) {
      // Shouldn't normally hit this since we end on last-alive, but cover it.
      matchEnded = true;
      matchEndMessage = 'Match over';
    }
  }

  /// Find a coin spawn position that doesn't overlap a virus.
  Offset _safeCoinPosition() {
    for (int attempt = 0; attempt < 10; attempt++) {
      final pos = _randomWorldPos();
      bool clear = true;
      for (final v in viruses) {
        if ((v.position - pos).distance < v.radius + 30) {
          clear = false;
          break;
        }
      }
      if (clear) return pos;
    }
    return _randomWorldPos();
  }

  void _resolveCollisions(double now) {
    final toRemoveCells = <Cell>{};
    final eatenEjected = <EjectedMass>{};
    final toInfect = <Player>{}; // owners to flip to zombie after this tick

    // Cells eat coins (Coin Rush). Cheap radius query, mirrors pellet logic.
    if (modeConfig.coinMode && coins.isNotEmpty) {
      for (final p in players) {
        if (p.isDead) continue;
        for (final c in p.cells) {
          final near = coinGrid.queryRadius(c.position, c.radius + 25);
          final rSq = c.radius * c.radius;
          for (final coin in near) {
            if ((coin.position - c.position).distanceSquared < rSq) {
              coin.position = _safeCoinPosition();
              p.coinScore += Coin.scoreValue;
              if (c.mass < GameConstants.maxCellMass) c.mass += Coin.mass;
            }
          }
        }
      }
    }

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
        // Teams mode: teammates can't damage each other.
        if (!canEat(a.ownerId, b.ownerId)) continue;
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
          final prey = _findOwner(b.ownerId);
          if (eater != null) eater.eatenCount++;
          if (modeConfig.rankedScoring && eater != null) {
            eater.rankedPoints += 10 + (b.mass / 10).round();
          }
          // Zombie infection: when a zombie eats a survivor cell, queue the
          // survivor owner for conversion. We can't mutate during iteration,
          // so flush after this loop.
          if (modeConfig.zombieMode &&
              eater != null &&
              prey != null &&
              eater.role == PlayerRole.zombie &&
              prey.role == PlayerRole.survivor) {
            toInfect.add(prey);
          }
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
        // Ranked: small penalty per death so spamming is discouraged.
        if (modeConfig.rankedScoring) {
          p.rankedPoints = max(0, p.rankedPoints - 30);
        }
      }
    }

    // Zombie Infection: flip queued survivors. We respawn them immediately as
    // a zombie so they keep playing under the new role.
    if (toInfect.isNotEmpty) {
      for (final p in toInfect) {
        p.role = PlayerRole.zombie;
        p.color = RoleConfig.color(PlayerRole.zombie)!;
        if (p.isDead || p.cells.isEmpty) {
          _spawnPlayer(p);
        }
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

  /// Returns a predicate that tells the bot which other ownerIds are friendly.
  /// Combines team affiliation (Teams mode) with shared role (Zombie/Hide &
  /// Seek). Cheap closure — returns a no-op when no mode wants ally checks.
  bool Function(String otherOwnerId) _isAllyOf(String selfOwnerId) {
    final teamMode = isTeamsMode;
    final roleMode = modeConfig.zombieMode || modeConfig.hideSeekMode;
    if (!teamMode && !roleMode) return (_) => false;

    final myTeam = _teamByOwner[selfOwnerId];
    final me = _findOwner(selfOwnerId);
    final myRole = me?.role ?? PlayerRole.none;
    return (other) {
      if (other == selfOwnerId) return false;
      if (teamMode && myTeam != null && myTeam != Team.none) {
        if (_teamByOwner[other] == myTeam) return true;
      }
      if (roleMode && myRole != PlayerRole.none) {
        final o = _findOwner(other);
        if (o != null && o.role == myRole) return true;
      }
      return false;
    };
  }

  // -------------------------------------------------------- leaderboard
  void _rebuildLeaderboard() {
    if (isTeamsMode) {
      _rebuildTeamLeaderboard();
      return;
    }
    if (modeConfig.coinMode) {
      _rebuildCoinLeaderboard();
      return;
    }
    if (modeConfig.rankedScoring) {
      _rebuildRankedLeaderboard();
      return;
    }
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

  /// Coin Rush: rank by coinScore, mass breaks ties.
  void _rebuildCoinLeaderboard() {
    final ps = <Player>[];
    for (final p in players) {
      if (p.isDead) continue;
      ps.add(p);
    }
    ps.sort((a, b) {
      final s = b.coinScore.compareTo(a.coinScore);
      if (s != 0) return s;
      return b.totalMass.compareTo(a.totalMass);
    });
    final entries = <LeaderboardEntry>[];
    for (final p in ps.take(10)) {
      entries.add(LeaderboardEntry(
        '${p.name} · ${p.coinScore}c',
        p.totalMass,
        p.isHuman,
      ));
    }
    leaderboard = entries;
    int rank = 1;
    humanRank = -1;
    for (final p in ps) {
      if (p.isHuman) {
        humanRank = rank;
        break;
      }
      rank++;
    }
  }

  /// Ranked Arena: rank by rankedPoints.
  void _rebuildRankedLeaderboard() {
    final ps = <Player>[];
    for (final p in players) {
      if (p.isDead) continue;
      ps.add(p);
    }
    ps.sort((a, b) {
      final s = b.rankedPoints.compareTo(a.rankedPoints);
      if (s != 0) return s;
      return b.totalMass.compareTo(a.totalMass);
    });
    final entries = <LeaderboardEntry>[];
    for (final p in ps.take(10)) {
      entries.add(LeaderboardEntry(
        '${p.name} · ${p.rankedPoints}p',
        p.totalMass,
        p.isHuman,
      ));
    }
    leaderboard = entries;
    int rank = 1;
    humanRank = -1;
    for (final p in ps) {
      if (p.isHuman) {
        humanRank = rank;
        break;
      }
      rank++;
    }
  }

  /// Teams leaderboard: 3 entries — one per playable team. `isHuman` flags
  /// the team the player belongs to so the leaderboard widget can highlight
  /// it. `humanRank` becomes the human team's standing (1-based).
  void _rebuildTeamLeaderboard() {
    final entries = <LeaderboardEntry>[];
    for (final t in TeamConfig.playable) {
      entries.add(LeaderboardEntry(
        TeamConfig.displayName(t),
        getTeamMass(t),
        t == humanPlayer.team,
      ));
    }
    entries.sort((a, b) => b.mass.compareTo(a.mass));
    leaderboard = entries;
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
  /// Returns true if the human is allowed to respawn under current mode rules.
  bool get canRespawnHuman => modeConfig.canHumanRespawn && !matchEnded;

  void respawnHuman() {
    if (!canRespawnHuman) return;
    _spawnPlayer(humanPlayer);
    // Re-apply role color if applicable (zombie/seeker).
    if (humanPlayer.role == PlayerRole.zombie ||
        humanPlayer.role == PlayerRole.seeker) {
      final c = RoleConfig.color(humanPlayer.role);
      if (c != null) humanPlayer.color = c;
    }
    gameOver = false;
    timeSurvived = 0;
  }
}
