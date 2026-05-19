/// World cache for Online Classic V2.
///
/// Owns the client-side mirror of every server-authoritative entity that
/// isn't the local player. Each entity carries a *target* (the value most
/// recently received from the server) and a *render* value that the
/// controller smooths toward the target every frame — that's the only thing
/// that prevents stutter from a 30 Hz snapshot stream.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'net/v2_packets.dart';

Color _parseHex(String hex) {
  var h = hex.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return Color(v ?? 0xFFFFFFFF);
}

/// One remote (non-local) cell as the renderer needs it.
class V2WorldCell {
  V2WorldCell({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.color,
    required this.skinId,
    required this.isHuman,
    required this.isSelf,
    required double initialX,
    required double initialY,
    required double initialMass,
    required this.freshSplit,
    required this.mergeReadyAtMs,
  })  : targetX = initialX,
        targetY = initialY,
        targetMass = initialMass,
        renderX = initialX,
        renderY = initialY,
        renderMass = initialMass;

  final String id;
  final String ownerId;
  final String name;
  final Color color;
  final String skinId;
  final bool isHuman;
  final bool isSelf;
  int mergeReadyAtMs;
  bool freshSplit;

  double targetX, targetY, targetMass;
  double renderX, renderY, renderMass;

  double get renderRadius => math.sqrt(renderMass / math.pi) * 10;

  void applyUpdate(V2UpdCell u) {
    targetX = u.x;
    targetY = u.y;
    targetMass = u.mass;
    freshSplit = u.freshSplit;
  }

  /// Exponentially smooth render position toward target. [dt] is seconds.
  /// At [smoothing] = 18 the half-life is ~38 ms — fast enough to look real,
  /// slow enough to swallow per-tick jitter.
  void tick(double dt, {double smoothing = 18}) {
    final f = 1 - math.exp(-smoothing * dt);
    renderX += (targetX - renderX) * f;
    renderY += (targetY - renderY) * f;
    renderMass += (targetMass - renderMass) * f;
  }
}

class V2WorldPellet {
  V2WorldPellet({
    required this.id,
    required this.x,
    required this.y,
    required this.color,
  });
  final String id;
  final double x;
  final double y;
  final Color color;
}

class V2WorldVirus {
  V2WorldVirus({
    required this.id,
    required double initialX,
    required double initialY,
    required this.mass,
  })  : targetX = initialX,
        targetY = initialY,
        renderX = initialX,
        renderY = initialY;
  final String id;
  double mass;
  double targetX, targetY;
  double renderX, renderY;
  double get renderRadius => math.sqrt(mass / math.pi) * 10;

  void tick(double dt, {double smoothing = 12}) {
    final f = 1 - math.exp(-smoothing * dt);
    renderX += (targetX - renderX) * f;
    renderY += (targetY - renderY) * f;
  }
}

class V2WorldEjected {
  V2WorldEjected({
    required this.id,
    required double initialX,
    required double initialY,
    required this.color,
    required this.ownerId,
    required this.addedAt,
  })  : targetX = initialX,
        targetY = initialY,
        renderX = initialX,
        renderY = initialY;
  final String id;
  final Color color;
  final String ownerId;
  final int addedAt; // ms timestamp when this entry was added to world
  double targetX, targetY;
  double renderX, renderY;

  void tick(double dt, {double smoothing = 22}) {
    final f = 1 - math.exp(-smoothing * dt);
    renderX += (targetX - renderX) * f;
    renderY += (targetY - renderY) * f;
  }
}

/// All server-authoritative state outside the local player. Mutated by
/// [applySnapshot]; the controller ticks render positions via [tickRender].
class V2World {
  final Map<String, V2WorldCell> cells = {};
  final Map<String, V2WorldPellet> pellets = {};
  final Map<String, V2WorldVirus> viruses = {};
  final Map<String, V2WorldEjected> ejected = {};

  /// Pellets the local prediction sim ate. Server will eventually confirm via
  /// `rmPellets`. Keyed by pellet id, value is the wall-clock ms at which the
  /// entry expires — if the server never confirms within ~2 s we evict it so
  /// the cache can't grow unbounded.
  final Map<String, int> locallyEatenPellets = {};
  static const _locallyEatenTtlMs = 2000;

