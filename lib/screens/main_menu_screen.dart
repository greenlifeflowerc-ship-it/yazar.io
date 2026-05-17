import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../utils/app_colors.dart';
import '../widgets/background_painter.dart';
import '../widgets/currency_display.dart';
import '../widgets/main_action_button.dart';
import 'dart:async';

import '../game/skin_settings.dart';
import '../models/boost.dart';
import '../services/auth_service.dart';
import '../widgets/boost_panel.dart';
import '../widgets/level_up_popup.dart';
import '../widgets/login_popup.dart';
import '../widgets/menu_icon_button.dart';
import '../widgets/shop_button.dart';
import 'game_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'skin_chooser_screen.dart';

class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen> {
  final TextEditingController _nicknameController = TextEditingController();

  // Fallback values used only when the player is not logged in.
  static const int _guestDna = 0;
  static const int _guestCoins = 0;
  static const int _guestLevel = 1;
  static const double _guestXpProgress = 0.0;

  bool _autoPopupShown = false;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_onAuthChanged);
    // Refresh boost state (auto-expires stale rows on the server) every time
    // we land on the main menu.
    AuthService.instance.refreshActiveBoosts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowLoginPopup();
      _maybeShowLevelUp();
    });
  }

  /// Pull any pending level-up payload (queued by the game screen after
  /// submit_match_result) and show the popup. Runs every time we land on the
  /// main menu, but is a no-op when there's nothing to show.
  Future<void> _maybeShowLevelUp() async {
    final r = AuthService.instance.consumePendingLevelUp();
    if (r == null || !mounted) return;
    await LevelUpPopup.show(
      context,
      newLevel: r.level,
      levelsGained: r.levelsGained,
      coinsAwarded: r.levelUpCoinsEarned,
      dnaAwarded: r.levelUpDnaEarned,
      unlockedSkins: r.newlyUnlockedSkins,
    );
  }

  void _onAuthChanged() {
    if (!mounted) return;
    setState(() {});
    // Pre-fill the nickname field from the profile username if the user
    // hasn't typed anything themselves.
    final username = AuthService.instance.profile?.username;
    if (username != null &&
        username.isNotEmpty &&
        _nicknameController.text.isEmpty) {
      _nicknameController.text = username;
    }
    // If a level-up was queued while we were not the active route (e.g. game
    // screen submitted), show it now.
    if (AuthService.instance.pendingLevelUp != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowLevelUp());
    }
  }

  Future<void> _maybeShowLoginPopup() async {
    if (_autoPopupShown) return;
    if (AuthService.instance.isLoggedIn) return;
    _autoPopupShown = true;
    await LoginPopup.show(context, dismissible: true);
  }

  void _openProfile() {
    if (AuthService.instance.isLoggedIn) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProfileScreen()),
      );
    } else {
      LoginPopup.show(context, dismissible: true);
    }
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
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
    final profile = AuthService.instance.profile;
    final dna = profile?.dna ?? _guestDna;
    final coins = profile?.coins ?? _guestCoins;
    return Positioned(
      top: 14,
      right: 14,
      child: Row(
        children: [
          CurrencyDisplay(
            icon: Icons.bubble_chart,
            iconColor: AppColors.dnaYellow,
            value: dna,
          ),
          const SizedBox(width: 10),
          CurrencyDisplay(
            icon: Icons.monetization_on,
            iconColor: AppColors.coinGreen,
            value: coins,
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
        // Both tiles are wired to AuthService so the multiplier badge +
        // countdown appear/disappear as boosts activate and expire.
        child: AnimatedBuilder(
          animation: AuthService.instance,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuBoostTile(
                kind: _BoostKind.xp,
                activeBoost: AuthService.instance.activeXpBoost,
                ownedQuantity: _ownedTotal('xp'),
                onTap: () => _openBoostPanel(context, 'xp'),
              ),
              const SizedBox(height: 14),
              _MenuBoostTile(
                kind: _BoostKind.mass,
                activeBoost: AuthService.instance.activeMassBoost,
                ownedQuantity: _ownedTotal('mass'),
                onTap: () => _openBoostPanel(context, 'mass'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _ownedTotal(String type) {
    var n = 0;
    for (final e in AuthService.instance.boostInventory) {
      if (e.def.type == type) n += e.quantity;
    }
    return n;
  }

  void _openBoostPanel(BuildContext context, String type) {
    if (AuthService.instance.isLoggedIn) {
      BoostPanel.show(context, type);
    } else {
      LoginPopup.show(context, dismissible: true);
    }
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
    final profile = AuthService.instance.profile;
    final level = profile?.level ?? _guestLevel;
    final progress = profile?.xpProgress ?? _guestXpProgress;
    return Positioned(
      right: 14,
      bottom: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ShopButton(onTap: () => debugPrint('Shop pressed')),
          const SizedBox(width: 10),
          // The XP bar in the bottom-right is the profile entry point: tap
          // opens the profile screen, or the login popup if there's no
          // session yet.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openProfile,
            child: XpBar(level: level, progress: progress),
          ),
        ],
      ),
    );
  }
}

enum _BoostKind { xp, mass }

/// Left-middle menu tile that doubles as a live boost indicator.
///
/// When no boost is active it renders as the original gold star / purple "M"
/// chip — no multiplier badge, no timer.
/// When a boost IS active it gets a corner multiplier badge ("2X" / "3X")
/// and a small countdown pill sitting OUTSIDE the icon (below it).
class _MenuBoostTile extends StatefulWidget {
  const _MenuBoostTile({
    required this.kind,
    required this.activeBoost,
    required this.ownedQuantity,
    required this.onTap,
  });

  final _BoostKind kind;
  final PlayerBoost? activeBoost;
  final int ownedQuantity;
  final VoidCallback onTap;

  @override
  State<_MenuBoostTile> createState() => _MenuBoostTileState();
}

class _MenuBoostTileState extends State<_MenuBoostTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _restartTicker();
  }

  @override
  void didUpdateWidget(covariant _MenuBoostTile old) {
    super.didUpdateWidget(old);
    if (widget.activeBoost?.id != old.activeBoost?.id) _restartTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _restartTicker() {
    _ticker?.cancel();
    if (widget.activeBoost == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final boost = widget.activeBoost;
    final isXp = widget.kind == _BoostKind.xp;
    final color = isXp ? AppColors.starYellow : AppColors.massPurple;
    final shadow =
        isXp ? AppColors.starYellowShadow : AppColors.massPurpleShadow;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 3D shadow under the tile.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 4,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: shadow,
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                ),
                // Tile face.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: 4,
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(13),
                      // Soft outer glow while a boost of this type is live.
                      boxShadow: boost != null
                          ? [
                              BoxShadow(
                                color: color.withValues(alpha: 0.6),
                                blurRadius: 14,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: isXp
                          ? const Icon(Icons.star,
                              color: Colors.white, size: 26)
                          : Text(
                              'M',
                              style: GoogleFonts.baloo2(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                height: 1,
                              ),
                            ),
                    ),
                  ),
                ),
                // Multiplier corner badge — only when a boost is active.
                if (boost != null)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: _multBadge(boost.multiplier),
                  ),
                // Owned-quantity badge bottom-left when player has SKUs but
                // none is active. Helps the player see they actually have
                // boosts to spend.
                if (boost == null && widget.ownedQuantity > 0)
                  Positioned(
                    left: -6,
                    bottom: 0,
                    child: _qtyBadge(widget.ownedQuantity),
                  ),
              ],
            ),
          ),
          // Countdown pill — sits outside/below the tile, only when active.
          if (boost != null) ...[
            const SizedBox(height: 5),
            _countdownPill(boost.remaining),
          ],
        ],
      ),
    );
  }

  Widget _multBadge(double m) {
    final txt = m % 1 == 0 ? m.toStringAsFixed(0) : m.toStringAsFixed(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFC107), Color(0xFFFF6A00)],
        ),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6A00).withValues(alpha: 0.45),
            blurRadius: 6,
          ),
        ],
      ),
      child: Text(
        '${txt}X',
        style: GoogleFonts.baloo2(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _qtyBadge(int qty) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        '×$qty',
        style: GoogleFonts.baloo2(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }

  Widget _countdownPill(Duration d) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.15), width: 1),
      ),
      child: Text(
        _formatRemaining(d),
        style: GoogleFonts.baloo2(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  static String _formatRemaining(Duration d) {
    final secs = d.inSeconds.clamp(0, 1 << 30);
    if (secs >= 3600) {
      final h = d.inHours;
      final m = d.inMinutes.remainder(60);
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
