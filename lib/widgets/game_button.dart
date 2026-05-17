import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class GameButton extends StatefulWidget {
  const GameButton({
    super.key,
    this.onTap,
    this.onPressStart,
    this.onPressEnd,
    required this.color,
    required this.size,
    required this.builder,
    this.enabled = true,
    this.hint,
  });

  /// Fires once when the user releases a tap on the button.
  final VoidCallback? onTap;

  /// Fires the moment the user touches down on the button. Combined with
  /// [onPressEnd] this lets parents implement hold-to-repeat behaviour
  /// (e.g. macro-eject) without losing the immediate tap.
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;

  final Color color;
  final double size;
  final WidgetBuilder builder;
  final bool enabled;
  final String? hint;

  @override
  State<GameButton> createState() => _GameButtonState();
}

class _GameButtonState extends State<GameButton> {
  final Set<int> _pointers = {};
  bool get _pressed => _pointers.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final fillColor = widget.enabled
        ? widget.color.withValues(alpha: 0.9)
        : const Color(0xFF888888).withValues(alpha: 0.7);

    return Listener(
      onPointerDown: (e) {
        if (!widget.enabled) return;
        final wasEmpty = _pointers.isEmpty;
        setState(() => _pointers.add(e.pointer));
        if (wasEmpty) {
          widget.onPressStart?.call();
        }
      },
      onPointerUp: (e) {
        final wasPressed = _pointers.isNotEmpty;
        setState(() => _pointers.remove(e.pointer));
        if (wasPressed && _pointers.isEmpty) {
          widget.onPressEnd?.call();
        }
      },
      onPointerCancel: (e) {
        final wasPressed = _pointers.isNotEmpty;
        setState(() => _pointers.remove(e.pointer));
        if (wasPressed && _pointers.isEmpty) {
          widget.onPressEnd?.call();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (widget.enabled) widget.onTap?.call();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: fillColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.9),
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        offset: const Offset(0, 4),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: Center(child: widget.builder(context)),
                ),
                if (widget.hint != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -14,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.hint!,
                          style: GoogleFonts.baloo2(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SplitIcon extends StatelessWidget {
  const SplitIcon({super.key, this.size = 36, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SplitPainter(color: color),
    );
  }
}

class _SplitPainter extends CustomPainter {
  _SplitPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;
    final r = size.width * 0.28;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c.translate(-r * 1.05, 0), r, paint);
    canvas.drawCircle(c.translate(r * 1.05, 0), r, paint);
    canvas.drawLine(
      Offset(c.dx, c.dy - size.height * 0.42),
      Offset(c.dx, c.dy + size.height * 0.42),
      paint..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _SplitPainter oldDelegate) => false;
}

class EjectIcon extends StatelessWidget {
  const EjectIcon({super.key, this.size = 30, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _EjectPainter(color: color),
    );
  }
}

class _EjectPainter extends CustomPainter {
  _EjectPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final c = size.center(Offset.zero);
    final r = size.width * 0.28;
    canvas.drawCircle(c, r, paint);
    canvas.drawLine(Offset(c.dx - r * 1.6, c.dy),
        Offset(c.dx - r * 0.9, c.dy), paint);
    canvas.drawLine(Offset(c.dx + r * 0.9, c.dy),
        Offset(c.dx + r * 1.6, c.dy), paint);
    canvas.drawLine(Offset(c.dx, c.dy - r * 1.6),
        Offset(c.dx, c.dy - r * 0.9), paint);
    canvas.drawLine(Offset(c.dx, c.dy + r * 0.9),
        Offset(c.dx, c.dy + r * 1.6), paint);
  }

  @override
  bool shouldRepaint(covariant _EjectPainter oldDelegate) => false;
}
