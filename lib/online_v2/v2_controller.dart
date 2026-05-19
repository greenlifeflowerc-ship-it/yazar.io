/// Online Classic V2 controller — the brain that glues:
///   • [V2SocketClient]  — the wire protocol
///   • [V2LocalSim]      — the local-player physics, reusing offline
///                         GameConstants/SplitHandler/EjectHandler/MergeHandler
///   • [V2World]         — every server-authoritative entity outside self,
///                         with target/render positions for smooth interp
///
/// Real-time guarantees implemented here:
///   – local movement is driven only by [V2LocalSim] and never by snapshots
///     (so there is no input-to-render lag)
///   – split / eject animate instantly via [V2LocalSim.doSplit] /
///     `doEject` and are simultaneously sent over the socket
///   – pellet eating predicts locally via [V2World.markPelletLocallyEaten]
///     and is later confirmed by the server's `rmPellets`
///   – remote players use only render positions from [V2World], which lerp
///     toward each new snapshot
///   – reconciliation runs only when the server's view of self diverges
///     past a tolerance; small drifts are blended in over a few snapshots,
///     a large mismatch (cell-count desync, death) snaps
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/entities/cell.dart' as ge;
import '../game/entities/ejected_mass.dart';
import '../game/entities/virus.dart' as ge;
import '../game/game_engine.dart';
import '../game/game_settings.dart';
import '../game/skin_settings.dart';
import 'net/v2_packets.dart';
import 'net/v2_socket_client.dart';
import 'v2_local_sim.dart';
import 'v2_skin_cache.dart';
import 'v2_world.dart';

class V2Controller extends ChangeNotifier {
  V2Controller({V2SocketClient? client}) : client = client ?? V2SocketClient();

  final V2SocketClient client;
  final V2World world = V2World();
  final V2LocalSim sim = V2LocalSim();
  final V2SkinCache skinCache = V2SkinCache();

  /// Local lifetime cap for self-spawned ejected mass. After this window the
  /// authoritative server-side copy (in [V2World.ejected]) has fully arrived,
  /// so the locally-spawned one is dropped to avoid double-rendering.
  /// Local ejected mass is rendered until the matching server-broadcast copy
  /// has had time to arrive (1 RTT + 1 server tick). Too short = visible
  /// "blink" when the feed disappears before the server version shows up.
  /// Too long = double-rendered feed (local + server overlap) is visible.
  /// 300 ms covers typical mobile latencies (RTT ≤ 250 ms) comfortably.
  static const _localEjectedLifetimeMs = 300;
  /// Local prediction window for virus pops, used to suppress accidental
  /// re-pop of the same virus across two ticks before the server confirms.
  final Set<String> _locallyPoppedViruses = {};
  /// Wall-clock ms of the most recent locally-predicted virus pop. Used by
  /// the reconcile path: while a predicted pop is fresh, local has many more
  /// cells than the server (server hasn't broadcast the fragments yet) and
  /// we have to wait it out instead of rebuilding immediately.
  int _lastVirusPopMs = 0;

  /// Enemy cells we locally predicted as eaten. The painter no longer draws
  /// them, but if the server keeps reporting them alive in a subsequent
  /// snapshot we restore them — guards against the prediction running ahead
  /// of the server when our local cell is RTT/2 in front of where the server
  /// thinks we are.
  final Map<String, V2WorldCell> _locallyKilledEnemy = {};
  final Map<String, int> _locallyKilledExpiry = {};
  static const _locallyKilledTtlMs = 1000;

  // ── connection / identity ─────────────────────────────────────────────
  V2ConnState _connState = V2ConnState.idle;
  V2ConnState get connState => _connState;
  String? _playerId;
  String? get playerId => _playerId;
  String _playerName = 'Player';
  String get playerName => _playerName;
  double _worldSize = 14142;
  double get worldSize => _worldSize;
  int _online = 0;
  int get online => _online;
  int _pingMs = 0;
  int get pingMs => _pingMs;

  // ── leaderboard / status ──────────────────────────────────────────────
  List<V2LeaderboardEntry> leaderboard = const [];
  bool _deadServerConfirmed = false;
  bool get isDead => _deadServerConfirmed && sim.cells.isEmpty;

