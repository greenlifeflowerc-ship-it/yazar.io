/// World cache for Online Classic V2.
///
/// Owns the client-side mirror of every server-authoritative entity that
/// isn't the local player. Each remote entity keeps a short ring of recent
/// server samples (prev + new) plus the wall-clock time they arrived. The
/// renderer plays the world back at `nowMs - interpDelay` so it always
/// interpolates between two KNOWN samples — that smooths out per-snapshot
/// jitter the way Source-engine clients do for agar.io-style games.
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
///
/// Holds two samples in addition to the live render value:
///   • prev*  — the previous server snapshot for this cell
///   • new*   — the latest server snapshot for this cell (= "target")
/// The renderer linearly interpolates between them based on
/// `(renderAtMs - prevRecvAt) / (newRecvAt - prevRecvAt)`. If `renderAtMs`
/// goes past `newRecvAt` we extrapolate up to a small budget so a single
/// dropped packet doesn't freeze the entity.
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
    required int recvAtMs,
  })  : prevX = initialX,
        prevY = initialY,
        prevMass = initialMass,
        prevRecvAt = recvAtMs,
        newX = initialX,
        newY = initialY,
        newMass = initialMass,
        newRecvAt = recvAtMs,
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

  // Snapshot buffer (prev + new).
  double prevX, prevY, prevMass;
  int prevRecvAt;
  double newX, newY, newMass;
  int newRecvAt;

  // Render-time interpolated values consumed by the painter.
  double renderX, renderY, renderMass;

  // Aliases kept for the controller's reconcile code, which targets the
  // authoritative server state regardless of interpolation timing.
  double get targetX => newX;
  double get targetY => newY;
  double get targetMass => newMass;

  double get renderRadius => math.sqrt(renderMass / math.pi) * 10;

  /// Push a fresh server update. Always rotates new→prev so the next render
  /// has two samples to interpolate between. If two updates arrive within
  /// the same wall-clock millisecond we keep the spacing non-zero so the
  /// interp denominator can't go to zero.
  void applyUpdate(V2UpdCell u, int recvAtMs) {
    prevX = newX;
    prevY = newY;
    prevMass = newMass;
    prevRecvAt = newRecvAt;
    newX = u.x;
    newY = u.y;
    newMass = u.mass;
    // Guard against burst arrivals: if two snapshots land within < 16 ms of
    // each other (TCP coalescing on a flaky link) the natural span shrinks
    // to a few ms and the interp would complete instantly, producing a
    // visible "jump-then-freeze" cycle. Spacing the receive time to one
    // server tick interval keeps playback smooth.
    final minSpan = 28;
    final candidate = recvAtMs <= prevRecvAt ? prevRecvAt + 1 : recvAtMs;
    newRecvAt = (candidate - prevRecvAt) < minSpan
        ? prevRecvAt + minSpan
        : candidate;
    freshSplit = u.freshSplit;
  }

  /// Resolve [renderX/Y/Mass] for the given wall-clock render time.
  /// Extrapolation budget is capped at 60 ms so a lost snapshot still keeps
  /// the cell moving briefly instead of freezing.
  void tickInterp(int renderAtMs) {
    final span = newRecvAt - prevRecvAt;
    double t;
    if (span <= 0) {
      t = 1.0;
    } else {
      t = (renderAtMs - prevRecvAt) / span;
      if (t < 0) t = 0;
      if (t > 1) {
        final extraMs = renderAtMs - newRecvAt;
        if (extraMs > 60) {
          t = 1 + 60 / span;
        }
      }
    }
    renderX = prevX + (newX - prevX) * t;
    renderY = prevY + (newY - prevY) * t;
    renderMass = prevMass + (newMass - prevMass) * t;
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
    required int recvAtMs,
  })  : prevX = initialX,
        prevY = initialY,
        prevRecvAt = recvAtMs,
        newX = initialX,
        newY = initialY,
        newRecvAt = recvAtMs,
        renderX = initialX,
        renderY = initialY;
  final String id;
  double mass;
  double prevX, prevY;
  int prevRecvAt;
  double newX, newY;
  int newRecvAt;
  double renderX, renderY;
  double get targetX => newX;
  double get targetY => newY;
  double get renderRadius => math.sqrt(mass / math.pi) * 10;

  void applyUpdate(double x, double y, double m, int recvAtMs) {
    prevX = newX;
    prevY = newY;
    prevRecvAt = newRecvAt;
    newX = x;
    newY = y;
    // Guard against burst arrivals: if two snapshots land within < 16 ms of
    // each other (TCP coalescing on a flaky link) the natural span shrinks
    // to a few ms and the interp would complete instantly, producing a
    // visible "jump-then-freeze" cycle. Spacing the receive time to one
    // server tick interval keeps playback smooth.
    final minSpan = 28;
    final candidate = recvAtMs <= prevRecvAt ? prevRecvAt + 1 : recvAtMs;
    newRecvAt = (candidate - prevRecvAt) < minSpan
        ? prevRecvAt + minSpan
        : candidate;
    mass = m;
  }

  void tickInterp(int renderAtMs) {
    final span = newRecvAt - prevRecvAt;
    double t;
    if (span <= 0) {
      t = 1.0;
    } else {
      t = (renderAtMs - prevRecvAt) / span;
      if (t < 0) t = 0;
      if (t > 1) {
        final extraMs = renderAtMs - newRecvAt;
        if (extraMs > 60) t = 1 + 60 / span;
      }
    }
    renderX = prevX + (newX - prevX) * t;
    renderY = prevY + (newY - prevY) * t;
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
    required int recvAtMs,
  })  : prevX = initialX,
        prevY = initialY,
        prevRecvAt = recvAtMs,
        newX = initialX,
        newY = initialY,
        newRecvAt = recvAtMs,
        renderX = initialX,
        renderY = initialY;
  final String id;
  final Color color;
  final String ownerId;
  final int addedAt; // ms timestamp when this entry was added to world
  double prevX, prevY;
  int prevRecvAt;
  double newX, newY;
  int newRecvAt;
  double renderX, renderY;
  double get targetX => newX;
  double get targetY => newY;

  void applyUpdate(double x, double y, int recvAtMs) {
    prevX = newX;
    prevY = newY;
    prevRecvAt = newRecvAt;
    newX = x;
    newY = y;
    // Guard against burst arrivals: if two snapshots land within < 16 ms of
    // each other (TCP coalescing on a flaky link) the natural span shrinks
    // to a few ms and the interp would complete instantly, producing a
    // visible "jump-then-freeze" cycle. Spacing the receive time to one
    // server tick interval keeps playback smooth.
    final minSpan = 28;
    final candidate = recvAtMs <= prevRecvAt ? prevRecvAt + 1 : recvAtMs;
    newRecvAt = (candidate - prevRecvAt) < minSpan
        ? prevRecvAt + minSpan
        : candidate;
  }

  void tickInterp(int renderAtMs) {
    final span = newRecvAt - prevRecvAt;
    double t;
    if (span <= 0) {
      t = 1.0;
    } else {
      t = (renderAtMs - prevRecvAt) / span;
      if (t < 0) t = 0;
      if (t > 1) {
        final extraMs = renderAtMs - newRecvAt;
        if (extraMs > 60) t = 1 + 60 / span;
      }
    }
    renderX = prevX + (newX - prevX) * t;
    renderY = prevY + (newY - prevY) * t;
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
  int lastSnapshotAtMs = 0;

  /// Render delay in ms — the renderer plays back the world this many ms in
  /// the past so it always has two real snapshots to interpolate between.
  /// ~110 ms = 3.3 server ticks @ 30 Hz: tolerates a single lost packet
  /// without freezing. Adjusted by the controller based on measured ping.
  int interpDelayMs = 110;

  String selfId = '';

  /// Apply one snapshot to the world. Old snapshots (lower [serverTick]) are
  /// dropped — UDP-style out-of-order delivery never matters on a TCP socket
  /// but the tick check is cheap and keeps the invariant explicit.
  void applySnapshot(V2State s) {
    if (s.serverTick <= lastServerTick) return;
    lastServerTick = s.serverTick;
    lastServerNow = s.serverNow;
    lastAckSeq = s.ackSeq;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    lastSnapshotAtMs = nowMs;

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
        recvAtMs: nowMs,
      );
    }
    for (final u in s.updCells) {
      cells[u.id]?.applyUpdate(u, nowMs);
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
        recvAtMs: nowMs,
      );
    }
    for (final u in s.updViruses) {
      viruses[u.id]?.applyUpdate(u.x, u.y, u.mass, nowMs);
    }
    for (final id in s.rmViruses) {
      viruses.remove(id);
    }

    // ── ejected ──
    for (final e in s.addEjected) {
      ejected[e.id] = V2WorldEjected(
        id: e.id,
        initialX: e.x,
        initialY: e.y,
        color: _parseHex(e.colorHex),
        ownerId: e.ownerId,
        addedAt: nowMs,
        recvAtMs: nowMs,
      );
    }
    for (final u in s.updEjected) {
      ejected[u.id]?.applyUpdate(u.x, u.y, nowMs);
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

  /// Resolve all interpolated render positions at the given wall-clock time.
  /// Pass the same `nowMs` you intend to use for camera / HUD so visuals
  /// stay temporally consistent. The render time fed to each entity is
  /// `nowMs - interpDelayMs`, which is how we always have two real samples.
  void tickRender(int nowMs) {
    final renderAt = nowMs - interpDelayMs;
    for (final c in cells.values) {
      c.tickInterp(renderAt);
    }
    for (final v in viruses.values) {
      v.tickInterp(renderAt);
    }
    for (final e in ejected.values) {
      e.tickInterp(renderAt);
    }
    if (locallyEatenPellets.isNotEmpty) {
      locallyEatenPellets.removeWhere((_, exp) => exp <= nowMs);
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
