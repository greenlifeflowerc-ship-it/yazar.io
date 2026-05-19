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
import '../game/mechanics/split_handler.dart';
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
  static const _localEjectedLifetimeMs = 500;
  /// Local prediction window for virus pops, used to suppress accidental
  /// re-pop of the same virus across two ticks before the server confirms.
  final Set<String> _locallyPoppedViruses = {};

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

  /// After `welcome` we spawn the local sim at world center as a placeholder
  /// — the server's actual chosen spawn point arrives one tick later.
  /// This flag forces a HARD snap on the first snapshot so the camera and
  /// the local cell land where the server thinks we are; without it the
  /// reconcile loop's 400 u distance cap would refuse to close the gap.
  bool _needsInitialSnap = false;

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
    _needsInitialSnap = true;
    _countMismatchTicks = 0;
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
      // Server respawned us. Snap to server-reported center of mass — and
      // re-arm the initial-snap path so the next reconcile rebuilds cells
      // straight from the authoritative addCells (not a single seed cell).
      sim.respawn(position: Offset(s.self.cmX, s.self.cmY), mass: s.self.mass);
      _needsInitialSnap = true;
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

    // 3. Predict eating of local-spawned feed (own cells absorbing own feed)
    //    and of server-side feed in viewport. Also expire stale local feed
    //    so it doesn't pile up after server's authoritative copy takes over.
    _predictEjectedEating();
    _expireLocalEjected();

    // 4. Predict virus pops. The server is authoritative but waiting a full
    //    RTT for the cell explosion makes the action feel rubbery, so we run
    //    the same SplitHandler.popVirus locally.
    _predictVirusPops();

    // 5. Smooth render positions of every remote-authoritative entity.
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
    for (final c in sim.cells) {
      if (c.mass < 22) continue;
      for (final e in sim.localEjected) {
        final age = nowMs - e.spawnTime.millisecondsSinceEpoch;
        if (e.ownerId == c.ownerId && age < 200) continue;
        final eatR = c.radius - e.radius * 0.4;
        if (eatR <= 0) continue;
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
    if (localToRemove.isNotEmpty) {
      sim.localEjected
          .removeWhere((e) => localToRemove.contains(e));
    }

    // ── server-broadcast ejected (other players' feed) ──
    // Skip ejected that belong to our own cells for the first 200 ms so our
    // own feed doesn't get self-eaten the moment the server confirms it.
    final serverToRemove = <String>[];
    for (final c in sim.cells) {
      if (c.mass < 22) continue;
      for (final e in world.ejected.values) {
        if (e.ownerId == selfId && nowMs - e.addedAt < 200) continue;
        final eatR = c.radius - ejectedRadius * 0.4;
        if (eatR <= 0) continue;
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
          // Pop locally — reuse the offline SplitHandler so fragment
          // distribution and merge cooldowns match the server bit-for-bit.
          final synthVirus = ge.Virus(id: v.id, position: Offset(v.renderX, v.renderY));
          SplitHandler(sim.engine, math.Random()).popVirus(sim.player, c, synthVirus);
          toPop.add(v.id);
          break;
        }
      }
    }
    for (final id in toPop) {
      _locallyPoppedViruses.add(id);
      world.viruses.remove(id);
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
      // We almost always have MORE cells locally for ~1 RTT (after a split,
      // a virus pop, or before the server has processed an upcoming merge),
      // or FEWER for ~1 RTT (after a local merge). Both are harmless — the
      // server catches up within a snapshot or two. Only rebuild when we
      // have STRICTLY FEWER cells than the server for an extended window,
      // which means we missed a real event (eaten by another player,
      // ate a virus we didn't predict, etc.).
      if (sim.cells.length < serverCells.length) {
        _countMismatchTicks++;
        if (_countMismatchTicks >= _countMismatchSnapThreshold) {
          _rebuildLocalFromServer(serverCells);
          _countMismatchTicks = 0;
        }
      } else {
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