  // ── match stats (consumed by the screen on death) ─────────────────────
  int _kills = 0;
  int get kills => _kills;
  double _highestMass = 0;
  double get highestMass => _highestMass;
  DateTime? _spawnedAt;
  int get survivalSeconds {
    final t = _spawnedAt;
    if (t == null) return 0;
    return DateTime.now().difference(t).inSeconds;
  }
  int get currentRank {
    final id = _playerId;
    if (id == null) return -1;
    for (int i = 0; i < leaderboard.length; i++) {
      if (leaderboard[i].id == id) return i + 1;
    }
    return -1; // not in top-N
  }
  /// Fires once when the server confirms death — the screen subscribes via
  /// ChangeNotifier and submits the match result to the profile RPC.
  bool _deathNotified = false;
  bool consumeDeathEvent() {
    if (_deadServerConfirmed && !_deathNotified) {
      _deathNotified = true;
      return true;
    }
    return false;
  }

  // ── input ─────────────────────────────────────────────────────────────
  /// Joystick direction in [-1,1] per axis.
  Offset _moveDir = Offset.zero;
  /// True while the player is holding the eject button (drives attack-spread).
  bool _attackMode = false;
  /// Latest non-zero direction — used as fallback aim for split/eject taps.
  Offset _lastDir = const Offset(1, 0);

  // ── input pump rate ───────────────────────────────────────────────────
  static const _inputIntervalMs = 33; // ~30 Hz, mirrors server tick
  int _lastInputSendMs = 0;

  // ── reconciliation state ──────────────────────────────────────────────
  /// Pending action sequence numbers we've sent but haven't seen acked yet.
  /// Used to know how far behind the server's view is and to optionally
  /// time out unconfirmed local actions.
  final List<_PendingAction> _pendingActions = [];
  int _countMismatchTicks = 0;
  static const _countMismatchSnapThreshold = 3; // ~100 ms at 30 Hz

  /// After `welcome` we spawn the local sim at world center as a placeholder
  /// — the server's actual chosen spawn point arrives one tick later.
  /// This flag forces a HARD snap on the first snapshot so the camera and
  /// the local cell land where the server thinks we are; without it the
  /// reconcile loop's 400 u distance cap would refuse to close the gap.
  bool _needsInitialSnap = false;

  // ── streams ───────────────────────────────────────────────────────────
  late final List<StreamSubscription<dynamic>> _subs;

  // ── lifecycle ─────────────────────────────────────────────────────────
  Future<void> connect({
    required String playerName,
    String skin = '',
    double massMultiplier = 1.0,
  }) async {
    _playerName = playerName.trim().isEmpty ? 'Player' : playerName.trim();
    _subs = [
      client.welcomes.listen(_onWelcome),
      client.snapshots.listen(_onSnapshot),
      client.pongs.listen(_onPong),
      client.stateChanges.listen(_onConnStateChanged),
    ];
    await client.connect(
      playerName: _playerName,
      skin: skin,
      massMultiplier: massMultiplier,
    );
  }

  void _onConnStateChanged(V2ConnState s) {
    _connState = s;
    notifyListeners();
  }

  void _onWelcome(V2Welcome w) {
    _playerId = w.playerId;
    _playerName = w.name;
    _worldSize = w.worldSize;
    world.selfId = w.playerId;
    world.clear();
    world.selfId = w.playerId;
    // Spawn the local sim with provisional state. The first snapshot will
    // correct its position via reconciliation.
    sim.spawn(
      playerId: w.playerId,
      name: w.name,
      color: const Color(0xFFFFD700),
      position: Offset(w.worldSize / 2, w.worldSize / 2),
      mass: 76,
      skinImage: SkinSettings.instance.skinImage,
    );
    _deadServerConfirmed = false;
    _pendingActions.clear();
    _needsInitialSnap = true;
    _countMismatchTicks = 0;
    _kills = 0;
    _highestMass = 0;
    _spawnedAt = DateTime.now();
    _deathNotified = false;
    notifyListeners();
  }

