import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/game_settings.dart';
import 'online_classic_controller.dart';
import 'online_entities.dart';

/// Custom painter for the online classic mode.
///
/// The local copy of [controller] gets mutated by `tickInterpolation` from a
/// Ticker, then `frame` fires and we redraw. Camera follows the predicted
/// self position so input feels instant; remote players/bots use the
/// snapshot-driven interpolation in the controller.
class OnlineClassicPainter extends CustomPainter {
  OnlineClassicPainter({
    required this.controller,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final OnlineClassicController controller;

  static const _gridSpacing = 50.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return; // no usable surface yet
    final settings = GameSettings.instance;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = settings.backgroundColor,
    );

    // Camera: follow the predicted self position so movement feels instant.
    // Zoom scales with self mass. The controller guarantees these are finite.
    final cx = controller.predictedX.isFinite
        ? controller.predictedX
        : controller.mapWidth / 2;
    final cy = controller.predictedY.isFinite
        ? controller.predictedY
        : controller.mapHeight / 2;
    final zoom = _zoomForMass(controller.selfMass.toDouble());
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-cx, -cy);

    final viewW = size.width / zoom;
    final viewH = size.height / zoom;
    final viewport = Rect.fromCenter(
      center: Offset(cx, cy),
      // A bigger margin makes sure entities right at the edge still draw.
      width: viewW + 400 / zoom,
      height: viewH + 400 / zoom,
    );

    if (settings.showGrid) _drawGrid(canvas, viewport, settings.gridColor, zoom);
    _drawWorldBorder(canvas, settings.borderColor, zoom);

    _drawPellets(canvas, viewport);
    _drawEjected(canvas, viewport);
    _drawViruses(canvas, viewport);
    _drawCells(canvas, viewport, zoom);

