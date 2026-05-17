import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/skin.dart';

class LevelUpPopup extends StatefulWidget {
  const LevelUpPopup({
    super.key,
    required this.newLevel,
    required this.levelsGained,
    required this.coinsAwarded,
    required this.dnaAwarded,
    required this.unlockedSkins,
  });

  final int newLevel;
  final int levelsGained;
  final int coinsAwarded;
  final int dnaAwarded;
  final List<UnlockedSkin> unlockedSkins;

  static Future<void> show(
    BuildContext context, {
    required int newLevel,
    required int levelsGained,
    required int coinsAwarded,
    required int dnaAwarded,
    required List<UnlockedSkin> unlockedSkins,
  }) {
    return showGeneralDialog(
      context: context,
      barrierLabel: 'level-up',
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      pageBuilder: (ctx, a, b) => LevelUpPopup(
        newLevel: newLevel,
        levelsGained: levelsGained,
        coinsAwarded: coinsAwarded,
        dnaAwarded: dnaAwarded,
        unlockedSkins: unlockedSkins,
      ),
      transitionDuration: const Duration(milliseconds: 280),
      transitionBuilder: (ctx, anim, b, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.86, end: 1.0)
                .chain(CurveTween(curve: Curves.easeOutBack))
                .animate(anim),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<LevelUpPopup> createState() => _LevelUpPopupState();
}

class _LevelUpPopupState extends State<LevelUpPopup>
    with SingleTickerProviderStateMixin {
  static final _fmt = NumberFormat.decimalPattern('en_US');
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSkins = widget.unlockedSkins.isNotEmpty;
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xE6181233),
                        Color(0xE60E2147),
                        Color(0xE61E3556),
                      ],
                    ),
                    border: Border.all(
                        color: const Color(0xFFFFC107).withValues(alpha: 0.5),
                        width: 1.2),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _header(),
                      const SizedBox(height: 14),
                      _rewards(),
                      if (hasSkins) ...[
                        const SizedBox(height: 16),
                        _unlockedHeader(),
                        const SizedBox(height: 10),
                        _skinsCarousel(),
                      ],
                      const SizedBox(height: 18),
                      _continueButton(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Column(
      children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            final t = _pulse.value;
            return Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [
                  Color(0xFFFFC107),
                  Color(0xFFFF6A00),
                ]),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFC107)
                        .withValues(alpha: 0.35 + 0.3 * t),
                    blurRadius: 28 + 14 * t,
                    spreadRadius: 4 + 6 * t,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '${widget.newLevel}',
                  style: GoogleFonts.baloo2(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          'LEVEL UP',
          style: GoogleFonts.baloo2(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        if (widget.levelsGained > 1)
          Text(
            'You gained ${widget.levelsGained} levels!',
            style: GoogleFonts.baloo2(
              color: const Color(0xFFFFC107),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );
  }

  Widget _rewards() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _rewardPill(
          icon: Icons.monetization_on,
          color: const Color(0xFF34C924),
          label: '+${_fmt.format(widget.coinsAwarded)}',
        ),
        const SizedBox(width: 10),
        _rewardPill(
          icon: Icons.bubble_chart,
          color: const Color(0xFFFFD60A),
          label: '+${_fmt.format(widget.dnaAwarded)}',
        ),
      ],
    );
  }

  Widget _rewardPill({
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _unlockedHeader() {
    return Text(
      widget.unlockedSkins.length == 1
          ? 'NEW SKIN UNLOCKED!'
          : '${widget.unlockedSkins.length} NEW SKINS UNLOCKED!',
      style: GoogleFonts.baloo2(
        color: const Color(0xFF00C8E0),
        fontSize: 13,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.5,
      ),
    );
  }

  Widget _skinsCarousel() {
    final list = widget.unlockedSkins;
    return SizedBox(
      height: 130,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: list.length,
        separatorBuilder: (ctx, idx) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final s = list[i];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(
                      color: const Color(0xFF00C8E0), width: 3),
                  boxShadow: [
                    BoxShadow(
                      color:
                          const Color(0xFF00C8E0).withValues(alpha: 0.45),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Image.asset(
                      s.imagePath,
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, err, st) => const Icon(
                          Icons.broken_image,
                          color: Colors.white24),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Lv ${s.unlockLevel}',
                style: GoogleFonts.baloo2(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _continueButton() {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        width: double.infinity,
        height: 50,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [
              Color(0xFFA63CFF),
              Color(0xFF1E9BFF),
              Color(0xFF00C8E0),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1E9BFF).withValues(alpha: 0.45),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          'AWESOME',
          style: GoogleFonts.baloo2(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.4,
          ),
        ),
      ),
    );
  }
}
