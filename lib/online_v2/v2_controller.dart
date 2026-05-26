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

  /// Hard cap on how many local pieces we keep alive simultaneously.
  /// At extreme feedSpeedMultiplier (up to 30 000 ejects/sec/cell) plus
  /// the ~ 1 s flight time before friction stops pieces, the steady-
  /// state population can reach low thousands. 2048 lets normal-to-fast
  /// micro stay continuously visible without the oldest pieces being
  /// dropped mid-flight — the cap is now only a safety net for
  /// pathological cases. Each piece is ~ 80 bytes, total ~ 160 KB which
  /// is comfortable on every supported phone.
  static const _localEjectedHardCap = 2048;
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

  /// Fires the moment death state transitions. The screen listens to this
  /// directly so it can toggle the death overlay / button-enabled state
  /// without subscribing the whole Stack to controller-wide notifyListeners
  /// (which would force a 30 Hz rebuild of every HUD element).
  final ValueNotifier<bool> deathListenable = ValueNotifier(false);

  /// Fires once per connection state change. Cheaper to listen to than the
  /// controller itself when all you care about is the chip color/text.
  final ValueNotifier<V2ConnState> connStateListenable =
      ValueNotifier(V2ConnState.idle);

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

  // ── input-replay reconciliation ───────────────────────────────────────
  // The agar.io-quality reconciliation pattern: snapshot the local sim's
  // step-by-step inputs each frame, then on every server snapshot:
  //   1. snap local cells to the authoritative server position
  //   2. replay every frame we've recorded since `ackSeq` was sent
  //   3. the resulting local cells reflect what the player sees NOW, with
  //      zero blend, zero rubber-banding, zero perpetual drift.
  /// Per-frame inputs since the most recent server-acked tick. Capped to
  /// 1.5 s at 60 Hz worth of frames. Oldest frames are evicted whenever
  /// the server acks past them.
  final List<_FrameInput> _frameHistory = [];
  static const _frameHistoryMaxLen = 96;
  /// Maps an outbound input sequence number to the wall-clock ms when we
  /// stamped it. We use this to find "the frame where the server's `ack`
  /// caught up to" — every later frame is what needs replaying.
  final Map<int, int> _seqStampMs = {};
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
    final gs = GameSettings.instance;
    await client.connect(
      playerName: _playerName,
      skin: skin,
      massMultiplier: massMultiplier,
      // Forward the player's eject tuning so the server-side physics
      // mirror the local sim — without this the server's copy of our
      // feed flies at the default speed/distance and visually drifts
      // away from the local rendering.
      ejectSpeedMultiplier: gs.ejectSpeedMultiplier,
      ejectDistanceMultiplier: gs.ejectDistanceMultiplier,
    );
  }

  void _onConnStateChanged(V2ConnState s) {
    _connState = s;
    connStateListenable.value = s;
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
      mass: 5000,
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
    // No notifyListeners — the screen's _hudTick + targeted listenables pick
    // up the new identity / mass on the next 100 ms beat. Welcome lands
    // before the first paint anyway, so there is no visible delay.
    deathListenable.value = false;
  }

  void _onPong(V2Pong p) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _pingMs = (now - p.clientT).clamp(0, 5000);
    // Adaptive interpolation delay. Baseline 95 ms (≈ 3 server ticks) covers
    // typical packet jitter on a stable connection. On a laggier link we add
    // a fraction of the ping so the buffer always holds two real snapshots
    // even when arrival times jitter. Cap at 240 ms so the visual lag stays
    // sub-perceptible.
    world.interpDelayMs = (95 + (_pingMs ~/ 4)).clamp(95, 240);
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
    // Own ejected feed is rendered OFFLINE-STYLE from sim.localEjected for
    // the whole flight. The server still mirrors our pieces (so other
    // players see them) but we DO NOT FIFO-match local↔server, we DO NOT
    // seed render positions, and the painter SKIPS world.ejected entries
    // where ownerId == selfId. Reasoning:
    //   • Server RNG ≠ client RNG, so the server's piece flies on a
    //     slightly different path/speed. The handoff used to look like
    //     a tiny stutter every snapshot.
    //   • The 110 ms snapshot interp delay made the server copy lag
    //     behind the local one, producing a visible "speed-brake" the
    //     moment FIFO match swapped them.
    //   • All consumption (cell eats own feed, enemy eats own feed,
    //     virus eats own feed) is detected locally against
    //     sim.localEjected, so the local copy is authoritative for the
    //     owner's view.
    world.applySnapshot(s);
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

    // ChangeNotifier broadcast is intentionally OMITTED here. The whole HUD
    // tree used to subscribe to us via Listenable.merge([gs, _ctrl]) and got
    // rebuilt 30 Hz — that was the single biggest source of jank on mobile.
    // Death is the only thing that needs sub-frame UI reaction, and it goes
    // through deathListenable below. Everything else (mass, ping, leaderboard,
    // online count) is refreshed by the screen's 10 Hz _hudTick which is
    // plenty fast for human perception of HUD numbers.
    final wantDeathUi = isDead;
    if (deathListenable.value != wantDeathUi) {
      deathListenable.value = wantDeathUi;
    }
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
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _seqStampMs[client.lastSentSeq] = nowMs;
    _pendingActions.add(_PendingAction(client.lastSentSeq, 'split', nowMs, aim));
    // Tag the current frame record so input-replay re-fires the split when
    // we rewind to before this seq.
    if (_frameHistory.isNotEmpty) {
      _frameHistory.last
        ..splitFired = true
        ..splitAim = aim;
    }
  }

  void doEject() {
    if (_deadServerConfirmed) return;
    final aim = _moveDir.distance > 0.05 ? _moveDir : _lastDir;
    sim.doEject(aim);
    // The offline EjectHandler fires `burst` ejects per cell per call (driven
    // by feedSpeedMultiplier). The server must do the same number per packet
    // — otherwise local mass drops further than server confirms, and the
    // reconcile snaps it back (visible as "mass disappearing" then refilling).
    // Cap 30 matches the server-side clamp so the network rate stays bounded
    // even at extreme feedSpeedMultiplier values.
    final burst = (GameSettings.instance.feedSpeedMultiplier / 10)
        .floor()
        .clamp(1, 30);
    client.sendEject(count: burst);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _seqStampMs[client.lastSentSeq] = nowMs;
    _pendingActions.add(_PendingAction(client.lastSentSeq, 'eject', nowMs, aim));
    if (_frameHistory.isNotEmpty) {
      _frameHistory.last
        ..ejectBurst = burst
        ..ejectAim = aim;
    }
  }

  void respawn() {
    if (!_deadServerConfirmed) return;
    client.sendRespawn();
  }

  // ──────────────────────────────────────────────────────── frame tick
  // Prediction throttle — eating predictions (pellet, ejected) MUST run
  // every frame because they gate visible feedback: a missed collision in
  // a single 16 ms frame = "the dot's under my cell but it isn't being
  // eaten". The heavier topology-changing predictions (virus pop, cell-
  // vs-cell) can safely run at 30 Hz — collision radii for those are 5–
  // 10× larger so a 33 ms skip never misses a hit.
  int _predictFrameCounter = 0;
  /// Drive simulation + interpolation + input send. Call from the screen's
  /// per-frame ticker.
  void tick(double dt) {
    if (dt <= 0) return;

    final nowMsFrame = DateTime.now().millisecondsSinceEpoch;
    // Open a NEW frame record FIRST so doSplit / doEject called between
    // ticks can tag it. The split / eject button taps that fire on this
    // frame will be appended to this record before it is closed.
    _frameHistory.add(_FrameInput(
      stampMs: nowMsFrame,
      dt: dt,
      moveDir: _moveDir,
      attack: _attackMode,
      lastDir: _lastDir,
    ));
    if (_frameHistory.length > _frameHistoryMaxLen) {
      _frameHistory.removeAt(0);
    }

    // 1. Local sim step (movement, cohesion, separation, integrate, eject,
    //    merge, auto-split cap). Mirrors Offline Classic 1:1. This MUST
    //    run every frame — it owns the local cell's position which the
    //    camera follows; throttling it would visibly cap the input rate.
    sim.step(dt, world: world);

    // Eating predictions run EVERY frame so a fast cell never passes over
    // food without consuming it.
    _predictPelletEating();
    _predictEjectedEating();
    _expireLocalEjected();

    // Heavy topology predictions alternate frames (≈ 30 Hz on a 60 Hz
    // device).
    final runHeavy = (_predictFrameCounter++ & 1) == 0;
    if (runHeavy) {
      _predictVirusPops();
    }

    // 6. Snapshot-buffer interpolation for every remote entity. Render time
    //    is `now - interpDelayMs` so we always interpolate between two real
    //    samples instead of chasing the latest one with exponential decay
    //    (which trails the target and visibly jitters on variable latency).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    world.tickRender(nowMs);

    // 7. Throttled input send to the server. Stamp the resulting seq so
    //    when the server's snapshot acks this seq we know which frame to
    //    rewind to for input replay.
    if (nowMs - _lastInputSendMs >= _inputIntervalMs) {
      _lastInputSendMs = nowMs;
      if (client.isConnected) {
        client.sendInput(
          dx: _moveDir.dx,
          dy: _moveDir.dy,
          attack: _attackMode,
        );
        _seqStampMs[client.lastSentSeq] = nowMs;
      }
    }

    // Intentionally NOT calling notifyListeners() per tick. The screen drives
    // the painter via its own per-frame ValueNotifier(_frame) and only needs
    // ChangeNotifier wake-ups on real state changes (snapshot, welcome,
    // connection change, death). Rebuilding the HUD subtree at 60 Hz was a
    // major source of jank on mid-tier mobile devices.
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

  /// Local cell-vs-ejected eating, for both our locally-spawned feed
  /// and the server-broadcast ejected from other players. Mirrors the
  /// offline rule: a cell needs mass >= 22, then anything inside the
  /// touch radius gets consumed (200 ms owner-immunity on own pieces).
  void _predictEjectedEating() {
    if (!sim.isInitialized || sim.cells.isEmpty) return;
    final selfId = _playerId;
    if (selfId == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ejectedRadius = math.sqrt(13 / math.pi) * 10;

    // ── local-only ejected (our own feed) ──
    final localToRemove = <EjectedMass>[];
    // Per-cell per-frame cap raised to 30 (was 6) so re-eating a
    // micro-feed cluster doesn't feel slow. At 60 Hz that's 1800
    // eats/sec/cell which is well above the realistic feed rate. The
    // cap still prevents the pathological 1000-piece-in-one-frame
    // mass jump to max, but normal play eats every piece in range
    // each frame.
    const eatsPerCellPerFrame = 30;
    for (final c in sim.cells) {
      if (c.mass < 22) continue;
      final cX = c.position.dx;
      final cY = c.position.dy;
      final eatR = c.radius + ejectedRadius;
      final eatR2 = eatR * eatR;
      int eatsThisFrame = 0;
      for (final e in sim.localEjected) {
        if (eatsThisFrame >= eatsPerCellPerFrame) break;
        if (localToRemove.contains(e)) continue;
        final dx = e.position.dx - cX;
        // AABB pre-cull avoids a sqrt+immunity-age check when the
        // piece is obviously outside the eat box. Cuts the per-frame
        // hot-loop cost by ~ 70 % when 1000+ pieces are alive.
        if (dx > eatR || dx < -eatR) continue;
        final dy = e.position.dy - cY;
        if (dy > eatR || dy < -eatR) continue;
        final age = nowMs - e.spawnTime.millisecondsSinceEpoch;
        if (e.ownerId == c.ownerId && age < 200) continue;
        if (dx * dx + dy * dy < eatR2) {
          if (c.mass < GameConstants.maxCellMass) {
            c.mass += GameConstants.ejectConsumedMass;
          }
          localToRemove.add(e);
          eatsThisFrame++;
        }
      }
    }
    // Enemy cells eating MY local feed — strict overlap (piece > 50 %
    // inside cell). The lenient touch-circles rule fired false eats off
    // the render-lagged enemy position.
    for (final c in world.cells.values) {
      if (c.isSelf) continue;
      if (c.targetMass < 22) continue;
      final cRadius = c.renderRadius;
      final eatR = cRadius - ejectedRadius * 0.4;
      if (eatR <= 0) continue;
      final cX = c.renderX;
      final cY = c.renderY;
      final eatR2 = eatR * eatR;
      for (final e in sim.localEjected) {
        if (localToRemove.contains(e)) continue;
        final dx = e.position.dx - cX;
        if (dx > eatR || dx < -eatR) continue;
        final dy = e.position.dy - cY;
        if (dy > eatR || dy < -eatR) continue;
        if (dx * dx + dy * dy < eatR2) {
          localToRemove.add(e);
        }
      }
    }
    // Viruses eating MY local feed.
    for (final v in world.viruses.values) {
      final vRadius = v.renderRadius;
      for (final e in sim.localEjected) {
        if (localToRemove.contains(e)) continue;
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

    // ── server-broadcast ejected (ENEMY feed only — own server-mirrored
    // pieces are filtered from the painter so eating them locally would
    // remove invisible entries) ──
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

  /// With the offline-style approach there is no time-based lifetime —
  /// local pieces live until something physically consumes them (cell,
  /// virus, enemy), exactly like Offline Classic. The hard cap is the
  /// only safety net so a runaway feed loop can't grow the list
  /// unbounded; we drop the OLDEST pieces (they've travelled the
  /// furthest and are most likely already off-screen anyway).
  void _expireLocalEjected() {
    if (sim.localEjected.length > _localEjectedHardCap) {
      sim.localEjected.removeRange(
        0,
        sim.localEjected.length - _localEjectedHardCap,
      );
    }
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

    // (a) we → eat → enemy.
    //
    // No per-cell cap any more — capping at 2 made multi-enemy combos
    // feel slow ("بطيئ كتير لياكل"). All enemies inside the eat
    // radius get consumed in the same predict pass, matching what the
    // server will compute and what the player visually expects when
    // they land in a cluster.
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
      //   • Pending split (local > server) ............ 60 ticks (~2 s)
      //     — we just split, the new cells are en route. Was 20 ticks
      //     (666 ms); under heavy load (dev mass + micro feed) the
      //     server's tick budget overruns delayed split acks past the
      //     666 ms threshold, which fired a rebuild that visibly
      //     "shrank" the freshly-split cells back into one.
      //   • Recent virus pop (local > server) ......... 30 ticks (~1 s)
      //     — we popped predictively, server hasn't broadcast fragments yet.
      //   • Otherwise local > server ..................  1 tick   (~33 ms)
      //     — almost certainly we just got eaten / server-side-merged. Snap
      //     to reality NOW so the player sees the death / merge in real time.
      //   • Local < server ............................  3 ticks (~100 ms)
      //     — server has cells we didn't predict; rebuild to catch up.
      final int tolerateTicks;
      if (localAhead) {
        if (hasPendingSplit) {
          tolerateTicks = 60;
        } else if (recentVirusPop) {
          tolerateTicks = 30;
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

    // ─────────────────────── trust-local reconciliation ───────────────
    // Cell counts match. For the local player's own cells we DO NOT touch
    // position — the local sim is the source of truth for "where am I" so
    // the joystick produces zero-lag motion. The server is still the
    // source of truth for:
    //   • Catastrophic divergence (we missed a virus pop, world boundary
    //     bounce, etc.) → snap-rebuild past a wide tolerance.
    //   • Total mass drift (pellet eating prediction is approximate) →
    //     gentle scaling.
    //   • Discrete events (death, respawn, split count) — those still go
    //     through the count-mismatch tolerate path above.
    //
    // The previous "snap + input replay" approach matched server exactly
    // but each replay re-ran the local EjectHandler RNG with fresh seeds,
    // which made feed pieces and split impulses jitter once per snapshot.
    // Trust-local restores the buttery-smooth single-player feel.
    double maxDrift2 = 0;
    for (final l in sim.cells) {
      V2WorldCell? nearest;
      double bestD2 = double.infinity;
      for (final r in serverCells) {
        final dx = r.targetX - l.position.dx;
        final dy = r.targetY - l.position.dy;
        final d2 = dx * dx + dy * dy;
        if (d2 < bestD2) {
          bestD2 = d2;
          nearest = r;
        }
      }
      if (nearest != null && bestD2 > maxDrift2) {
        maxDrift2 = bestD2;
      }
    }

    // 800 u tolerance — was 350 u, but a fresh split at high mass
    // routinely drifted 300-400 u within a single RTT (cells flying at
    // 1500 u/s impulse while server is still processing the split),
    // triggering a position rebuild that snapped the local cells back
    // to where the server thinks they "should" be. That's the
    // rubber-band the player reported. 800 u only catches a genuine
    // physics divergence (missed virus pop, off-screen kill, …)
    // without firing on normal play.
    const hardSnapDrift = 800.0;
    if (maxDrift2 > hardSnapDrift * hardSnapDrift) {
      _rebuildLocalFromServer(serverCells);
    }

    // SMOOTH mass convergence — DEAD-SLOW so the player never sees
    // a "cell suddenly bigger / smaller" jump. Lerps 2 % of the gap
    // per snapshot, capped at 1.5 % of the cell's current mass per
    // snapshot. Even a worst-case drift of +10 K mass (a server-side
    // virus pop we never predicted) converges over ~ 2 seconds of
    // sub-perceptible growth instead of a 1-frame snap.
    if (s.self.mass > 0 && sim.cells.isNotEmpty) {
      final localTotal = sim.cells.fold(0.0, (acc, c) => acc + c.mass);
      final serverTotal = s.self.mass;
      if (localTotal > 0) {
        final relDrift = (serverTotal - localTotal).abs() / localTotal;
        if (relDrift > 0.01) {
          var desired = (serverTotal - localTotal) * 0.02;
          final cap = localTotal * 0.015;
          if (desired > cap) desired = cap;
          if (desired < -cap) desired = -cap;
          final targetTotal = localTotal + desired;
          final scale = targetTotal / localTotal;
          for (final c in sim.cells) {
            c.mass = (c.mass * scale).clamp(1.0, GameConstants.maxCellMass);
          }
        }
      }
    }

    // Trim stamp map so it doesn't grow unbounded.
    _seqStampMs.removeWhere((seq, _) => seq <= s.ackSeq);
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

      // Use the LOCAL mass entirely when a donor exists — never let
      // rebuild change a cell's size, in either direction. Both
      // directions would produce a visible "pop" (shrink or grow) the
      // moment rebuild fires, which is the most jarring split glitch
      // the player notices. Only brand-new server cells with no
      // donor (e.g. a server-side virus pop we missed predicting) use
      // the server's mass since we have no local reference. Smooth
      // mass-scale below will reconcile any drift gradually.
      final keepMass = donor?.mass ?? s.targetMass;
      final cell = ge.Cell(
        id: s.id,
        ownerId: s.ownerId,
        position: Offset(s.targetX, s.targetY),
        mass: keepMass,
        color: s.color,
        name: s.name,
        mergeReadyAt: now.add(Duration(milliseconds: remainingMs)),
        isFreshSplit: s.freshSplit,
        // Donor carries the in-flight motion so the cell doesn't visually
        // stop the frame we rebuild it.
        velocity: donor?.velocity ?? Offset.zero,
        splitImpulse: donor?.splitImpulse ?? Offset.zero,
      );
      // Preserve visual animation state across the rebuild — bumps decay
      // smoothly from collisions and wobblePhase drives the jelly idle
      // animation. Without preserving them the cell would visually
      // "snap" back to a perfect disc every 33 ms.
      if (donor != null) {
        cell.bumps.addAll(donor.bumps);
        cell.wobblePhase = donor.wobblePhase;
      }
      fresh.add(cell);
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
    deathListenable.dispose();
    connStateListenable.dispose();
    super.dispose();
  }
}

class _PendingAction {
  _PendingAction(this.seq, this.kind, this.stampMs, this.aim);
  final int seq;
  final String kind; // 'split' | 'eject'
  final int stampMs;
  final Offset aim;
}

/// One frame's worth of input + simulation parameters. Replaying these in
/// order from the server-confirmed cell state reproduces the local sim's
/// current state — that's what gives the player zero-lag prediction
/// without rubber-banding when the server's view differs.
class _FrameInput {
  _FrameInput({
    required this.stampMs,
    required this.dt,
    required this.moveDir,
    required this.attack,
    required this.lastDir,
  });
  final int stampMs;
  final double dt;
  final Offset moveDir;
  final bool attack;
  final Offset lastDir;
  // Discrete actions fired DURING this frame (set immediately when
  // doSplit / doEject runs, before the frame record is closed).
  bool splitFired = false;
  Offset splitAim = Offset.zero;
  int ejectBurst = 0;
  Offset ejectAim = Offset.zero;
}
