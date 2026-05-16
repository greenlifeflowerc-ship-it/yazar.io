import 'package:flutter/material.dart';

import '../game/game_engine.dart';

class Minimap extends StatelessWidget {
  const Minimap({super.key, required this.engine, this.size = 110});

  final GameEngine engine;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24, width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CustomPaint(
          painter: _MinimapPainter(engine: engine),
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({required this.engine});
  final GameEngine engine;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / GameConstants.worldSize;

    // viruses
    final virusPaint = Paint()..color = const Color(0xFF33FF33);
    for (final v in engine.viruses) {
      canvas.drawCircle(
        Offset(v.position.dx * scale, v.position.dy * scale),
        2.5,
        virusPaint,
      );
    }

    // bots
    final botPaint = Paint()..color = Colors.white54;
    for (final p in engine.players) {
      if (p.isDead || p.isHuman) continue;
      final c = p.centerOfMass;
      canvas.drawCircle(
        Offset(c.dx * scale, c.dy * scale),
        2,
        botPaint,
      );
    }

    // player
    if (!engine.humanPlayer.isDead && engine.humanPlayer.cells.isNotEmpty) {
      final c = engine.humanPlayer.centerOfMass;
      final paint = Paint()..color = Colors.white;
      canvas.drawCircle(
        Offset(c.dx * scale, c.dy * scale),
        4,
        paint,
      );
      final ring = Paint()
        ..color = const Color(0xFFFFD60A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(
        Offset(c.dx * scale, c.dy * scale),
        5,
        ring,
      );
    }

    // viewport rectangle
    if (engine.viewportSize.width > 0 && engine.cameraZoom > 0) {
      final viewW = engine.viewportSize.width / engine.cameraZoom;
      final viewH = engine.viewportSize.height / engine.cameraZoom;
      final rect = Rect.fromCenter(
        center:
            Offset(engine.cameraPos.dx * scale, engine.cameraPos.dy * scale),
        width: viewW * scale,
        height: viewH * scale,
      );
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) => true;
}
