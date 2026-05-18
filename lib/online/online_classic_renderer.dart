import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../game/game_settings.dart';
import 'online_classic_controller.dart';
import 'online_entities.dart';

/// Custom painter for the online classic mode.
///
/// Reads smoothed camera position / zoom directly from the controller so the
/// visual output is frame-rate independent and identical to the offline
/// GamePainter (same lerp constants, same pellet pulse, same virus geometry,
/// same cell wobble, same direction arrow).
class OnlineClassicPainter extends CustomPainter {
  OnlineClassicPainter({
    required this.controller,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final OnlineClassicController controller;

  static const _gridSpacing = 50.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final settings = GameSettings.instance;
    final renderScale = settings.renderScale;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = settings.backgroundColor,
    );

    // Camera: use smoothed position + zoom from the controller.
    // The controller already applies the zoom formula + lerp; we only multiply
    // by renderScale here so a downscaled canvas shows the same world area —
    // exactly matching GamePainter logic.
    final cx = controller.cameraX.isFinite
        ? controller.cameraX
        : controller.mapWidth / 2;
    final cy = controller.cameraY.isFinite
        ? controller.cameraY
        : controller.mapHeight / 2;
    final zoom = controller.cameraZoom * renderScale;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-cx, -cy);

    final viewW = size.width / zoom;
    final viewH = size.height / zoom;
    final viewport = Rect.fromCenter(
      center: Offset(cx, cy),
      width: viewW + 400 / zoom,
      height: viewH + 400 / zoom,
    );

    if (settings.showGrid) _drawGrid(canvas, viewport, settings.gridColor, zoom);
    _drawWorldBorder(canvas, settings.borderColor, zoom);

    _drawPellets(canvas, viewport);
    _drawEjected(canvas, viewport);
    _drawViruses(canvas, viewport, zoom);
    _drawCells(canvas, viewport, zoom);

    // Direction arrow — drawn in world space after cells, identical to offline.
    if (!controller.selfDead &&
        controller.cells.values.any((c) => c.isSelf)) {
      _drawMobileDirectionArrow(canvas, zoom);
    }

    canvas.restore();
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
      if (!p.x.isFinite || !p.y.isFinite || p.radius <= 0) continue;
      if (!view.contains(Offset(p.x, p.y))) continue;
      // Pulse animation — identical to offline GamePainter._drawPellets.
      final pulse = 1 + sin(p.pulsePhase) * 0.05;
      paint.color = p.color;
      canvas.drawCircle(Offset(p.x, p.y), p.radius * pulse, paint);
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

  void _drawViruses(Canvas canvas, Rect view, double zoom) {
    if (controller.viruses.isEmpty) return;
    final fillPaint = Paint()..color = const Color(0xFF33FF33);
    // Stroke width zoom-corrected — identical to offline GamePainter.
    final strokePaint = Paint()
      ..color = const Color(0xFF1F8A1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 / zoom;
    // 45 spikes — matches offline GamePainter._drawSingleVirus.
    const spikes = 45;
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

      // Self highlight ring — same as original.
      if (c.isSelf) {
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..color = const Color(0xFFFFD600).withValues(alpha: 0.8)
          ..strokeWidth = max(3.0, r * 0.12)
          ..maskFilter =
              MaskFilter.blur(BlurStyle.normal, max(2.0, r * 0.18));
        canvas.drawCircle(pos, r + 4, ring);
      }

      fillPaint.color = c.color;
      strokePaint
        ..color = _darken(c.color, 0.25)
        ..strokeWidth = max(2.0, r * 0.05);

      final skin = controller.skinFor(c);

      // Jelly wobble deformation — mirrors offline GamePainter._drawSingleCell.
      if (c.bumps.isNotEmpty && quality != 0) {
        _drawWobblyCell(
          canvas: canvas,
          c: c,
          pos: pos,
          r: r,
          skin: skin,
          fillPaint: fillPaint,
          strokePaint: strokePaint,
          filter: filter,
          quality: quality,
        );
      } else if (skin != null) {
        _drawSkinnedCell(canvas, pos, r, skin, fillPaint, strokePaint, filter);
      } else {
        canvas.drawCircle(pos, r, fillPaint);
        canvas.drawCircle(pos, r, strokePaint);
      }

      _drawLabel(canvas, c, zoom);
    }
  }

