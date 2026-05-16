import 'dart:math';

import 'package:flutter/material.dart';

import '../utils/app_colors.dart';

class _Pellet {
  _Pellet(this.dx, this.dy, this.radius, this.color);

  final double dx;
  final double dy;
  final double radius;
  final Color color;
}

class MenuBackground extends StatefulWidget {
  const MenuBackground({super.key, this.pelletCount = 55});

  final int pelletCount;

  @override
  State<MenuBackground> createState() => _MenuBackgroundState();
}

class _MenuBackgroundState extends State<MenuBackground> {
  late final List<_Pellet> _pellets;

  @override
  void initState() {
    super.initState();
    final rng = Random(42);
    _pellets = List.generate(widget.pelletCount, (_) {
      return _Pellet(
        rng.nextDouble(),
        rng.nextDouble(),
        6 + rng.nextDouble() * 8,
        AppColors.pelletColors[rng.nextInt(AppColors.pelletColors.length)],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _BackgroundPainter(pellets: _pellets),
      ),
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({required this.pellets});

  final List<_Pellet> pellets;

  static const double _gridSpacing = 40;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = AppColors.background;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final gridPaint = Paint()
      ..color = AppColors.gridLine
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += _gridSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y <= size.height; y += _gridSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    for (final pellet in pellets) {
      final paint = Paint()..color = pellet.color;
      final shadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.06)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      final center = Offset(pellet.dx * size.width, pellet.dy * size.height);
      canvas.drawCircle(center.translate(0, 1.5), pellet.radius, shadowPaint);
      canvas.drawCircle(center, pellet.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BackgroundPainter oldDelegate) =>
      oldDelegate.pellets != pellets;
}
