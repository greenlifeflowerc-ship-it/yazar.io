import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../utils/app_colors.dart';
import '../widgets/background_painter.dart';
import '../widgets/currency_display.dart';
import '../widgets/main_action_button.dart';
import '../game/skin_settings.dart';
import '../widgets/menu_icon_button.dart';
import '../widgets/shop_button.dart';
import 'game_screen.dart';
import 'settings_screen.dart';
import 'skin_chooser_screen.dart';

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> {
  final TextEditingController _nicknameController = TextEditingController();

  final int _dna = 26281;
  final int _coins = 996797;
  final int _level = 5;
  final double _xpProgress = 0.55;

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  void _openGame() {
    debugPrint('Classic pressed (nickname: ${_nicknameController.text})');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GameScreen(nickname: _nicknameController.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final shortest = size.shortestSide;
    final isSmall = shortest < 380;

    final titleSize = isSmall ? 44.0 : 56.0;
    final buttonWidth = isSmall ? 150.0 : 180.0;
    final buttonHeight = isSmall ? 60.0 : 70.0;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            const MenuBackground(),
            _topLeft(),
            _topRight(),
            _leftMiddle(),
            _center(titleSize, buttonWidth, buttonHeight),
            _bottomLeft(),
            _bottomRight(),
          ],
        ),
      ),
    );
  }

  Widget _topLeft() {
    return Positioned(
      top: 10,
      left: 12,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              MenuIconButton(
                icon: Icons.card_giftcard,
                color: AppColors.freeGreen,
                shadowColor: AppColors.freeGreenShadow,
                label: 'Free',
                badge: '!',
                onTap: () => debugPrint('Free pressed'),
              ),
              const SizedBox(height: 4),
              Text(
                '19h 16m',
                style: GoogleFonts.baloo2(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          MenuIconButton(
            icon: Icons.refresh,
            color: AppColors.cyanButton,
            shadowColor: AppColors.cyanButtonShadow,
            onTap: () => debugPrint('Refresh pressed'),
          ),
          const SizedBox(width: 8),
          MenuIconButton(
            icon: Icons.science,
            color: AppColors.cyanButton,
            shadowColor: AppColors.cyanButtonShadow,
            badge: '!',
            onTap: () => debugPrint('Potion pressed'),
          ),
        ],
      ),
    );
  }

  Widget _topRight() {
    return Positioned(
      top: 14,
      right: 14,
      child: Row(
        children: [
          CurrencyDisplay(
            icon: Icons.bubble_chart,
            iconColor: AppColors.dnaYellow,
            value: _dna,
          ),
          const SizedBox(width: 10),
          CurrencyDisplay(
            icon: Icons.monetization_on,
            iconColor: AppColors.coinGreen,
            value: _coins,
          ),
        ],
      ),
    );
  }

  Widget _leftMiddle() {
    return Positioned(
      left: 14,
      top: 0,
      bottom: 0,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _boostTile(
              icon: Icons.star,
              color: AppColors.starYellow,
              shadowColor: AppColors.starYellowShadow,
              count: '3X',
              label: '763',
              onTap: () => debugPrint('Level boost pressed'),
            ),
            const SizedBox(height: 10),
            _boostTile(
              icon: Icons.bolt,
              color: AppColors.massPurple,
              shadowColor: AppColors.massPurpleShadow,
              count: '2X',
              label: '35',
              showM: true,
              onTap: () => debugPrint('Mass boost pressed'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boostTile({
    required IconData icon,
    required Color color,
    required Color shadowColor,
    required String count,
    required String label,
    bool showM = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 4,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: shadowColor,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 4,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: showM
                      ? Text(
                          'M',
                          style: GoogleFonts.baloo2(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        )
                      : Icon(icon, color: Colors.white, size: 28),
                ),
              ),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.classicOrange,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text(
                  count,
                  style: GoogleFonts.baloo2(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
            ),
            Positioned(
              left: -2,
              bottom: -8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.cardBorder, width: 1.2),
                ),
                child: Text(
                  label,
                  style: GoogleFonts.baloo2(
                    color: AppColors.textDark,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _center(double titleSize, double buttonWidth, double buttonHeight) {
    return Positioned.fill(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'YAZAR.IO',
              style: GoogleFonts.baloo2(
                color: AppColors.textDark,
                fontSize: titleSize,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                height: 1,
              ),
            ),
            const SizedBox(height: 14),
            _nicknameRow(),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MainActionButton(
                  label: 'Classic',
                  icon: Icons.play_arrow,
                  color: AppColors.classicOrange,
                  shadowColor: AppColors.classicOrangeShadow,
                  width: buttonWidth,
                  height: buttonHeight,
                  onTap: _openGame,
                ),
                const SizedBox(width: 16),
                MainActionButton(
                  label: 'More',
                  icon: Icons.star,
                  color: AppColors.moreBlue,
                  shadowColor: AppColors.moreBlueShadow,
                  width: buttonWidth,
                  height: buttonHeight,
                  onTap: () => debugPrint('More pressed'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _nicknameRow() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: SkinSettings.instance,
          builder: (context, _) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SkinChooserScreen()),
              );
              if (mounted) setState(() {}); // refresh avatar preview
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: AppColors.cardBorder, width: 2),
                  ),
                  child: ClipOval(
                    child: SkinSettings.instance.skinPath != null
                        ? Image.asset(
                            SkinSettings.instance.skinPath!,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, st) => const Icon(
                                Icons.person,
                                color: AppColors.textMuted,
                                size: 28),
                          )
                        : const Icon(Icons.person,
                            color: AppColors.textMuted, size: 28),
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: AppColors.shopGreen,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.add,
                        color: Colors.white, size: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 240,
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.cardBorder, width: 2),
          ),
          child: TextField(
            controller: _nicknameController,
            textAlignVertical: TextAlignVertical.center,
            style: GoogleFonts.baloo2(
              color: AppColors.textDark,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              hintText: 'Nickname',
              hintStyle: GoogleFonts.baloo2(
                color: AppColors.textMuted,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bottomLeft() {
    return Positioned(
      left: 14,
      bottom: 14,
      child: Row(
        children: [
          MenuIconButton(
            icon: Icons.build,
            color: AppColors.moreBlue,
            shadowColor: AppColors.moreBlueShadow,
            size: 46,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          const SizedBox(width: 8),
          MenuIconButton(
            icon: Icons.people,
            color: AppColors.moreBlue,
            shadowColor: AppColors.moreBlueShadow,
            size: 46,
            onTap: () => debugPrint('Friends pressed'),
          ),
        ],
      ),
    );
  }

  Widget _bottomRight() {
    return Positioned(
      right: 14,
      bottom: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ShopButton(onTap: () => debugPrint('Shop pressed')),
          const SizedBox(width: 10),
          XpBar(level: _level, progress: _xpProgress),
        ],
      ),
    );
  }
}
