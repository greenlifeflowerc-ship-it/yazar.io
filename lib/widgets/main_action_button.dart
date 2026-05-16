import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MainActionButton extends StatefulWidget {
  const MainActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.shadowColor,
    required this.onTap,
    this.width = 180,
    this.height = 70,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color shadowColor;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  State<MainActionButton> createState() => _MainActionButtonState();
}

class _MainActionButtonState extends State<MainActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: SizedBox(
          width: widget.width,
          height: widget.height + 8,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 8,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.shadowColor,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(widget.icon, color: Colors.white, size: 28),
                      const SizedBox(width: 8),
                      Text(
                        widget.label,
                        style: GoogleFonts.baloo2(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
