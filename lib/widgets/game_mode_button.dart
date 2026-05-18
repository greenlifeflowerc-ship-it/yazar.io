import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/game_mode.dart';

class GameModeButton extends StatefulWidget {
  const GameModeButton({
    super.key,
    required this.mode,
    required this.onTap,
    this.width = 140,
    this.height = 64,
  });

  final GameMode mode;
  final VoidCallback onTap;
  final double width;
  final double height;

  @override
  State<GameModeButton> createState() => _GameModeButtonState();
}

class _GameModeButtonState extends State<GameModeButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.4, end: 0.9).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  // Outer glow pulse
                  BoxShadow(
                    color: mode.glowColor
                        .withValues(alpha: _pulseAnimation.value * 0.6),
                    blurRadius: 14,
                    spreadRadius: 0.5,
                  ),
                  // Drop shadow
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Base layered gradient
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: mode.gradientColors,
                        ),
                      ),
                    ),
                    // Top sheen overlay
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.28),
                              Colors.white.withValues(alpha: 0.0),
                              Colors.black.withValues(alpha: 0.25),
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                    // Decorative radial glow on the right
                    Positioned(
                      right: -20,
                      top: -20,
                      child: Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              mode.glowColor.withValues(alpha: 0.6),
                              mode.glowColor.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Inner glow border
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                    // Content
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          // Icon (no background)
                          SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(
                              mode.icon,
                              color: Colors.white,
                              size: 26,
                              shadows: [
                                Shadow(
                                  color: mode.glowColor
                                      .withValues(alpha: 0.9),
                                  blurRadius: 8,
                                ),
                                Shadow(
                                  color: Colors.black
                                      .withValues(alpha: 0.5),
                                  blurRadius: 3,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 7),
                          // Title + subtitle
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  mode.name,
                                  style: GoogleFonts.baloo2(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                    height: 1.05,
                                    letterSpacing: 0.3,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.55),
                                        blurRadius: 3,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  mode.subtitle,
                                  style: GoogleFonts.baloo2(
                                    color: Colors.white
                                        .withValues(alpha: 0.85),
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                    letterSpacing: 0.2,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