  int lastServerTick = -1;
  int lastServerNow = 0;
  int lastAckSeq = 0;

  String selfId = '';

  /// Apply one snapshot to the world. Old snapshots (lower [serverTick]) are
  /// dropped — UDP-style out-of-order delivery never matters on a TCP socket
  /// but the tick check is cheap and keeps the invariant explicit.
  void applySnapshot(V2State s) {
    if (s.serverTick <= lastServerTick) return;
    lastServerTick = s.serverTick;
    lastServerNow = s.serverNow;
    lastAckSeq = s.ackSeq;

    // ── cells ──
    for (final c in s.addCells) {
      cells[c.id] = V2WorldCell(
        id: c.id,
        ownerId: c.ownerId,
        name: c.name,
        color: _parseHex(c.colorHex),
        skinId: c.skinId,
        isHuman: c.isHuman,
        isSelf: c.ownerId == selfId,
        initialX: c.x,
        initialY: c.y,
        initialMass: c.mass,
        freshSplit: c.freshSplit,
        mergeReadyAtMs: c.mergeReadyAt,
      );
    }
    for (final u in s.updCells) {
      cells[u.id]?.applyUpdate(u);
    }
    for (final id in s.rmCells) {
      cells.remove(id);
    }

    // ── pellets ──
    for (final p in s.addPellets) {
      // Server respawns are always brand-new IDs, so a hit in the "locally
      // eaten" cache for *this* id means we hallucinated an eat that the
      // server never confirmed. Drop the local prediction silently.
      if (locallyEatenPellets.containsKey(p.id)) continue;
      pellets[p.id] = V2WorldPellet(
        id: p.id,
        x: p.x,
        y: p.y,
        color: _parseHex(p.colorHex),
      );
    }
    for (final id in s.rmPellets) {
      pellets.remove(id);
      locallyEatenPellets.remove(id);
    }

    // ── viruses ──
    for (final v in s.addViruses) {
      viruses[v.id] = V2WorldVirus(
        id: v.id,
        initialX: v.x,
        initialY: v.y,
        mass: v.mass,
      );
    }
    for (final u in s.updViruses) {
      final v = viruses[u.id];
      if (v == null) continue;
      v.targetX = u.x;
      v.targetY = u.y;
      v.mass = u.mass;
    }
    for (final id in s.rmViruses) {
      viruses.remove(id);
    }

    // ── ejected ──
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final e in s.addEjected) {
      ejected[e.id] = V2WorldEjected(
        id: e.id,
        initialX: e.x,
        initialY: e.y,
        color: _parseHex(e.colorHex),
        ownerId: e.ownerId,
        addedAt: nowMs,
      );
    }
    for (final u in s.updEjected) {
      final e = ejected[u.id];
      if (e == null) continue;
      e.targetX = u.x;
      e.targetY = u.y;
    }
    for (final id in s.rmEjected) {
      ejected.remove(id);
    }
  }

  /// Mark a pellet as "ate locally". Removes it from the visible cache
  /// immediately and records the id so the next snapshot can't accidentally
  /// re-add it via `addPellets`.
  void markPelletLocallyEaten(String id) {
    pellets.remove(id);
    locallyEatenPellets[id] =
        DateTime.now().millisecondsSinceEpoch + _locallyEatenTtlMs;
  }

  /// Decay smoothing for every render-position-tracked entity, expire the
  /// locally-eaten cache. Call this every frame.
  void tickRender(double dt) {
    for (final c in cells.values) {
      c.tick(dt);
    }
    for (final v in viruses.values) {
      v.tick(dt);
    }
    for (final e in ejected.values) {
      e.tick(dt);
    }
    if (locallyEatenPellets.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      locallyEatenPellets.removeWhere((_, exp) => exp <= now);
    }
  }

  void clear() {
    cells.clear();
    pellets.clear();
    viruses.clear();
    ejected.clear();
    locallyEatenPellets.clear();
    lastServerTick = -1;
  }
}
