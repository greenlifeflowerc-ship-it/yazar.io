/// Wire packet definitions for Online Classic V2.
///
/// The server protocol is documented in `server/src/index.ts`. This file
/// owns the Dart-side data classes and the JSON parser. Keep the field names
/// in sync with the server (single source of truth lives in the server's
/// comment header at the top of `index.ts`).
library;

import 'package:flutter/foundation.dart';

/// Connection lifecycle for the V2 layer. Mirrors the legacy
/// [`OnlineConnState`] but lives independently so the new layer doesn't pull
/// the old `online/` module into its dependency graph.
enum V2ConnState {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
  closed,
}

/// First server packet after `join`. Carries the assigned player id and the
/// world constants the client needs to start its local prediction sim.
class V2Welcome {
  V2Welcome({
    required this.playerId,
    required this.worldSize,
    required this.tickRate,
    required this.tickMs,
    required this.name,
  });

  final String playerId;
  final double worldSize;
  final int tickRate;
  final double tickMs;
  final String name;

  static V2Welcome? tryParse(Map<String, dynamic> m) {
    if (m['type'] != 'welcome') return null;
    final id = m['id'];
    final ws = m['worldSize'];
    if (id is! String || ws is! num) return null;
    return V2Welcome(
      playerId: id,
      worldSize: ws.toDouble(),
      tickRate: (m['tickRate'] as num?)?.toInt() ?? 30,
      tickMs: (m['tickMs'] as num?)?.toDouble() ?? 1000.0 / 30.0,
      name: (m['name'] as String?) ?? 'Player',
    );
  }
}

/// Server reply to a ping; carries the original client timestamp echoed back
/// plus the server's wall clock for latency / clock-skew estimation.
class V2Pong {
  V2Pong({required this.clientT, required this.serverNow});
  final int clientT;
  final int serverNow;

