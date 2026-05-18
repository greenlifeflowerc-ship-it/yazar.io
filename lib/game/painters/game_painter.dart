import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../entities/black_hole.dart';
import '../entities/cell.dart';
import '../entities/coin.dart';
import '../entities/ejected_mass.dart';
import '../entities/pellet.dart';
import '../entities/virus.dart';
import '../game_engine.dart';
import '../game_mode_type.dart';
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

    // Calculate viewport rectangle in world coordinates
    final viewW = size.width / zoom;
    final viewH = size.height / zoom;
    
    // Increased the margin slightly for smoother rendering (Culling)
    final renderMargin = 150.0 / zoom; 
    final viewport = Rect.fromCenter(
      center: engine.cameraPos,
      width: viewW + renderMargin,
      height: viewH + renderMargin,
    );

    if (settings.showGrid) _drawGrid(canvas, viewport, settings.gridColor);
    _drawWorldBorder(canvas, settings.borderColor);

    // Mode-specific world overlays drawn under the entities so cells/pellets
    // still read on top of them.
    if (engine.modeConfig.shrinkingZone) _drawSafeZone(canvas);
    if (engine.modeConfig.blackHoleMode) _drawBlackHoles(canvas);

    // Using Grid Querying for everything to optimize performance
    _drawPellets(canvas, viewport);
    if (engine.modeConfig.coinMode) _drawCoins(canvas, viewport);
    _drawEjected(canvas, viewport);
    _drawParticles(canvas, viewport);

    // Unified drawing for viruses and cells
    _drawEntities(canvas, viewport);

    canvas.restore();
  }

  void _drawSafeZone(Canvas canvas) {
    final r = engine.safeZoneRadius;
    if (r <= 0 || r >= GameConstants.worldSize) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12 / engine.cameraZoom
      ..color = const Color(0xFFFFD600).withValues(alpha: 0.75);
    canvas.drawCircle(engine.safeZoneCenter, r, paint);
    final dangerPaint = Paint()
      ..color = const Color(0xFFFF1F2D).withValues(alpha: 0.10);
    // Soft red wash beyond the boundary at a coarse approximation.
    canvas.drawCircle(
      engine.safeZoneCenter,
      r + 4000,
      Paint()
        ..color = const Color(0xFFFF1F2D).withValues(alpha: 0.04)
        ..blendMode = BlendMode.srcOver,
    );
    canvas.drawCircle(engine.safeZoneCenter, r + 30 / engine.cameraZoom,
        dangerPaint);
  }

  void _drawBlackHoles(Canvas canvas) {
    for (final bh in engine.blackHoles) {
      // Outer pull-radius hint ring.
      final pullPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / engine.cameraZoom
        ..color = const Color(0xFF40C4FF).withValues(alpha: 0.25);
      canvas.drawCircle(bh.position, bh.pullRadius, pullPaint);

      // Vortex rings rotating with phase.
      for (int i = 0; i < 4; i++) {
        final t = (bh.phase + i * 0.5) % (pi * 2);
        final ringR = bh.dangerRadius * (1 + i * 0.7);
        final ringPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(1.0, 4 / engine.cameraZoom)
          ..color = const Color(0xFF80D8FF)
              .withValues(alpha: (0.55 - i * 0.12).clamp(0.0, 1.0));
        canvas.drawArc(
          Rect.fromCircle(center: bh.position, radius: ringR),
          t,
          pi * 1.4,
          false,
          ringPaint,
        );
      }

      // Inky core.
      final corePaint = Paint()
        ..shader = ui.Gradient.radial(
          bh.position,
          bh.dangerRadius,
          [
            const Color(0xFF000000),
            const Color(0xFF1A1A2E),
            const Color(0xFF1A1A2E).withValues(alpha: 0.0),
          ],
          [0.0, 0.6, 1.0],
        );
      canvas.drawCircle(bh.position, bh.dangerRadius, corePaint);
    }
  }

  void _drawCoins(Canvas canvas, Rect view) {
    final paint = Paint();
    for (final Coin c in engine.coinGrid.queryRect(view)) {
      final pulse = 1 + sin(c.pulsePhase) * 0.12;
      final r = Coin.radius * pulse;
      paint.shader = ui.Gradient.radial(
        c.position,
        r,
        [
          const Color(0xFFFFF59D),
          const Color(0xFFFFC107),
          const Color(0xFFFF8F00),
        ],
        [0.0, 0.6, 1.0],
      );
      canvas.drawCircle(c.position, r, paint);
      paint.shader = null;
      paint.color = const Color(0xFFFFE082).withValues(alpha: 0.85);
      canvas.drawCircle(c.position, r * 0.45, paint);
    }
  }

  void _drawGrid(Canvas canvas, Rect view, Color gridColor) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1 / engine.cameraZoom;
    final startX = (view.left / _gridSpacing).floor() * _gridSpacing;
    final endX = (view.right / _gridSpacing).ceil() * _gridSpacing;
    final startY = (view.top / _gridSpacing).floor() * _gridSpacing;
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
      ..strokeWidth = 8 / engine.cameraZoom;
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
    final paint = Paint();
    // Use spatial grid query for pellets (major optimization)
    final near = engine.pelletGrid.queryRect(view);
    for (final p in near) {
      final pulse = 1 + sin(p.pulsePhase) * 0.05;
      paint.color = p.color;
      canvas.drawCircle(p.position, Pellet.radius * pulse, paint);
    }
  }

  void _drawEjected(Canvas canvas, Rect view) {
    // Use spatial grid query for ejected mass
    final near = engine.ejectGrid.queryRect(view);
    for (final EjectedMass e in near) {
      final radius = e.radius;
      final gradient = ui.Gradient.radial(
        e.position,
        radius,
        [
          e.color,
          e.color,
          Colors.grey.withValues(alpha: 0.5),
          Colors.grey.withValues(alpha: 0),
        ],
        [
          0.0,
          ((radius - 10) / radius).clamp(0.0, 1.0),
          ((radius - 2) / radius).clamp(0.0, 1.0),
          1.0,
        ],
      );

      canvas.drawCircle(e.position, radius, Paint()..shader = gradient);
    }
  }

  void _drawParticles(Canvas canvas, Rect view) {
    final paint = Paint();
    // Particles are few, but still checking against viewport
    for (final p in engine.particles) {
      if (!view.contains(p.position)) continue;
      final a = (p.life / p.maxLife).clamp(0.0, 1.0);
      paint.color = p.color.withValues(alpha: a);
      canvas.drawCircle(p.position, p.radius, paint);
    }
  }

  void _drawEntities(Canvas canvas, Rect view) {
    final entities = <_DrawableEntity>[];
    final skinByOwner = <String, ui.Image>{};

    // Use Spatial Grid to find ONLY visible cells
    final visibleCells = engine.cellGrid.queryRect(view);
    for (final c in visibleCells) {
      entities.add(_DrawableEntity(mass: c.mass, cell: c));
    }

    // Cache skins for visible players
    for (final p in engine.players) {
      if (p.isDead) continue;
      // If player has any visible cells, cache the skin
      bool isVisible = p.cells.any((c) => visibleCells.contains(c));
      if (isVisible) {
        final skin = p.skinImage;
        if (skin != null) skinByOwner[p.id] = skin;
      }
    }

    // Use Spatial Grid to find ONLY visible viruses
    final visibleViruses = engine.virusGrid.queryRect(view);
    for (final v in visibleViruses) {
      entities.add(_DrawableEntity(mass: v.mass, virus: v));
    }

    // Sort by mass so smaller objects are drawn first (Z-Index)
    entities.sort((a, b) => a.mass.compareTo(b.mass));

    final fillPaint = Paint();
    final strokePaint = Paint()..style = PaintingStyle.stroke;

    for (final entity in entities) {
      if (entity.virus != null) {
        _drawSingleVirus(canvas, entity.virus!);
      } else if (entity.cell != null) {
        _drawSingleCell(
          canvas: canvas,
          c: entity.cell!,
          skin: skinByOwner[entity.cell!.ownerId],
          fillPaint: fillPaint,
          strokePaint: strokePaint,
        );
      }
    }

    if (!engine.humanPlayer.isDead && engine.humanPlayer.cells.isNotEmpty) {
      _drawMobileDirectionArrow(canvas);
    }
  }

  void _drawMobileDirectionArrow(Canvas canvas) {
    final player = engine.humanPlayer;
    final dir = engine.lastNonZeroDir;
    if (dir.distance < 0.05) return;

    final center = player.centerOfMass;
    final unit = dir / dir.distance;
    
    double maxDist = 0;
    for (final c in player.cells) {
      final d = (c.position - center).distance + c.radius;
      if (d > maxDist) maxDist = d;
    }

    final arrowDist = maxDist + 10.0;
    final arrowCenter = center + unit * arrowDist;
    final perp = Offset(-unit.dy, unit.dx);

    final length = 30.0 / engine.cameraZoom;
    final width = 35.0 / engine.cameraZoom;
    final backIndentation = 8.0 / engine.cameraZoom;

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

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
    
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, borderPaint);
  }

  void _drawSingleVirus(Canvas canvas, Virus v) {
    final fillPaint = Paint()..color = const Color(0xFF33FF33);
    final strokePaint = Paint()
      ..color = const Color(0xFF1F8A1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 / engine.cameraZoom;

    final path = Path();
    const spikes = 45;
    for (int i = 0; i <= spikes * 2; i++) {
      final ang = (i / (spikes * 2)) * 2 * pi;
      final r = (i % 2 == 0) ? v.radius : v.radius * 0.94;
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

  void _drawSingleCell({
    required Canvas canvas,
    required Cell c,
    required ui.Image? skin,
    required Paint fillPaint,
    required Paint strokePaint,
  }) {
    final baseR = c.radius;
    final quality = GameSettings.instance.graphicsQuality;
    
    void drawPerfectCircle(Canvas canvas, Offset pos, double r) {
      if (skin != null) {
        canvas.drawCircle(pos, r, fillPaint);
        canvas.save();
        canvas.clipPath(Path()..addOval(Rect.fromCircle(center: pos, radius: r)));
        final dst = Rect.fromCircle(center: pos, radius: r);
        canvas.drawImageRect(
          skin,
          Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
          dst,
          Paint()..filterQuality = quality == 0 ? FilterQuality.low : FilterQuality.medium,
        );
        canvas.restore();
        canvas.drawCircle(pos, r, strokePaint);
      } else {
        canvas.drawCircle(pos, r, fillPaint);
        canvas.drawCircle(pos, r, strokePaint);
      }
    }

    // Teams mode: draw a soft team-coloured glow ring just behind the cell so
    // allies and enemies read instantly regardless of skin. Costs one extra
    // circle per cell — negligible.
    if (engine.isTeamsMode) {
      final team = engine.teamOf(c.ownerId);
      if (team != Team.none) {
        final glow = Paint()
          ..color = TeamConfig.glowColor(team).withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(3.0, c.radius * 0.12)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            max(2.0, c.radius * 0.18),
          );
        canvas.drawCircle(c.position, baseR + max(2.0, c.radius * 0.06), glow);
      }
    }

    // Role-based glow (Zombie Infection, Hide & Seek). Same trick as team
    // glow — Survivors get nothing so original skin is preserved.
    if (engine.modeConfig.zombieMode || engine.modeConfig.hideSeekMode) {
      final role = engine.roleOf(c.ownerId);
      final glowColor = RoleConfig.glowColor(role);
      if (glowColor != Colors.transparent &&
          role != PlayerRole.none &&
          role != PlayerRole.survivor) {
        final glow = Paint()
          ..color = glowColor.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(3.0, c.radius * 0.14)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            max(2.0, c.radius * 0.22),
          );
        canvas.drawCircle(
            c.position, baseR + max(2.0, c.radius * 0.08), glow);
      }
    }

    fillPaint.color = c.color;
    strokePaint.color = _darken(c.color, 0.25);
    strokePaint.strokeWidth = max(2.0, c.radius * 0.05);

    if (c.bumps.isEmpty || quality == 0) {
      drawPerfectCircle(canvas, c.position, baseR);
      _drawCellLabel(canvas, c);
      return;
    }

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
          double weight = 0.5 * (1.0 + cos((diff / influenceRange) * pi));
          deformation += bump.magnitude * weight;
        }
      }
      final r = baseR * (1.0 + deformation);
      final p = Offset(c.position.dx + cos(vAng) * r, c.position.dy + sin(vAng) * r);
      if (i == 0) path.moveTo(p.dx, p.dy);
      else path.lineTo(p.dx, p.dy);
    }
    path.close();

    if (skin != null) {
      canvas.drawPath(path, fillPaint);
      canvas.save();
      canvas.clipPath(path);
      final dst = Rect.fromCenter(center: c.position, width: baseR * 2.2, height: baseR * 2.2);
      canvas.drawImageRect(
        skin,
        Rect.fromLTWH(0, 0, skin.width.toDouble(), skin.height.toDouble()),
        dst,
        Paint()..filterQuality = quality == 0 ? FilterQuality.low : FilterQuality.medium,
      );
      canvas.restore();
      canvas.drawPath(path, strokePaint);
    } else {
      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, strokePaint);
    }

    _drawCellLabel(canvas, c);
  }

  void _drawCellLabel(Canvas canvas, Cell c) {
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
  bool shouldRepaint(covariant GamePainter oldDelegate) => true;
}

class _DrawableEntity {
  final double mass;
  final Cell? cell;
  final Virus? virus;
  _DrawableEntity({required this.mass, this.cell, this.virus});
}