  /// Jelly deformation — identical algorithm to offline GamePainter.
  void _drawWobblyCell({
    required Canvas canvas,
    required OnlineCell c,
    required Offset pos,
    required double r,
    required ui.Image? skin,
    required Paint fillPaint,
    required Paint strokePaint,
    required FilterQuality filter,
    required int quality,
  }) {
    final path = Path();
    final vertices = quality == 1 ? 60 : 120;
    for (int i = 0; i <= vertices; i++) {
      final vAng = (i / vertices) * 2 * pi;
      double deformation = 0;
      for (final bump in c.bumps) {
        double diff = (vAng - bump.angle).abs();
        if (diff > pi) diff = 2 * pi - diff;
        const influenceRange = 0.4;
        if (diff < influenceRange) {
          final weight = 0.5 * (1.0 + cos((diff / influenceRange) * pi));
          deformation += bump.magnitude * weight;
        }
      }
      final rr = r * (1.0 + deformation);
      final p =
          Offset(pos.dx + cos(vAng) * rr, pos.dy + sin(vAng) * rr);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();

    if (skin != null) {
      canvas.drawPath(path, fillPaint);
      canvas.save();
      canvas.clipPath(path);
      final dst = Rect.fromCenter(
          center: pos, width: r * 2.2, height: r * 2.2);
      canvas.drawImageRect(
        skin,
        Rect.fromLTWH(
            0, 0, skin.width.toDouble(), skin.height.toDouble()),
        dst,
        Paint()..filterQuality = filter,
      );
      canvas.restore();
      canvas.drawPath(path, strokePaint);
    } else {
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
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
    canvas.drawCircle(pos, r, fillPaint);
    canvas.save();
    canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: pos, radius: r)));
    canvas.drawImageRect(
      skin,
      Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
      Rect.fromCircle(center: pos, radius: r),
      Paint()..filterQuality = filter,
    );
    canvas.restore();
    canvas.drawCircle(pos, r, strokePaint);
  }

  /// Direction arrow — identical to offline GamePainter._drawMobileDirectionArrow.
  void _drawMobileDirectionArrow(Canvas canvas, double zoom) {
    final dir = controller.lastNonZeroInputDir;
    if (dir.distance < 0.05) return;

    // Compute mass-weighted center and max extent of self cells.
    double cx = 0, cy = 0, totalMass = 0, maxDist = 0;
    for (final c in controller.cells.values) {
      if (!c.isSelf) continue;
      cx += c.renderX * c.renderMass;
      cy += c.renderY * c.renderMass;
      totalMass += c.renderMass;
    }
    if (totalMass <= 0) return;
    cx /= totalMass;
    cy /= totalMass;
    final center = Offset(cx, cy);

    for (final c in controller.cells.values) {
      if (!c.isSelf) continue;
      final d =
          (Offset(c.renderX, c.renderY) - center).distance + c.renderRadius;
      if (d > maxDist) maxDist = d;
    }

    final unit = dir / dir.distance;
    final arrowDist = maxDist + 10.0;
    final arrowCenter = center + unit * arrowDist;
    final perp = Offset(-unit.dy, unit.dx);

    final length = 30.0 / zoom;
    final width = 35.0 / zoom;
    final backIndentation = 8.0 / zoom;

    final tip = arrowCenter + unit * length;
    final p1 = arrowCenter + perp * (width / 2);
    final p2 = arrowCenter - perp * (width / 2);
    final backCenter = arrowCenter + unit * backIndentation;

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(backCenter.dx, backCenter.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
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