    canvas.restore();
  }

  double _zoomForMass(double mass) {
    final m = mass.clamp(10, 1e9).toDouble();
    final z = pow(64 / m, 0.25).toDouble();
    final mult = 1.0 / GameSettings.instance.zoomMultiplier;
    return (z * mult).clamp(0.05, 4.0);
  }

  void _drawGrid(Canvas canvas, Rect view, Color color, double zoom) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1 / zoom;
    final startX = (view.left / _gridSpacing).floor() * _gridSpacing;
    final endX = (view.right / _gridSpacing).ceil() * _gridSpacing;
    final startY = (view.top / _gridSpacing).floor() * _gridSpacing;
    final endY = (view.bottom / _gridSpacing).ceil() * _gridSpacing;
    final mapW = controller.mapWidth;
    final mapH = controller.mapHeight;
    final left = max(0.0, view.left);
    final right = min(mapW, view.right);
    final top = max(0.0, view.top);
    final bottom = min(mapH, view.bottom);
    for (double x = startX; x <= endX; x += _gridSpacing) {
      if (x < 0 || x > mapW) continue;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
    for (double y = startY; y <= endY; y += _gridSpacing) {
      if (y < 0 || y > mapH) continue;
      canvas.drawLine(Offset(left, y), Offset(right, y), paint);
    }
  }

  void _drawWorldBorder(Canvas canvas, Color color, double zoom) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8 / zoom;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, controller.mapWidth, controller.mapHeight),
      paint,
    );
  }

  void _drawPellets(Canvas canvas, Rect view) {
    if (controller.pellets.isEmpty) return;
    final paint = Paint();
    for (final p in controller.pellets.values) {
      // Skip invalid entries instead of crashing the canvas.
      if (!p.x.isFinite || !p.y.isFinite || p.radius <= 0) continue;
      // Locally-predicted eats are hidden until the server confirms.
      if (controller.isPelletEatenLocally(p.id)) continue;
      if (!view.contains(Offset(p.x, p.y))) continue;
      paint.color = p.color;
      canvas.drawCircle(Offset(p.x, p.y), p.radius, paint);
    }
  }

  void _drawEjected(Canvas canvas, Rect view) {
    if (controller.ejected.isEmpty) return;
    final fillPaint = Paint();
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final e in controller.ejected.values) {
      if (!e.renderX.isFinite || !e.renderY.isFinite || e.radius <= 0) continue;
      if (!view.contains(Offset(e.renderX, e.renderY))) continue;
      fillPaint.color = e.color;
      strokePaint.color = _darken(e.color, 0.3);
      final pos = Offset(e.renderX, e.renderY);
      canvas.drawCircle(pos, e.radius, fillPaint);
      canvas.drawCircle(pos, e.radius, strokePaint);
    }
  }

  void _drawViruses(Canvas canvas, Rect view) {
    if (controller.viruses.isEmpty) return;
    final fillPaint = Paint()..color = const Color(0xFF33FF33);
    final strokePaint = Paint()
      ..color = const Color(0xFF1F8A1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    const spikes = 28;
    for (final v in controller.viruses.values) {
      if (!v.x.isFinite || !v.y.isFinite || v.radius <= 0) continue;
      if (!view.contains(Offset(v.x, v.y))) continue;
      final path = Path();
      for (int i = 0; i <= spikes * 2; i++) {
        final ang = (i / (spikes * 2)) * 2 * pi;
        final r = (i % 2 == 0) ? v.radius : v.radius * 0.94;
        final x = v.x + cos(ang) * r;
        final y = v.y + sin(ang) * r;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
    }
  }

  void _drawCells(Canvas canvas, Rect view, double zoom) {
    if (controller.cells.isEmpty) return;
    final sorted = controller.cells.values.toList()
      ..sort((a, b) => a.renderMass.compareTo(b.renderMass));
    final fillPaint = Paint();
    final strokePaint = Paint()..style = PaintingStyle.stroke;
    final quality = GameSettings.instance.graphicsQuality;
    final filter =
        quality == 0 ? FilterQuality.low : FilterQuality.medium;
    for (final c in sorted) {
      final r = c.renderRadius;
      if (!c.renderX.isFinite || !c.renderY.isFinite || r <= 0) continue;
      if (!view.contains(Offset(c.renderX, c.renderY))) continue;
      final pos = Offset(c.renderX, c.renderY);
      // Self highlight ring drawn behind the cell.
      if (c.isSelf) {
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFFFFD600).withValues(alpha: 0.8)
          ..strokeWidth = max(3.0, r * 0.12)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, max(2.0, r * 0.18));
        canvas.drawCircle(pos, r + 4, ring);
      }
      fillPaint.color = c.color;
      strokePaint
        ..color = _darken(c.color, 0.25)
        ..strokeWidth = max(2.0, r * 0.05);

      final skin = controller.skinFor(c);
      if (skin != null) {
        _drawSkinnedCell(canvas, pos, r, skin, fillPaint, strokePaint, filter);
      } else {
        canvas.drawCircle(pos, r, fillPaint);
        canvas.drawCircle(pos, r, strokePaint);
      }
      _drawLabel(canvas, c, zoom);
    }
  }

  void _drawSkinnedCell(
    Canvas canvas,
    Offset pos,
    double r,
    ui.Image skin,
    Paint fillPaint,
    Paint strokePaint,
    FilterQuality filter,
  ) {
    // Same technique as the offline GamePainter: fill the colour underneath,
    // clip to a perfect circle, blit the skin, then stroke the outline.
    canvas.drawCircle(pos, r, fillPaint);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: pos, radius: r)));
    canvas.drawImageRect(
      skin,
      Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
      Rect.fromCircle(center: pos, radius: r),
      Paint()..filterQuality = filter,
    );
    canvas.restore();
    canvas.drawCircle(pos, r, strokePaint);
  }

  void _drawLabel(Canvas canvas, OnlineCell c, double zoom) {
    final screenR = c.renderRadius * zoom;
    if (screenR < 14) return;
    final fontSize = (c.renderRadius * 0.32).clamp(12.0, 64.0);
    final tp = TextPainter(
      text: TextSpan(
        text: c.name,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(
      canvas,
      Offset(
        c.renderX - tp.width / 2,
        c.renderY - tp.height / 2 - fontSize * 0.4,
      ),
    );
    if (screenR < 24) return;
    if (!GameSettings.instance.showMassLabels) return;
    final massTp = TextPainter(
      text: TextSpan(
        text: c.renderMass.round().toString(),
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize * 0.7,
          fontWeight: FontWeight.w800,
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    massTp.layout();
    massTp.paint(
      canvas,
      Offset(c.renderX - massTp.width / 2, c.renderY + fontSize * 0.05),
    );
  }

  Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * (1 - amount)).clamp(0.0, 1.0))
        .toColor();
  }

  @override
  bool shouldRepaint(covariant OnlineClassicPainter old) => true;
}
