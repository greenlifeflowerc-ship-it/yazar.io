import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

class DeathScreen extends StatelessWidget {
  const DeathScreen({
    super.key,
    required this.highestMass,
    required this.timeSurvived,
    required this.eatenCount,
    required this.rank,
    required this.onPlayAgain,
    required this.onMainMenu,
  });

  final double highestMass;
  final double timeSurvived;
  final int eatenCount;
  final int rank;
  final VoidCallback onPlayAgain;
  final VoidCallback onMainMenu;

  String _formatTime(double seconds) {
    final m = (seconds / 60).floor();
    final s = (seconds % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern('en_US');
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'YOU DIED',
                style: GoogleFonts.baloo2(
                  color: const Color(0xFFFF1F2D),
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 14),
              _statRow('Highest mass', fmt.format(highestMass.round())),
              _statRow('Time survived', _formatTime(timeSurvived)),
              _statRow('Cells eaten', '$eatenCount'),
              _statRow('Best rank', rank > 0 ? '#$rank' : '—'),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _menuButton(
                    label: 'PLAY AGAIN',
                    color: const Color(0xFFFF6A00),
                    shadow: const Color(0xFFB73A00),
                    onTap: onPlayAgain,
                  ),
                  const SizedBox(width: 16),
                  _menuButton(
                    label: 'MAIN MENU',
                    color: const Color(0xFF1E9BFF),
                    shadow: const Color(0xFF0066C8),
                    onTap: onMainMenu,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: GoogleFonts.baloo2(
                color: const Color(0xFF8A8A8A),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.baloo2(
              color: const Color(0xFF2A2A2A),
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuButton({
    required String label,
    required Color color,
    required Color shadow,
    required VoidCallback onTap,
  }) {
    return _Press(
      onTap: onTap,
      child: SizedBox(
        width: 180,
        height: 56,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 6,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: shadow,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 6,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(
                    label,
                    style: GoogleFonts.baloo2(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Press extends StatefulWidget {
  const _Press({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
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
        duration: const Duration(milliseconds: 80),
        child: widget.child,
      ),
    );
  }
}
