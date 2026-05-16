import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../entities/cell.dart';
import '../entities/ejected_mass.dart';
import '../entities/pellet.dart';
import '../game_engine.dart';
import '../game_settings.dart';

class GamePainter extends CustomPainter {
  GamePainter({required this.engine, required Listenable repaint})
      : super(repaint: repaint);

  final GameEngine engine;

  static const _gridSpacing = 50.0;

  @override
  void paint(Canvas canvas, Size size) {
    engine.viewportSize = size;
    final settings = GameSettings.instance;

    final bgPaint = Paint()..color = settings.backgroundColor;
    canvas.drawRect(Offset.zero & size, bgPaint);

    canvas.save();
    final zoom = engine.cameraZoom;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-engine.cameraPos.dx, -engine.cameraPos.dy);

    final viewW = size.width / zoom;
    final viewH = size.height / zoom;
    final viewport = Rect.fromCenter(
      center: engine.cameraPos,
      width: viewW + 400,
      height: viewH + 400,
    );

    if (settings.showGrid) _drawGrid(canvas, viewport, settings.gridColor);
    _drawWorldBorder(canvas, settings.borderColor);
    _drawPellets(canvas, viewport);
    _drawEjected(canvas, viewport);
    _drawParticles(canvas, viewport);
    _drawViruses(canvas, viewport);
    _drawCells(canvas, viewport);

