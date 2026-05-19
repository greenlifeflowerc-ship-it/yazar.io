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
import '../game/game_engine.dart';
import '../game/skin_settings.dart';
import 'net/v2_packets.dart';
import 'net/v2_socket_client.dart';
import 'v2_local_sim.dart';
import 'v2_world.dart';

class V2Controller extends ChangeNotifier {
  V2Controller({V2SocketClient? client}) : client = client ?? V2SocketClient();

  final V2SocketClient client;
  final V2World world = V2World();
  final V2LocalSim sim = V2LocalSim();

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
  static const _countMismatchSnapThreshold = 6; // ~200 ms at 30 Hz

  // ── streams ───────────────────────────────────────────────────────────
  late final List<StreamSubscription<dynamic>> _subs;

  // ── lifecycle ─────────────────────────────────────────────────────────
  Future<void> connect({required String playerName, String skin = ''}) async {
    _playerName = playerName.trim().isEmpty ? 'Player' : playerName.trim();
    _subs = [
      client.welcomes.listen(_onWelcome),
      client.snapshots.listen(_onSnapshot),
      client.pongs.listen(_onPong),
      client.stateChanges.listen(_onConnStateChanged),
    ];
    await client.connect(playerName: _playerName, skin: skin);
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
      // Server respawned us. Snap to server-reported center of mass.
      sim.respawn(position: Offset(s.self.cmX, s.self.cmY), mass: s.self.mass);
    }

    _reconcileSelf(s);
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────── input plumbing
  void setMoveDir(Offset d) {
    // Clamp to the unit disc.
    final m = d.distance;
    final clamped = m > 1 ? d / m : d;
    _moveDir = clamped;
    if (clamped.distance > 0.05) _lastDir = clamped;
    sim.moveDir = clamped;
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
    client.sendEject();
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
    sim.step(dt);

    // 2. Predict pellet eating against the current world cache.
    _predictPelletEating();

    // 3. Smooth render positions of every remote-authoritative entity.
    world.tickRender(dt);

    // 4. Throttled input send to the server.
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
    if (sim.cells.isEmpty) return;
    // Snapshot ids so we don't mutate the map while iterating.
    final toEat = <String>[];
    for (final c in sim.cells) {
      final r = c.radius;
      final rSq = r * r;
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
    if (sim.cells.isEmpty) {
      // Local was empty but server says we have cells — rebuild from server.
      _rebuildLocalFromServer(serverCells);
      _countMismatchTicks = 0;
      return;
    }

    if (sim.cells.length != serverCells.length) {
      _countMismatchTicks++;
      if (_countMismatchTicks >= _countMismatchSnapThreshold) {
        _rebuildLocalFromServer(serverCells);
        _countMismatchTicks = 0;
      }
      return;
    }
    _countMismatchTicks = 0;

    // Same cell count — pair by descending mass and blend per pair.
    final localSorted = [...sim.cells]
      ..sort((a, b) => b.mass.compareTo(a.mass));
    final serverSorted = [...serverCells]
      ..sort((a, b) => b.targetMass.compareTo(a.targetMass));

    for (int i = 0; i < localSorted.length; i++) {
      final l = localSorted[i];
      final r = serverSorted[i];
      final dx = r.targetX - l.position.dx;
      final dy = r.targetY - l.position.dy;
      final d = math.sqrt(dx * dx + dy * dy);
      final massDelta = r.targetMass - l.mass;

      // Tiny drift: ignore — local sim is matching the server.
      if (d < 12 && massDelta.abs() < l.mass * 0.02) continue;

      // Medium drift: gentle blend (12 % position, 30 % mass per snapshot).
      if (d < 220 && massDelta.abs() < l.mass * 0.15) {
        l.position = Offset(
          l.position.dx + dx * 0.12,
          l.position.dy + dy * 0.12,
        );
        l.mass += massDelta * 0.30;
        continue;
      }

      // Large drift: harder blend (45 % / 60 %). At this point our local
      // prediction is meaningfully wrong (lost packets, ate something we
      // didn't expect, etc.) so we close it fast — but still smoothly.
      l.position = Offset(
        l.position.dx + dx * 0.45,
        l.position.dy + dy * 0.45,
      );
      l.mass += massDelta * 0.60;
    }
  }

  void _rebuildLocalFromServer(List<V2WorldCell> serverCells) {
    sim.player.cells.clear();
    final now = DateTime.now();
    for (final s in serverCells) {
      sim.player.cells.add(ge.Cell(
        id: s.id,
        ownerId: s.ownerId,
        position: Offset(s.targetX, s.targetY),
        mass: s.targetMass,
        color: s.color,
        name: s.name,
        mergeReadyAt: s.freshSplit
            ? now.add(const Duration(milliseconds: 200))
            : now,
        isFreshSplit: s.freshSplit,
      ));
    }
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
