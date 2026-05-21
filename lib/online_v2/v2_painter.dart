/// Online Classic V2 painter.
///
/// Renders the exact same scene as the offline `GamePainter` but sourced
/// from the V2 split-brain world: the LOCAL human's cells come from
/// [V2LocalSim] (driven by client-side prediction, no input lag) while
/// every other entity comes from [V2World] (interpolated render positions).
/// Look mirrors offline as closely as we can without dragging the offline
/// engine in: same colors, label style, virus spikes, ejected gradients,
/// jelly bumps on local cells.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/entities/cell.dart' as ge;
import '../game/game_engine.dart';
import '../game/game_settings.dart';
import '../game/skin_settings.dart';
import 'v2_controller.dart';

class V2Painter extends CustomPainter {
  V2Painter({
    required this.controller,
    required this.cameraPos,
    required this.cameraZoom,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final V2Controller controller;
  final Offset cameraPos;
  final double cameraZoom;

  static const double _gridSpacing = 50.0;

  // ─────────────────────────────────────── reusable paints (static, no GC)
  // The painter is reconstructed on every frame (60 Hz). Instance Paints
  // would trigger ~hundreds of allocations per second; static reusable
  // Paints cut that to zero. Their mutable fields (color, strokeWidth) are
  // updated per call site, so callers must always set what they need.
  static final Paint _bgPaint = Paint();
  static final Paint _gridPaint = Paint();
  static final Paint _borderPaint = Paint()..style = PaintingStyle.stroke;
  static final Paint _pelletPaint = Paint();
  static final Paint _ejectedPaint = Paint();
  static final Paint _virusFill = Paint()..color = const Color(0xFF33FF33);
  static final Paint _virusStroke = Paint()
    ..color = const Color(0xFF1F8A1F)
    ..style = PaintingStyle.stroke;
  static final Paint _cellFill = Paint();
  static final Paint _cellStroke = Paint()..style = PaintingStyle.stroke;
  static final Paint _skinPaint = Paint()..filterQuality = FilterQuality.low;
  static final Paint _aimFill = Paint();
  static final Paint _aimStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;

  // ─────────────────────────────────────── reusable paths (no per-cell GC)
  // Each callsite must `path.reset()` before adding new segments. These are
  // static so allocation only happens once per process for the life of the
  // painter, not 60 / 120 Hz × N entities.
  static final Path _scratchPath = Path();
  static final Path _scratchClipPath = Path();

  // ─────────────────────────────────────── label cache
  // TextPainter.layout() runs font shaping — expensive enough to dominate
  // the per-frame budget when called 30+ times. Cache the laid-out painter
  // keyed by (text, fontSize bucket). Names are stable; mass is bucketed to
  // the nearest 10 so we hit the cache 90 % of the time even mid-game.
  // Cache is bounded so it can't leak across long sessions.
  static final Map<String, TextPainter> _labelCache = <String, TextPainter>{};
  static const int _labelCacheMax = 256;

  static TextPainter _label(String text, double fontSize, {bool bold = true}) {
    // Quantize fontSize to 0.5 px so micro-zoom changes don't blow the cache.
    final fs = (fontSize * 2).round() / 2.0;
    final key = bold ? 'b|$fs|$text' : 'n|$fs|$text';
    final cached = _labelCache[key];
    if (cached != null) return cached;
    if (_labelCache.length >= _labelCacheMax) {
      // Cheap eviction — drop the oldest 1/4 of the cache.
      final keys = _labelCache.keys.take(_labelCacheMax ~/ 4).toList();
      for (final k in keys) {
        _labelCache.remove(k);
      }
    }
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fs,
          fontWeight: bold ? FontWeight.w900 : FontWeight.w800,
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    _labelCache[key] = tp;
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final settings = GameSettings.instance;
    final renderScale = settings.renderScale;

    _bgPaint.color = settings.backgroundColor;
    canvas.drawRect(Offset.zero & size, _bgPaint);

    canvas.save();
    final zoom = cameraZoom * renderScale;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-cameraPos.dx, -cameraPos.dy);

    final viewW = size.width / zoom;
    final viewH = size.height / zoom;
    final margin = 150.0 / zoom;
    final viewport = Rect.fromCenter(
      center: cameraPos,
      width: viewW + margin,
      height: viewH + margin,
    );

    if (settings.showGrid) _drawGrid(canvas, viewport, settings.gridColor);
    _drawWorldBorder(canvas, settings.borderColor);

    _drawPellets(canvas, viewport);
    _drawEjected(canvas, viewport);

    _drawEntities(canvas, viewport);

    canvas.restore();
  }

  // ────────────────────────────────────────────────── world chrome
  void _drawGrid(Canvas canvas, Rect view, Color color) {
    final paint = _gridPaint
      ..color = color
      ..strokeWidth = 1 / cameraZoom;
    final startX = (view.left / _gridSpacing).floor() * _gridSpacing;
    final endX = (view.right / _gridSpacing).ceil() * _gridSpacing;
    final startY = (view.top / _gridSpacing).floor() * _gridSpacing;
    final endY = (view.bottom / _gridSpacing).ceil() * _gridSpacing;
    final left = math.max(0.0, view.left);
    final right = math.min(GameConstants.worldSize, view.right);
    final top = math.max(0.0, view.top);
    final bottom = math.min(GameConstants.worldSize, view.bottom);
    for (double x = startX; x <= endX; x += _gridSpacing) {
      if (x < 0 || x > GameConstants.worldSize) continue;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
    for (double y = startY; y <= endY; y += _gridSpacing) {
      if (y < 0 || y > GameConstants.worldSize) continue;
      canvas.drawLine(Offset(left, y), Offset(right, y), paint);
    }
  }

  void _drawWorldBorder(Canvas canvas, Color color) {
    final paint = _borderPaint
      ..color = color
      ..strokeWidth = 8 / cameraZoom;
    canvas.drawRect(
      const Rect.fromLTWH(
        0,
        0,
        GameConstants.worldSize,
        GameConstants.worldSize,
      ),
      paint,
    );
  }

  // ────────────────────────────────────────────────── pellets
  void _drawPellets(Canvas canvas, Rect view) {
    final paint = _pelletPaint;
    // Inline AABB cull — avoids one Offset alloc per pellet per frame, which
    // adds up fast at 8 K pellets × 60 fps on mid-tier mobile GC.
    final left = view.left, top = view.top, right = view.right, bottom = view.bottom;
    for (final p in controller.world.pellets.values) {
      final px = p.x, py = p.y;
      if (px < left || px > right || py < top || py > bottom) continue;
      paint.color = p.color;
      canvas.drawCircle(Offset(px, py), 6.0, paint);
    }
  }

  // ────────────────────────────────────────────────── ejected mass
  void _drawEjected(Canvas canvas, Rect view) {
    // Server-side ejected (every other player's feed).
    for (final e in controller.world.ejected.values) {
      final pos = Offset(e.renderX, e.renderY);
      if (!view.contains(pos)) continue;
      _drawEjectedCircle(canvas, pos, _ejectedRadius, e.color);
    }
    // Local-only ejected — the human's own feed, animated by the local sim.
    for (final e in controller.sim.localEjected) {
      if (!view.contains(e.position)) continue;
      _drawEjectedCircle(canvas, e.position, e.radius, e.color);
    }
  }

  static const double _ejectedRadius = 20.34; // sqrt(13/pi)*10 — eject mass=13
  void _drawEjectedCircle(Canvas canvas, Offset pos, double r, Color color) {
    final gradient = ui.Gradient.radial(
      pos,
      r,
      [
        color,
        color,
        Colors.grey.withValues(alpha: 0.5),
        Colors.grey.withValues(alpha: 0),
      ],
      [
        0.0,
        ((r - 10) / r).clamp(0.0, 1.0),
        ((r - 2) / r).clamp(0.0, 1.0),
        1.0,
      ],
    );
    _ejectedPaint.shader = gradient;
    canvas.drawCircle(pos, r, _ejectedPaint);
  }

  // ─────────────────────────────── pooled drawable buffer (static, reused)
  // _drawsPool is an append-only pool of _Drawable instances that grows to
  // peak demand. _drawsLive is the per-frame working set — cleared and
  // refilled each frame, sorted in place, then drawn. List.clear() is O(1)
  // and reusing _Drawable instances eliminates ~60 allocs/frame.
  static final List<_Drawable> _drawsPool = <_Drawable>[];
  static final List<_Drawable> _drawsLive = <_Drawable>[];

  _Drawable _nextDrawable() {
    final live = _drawsLive;
    final pool = _drawsPool;
    if (live.length < pool.length) {
      final d = pool[live.length];
      live.add(d);
      return d;
    }
    final d = _Drawable();
    pool.add(d);
    live.add(d);
    return d;
  }

  // ────────────────────────────────────────────────── cells + viruses
  void _drawEntities(Canvas canvas, Rect view) {
    _drawsLive.clear();

    // Remote players (and the server's view of self — we skip self because
    // we render the local-sim cells instead).
    for (final c in controller.world.cells.values) {
      if (c.isSelf) continue;
      final rx = c.renderX, ry = c.renderY;
      if (rx < view.left || rx > view.right || ry < view.top || ry > view.bottom) {
        continue;
      }
      final d = _nextDrawable();
      d.mass = c.renderMass;
      d.kind = _Kind.cell;
      d.cellPos = Offset(rx, ry);
      d.cellRadius = c.renderRadius;
      d.cellName = c.name;
      d.cellColor = c.color;
      d.cellOwnerId = c.ownerId;
      d.cellIsHuman = c.isHuman;
      d.cellSkinId = c.skinId;
      d.cellLocal = null;
    }

    // Local human cells — straight from V2LocalSim. No interpolation.
    final selfPlayer = controller.sim.isInitialized ? controller.sim.player : null;
    final selfId = selfPlayer?.id;
    if (selfPlayer != null) {
      for (final c in selfPlayer.cells) {
        final cp = c.position;
        if (cp.dx < view.left || cp.dx > view.right ||
            cp.dy < view.top || cp.dy > view.bottom) {
          continue;
        }
        final d = _nextDrawable();
        d.mass = c.mass;
        d.kind = _Kind.cell;
        d.cellPos = cp;
        d.cellRadius = c.radius;
        d.cellName = c.name;
        d.cellColor = c.color;
        d.cellOwnerId = c.ownerId;
        d.cellIsHuman = true;
        d.cellSkinId = '';
        d.cellLocal = c;
      }
    }

    // Viruses (rendered with the same draw order as cells, by mass).
    for (final v in controller.world.viruses.values) {
      final rx = v.renderX, ry = v.renderY;
      if (rx < view.left || rx > view.right || ry < view.top || ry > view.bottom) {
        continue;
      }
      final d = _nextDrawable();
      d.mass = v.mass;
      d.kind = _Kind.virus;
      d.cellPos = Offset(rx, ry);
      d.cellRadius = v.renderRadius;
      d.cellLocal = null;
    }

    // Z-order by mass — small entities under big ones. Sort in place; the
    // live list only holds this frame's entries.
    final live = _drawsLive..sort((a, b) => a.mass.compareTo(b.mass));

    final ss = SkinSettings.instance;
    for (final d in live) {
      if (d.kind == _Kind.virus) {
        _drawVirus(canvas, d.cellPos, d.cellRadius);
      } else {
        ui.Image? skin;
        if (d.cellOwnerId == selfId) {
          skin = ss.isAltFaceActive && ss.altSkinImage != null
              ? ss.altSkinImage
              : ss.skinImage;
        } else if (d.cellSkinId.isNotEmpty) {
          // Remote players — async-loaded from the asset bundle the first
          // time we see their skin id; cached for the rest of the session.
          skin = controller.skinCache.get(d.cellSkinId);
        }
        _drawCell(canvas, d, skin: skin, fill: _cellFill, stroke: _cellStroke);
      }
    }

    if (selfPlayer != null && selfPlayer.cells.isNotEmpty) {
      _drawAimArrow(canvas, selfPlayer);
    }
  }

  void _drawVirus(Canvas canvas, Offset pos, double r) {
    _virusStroke.strokeWidth = 3 / cameraZoom;
    // 30 spikes × 2 verts = 60 segments — visually indistinguishable from the
    // previous 90, halves the per-virus path build cost.
    const spikes = 30;
    final path = _scratchPath..reset();
    final two = 2 * math.pi;
    for (int i = 0; i <= spikes * 2; i++) {
      final ang = (i / (spikes * 2)) * two;
      final rr = (i % 2 == 0) ? r : r * 0.94;
      final x = pos.dx + math.cos(ang) * rr;
      final y = pos.dy + math.sin(ang) * rr;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, _virusFill);
    canvas.drawPath(path, _virusStroke);
  }

  void _drawCell(
    Canvas canvas,
    _Drawable d, {
    required ui.Image? skin,
    required Paint fill,
    required Paint stroke,
  }) {
    final r = d.cellRadius;
    final pos = d.cellPos;
    final quality = GameSettings.instance.graphicsQuality;

    fill.color = d.cellColor;
    stroke.color = _darken(d.cellColor, 0.25);
    stroke.strokeWidth = math.max(2.0, r * 0.05);

    final local = d.cellLocal;
    final hasBumps = local != null && local.bumps.isNotEmpty && quality > 0;
    if (!hasBumps) {
      _drawDisc(canvas, pos, r, fill, stroke, skin, quality);
    } else {
      _drawJellyCell(canvas, local, fill, stroke, skin, quality);
    }
    _drawCellLabel(canvas, pos, r, d.cellName, d.mass);
  }

  void _drawDisc(
    Canvas canvas,
    Offset pos,
    double r,
    Paint fill,
    Paint stroke,
    ui.Image? skin,
    int quality,
  ) {
    canvas.drawCircle(pos, r, fill);
    if (skin != null) {
      canvas.save();
      _scratchClipPath
        ..reset()
        ..addOval(Rect.fromCircle(center: pos, radius: r));
      canvas.clipPath(_scratchClipPath);
      final dst = Rect.fromCircle(center: pos, radius: r);
      _skinPaint.filterQuality =
          quality == 0 ? FilterQuality.low : FilterQuality.medium;
      canvas.drawImageRect(
        skin,
        Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
        dst,
        _skinPaint,
      );
      canvas.restore();
    }
    canvas.drawCircle(pos, r, stroke);
  }

  void _drawJellyCell(
    Canvas canvas,
    ge.Cell c,
    Paint fill,
    Paint stroke,
    ui.Image? skin,
    int quality,
  ) {
    final r = c.radius;
    final path = _scratchPath..reset();
    // Halved from 60 / 120 — the bump deformation is low-frequency (a few
    // bumps × cos-shaped falloff) so visually 32 / 64 vertices is identical
    // even on a max-radius cell. Cuts jelly path-build cost in half.
    final vertices = quality == 1 ? 32 : 64;
    for (int i = 0; i <= vertices; i++) {
      final vAng = (i / vertices) * 2 * math.pi;
      double deformation = 0;
      for (final bump in c.bumps) {
        double diff = (vAng - bump.angle).abs();
        if (diff > math.pi) diff = 2 * math.pi - diff;
        const influence = 0.4;
        if (diff < influence) {
          final w = 0.5 * (1 + math.cos((diff / influence) * math.pi));
          deformation += bump.magnitude * w;
        }
      }
      final rr = r * (1 + deformation);
      final p = Offset(
        c.position.dx + math.cos(vAng) * rr,
        c.position.dy + math.sin(vAng) * rr,
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, fill);
    if (skin != null) {
      canvas.save();
      canvas.clipPath(path);
      final dst = Rect.fromCenter(
        center: c.position,
        width: r * 2.2,
        height: r * 2.2,
      );
      _skinPaint.filterQuality =
          quality == 0 ? FilterQuality.low : FilterQuality.medium;
      canvas.drawImageRect(
        skin,
        Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
        dst,
        _skinPaint,
      );
      canvas.restore();
    }
    canvas.drawPath(path, stroke);
  }

  void _drawCellLabel(
    Canvas canvas,
    Offset pos,
    double r,
    String name,
    double mass,
  ) {
    final screenR = r * cameraZoom;
    if (screenR < 14) return;
    // Quantize font size to 2 px buckets so we don't blow the cache when the
    // cell radius drifts by a fraction. Visually no difference.
    final fontSize = ((r * 0.32).clamp(12.0, 64.0) / 2).round() * 2.0;
    final tp = _label(name, fontSize, bold: true);
    tp.paint(
      canvas,
      Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2 - fontSize * 0.4),
    );
    if (screenR < 24 || !GameSettings.instance.showMassLabels) return;
    // Bucket mass to nearest 10 — a 320 → 330 → 340 transition is what the
    // player sees anyway, and it gives 90 %+ cache hit-rate across frames.
    final massBucket = (mass / 10).round() * 10;
    final mp = _label(massBucket.toString(), fontSize * 0.7, bold: false);
    mp.paint(
      canvas,
      Offset(pos.dx - mp.width / 2, pos.dy + fontSize * 0.05),
    );
  }

  void _drawAimArrow(Canvas canvas, dynamic player) {
    final dir = controller.sim.lastNonZeroDir;
    if (dir.distance < 0.05) return;
    final center = controller.sim.centerOfMass;
    final unit = dir / dir.distance;
    double maxDist = 0;
    for (final c in controller.sim.cells) {
      final d = (c.position - center).distance + c.radius;
      if (d > maxDist) maxDist = d;
    }
    final tipBase = center + unit * (maxDist + 10);
    final perp = Offset(-unit.dy, unit.dx);
    final length = 30 / cameraZoom;
    final width = 35 / cameraZoom;
    final back = 8 / cameraZoom;
    final tip = tipBase + unit * length;
    final p1 = tipBase + perp * (width / 2);
    final p2 = tipBase - perp * (width / 2);
    final backC = tipBase + unit * back;
    final path = _scratchPath
      ..reset()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(backC.dx, backC.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    _aimFill.color = Colors.white.withValues(alpha: 0.4);
    canvas.drawPath(path, _aimFill);
    _aimStroke.color = Colors.white.withValues(alpha: 0.1);
    canvas.drawPath(path, _aimStroke);
  }

  Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * (1 - amount)).clamp(0.0, 1.0))
        .toColor();
  }

  @override
  bool shouldRepaint(covariant V2Painter old) => true;
}

enum _Kind { cell, virus }

/// Mutable drawable so the painter can pool instances across frames. The
/// previous immutable version allocated a fresh _Drawable for every cell +
/// virus every frame — ~60 allocations × 60 fps = 3.6 K objects/sec of GC
/// pressure that we no longer pay.
class _Drawable {
  double mass = 0;
  _Kind kind = _Kind.cell;
  Offset cellPos = Offset.zero;
  double cellRadius = 0;
  String cellName = '';
  Color cellColor = Colors.white;
  String cellOwnerId = '';
  bool cellIsHuman = false;
  String cellSkinId = '';
  ge.Cell? cellLocal;
}