    canvas.restore();
  }

  void _drawGrid(Canvas canvas, Rect view, Color gridColor) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1 / engine.cameraZoom;
    final startX =
        (view.left / _gridSpacing).floor() * _gridSpacing;
    final endX = (view.right / _gridSpacing).ceil() * _gridSpacing;
    final startY =
        (view.top / _gridSpacing).floor() * _gridSpacing;
    final endY = (view.bottom / _gridSpacing).ceil() * _gridSpacing;
    final left = max(0.0, view.left);
    final right = min(GameConstants.worldSize, view.right);
    final top = max(0.0, view.top);
    final bottom = min(GameConstants.worldSize, view.bottom);
    for (double x = startX; x <= endX; x += _gridSpacing) {
      if (x < 0 || x > GameConstants.worldSize) continue;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
    for (double y = startY; y <= endY; y += _gridSpacing) {
      if (y < 0 || y > GameConstants.worldSize) continue;
      canvas.drawLine(Offset(left, y), Offset(right, y), paint);
    }
  }

  void _drawWorldBorder(Canvas canvas, Color borderColor) {
    final paint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6 / engine.cameraZoom;
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

  void _drawPellets(Canvas canvas, Rect view) {
    // With 3000 pellets, iterating the full list every frame is the most
    // expensive thing the painter does. The spatial grid trims it to whatever
    // buckets overlap the viewport — typically a few hundred pellets max.
    final paint = Paint();
    final near = engine.pelletGrid.queryRect(view);
    for (final p in near) {
      if (!view.contains(p.position)) continue;
      final pulse = 1 + sin(p.pulsePhase) * 0.05;
      paint.color = p.color;
      canvas.drawCircle(p.position, Pellet.radius * pulse, paint);
    }
  }

  void _drawEjected(Canvas canvas, Rect view) {
    final paint = Paint();
    final near = engine.ejectGrid.queryRect(view);
    for (final EjectedMass e in near) {
      if (!view.contains(e.position)) continue;
      paint.color = e.color;
      canvas.drawCircle(e.position, e.radius, paint);
    }
  }

  void _drawParticles(Canvas canvas, Rect view) {
    final paint = Paint();
    for (final p in engine.particles) {
      if (!view.contains(p.position)) continue;
      final a = (p.life / p.maxLife).clamp(0.0, 1.0);
      paint.color = p.color.withValues(alpha: a);
      canvas.drawCircle(p.position, p.radius, paint);
    }
  }

  void _drawViruses(Canvas canvas, Rect view) {
    final fillPaint = Paint()..color = const Color(0xFF33FF33);
    final strokePaint = Paint()
      ..color = const Color(0xFF1F8A1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 / engine.cameraZoom;
    const spikes = 20;
    for (final v in engine.viruses) {
      if (!view.contains(v.position)) continue;
      final path = Path();
      for (int i = 0; i <= spikes * 2; i++) {
        final t = i / (spikes * 2);
        final ang = t * 2 * pi;
        final r = (i % 2 == 0) ? v.radius : v.radius * 0.78;
        final x = v.position.dx + cos(ang) * r;
        final y = v.position.dy + sin(ang) * r;
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

  void _drawCells(Canvas canvas, Rect view) {
    final cells = <Cell>[];
    // Resolve owner skin once per paint instead of doing an O(players) lookup
    // per cell each frame.
    final skinByOwner = <String, ui.Image>{};
    for (final p in engine.players) {
      if (p.isDead) continue;
      cells.addAll(p.cells);
      final skin = p.skinImage;
      if (skin != null) skinByOwner[p.id] = skin;
    }
    cells.sort((a, b) => a.mass.compareTo(b.mass));

    final fillPaint = Paint();
    final strokePaint = Paint()..style = PaintingStyle.stroke;
    final shadowPaint = Paint();

    for (final c in cells) {
      if (!view.contains(c.position)) continue;

      // motion blur trail + directional squash are driven by the split
      // impulse only — input-driven movement keeps cells round/breathing.
      final smag = c.splitImpulse.distance;
      if (smag > 200) {
        final v = c.splitImpulse / smag;
        for (int i = 1; i <= 3; i++) {
          final off = c.position - v * (i * c.radius * 0.4);
          shadowPaint.color = c.color.withValues(alpha: 0.18 / i);
          canvas.drawCircle(off, c.radius * (1 - i * 0.06), shadowPaint);
        }
      }

      // Solid circle with jelly: subtle breathing pulse + directional squash.
      final breathe = 1.0 + sin(c.wobblePhase) * 0.025;
      final r = c.radius * breathe;

      canvas.save();
      canvas.translate(c.position.dx, c.position.dy);

      if (smag > 80) {
        final ang = atan2(c.splitImpulse.dy, c.splitImpulse.dx);
        final stretch = (smag / 2400).clamp(0.0, 0.14);
        canvas.rotate(ang);
        canvas.scale(1 + stretch, 1 - stretch * 0.8);
      }

      fillPaint.color = c.color;
      strokePaint.color = _darken(c.color, 0.25);
      strokePaint.strokeWidth = max(2.0, c.radius * 0.05);

      // Every player can wear a skin — humans pick from SkinSettings, bots get
      // a random one from SkinRegistry at game init. Lookup is O(1) via the
      // owner→skin map built once per paint.
      final skin = skinByOwner[c.ownerId];
      if (skin != null) {
        // Paint the team colour underneath so transparent PNGs still look
        // tinted instead of showing the world background through them.
        canvas.drawCircle(Offset.zero, r, fillPaint);
        final dst = Rect.fromCircle(center: Offset.zero, radius: r);
        canvas.save();
        canvas.clipPath(Path()..addOval(dst));
        canvas.drawImageRect(
          skin,
          Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
          dst,
          Paint()..filterQuality = FilterQuality.medium,
        );
        canvas.restore();
        canvas.drawCircle(Offset.zero, r, strokePaint);
      } else {
        canvas.drawCircle(Offset.zero, r, fillPaint);
        canvas.drawCircle(Offset.zero, r, strokePaint);
      }
      canvas.restore();

      _drawCellLabel(canvas, c);
    }
  }

  void _drawCellLabel(Canvas canvas, Cell c) {
    // Cells too small (in screen pixels) shouldn't bother laying out text —
    // TextPainter.layout() is the most expensive per-frame cost in the painter.
    final screenRadius = c.radius * engine.cameraZoom;
    if (screenRadius < 14) return;

    final fontSize = (c.radius * 0.32).clamp(12.0, 64.0);
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
      textDirection: ui.TextDirection.ltr,
    );
    tp.layout();
    tp.paint(
      canvas,
      Offset(c.position.dx - tp.width / 2,
          c.position.dy - tp.height / 2 - fontSize * 0.4),
    );

    // Mass label only on larger cells, and only if the setting allows it.
    if (screenRadius < 24) return;
    if (!GameSettings.instance.showMassLabels) return;
    final massTp = TextPainter(
      text: TextSpan(
        text: c.mass.toStringAsFixed(0),
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize * 0.7,
          fontWeight: FontWeight.w800,
          shadows: const [
            Shadow(color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    );
    massTp.layout();
    massTp.paint(
      canvas,
      Offset(c.position.dx - massTp.width / 2,
          c.position.dy + fontSize * 0.05),
    );
  }

  Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * (1 - amount)).clamp(0.0, 1.0))
        .toColor();
  }

  @override
  bool shouldRepaint(covariant GamePainter oldDelegate) => false;
}
