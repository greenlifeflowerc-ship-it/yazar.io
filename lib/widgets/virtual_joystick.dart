import 'package:flutter/material.dart';

class VirtualJoystick extends StatefulWidget {
  const VirtualJoystick({
    super.key,
    required this.onChanged,
    required this.onReleased,
    this.maxRadius = 80,
    this.knobRadius = 35,
  });

  final ValueChanged<Offset> onChanged;
  final VoidCallback onReleased;
  final double maxRadius;
  final double knobRadius;

  @override
  State<VirtualJoystick> createState() => _VirtualJoystickState();
}

class _VirtualJoystickState extends State<VirtualJoystick> {
  Offset? _center;
  Offset? _knob;

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _center = d.localPosition;
      _knob = d.localPosition;
    });
    widget.onChanged(Offset.zero);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_center == null) return;
    final delta = d.localPosition - _center!;
    final mag = delta.distance;
    final clamped =
        mag > widget.maxRadius ? delta * (widget.maxRadius / mag) : delta;
    setState(() => _knob = _center! + clamped);
    widget.onChanged(clamped / widget.maxRadius);
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() {
      _center = null;
      _knob = null;
    });
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: SizedBox.expand(
        child: _center == null
            ? const SizedBox.shrink()
            : CustomPaint(
                painter: _JoystickPainter(
                  center: _center!,
                  knob: _knob!,
                  outerRadius: widget.maxRadius,
                  knobRadius: widget.knobRadius,
                ),
              ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({
    required this.center,
    required this.knob,
    required this.outerRadius,
    required this.knobRadius,
  });

  final Offset center;
  final Offset knob;
  final double outerRadius;
  final double knobRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final outerFill = Paint()..color = Colors.white.withValues(alpha: 0.35);
    final outerStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawCircle(center, outerRadius, outerFill);
    canvas.drawCircle(center, outerRadius, outerStroke);

    final shadow = Paint()..color = Colors.black.withValues(alpha: 0.25);
    canvas.drawCircle(knob + const Offset(0, 3), knobRadius, shadow);
    final knobFill = Paint()..color = Colors.white;
    canvas.drawCircle(knob, knobRadius, knobFill);
    final knobStroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(knob, knobRadius, knobStroke);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) =>
      oldDelegate.center != center || oldDelegate.knob != knob;
}
