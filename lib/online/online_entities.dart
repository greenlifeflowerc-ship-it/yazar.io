import 'package:flutter/material.dart';

/// Plain data containers for the entities the server sends every tick.
/// Each entity tracks both a target position (from the latest snapshot) and a
/// render position that the controller interpolates toward the target — this
/// is what makes movement look smooth at 60 FPS while the server only sends
/// updates at ~25 Hz.

Color _parseHex(String hex) {
  var h = hex.replaceAll('#', '');
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return Color(v ?? 0xFFFFFFFF);
}

class OnlineCell {
  OnlineCell({
    required this.id,
    required this.name,
    required this.targetX,
    required this.targetY,
    required this.targetMass,
    required this.targetRadius,
    required this.color,
    required this.skinId,
    required this.ownerId,
    required this.isHuman,
    required this.isSelf,
  })  : renderX = targetX,
        renderY = targetY,
        renderMass = targetMass,
        renderRadius = targetRadius;

  final String id;
  String name;
  double targetX;
  double targetY;
  double targetMass;
  double targetRadius;
  Color color;
  String skinId;
  String ownerId;
  bool isHuman;
  bool isSelf;

  // Interpolated values, updated each frame.
  double renderX;
  double renderY;
  double renderMass;
  double renderRadius;

  /// Mark how recently this entity was confirmed by the server. Stale ones
  /// (never resent) are pruned by the controller.
  int lastSnapshotMs = 0;

  /// Smoothly move the rendered state toward the latest server target.
  /// `t` is a 0..1 blend (e.g. `1 - exp(-15 * dt)`).
  void interpolate(double t) {
    renderX = _lerp(renderX, targetX, t);
    renderY = _lerp(renderY, targetY, t);
    renderMass = _lerp(renderMass, targetMass, t);
    renderRadius = _lerp(renderRadius, targetRadius, t);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  factory OnlineCell.fromJson(Map<String, dynamic> j) => OnlineCell(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        targetX: (j['x'] as num).toDouble(),
        targetY: (j['y'] as num).toDouble(),
        targetMass: (j['mass'] as num).toDouble(),
        targetRadius: (j['radius'] as num).toDouble(),
        color: _parseHex(j['color'] as String? ?? '#FFFFFF'),
        skinId: (j['skinId'] as String?) ?? '',
        ownerId: (j['ownerId'] as String?) ?? (j['id'] as String),
        isHuman: j['isHuman'] == true,
        isSelf: j['isSelf'] == true,
      );

  void updateFromJson(Map<String, dynamic> j, int snapshotMs) {
    targetX = (j['x'] as num).toDouble();
    targetY = (j['y'] as num).toDouble();
    targetMass = (j['mass'] as num).toDouble();
    targetRadius = (j['radius'] as num).toDouble();
    color = _parseHex(j['color'] as String? ?? '#FFFFFF');
    name = (j['name'] as String?) ?? name;
    final newSkin = j['skinId'] as String?;
    if (newSkin != null) skinId = newSkin;
    final newOwner = j['ownerId'] as String?;
    if (newOwner != null) ownerId = newOwner;
    isHuman = j['isHuman'] == true;
    isSelf = j['isSelf'] == true;
    lastSnapshotMs = snapshotMs;
  }
}

/// Pellets and viruses don't move between updates, so they don't need
/// interpolation — we just store the target position as the render position.
class OnlinePellet {
  OnlinePellet({
    required this.id,
    required this.x,
    required this.y,
    required this.radius,
    required this.color,
  });

  final String id;
  double x;
  double y;
  double radius;
  Color color;
  int lastSnapshotMs = 0;

  factory OnlinePellet.fromJson(Map<String, dynamic> j) => OnlinePellet(
        id: j['id'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        // Server strips constant fields; default to the pellet baseline.
        radius: (j['radius'] as num?)?.toDouble() ?? 6.0,
        color: _parseHex(j['color'] as String? ?? '#FFFFFF'),
      );

  void updateFromJson(Map<String, dynamic> j, int snapshotMs) {
    x = (j['x'] as num).toDouble();
    y = (j['y'] as num).toDouble();
    final r = (j['radius'] as num?)?.toDouble();
    if (r != null) radius = r;
    color = _parseHex(j['color'] as String? ?? '#FFFFFF');
    lastSnapshotMs = snapshotMs;
  }
}

class OnlineVirus {
  OnlineVirus({
    required this.id,
    required this.x,
    required this.y,
    required this.radius,
  });

  final String id;
  double x;
  double y;
  double radius;
  int lastSnapshotMs = 0;

  factory OnlineVirus.fromJson(Map<String, dynamic> j) => OnlineVirus(
        id: j['id'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        radius: (j['radius'] as num).toDouble(),
      );

  void updateFromJson(Map<String, dynamic> j, int snapshotMs) {
    x = (j['x'] as num).toDouble();
    y = (j['y'] as num).toDouble();
    radius = (j['radius'] as num).toDouble();
    lastSnapshotMs = snapshotMs;
  }
}

/// Ejected mass (feed). Moves on the server; we just lerp render position
/// toward each snapshot target so it doesn't stutter at 25 Hz.
class OnlineEjected {
  OnlineEjected({
    required this.id,
    required this.targetX,
    required this.targetY,
    required this.radius,
    required this.color,
  })  : renderX = targetX,
        renderY = targetY;

  final String id;
  double targetX;
  double targetY;
  double radius;
  Color color;
  double renderX;
  double renderY;
  int lastSnapshotMs = 0;

  void interpolate(double t) {
    renderX = renderX + (targetX - renderX) * t;
    renderY = renderY + (targetY - renderY) * t;
  }

  factory OnlineEjected.fromJson(Map<String, dynamic> j) => OnlineEjected(
        id: j['id'] as String,
        targetX: (j['x'] as num).toDouble(),
        targetY: (j['y'] as num).toDouble(),
        radius: (j['radius'] as num).toDouble(),
        color: _parseHex(j['color'] as String? ?? '#FFFFFF'),
      );

  void updateFromJson(Map<String, dynamic> j, int snapshotMs) {
    targetX = (j['x'] as num).toDouble();
    targetY = (j['y'] as num).toDouble();
    radius = (j['radius'] as num).toDouble();
    color = _parseHex(j['color'] as String? ?? '#FFFFFF');
    lastSnapshotMs = snapshotMs;
  }
}

class OnlineLeaderboardEntry {
  OnlineLeaderboardEntry({
    required this.id,
    required this.name,
    required this.mass,
  });

  final String id;
  final String name;
  final int mass;

  factory OnlineLeaderboardEntry.fromJson(Map<String, dynamic> j) =>
      OnlineLeaderboardEntry(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '?',
        mass: (j['mass'] as num).toInt(),
      );
}

/// Connection lifecycle for the online classic UI to react to.
enum OnlineConnState {
  idle,
  connecting,
  connected,
  reconnecting,
  failed,
  closed,
}