  void _onPong(V2Pong p) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _pingMs = (now - p.clientT).clamp(0, 5000);
  }

  void _onSnapshot(V2State s) {
    // Track the last input seq the server has incorporated. Any pending
    // action with seq <= ack has been observed authoritatively.
    _pendingActions.removeWhere((p) => p.seq <= s.ackSeq);

    // FIFO-match server-confirmed ejected pieces to our locally-predicted
    // ones, drop the locals, AND seed the new server pieces' render position
    // with the local piece's last position. Without the position transfer,
    // the local piece (rendered at the predicted cell edge + flight) vanishes
    // and the server piece pops up tens of units behind it — looks like the
    // feed "teleported back" or "disappeared" then a new one appeared.
    // Reconcile locally-predicted enemy kills against the snapshot. If the
    // server confirmed (rmCells), drop the tracking. If the server is still
    // updating that cell (updCells), we mispredicted — restore it so the
    // player doesn't lose sight of an enemy that's actually still alive.
    if (_locallyKilledExpiry.isNotEmpty) {
      final ids = _locallyKilledExpiry.keys.toList();
      for (final id in ids) {
        if (s.rmCells.contains(id)) {
          _locallyKilledEnemy.remove(id);
          _locallyKilledExpiry.remove(id);
        } else if (s.updCells.any((u) => u.id == id)) {
          final restored = _locallyKilledEnemy[id];
          if (restored != null) world.cells[id] = restored;
          _locallyKilledEnemy.remove(id);
          _locallyKilledExpiry.remove(id);
        }
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _locallyKilledExpiry.removeWhere((id, exp) {
        if (nowMs > exp) {
          final restored = _locallyKilledEnemy[id];
          if (restored != null) world.cells[id] = restored;
          _locallyKilledEnemy.remove(id);
          return true;
        }
        return false;
      });
    }

    final selfId = _playerId;
    final inheritedRenderPos = <String, Offset>{};
    if (selfId != null && s.addEjected.isNotEmpty && sim.localEjected.isNotEmpty) {
      final ownAdds = <V2AddEjected>[];
      for (final e in s.addEjected) {
        if (e.ownerId == selfId) ownAdds.add(e);
      }
      if (ownAdds.isNotEmpty) {
        final toDrop = ownAdds.length > sim.localEjected.length
            ? sim.localEjected.length
            : ownAdds.length;
        for (int i = 0; i < toDrop; i++) {
          inheritedRenderPos[ownAdds[i].id] = sim.localEjected[i].position;
        }
        sim.localEjected.removeRange(0, toDrop);
      }
    }

    world.applySnapshot(s);

    // Seed render positions so the visual continues from where local was —
    // the smooth tick() will then converge it onto the server's authoritative
    // target over the next few frames without any visible jump.
    if (inheritedRenderPos.isNotEmpty) {
      for (final entry in inheritedRenderPos.entries) {
        final w = world.ejected[entry.key];
        if (w != null) {
          w.renderX = entry.value.dx;
          w.renderY = entry.value.dy;
        }
      }
    }
    _online = s.online;
    leaderboard = s.leaderboard;

    // Self status — drives the death / respawn flow.
    final wasDead = _deadServerConfirmed;
    _deadServerConfirmed = s.self.dead;
    if (!wasDead && s.self.dead) {
      // Server confirms death. Drop local cells; renderer will show the
      // death overlay.
      sim.killSelf();
    } else if (wasDead && !s.self.dead) {
      // Server respawned us. Snap to server-reported center of mass — and
      // re-arm the initial-snap path so the next reconcile rebuilds cells
      // straight from the authoritative addCells (not a single seed cell).
      sim.respawn(position: Offset(s.self.cmX, s.self.cmY), mass: s.self.mass);
      _needsInitialSnap = true;
      // New life — reset run stats so submitMatchResult only sees this run.
      _kills = 0;
      _highestMass = s.self.mass;
      _spawnedAt = DateTime.now();
      _deathNotified = false;
    }

    // Match stats are authoritative from the server's self payload.
    if (s.self.kills > _kills) _kills = s.self.kills;
    if (s.self.highestMass > _highestMass) _highestMass = s.self.highestMass;

    _reconcileSelf(s);
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────── input plumbing
  void setMoveDir(Offset d) {
    // Clamp the raw input vector to the unit disc — the joystick already
    // limits magnitude to [0, 1] but pinch-pad inputs can go outside.
    final m = d.distance;
    final clamped = m > 1 ? d / m : d;
    if (clamped.distance > 0.05) {
      // Active input: moveDir carries BOTH direction and intensity so
      // _applyInputForce can scale force by joystick pull (Agar.io feel
      // — a half-pulled joystick = half force, lets split cells regroup).
      _moveDir = clamped;
      // lastDir is the *aim* fallback for "continue moving on release",
      // so we store it as a pure unit vector — releasing a half-pulled
      // joystick should glide forward at full power, not half.
      _lastDir = clamped / clamped.distance;
    } else {
      // Joystick released. Mirror the offline GameEngine rule:
      //   stopOnRelease=true  → stop moving
      //   stopOnRelease=false → keep gliding in the last aim direction
      //     at full intensity (since _lastDir is already a unit vector).
      _moveDir = GameSettings.instance.stopOnRelease ? Offset.zero : _lastDir;
    }
    sim.moveDir = _moveDir;
    sim.lastNonZeroDir = _lastDir;
  }

  void setAttackMode(bool active) {
    _attackMode = active;
    sim.attackMode = active;
  }

  void doSplit() {
    if (_deadServerConfirmed) return;
    final aim = _moveDir.distance > 0.05 ? _moveDir : _lastDir;
    sim.doSplit(aim);
    client.sendSplit();
    _pendingActions.add(_PendingAction(client.lastSentSeq, 'split'));
  }

  void doEject() {
    if (_deadServerConfirmed) return;
    final aim = _moveDir.distance > 0.05 ? _moveDir : _lastDir;
    sim.doEject(aim);
    // The offline EjectHandler fires `burst` ejects per cell per call (driven
    // by feedSpeedMultiplier). The server must do the same number per packet
    // — otherwise local mass drops further than server confirms, and the
    // reconcile snaps it back (visible as "mass disappearing" then refilling).
    final burst = (GameSettings.instance.feedSpeedMultiplier / 10)
        .floor()
        .clamp(1, 10);
    client.sendEject(count: burst);
    _pendingActions.add(_PendingAction(client.lastSentSeq, 'eject'));
  }

  void respawn() {
    if (!_deadServerConfirmed) return;
    client.sendRespawn();
  }

  // ──────────────────────────────────────────────────────── frame tick
  /// Drive simulation + interpolation + input send. Call from the screen's
  /// per-frame ticker.
  void tick(double dt) {
    if (dt <= 0) return;

    // 1. Local sim step (movement, cohesion, separation, integrate, eject,
    //    merge, auto-split cap). Mirrors Offline Classic 1:1.
    sim.step(dt, world: world);

    // 2. Predict pellet eating against the current world cache.
    _predictPelletEating();

    // 3. Predict eating of local-spawned feed (own cells absorbing own feed)
    //    and of server-side feed in viewport. Also expire stale local feed
    //    so it doesn't pile up after server's authoritative copy takes over.
    _predictEjectedEating();
    _expireLocalEjected();

    // 4. Predict virus pops. The server is authoritative but waiting a full
    //    RTT for the cell explosion makes the action feel rubbery, so we run
    //    the same SplitHandler.popVirus locally.
    _predictVirusPops();

    // 5. Predict cell-vs-cell eating both directions — we eating an enemy
    //    AND being eaten ourselves. Without this, both events lag by ~1 RTT
    //    (the server's tick + the snapshot round-trip), which makes
    //    aggressive plays feel sluggish.
    _predictCellEating();

    // 6. Smooth render positions of every remote-authoritative entity.
    world.tickRender(dt);

    // 6. Throttled input send to the server.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastInputSendMs >= _inputIntervalMs) {
      _lastInputSendMs = nowMs;
      if (client.isConnected) {
        client.sendInput(
          dx: _moveDir.dx,
          dy: _moveDir.dy,
          attack: _attackMode,
        );
      }
    }

    notifyListeners();
  }

  void _predictPelletEating() {
    if (!sim.isInitialized || sim.cells.isEmpty) return;
    final toEat = <String>[];
    for (final c in sim.cells) {
      final rSq = c.radius * c.radius;
      for (final p in world.pellets.values) {
        final dx = p.x - c.position.dx;
        final dy = p.y - c.position.dy;
        if (dx * dx + dy * dy < rSq) {
          toEat.add(p.id);
          if (c.mass < GameConstants.maxCellMass) c.mass += 1.0;
        }
      }
    }
    for (final id in toEat) {
      world.markPelletLocallyEaten(id);
    }
  }

  /// Local cell-vs-ejected eating, for both our locally-spawned feed and the
  /// server-broadcast ejected from other players. Mirrors the offline rule:
  /// a cell needs mass >= 22, then anything inside `radius - ejectedRadius*0.4`
  /// gets consumed. The 200 ms owner-immunity matches the offline / server
  /// formula so the feed isn't self-eaten before it travels.
  void _predictEjectedEating() {
    if (!sim.isInitialized || sim.cells.isEmpty) return;
    final selfId = _playerId;
    if (selfId == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ejectedRadius = math.sqrt(13 / math.pi) * 10;

    // ── local-only ejected (our own feed) ──
    final localToRemove = <EjectedMass>[];
    // Check if MY cells eat MY local feed.
    for (final c in sim.cells) {
      if (c.mass < 22) continue;
      for (final e in sim.localEjected) {
        if (localToRemove.contains(e)) continue;
        final age = nowMs - e.spawnTime.millisecondsSinceEpoch;
        if (e.ownerId == c.ownerId && age < 200) continue;
        final eatR = c.radius + e.radius;
        final dx = e.position.dx - c.position.dx;
        final dy = e.position.dy - c.position.dy;
        if (dx * dx + dy * dy < eatR * eatR) {
          if (c.mass < GameConstants.maxCellMass) {
            c.mass += GameConstants.ejectConsumedMass;
          }
          localToRemove.add(e);
        }
      }
    }
    // Check if OTHER players' cells eat MY local feed.
    for (final c in world.cells.values) {
      if (c.isSelf) continue; // skipped, we use sim.cells above
      if (c.targetMass < 22) continue;
      final cRadius = c.renderRadius;
      for (final e in sim.localEjected) {
        if (localToRemove.contains(e)) continue;
        final eatR = cRadius + e.radius;
        final dx = e.position.dx - c.renderX;
        final dy = e.position.dy - c.renderY;
        if (dx * dx + dy * dy < eatR * eatR) {
          localToRemove.add(e);
        }
      }
    }
    // Check if viruses eat MY local feed.
    for (final v in world.viruses.values) {
      final vRadius = v.renderRadius;
      for (final e in sim.localEjected) {
        if (localToRemove.contains(e)) continue;
        // Viruses eat ejected mass if it's within (virusR + ejectedR*0.5).
        final trigger = vRadius + e.radius * 0.5;
        final dx = e.position.dx - v.renderX;
        final dy = e.position.dy - v.renderY;
        if (dx * dx + dy * dy < trigger * trigger) {
          localToRemove.add(e);
        }
      }
    }
    if (localToRemove.isNotEmpty) {
      sim.localEjected.removeWhere((e) => localToRemove.contains(e));
    }

    // ── server-broadcast ejected (other players' feed) ──
    // Only predict eating ENEMY feed locally. Our own feed is server-
    // authoritative: the local cell sits ahead of the server cell, so a
    // local "I caught my own feed" prediction routinely runs ahead of the
    // server and silently wipes feed that the server still has alive — the
    // visible symptom is "my feed pieces vanished for no reason". Letting
    // the server's rmEjected drive the removal of own feed eliminates the
    // false positive entirely while staying responsive for enemy feed.
    final serverToRemove = <String>[];
    for (final c in sim.cells) {
      if (c.mass < 22) continue;
      for (final e in world.ejected.values) {
        if (e.ownerId == selfId) continue;
        final eatR = c.radius + ejectedRadius;
        final dx = e.renderX - c.position.dx;
        final dy = e.renderY - c.position.dy;
        if (dx * dx + dy * dy < eatR * eatR) {
          if (c.mass < GameConstants.maxCellMass) {
            c.mass += GameConstants.ejectConsumedMass;
          }
          serverToRemove.add(e.id);
        }
      }
    }
    for (final id in serverToRemove) {
      world.ejected.remove(id);
    }
  }

  /// After [_localEjectedLifetimeMs], the server-broadcast copy of our own
  /// feed is fully visible via [V2World.ejected]. Drop the local-only one so
  /// we don't render it twice.
  void _expireLocalEjected() {
    if (sim.localEjected.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    sim.localEjected.removeWhere((e) =>
        nowMs - e.spawnTime.millisecondsSinceEpoch > _localEjectedLifetimeMs);
  }

  /// Predict cell-vs-cell eating, both directions:
  ///   • We eat an enemy → remove their cell locally, add their mass.
  ///     Tracked for ~1 s; if the server keeps reporting the cell alive in
  ///     subsequent snapshots we restore it (false-positive recovery).
  ///   • We get eaten → drop the local cell immediately. The next snapshot's
  ///     reconcile will confirm; if we mispredicted, the server-driven
  ///     rebuild restores the cell on the next snapshot.
  ///
  /// Uses MASS-based ratio (matches the server). Uses the server's
  /// authoritative target position for enemy cells (renderX/Y lags behind
  /// what the server thinks is happening, which would make us miss eats
  /// the server commits to).
  void _predictCellEating() {
    if (!sim.isInitialized || sim.cells.isEmpty) return;
    final selfId = _playerId;
    if (selfId == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // (a) we → eat → enemy
    final eaten = <String>[];
    for (final ours in sim.cells) {
      final ar = ours.radius;
      for (final enemy in world.cells.values) {
        if (enemy.ownerId == selfId) continue;
        if (eaten.contains(enemy.id)) continue;
        if (_locallyKilledEnemy.containsKey(enemy.id)) continue;
        if (ours.mass <= enemy.targetMass) continue;
        final ratio = ours.isFreshSplit ? 1.33 : 1.25;
        if (ours.mass < enemy.targetMass * ratio) continue;
        final br = math.sqrt(enemy.targetMass / math.pi) * 10;
        final eatR = ar - br * 0.4;
        if (eatR <= 0) continue;
        // Use targetX/Y (authoritative) — renderX/Y lags ~38 ms behind.
        final dx = enemy.targetX - ours.position.dx;
        final dy = enemy.targetY - ours.position.dy;
        if (dx * dx + dy * dy < eatR * eatR) {
          if (ours.mass < GameConstants.maxCellMass) {
            ours.mass = math.min(
              GameConstants.maxCellMass,
              ours.mass + enemy.targetMass,
            );
          }
          eaten.add(enemy.id);
        }
      }
    }
    for (final id in eaten) {
      final cell = world.cells.remove(id);
      if (cell != null) {
        // Stash so we can restore on mispredict.
        _locallyKilledEnemy[id] = cell;
        _locallyKilledExpiry[id] = nowMs + _locallyKilledTtlMs;
      }
    }

    // (b) enemy → eats → us
    final dead = <ge.Cell>[];
    for (final ours in sim.cells) {
      for (final enemy in world.cells.values) {
        if (enemy.ownerId == selfId) continue;
        if (enemy.targetMass <= ours.mass) continue;
        final ratio = enemy.freshSplit ? 1.33 : 1.25;
        if (enemy.targetMass < ours.mass * ratio) continue;
        final er = math.sqrt(enemy.targetMass / math.pi) * 10;
        final eatR = er - ours.radius * 0.4;
        if (eatR <= 0) continue;
        final dx = ours.position.dx - enemy.targetX;
        final dy = ours.position.dy - enemy.targetY;
        if (dx * dx + dy * dy < eatR * eatR) {
          dead.add(ours);
          break;
        }
      }
    }
    if (dead.isNotEmpty) {
      sim.player.cells.removeWhere(dead.contains);
    }
  }

  /// Predict virus pops locally so the cell shatter animation fires the
  /// instant our cell touches the virus, instead of waiting one RTT for the
  /// server to broadcast the new fragment cells.
  void _predictVirusPops() {
    if (!sim.isInitialized || sim.cells.isEmpty) return;
    final cells = [...sim.cells];
    final toPop = <String>[];
    for (final c in cells) {
      final cr = c.radius;
      for (final v in world.viruses.values) {
        if (_locallyPoppedViruses.contains(v.id)) continue;
        final vr = v.renderRadius;
        if (cr <= vr * 1.15) continue;
        final trigger = cr + vr * 0.2;
        final dx = v.renderX - c.position.dx;
        final dy = v.renderY - c.position.dy;
        if (dx * dx + dy * dy < trigger * trigger) {
          // Pop locally — reuse the sim's existing SplitHandler so the RNG
          // is stable and we don't allocate a fresh handler on every pop.
          final synthVirus = ge.Virus(id: v.id, position: Offset(v.renderX, v.renderY));
          sim.splitHandler.popVirus(sim.player, c, synthVirus);
          toPop.add(v.id);
          break;
        }
      }
    }
    for (final id in toPop) {
      _locallyPoppedViruses.add(id);
      world.viruses.remove(id);
    }
    if (toPop.isNotEmpty) {
      _lastVirusPopMs = DateTime.now().millisecondsSinceEpoch;
    }
    // Cap the set so it doesn't grow indefinitely — server confirms
    // pops within ~200 ms; 256 entries gives a few seconds of headroom.
    if (_locallyPoppedViruses.length > 256) {
      _locallyPoppedViruses.clear();
    }
  }

  // ──────────────────────────────────────────────────────── reconciliation
  /// Compare local self vs. server's view of self and apply the smallest
  /// correction that closes the gap.
  ///
  /// We never just "snap to server" for a tick or two of drift — that would
  /// produce visible rubberbanding even when the local sim is correct.
  /// Instead:
  ///   • count mismatch persists >threshold ticks → full rebuild
  ///   • count matches → lerp each local cell's position/mass toward the
  ///     best-matched server cell with a small factor per snapshot
  void _reconcileSelf(V2State s) {
    if (_playerId == null) return;
    if (_deadServerConfirmed) return;
    final serverCells = <V2WorldCell>[];
    for (final c in world.cells.values) {
      if (c.ownerId == _playerId) serverCells.add(c);
    }
    if (serverCells.isEmpty) {
      // Server has no view of us in this snapshot (out of viewport for
      // ourselves shouldn't happen) — skip.
      return;
    }
    if (_needsInitialSnap) {
      // First snapshot since welcome — accept the server's chosen spawn
      // point verbatim. Otherwise the placeholder mid-world spawn drifts
      // the local cell ~half a world away from where snapshots target.
      _rebuildLocalFromServer(serverCells);
      _needsInitialSnap = false;
      _countMismatchTicks = 0;
      return;
    }
    if (sim.cells.isEmpty) {
      // Local was empty but server says we have cells — rebuild from server.
      _rebuildLocalFromServer(serverCells);
      _countMismatchTicks = 0;
      return;
    }

    if (sim.cells.length != serverCells.length) {
      _countMismatchTicks++;
      final localAhead = sim.cells.length > serverCells.length;
      final hasPendingSplit =
          _pendingActions.any((p) => p.kind == 'split');
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final recentVirusPop = nowMs - _lastVirusPopMs < 500;

      // Decide how long to tolerate the count mismatch before snapping:
      //   • Pending split (local > server) ............ 20 ticks (~666 ms)
      //     — we just split, the new cells are en route through the server.
      //   • Recent virus pop (local > server) ......... 12 ticks (~400 ms)
      //     — we popped predictively, server hasn't broadcast fragments yet.
      //   • Otherwise local > server ..................  1 tick   (~33 ms)
      //     — almost certainly we just got eaten / server-side-merged. Snap
      //     to reality NOW so the player sees the death / merge in real time.
      //   • Local < server ............................  3 ticks (~100 ms)
      //     — server has cells we didn't predict; rebuild to catch up.
      final int tolerateTicks;
      if (localAhead) {
        if (hasPendingSplit) {
          tolerateTicks = 20;
        } else if (recentVirusPop) {
          tolerateTicks = 12;
        } else {
          tolerateTicks = 1;
        }
      } else {
        tolerateTicks = _countMismatchSnapThreshold; // 3
      }

      if (_countMismatchTicks >= tolerateTicks) {
        _rebuildLocalFromServer(serverCells);
        _countMismatchTicks = 0;
      }
      return;
    }
    _countMismatchTicks = 0;

    // Same cell count — pair each local cell with its NEAREST server cell
    // (capped to a reasonable radius) instead of by mass index. Mass-index
    // pairing fights split/merge cycles when two new cells start with the
    // same mass at very different positions.
    final usedServer = <V2WorldCell>{};
    for (final l in sim.cells) {
      V2WorldCell? best;
      double bestD2 = double.infinity;
      for (final r in serverCells) {
        if (usedServer.contains(r)) continue;
        final dx = r.targetX - l.position.dx;
        final dy = r.targetY - l.position.dy;
        final d2 = dx * dx + dy * dy;
        if (d2 < bestD2) {
          bestD2 = d2;
          best = r;
        }
      }
      if (best == null) continue;
      usedServer.add(best);
      // Don't pull across long distances — pairing is likely wrong if the
      // match is more than 400 u away (a split cell can drift faster than
      // that legitimately, so this guards against bad pairings only).
      final d = math.sqrt(bestD2);
      if (d > 400) continue;

      final dx = best.targetX - l.position.dx;
      final dy = best.targetY - l.position.dy;
      final massDelta = best.targetMass - l.mass;

      // Tiny drift: ignore — local sim is matching the server.
      if (d < 12 && massDelta.abs() < l.mass * 0.02) continue;

      // Medium drift: blend position gently, mass more aggressively.
      if (d < 220 && massDelta.abs() < l.mass * 0.15) {
        l.position = Offset(
          l.position.dx + dx * 0.14,
          l.position.dy + dy * 0.14,
        );
        l.mass += massDelta * 0.55;
        continue;
      }

      // Large drift: snap hard — prediction is meaningfully wrong.
      l.position = Offset(
        l.position.dx + dx * 0.55,
        l.position.dy + dy * 0.55,
      );
      l.mass += massDelta * 0.90;
    }

    // Total-mass correction: if local total diverges >8% from server-reported
    // mass, scale all cells proportionally. This catches accumulated pellet-
    // eating divergence that per-cell blending is too slow to close alone.
    if (s.self.mass > 0 && sim.cells.isNotEmpty) {
      final localTotal = sim.cells.fold(0.0, (acc, c) => acc + c.mass);
      final serverTotal = s.self.mass;
      final drift = (serverTotal - localTotal).abs();
      if (drift > localTotal * 0.08 && localTotal > 0) {
        final scale = serverTotal / localTotal;
        for (final c in sim.cells) {
          c.mass = (c.mass * scale).clamp(1.0, GameConstants.maxCellMass);
        }
      }
    }
  }

  void _rebuildLocalFromServer(List<V2WorldCell> serverCells) {
    final now = DateTime.now();
    final serverNow = world.lastServerNow;
    // To avoid the visible 1-frame "stop" of a wholesale clear+rebuild, we
    // preserve velocity / splitImpulse from the closest local cell when we
    // create the new authoritative cell. We pair greedily by ID first
    // (matches across confirmed snapshots), then by nearest position
    // (matches a local-only predicted split to its eventual server cell).
    final byId = <String, ge.Cell>{
      for (final c in sim.player.cells) c.id: c,
    };
    final leftover = <ge.Cell>[
      for (final c in sim.player.cells)
        if (!serverCells.any((s) => s.id == c.id)) c,
    ];

    final fresh = <ge.Cell>[];
    for (final s in serverCells) {
      final remainingMs = serverNow > 0
          ? (s.mergeReadyAtMs - serverNow).clamp(0, 28000)
          : (s.freshSplit ? 500 : 0);

      ge.Cell? donor = byId.remove(s.id);
      if (donor == null && leftover.isNotEmpty) {
        ge.Cell? best;
        double bestD2 = double.infinity;
        for (final c in leftover) {
          final dx = c.position.dx - s.targetX;
          final dy = c.position.dy - s.targetY;
          final d2 = dx * dx + dy * dy;
          if (d2 < bestD2) {
            bestD2 = d2;
            best = c;
          }
        }
        if (best != null && bestD2 < 400 * 400) {
          leftover.remove(best);
          donor = best;
        }
      }

      fresh.add(ge.Cell(
        id: s.id,
        ownerId: s.ownerId,
        position: Offset(s.targetX, s.targetY),
        mass: s.targetMass,
        color: s.color,
        name: s.name,
        mergeReadyAt: now.add(Duration(milliseconds: remainingMs)),
        isFreshSplit: s.freshSplit,
        // Donor carries the in-flight motion so the cell doesn't visually
        // stop the frame we rebuild it.
        velocity: donor?.velocity ?? Offset.zero,
        splitImpulse: donor?.splitImpulse ?? Offset.zero,
      ));
    }
    sim.player.cells
      ..clear()
      ..addAll(fresh);
  }

  // ──────────────────────────────────────────────────────── disposal
  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await client.dispose();
    super.dispose();
  }
}

class _PendingAction {
  _PendingAction(this.seq, this.kind);
  final int seq;
  final String kind;
}