  static V2Pong? tryParse(Map<String, dynamic> m) {
    if (m['type'] != 'pong') return null;
    return V2Pong(
      clientT: (m['t'] as num?)?.toInt() ?? 0,
      serverNow: (m['now'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One cell appearing for the first time in this client's viewport.
/// Carries the full identity (owner, name, color, skin) so the renderer can
/// draw it; subsequent `updCells` entries only carry position/mass deltas.
class V2AddCell {
  V2AddCell({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.x,
    required this.y,
    required this.mass,
    required this.colorHex,
    required this.skinId,
    required this.isHuman,
    required this.freshSplit,
    required this.mergeReadyAt,
  });

  final String id;
  final String ownerId;
  final String name;
  final double x;
  final double y;
  final double mass;
  final String colorHex;
  final String skinId;
  final bool isHuman;
  final bool freshSplit;
  final int mergeReadyAt;
}

class V2UpdCell {
  V2UpdCell({
    required this.id,
    required this.x,
    required this.y,
    required this.mass,
    required this.freshSplit,
  });
  final String id;
  final double x;
  final double y;
  final double mass;
  final bool freshSplit;
}

class V2AddPellet {
  V2AddPellet({
    required this.id,
    required this.x,
    required this.y,
    required this.colorHex,
  });
  final String id;
  final double x;
  final double y;
  final String colorHex;
}

class V2AddVirus {
  V2AddVirus({
    required this.id,
    required this.x,
    required this.y,
    required this.mass,
  });
  final String id;
  final double x;
  final double y;
  final double mass;
}

class V2UpdVirus {
  V2UpdVirus({
    required this.id,
    required this.x,
    required this.y,
    required this.mass,
  });
  final String id;
  final double x;
  final double y;
  final double mass;
}

class V2AddEjected {
  V2AddEjected({
    required this.id,
    required this.x,
    required this.y,
    required this.colorHex,
    required this.ownerId,
  });
  final String id;
  final double x;
  final double y;
  final String colorHex;
  final String ownerId;
}

class V2UpdEjected {
  V2UpdEjected({
    required this.id,
    required this.x,
    required this.y,
  });
  final String id;
  final double x;
  final double y;
}

class V2SelfStatus {
  V2SelfStatus({
    required this.id,
    required this.dead,
    required this.cmX,
    required this.cmY,
    required this.mass,
    required this.kills,
    required this.highestMass,
  });
  final String id;
  final bool dead;
  final double cmX;
  final double cmY;
  final double mass;
  final int kills;
  final double highestMass;
}

class V2LeaderboardEntry {
  V2LeaderboardEntry({
    required this.id,
    required this.name,
    required this.mass,
    required this.isHuman,
  });
  final String id;
  final String name;
  final int mass;
  final bool isHuman;
}

/// A single per-tick state snapshot. Parsed once on receive and consumed by
/// the controller, which folds the diffs into its local world cache.
class V2State {
  V2State({
    required this.serverTick,
    required this.serverNow,
    required this.ackSeq,
    required this.self,
    required this.addCells,
    required this.updCells,
    required this.rmCells,
    required this.addPellets,
    required this.rmPellets,
    required this.addViruses,
    required this.updViruses,
    required this.rmViruses,
    required this.addEjected,
    required this.updEjected,
    required this.rmEjected,
    required this.leaderboard,
    required this.online,
  });

  final int serverTick;
  final int serverNow;
  final int ackSeq;
  final V2SelfStatus self;
  final List<V2AddCell> addCells;
  final List<V2UpdCell> updCells;
  final List<String> rmCells;
  final List<V2AddPellet> addPellets;
  final List<String> rmPellets;
  final List<V2AddVirus> addViruses;
  final List<V2UpdVirus> updViruses;
  final List<String> rmViruses;
  final List<V2AddEjected> addEjected;
  final List<V2UpdEjected> updEjected;
  final List<String> rmEjected;
  final List<V2LeaderboardEntry> leaderboard;
  final int online;

  static V2State? tryParse(Map<String, dynamic> m) {
    if (m['type'] != 'state') return null;
    try {
      final selfM = (m['self'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cm = (selfM['cm'] as Map?)?.cast<String, dynamic>() ?? const {};
      final self = V2SelfStatus(
        id: (selfM['id'] as String?) ?? '',
        dead: selfM['dead'] == true,
        cmX: (cm['x'] as num?)?.toDouble() ?? 0,
        cmY: (cm['y'] as num?)?.toDouble() ?? 0,
        mass: (selfM['mass'] as num?)?.toDouble() ?? 0,
        kills: (selfM['kills'] as num?)?.toInt() ?? 0,
        highestMass: (selfM['highestMass'] as num?)?.toDouble() ?? 0,
      );

      final addCells = <V2AddCell>[];
      for (final raw in (m['addCells'] as List? ?? const [])) {
        final c = (raw as Map).cast<String, dynamic>();
        addCells.add(V2AddCell(
          id: (c['id'] as String?) ?? '',
          ownerId: (c['o'] as String?) ?? '',
          name: (c['n'] as String?) ?? '',
          x: (c['x'] as num?)?.toDouble() ?? 0,
          y: (c['y'] as num?)?.toDouble() ?? 0,
          mass: (c['m'] as num?)?.toDouble() ?? 0,
          colorHex: (c['col'] as String?) ?? '#FFFFFF',
          skinId: (c['sk'] as String?) ?? '',
          isHuman: ((c['h'] as num?)?.toInt() ?? 0) == 1,
          freshSplit: ((c['s'] as num?)?.toInt() ?? 0) == 1,
          mergeReadyAt: (c['mr'] as num?)?.toInt() ?? 0,
        ));
      }

      final updCells = <V2UpdCell>[];
      for (final raw in (m['updCells'] as List? ?? const [])) {
        final c = (raw as Map).cast<String, dynamic>();
        updCells.add(V2UpdCell(
          id: (c['id'] as String?) ?? '',
          x: (c['x'] as num?)?.toDouble() ?? 0,
          y: (c['y'] as num?)?.toDouble() ?? 0,
          mass: (c['m'] as num?)?.toDouble() ?? 0,
          freshSplit: ((c['s'] as num?)?.toInt() ?? 0) == 1,
        ));
      }

      final rmCells = _stringList(m['rmCells']);

      final addPellets = <V2AddPellet>[];
      for (final raw in (m['addPellets'] as List? ?? const [])) {
        final p = (raw as Map).cast<String, dynamic>();
        addPellets.add(V2AddPellet(
          id: (p['id'] as String?) ?? '',
          x: (p['x'] as num?)?.toDouble() ?? 0,
          y: (p['y'] as num?)?.toDouble() ?? 0,
          colorHex: (p['c'] as String?) ?? '#FFFFFF',
        ));
      }
      final rmPellets = _stringList(m['rmPellets']);

      final addViruses = <V2AddVirus>[];
      for (final raw in (m['addViruses'] as List? ?? const [])) {
        final v = (raw as Map).cast<String, dynamic>();
        addViruses.add(V2AddVirus(
          id: (v['id'] as String?) ?? '',
          x: (v['x'] as num?)?.toDouble() ?? 0,
          y: (v['y'] as num?)?.toDouble() ?? 0,
          mass: (v['m'] as num?)?.toDouble() ?? 0,
        ));
      }
      final updViruses = <V2UpdVirus>[];
      for (final raw in (m['updViruses'] as List? ?? const [])) {
        final v = (raw as Map).cast<String, dynamic>();
        updViruses.add(V2UpdVirus(
          id: (v['id'] as String?) ?? '',
          x: (v['x'] as num?)?.toDouble() ?? 0,
          y: (v['y'] as num?)?.toDouble() ?? 0,
          mass: (v['m'] as num?)?.toDouble() ?? 0,
        ));
      }
      final rmViruses = _stringList(m['rmViruses']);

      final addEjected = <V2AddEjected>[];
      for (final raw in (m['addEjected'] as List? ?? const [])) {
        final e = (raw as Map).cast<String, dynamic>();
        addEjected.add(V2AddEjected(
          id: (e['id'] as String?) ?? '',
          x: (e['x'] as num?)?.toDouble() ?? 0,
          y: (e['y'] as num?)?.toDouble() ?? 0,
          colorHex: (e['c'] as String?) ?? '#FFFFFF',
          ownerId: (e['o'] as String?) ?? '',
        ));
      }
      final updEjected = <V2UpdEjected>[];
      for (final raw in (m['updEjected'] as List? ?? const [])) {
        final e = (raw as Map).cast<String, dynamic>();
        updEjected.add(V2UpdEjected(
          id: (e['id'] as String?) ?? '',
          x: (e['x'] as num?)?.toDouble() ?? 0,
          y: (e['y'] as num?)?.toDouble() ?? 0,
        ));
      }
      final rmEjected = _stringList(m['rmEjected']);

      final lb = <V2LeaderboardEntry>[];
      for (final raw in (m['leaderboard'] as List? ?? const [])) {
        final l = (raw as Map).cast<String, dynamic>();
        lb.add(V2LeaderboardEntry(
          id: (l['id'] as String?) ?? '',
          name: (l['name'] as String?) ?? '',
          mass: (l['mass'] as num?)?.toInt() ?? 0,
          isHuman: l['isHuman'] == true,
        ));
      }

      return V2State(
        serverTick: (m['t'] as num?)?.toInt() ?? 0,
        serverNow: (m['now'] as num?)?.toInt() ?? 0,
        ackSeq: (m['ack'] as num?)?.toInt() ?? 0,
        self: self,
        addCells: addCells,
        updCells: updCells,
        rmCells: rmCells,
        addPellets: addPellets,
        rmPellets: rmPellets,
        addViruses: addViruses,
        updViruses: updViruses,
        rmViruses: rmViruses,
        addEjected: addEjected,
        updEjected: updEjected,
        rmEjected: rmEjected,
        leaderboard: lb,
        online: (m['online'] as num?)?.toInt() ?? 0,
      );
    } catch (e, st) {
      debugPrint('V2State parse failed: $e\n$st');
      return null;
    }
  }
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final e in raw) {
    if (e is String) out.add(e);
  }
  return out;
}
