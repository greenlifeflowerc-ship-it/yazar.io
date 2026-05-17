import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../game/skin_settings.dart';
import '../models/skin.dart';
import '../services/auth_service.dart';
import '../services/profile_service.dart';
import '../utils/app_colors.dart';
import '../widgets/background_painter.dart';

class _SkinTab {
  const _SkinTab(this.label, this.category);
  final String label;
  final String? category; // null = empty slot
}

class SkinChooserScreen extends StatefulWidget {
  const SkinChooserScreen({super.key});

  @override
  State<SkinChooserScreen> createState() => _SkinChooserScreenState();
}

class _SkinChooserScreenState extends State<SkinChooserScreen> {
  static const List<_SkinTab> _tabs = [
    _SkinTab('Free',    'free'),
    _SkinTab('Level',   'level'),
    _SkinTab('Premium', 'premium'),
    _SkinTab('—',       null),
  ];

  static final _fmt = NumberFormat.decimalPattern('en_US');

  int _tabIndex = 0;
  bool _loading = true;
  List<Skin> _all = [];
  String? _equippedKey;
  int _selectedIndex = 0;
  String? _busyKey;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.28);
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    // ── Try server path first (requires login) ──────────────────────────
    bool serverLoaded = false;
    if (AuthService.instance.isLoggedIn) {
      try {
        await ProfileService.instance.syncSkinCatalogueFromAssets();
        final payload = await ProfileService.instance.getPlayerSkins();
        if (!mounted) return;
        if (payload.skins.isNotEmpty) {
          setState(() {
            _all = payload.skins;
            _equippedKey = payload.equippedKey;
            _selectedIndex = 0;
            _loading = false;
          });
          serverLoaded = true;
          // Auto-pick the tab where the equipped skin lives.
          final equipped = payload.equippedKey;
          if (equipped != null) {
            final eq = _all.firstWhere(
              (s) => s.key == equipped,
              orElse: () => _all.first,
            );
            final tab = _tabs.indexWhere((t) => t.category == eq.category);
            if (tab >= 0) setState(() => _tabIndex = tab);
          }
          _jumpToSelected();
        }
      } catch (_) {
        // Fall through to local fallback.
      }
    }

    // ── Local fallback: build skins from the asset manifest ─────────────
    // Used when not logged-in, SQL migrations haven't been run, or the
    // server returned an empty catalogue.
    if (!serverLoaded) {
      await _loadLocalFallback();
    }
  }

  // Builds [Skin] objects directly from the asset manifest using the same
  // naming / pricing rules as [ProfileService.syncSkinCatalogueFromAssets].
  // Free skins are marked owned=true; level and premium skins are locked.
  Future<void> _loadLocalFallback() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final allPaths = manifest.listAssets();

      bool isImg(String p) {
        final s = p.toLowerCase();
        return s.endsWith('.png') ||
            s.endsWith('.jpg') ||
            s.endsWith('.jpeg') ||
            s.endsWith('.webp');
      }

      List<String> pick(String prefix) =>
          allPaths.where((p) => p.startsWith(prefix) && isImg(p)).toList()
            ..sort();

      String keyOf(String path) {
        final s = path.replaceFirst('assets/skins/', '');
        final dot = s.lastIndexOf('.');
        return dot > 0 ? s.substring(0, dot) : s;
      }

      String nameOf(String path) {
        final file = path.split('/').last;
        final dot = file.lastIndexOf('.');
        final stem = dot > 0 ? file.substring(0, dot) : file;
        return stem
            .replaceAll(RegExp(r'^skin_\d+_'), '')
            .replaceAll('_', ' ');
      }

      final skins = <Skin>[];

      final levels = pick('assets/skins/level/');
      for (int i = 0; i < levels.length; i++) {
        final unlockLvl = ((i + 1) * 5).clamp(5, 150);
        skins.add(Skin(
          id: keyOf(levels[i]),
          key: keyOf(levels[i]),
          name: nameOf(levels[i]),
          category: 'level',
          imagePath: levels[i],
          unlockLevel: unlockLvl,
          priceCoins: 0,
          sortOrder: i,
          owned: false,
          equipped: false,
        ));
      }

      final premiums = pick('assets/skins/premium/');
      if (premiums.isNotEmpty) {
        final n = premiums.length;
        for (int i = 0; i < n; i++) {
          final t = n == 1 ? 0.0 : i / (n - 1);
          final price = (50 + t * (9999 - 50)).round();
          skins.add(Skin(
            id: keyOf(premiums[i]),
            key: keyOf(premiums[i]),
            name: nameOf(premiums[i]),
            category: 'premium',
            imagePath: premiums[i],
            unlockLevel: 0,
            priceCoins: price,
            sortOrder: i,
            owned: false,
            equipped: false,
          ));
        }
      }

      final frees = pick('assets/skins/free/');
      for (int i = 0; i < frees.length; i++) {
        skins.add(Skin(
          id: keyOf(frees[i]),
          key: keyOf(frees[i]),
          name: nameOf(frees[i]),
          category: 'free',
          imagePath: frees[i],
          unlockLevel: 0,
          priceCoins: 0,
          sortOrder: i,
          owned: true, // free skins are always available
          equipped: false,
        ));
      }

      if (!mounted) return;
      setState(() {
        if (skins.isNotEmpty) _all = skins;
        _loading = false;
      });
      _jumpToSelected();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Skin> get _currentTabSkins =>
      _all.where((s) => s.category == _tabs[_tabIndex].category).toList()
        ..sort((a, b) => a.sortOrder - b.sortOrder);

  void _jumpToSelected() {
    if (!_pageController.hasClients) return;
    final list = _currentTabSkins;
    if (list.isEmpty) return;
    final idx = _selectedIndex.clamp(0, list.length - 1);
    _pageController.jumpToPage(idx);
  }

  void _selectTab(int i) {
    if (_tabs[i].category == null) return;
    if (i == _tabIndex) return;
    setState(() {
      _tabIndex = i;
      _selectedIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToSelected());
  }

  Skin? get _selected {
    final list = _currentTabSkins;
    if (list.isEmpty) return null;
    return list[_selectedIndex.clamp(0, list.length - 1)];
  }

  Future<void> _equip(Skin s) async {
    if (!s.owned || _busyKey != null) return;
    setState(() => _busyKey = s.key);
    try {
      if (AuthService.instance.isLoggedIn) {
        // Try server equip; if it fails (SQL not ready), just save locally.
        try {
          await ProfileService.instance.equipSkin(s.key);
        } catch (_) {}
      }
      AuthService.instance.setEquippedSkinKey(s.key);
      await SkinSettings.instance.selectSkin(s.imagePath);
      setState(() => _equippedKey = s.key);
      await _refreshSilently();
    } catch (e) {
      if (mounted) _snack(_humanError(e));
    }
    if (mounted) setState(() => _busyKey = null);
  }

  Future<void> _buyPremium(Skin s) async {
    if (_busyKey != null) return;
    if (!AuthService.instance.isLoggedIn) {
      _snack('Sign in to purchase premium skins.');
      return;
    }
    setState(() => _busyKey = s.key);
    try {
      await ProfileService.instance.buyPremiumSkin(s.key);
      await AuthService.instance.refreshProfile();
      await _refreshSilently();
    } catch (e) {
      if (mounted) _snack(_humanError(e));
    }
    if (mounted) setState(() => _busyKey = null);
  }

  Future<void> _refreshSilently() async {
    if (!AuthService.instance.isLoggedIn) return;
    try {
      final payload = await ProfileService.instance.getPlayerSkins();
      if (!mounted) return;
      if (payload.skins.isNotEmpty) {
        setState(() {
          _all = payload.skins;
          _equippedKey = payload.equippedKey;
        });
      }
    } catch (_) {}
  }

  String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('Not enough Coins')) return 'Not enough Coins.';
    if (s.contains('Already owned')) return 'You already own this skin.';
    if (s.contains("don't own")) return "You don't own this skin yet.";
    return s
        .replaceAll('Exception: ', '')
        .replaceAll('PostgrestException(message: ', '')
        .replaceAll(RegExp(r', code:.*$'), '');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF1B1247),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            const MenuBackground(pelletCount: 35),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Column(
                children: [
                  _header(),
                  const SizedBox(height: 6),
                  _tabRow(),
                  Expanded(child: _carousel()),
                  _bottomBar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final coins = AuthService.instance.profile?.coins ?? 0;
    return Row(
      children: [
        _BackChip(onTap: () => Navigator.of(context).pop()),
        const SizedBox(width: 14),
        Text(
          'SKINS',
          style: GoogleFonts.baloo2(
            color: AppColors.textDark,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
          ),
        ),
        const Spacer(),
        if (AuthService.instance.isLoggedIn)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.cardBorder, width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.monetization_on,
                    color: Color(0xFF34C924), size: 16),
                const SizedBox(width: 4),
                Text(
                  _fmt.format(coins),
                  style: GoogleFonts.baloo2(
                    color: AppColors.textDark,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _tabRow() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          for (int i = 0; i < _tabs.length; i++) Expanded(child: _tabButton(i)),
        ],
      ),
    );
  }

  Widget _tabButton(int i) {
    final t = _tabs[i];
    final selected = i == _tabIndex;
    final enabled = t.category != null;
    final color = !enabled
        ? const Color(0xFFE0E0E0)
        : selected
            ? AppColors.classicOrange
            : Colors.white;
    final shadow = !enabled
        ? const Color(0xFFB8B8B8)
        : selected
            ? AppColors.classicOrangeShadow
            : const Color(0xFFCCCCCC);
    final textColor = selected ? Colors.white : AppColors.textDark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => _selectTab(i) : null,
        child: SizedBox(
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 5,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: shadow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: 5,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: enabled ? shadow : const Color(0xFFB8B8B8),
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      t.label.toUpperCase(),
                      style: GoogleFonts.baloo2(
                        color: enabled ? textColor : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _carousel() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final list = _currentTabSkins;
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined,
                  color: AppColors.textMuted, size: 44),
              const SizedBox(height: 10),
              Text(
                'No skins in this category yet.',
                textAlign: TextAlign.center,
                style: GoogleFonts.baloo2(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return PageView.builder(
      controller: _pageController,
      itemCount: list.length,
      onPageChanged: (i) => setState(() => _selectedIndex = i),
      itemBuilder: (context, i) => _skinTile(list, i),
    );
  }

  Widget _skinTile(List<Skin> list, int i) {
    final s = list[i];
    final selected = i == _selectedIndex;
    final equipped = s.key == _equippedKey;
    final locked = !s.owned;
    return Center(
      child: AnimatedScale(
        scale: selected ? 1.0 : 0.78,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: selected ? 1.0 : 0.6,
          duration: const Duration(milliseconds: 220),
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(
                  color: equipped
                      ? const Color(0xFF34C924)
                      : selected
                          ? AppColors.classicOrange
                          : AppColors.cardBorder,
                  width: selected ? 4 : 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: selected
                        ? AppColors.classicOrange.withValues(alpha: 0.35)
                        : Colors.black.withValues(alpha: 0.08),
                    blurRadius: selected ? 24 : 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: ClipOval(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Image always rendered, but greyed out / faded when
                      // locked.
                      ColorFiltered(
                        colorFilter: locked
                            ? const ColorFilter.matrix([
                                0.2126, 0.7152, 0.0722, 0, 0,
                                0.2126, 0.7152, 0.0722, 0, 0,
                                0.2126, 0.7152, 0.0722, 0, 0,
                                0,      0,      0,      1, 0,
                              ])
                            : const ColorFilter.mode(
                                Colors.transparent, BlendMode.multiply),
                        child: Image.asset(
                          s.imagePath,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, err, st) => Container(
                            color: const Color(0xFFEEEEEE),
                            child: const Icon(Icons.broken_image,
                                color: AppColors.textMuted),
                          ),
                        ),
                      ),
                      if (locked)
                        Container(
                          color: Colors.black.withValues(alpha: 0.30),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.lock,
                                  color: Colors.white, size: 26),
                            ),
                          ),
                        ),
                      if (equipped)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Color(0xFF34C924),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check,
                                color: Colors.white, size: 14),
                          ),
                        ),
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

  Widget _bottomBar() {
    final selected = _selected;
    final hasAny = _currentTabSkins.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected != null)
            _selectionInfo(selected),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ArrowButton(
                icon: Icons.chevron_left,
                onTap: hasAny && _selectedIndex > 0
                    ? () => _pageController.previousPage(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                        )
                    : null,
              ),
              const SizedBox(width: 14),
              _primaryAction(selected),
              const SizedBox(width: 14),
              _ArrowButton(
                icon: Icons.chevron_right,
                onTap: hasAny &&
                        _selectedIndex < _currentTabSkins.length - 1
                    ? () => _pageController.nextPage(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                        )
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _selectionInfo(Skin s) {
    String line;
    Color color = AppColors.textMuted;
    if (s.owned) {
      if (s.key == _equippedKey) {
        line = 'Equipped';
        color = const Color(0xFF34C924);
      } else {
        line = 'Owned';
        color = AppColors.textDark;
      }
    } else if (s.isLevel) {
      line = 'Unlocks at Level ${s.unlockLevel}';
      color = const Color(0xFF1E9BFF);
    } else if (s.isPremium) {
      line = '${_fmt.format(s.priceCoins)} Coins';
      color = const Color(0xFF34C924);
    } else {
      line = 'Free';
    }

    return Text(
      line,
      style: GoogleFonts.baloo2(
        color: color,
        fontSize: 13,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _primaryAction(Skin? s) {
    if (s == null) {
      return const _ApplyButton(
        label: '—', enabled: false, onTap: _noop,
      );
    }
    final equipped = s.key == _equippedKey;
    final coins = AuthService.instance.profile?.coins ?? 0;
    final busy = _busyKey == s.key;

    if (!s.owned) {
      if (s.isPremium) {
        final affordable = coins >= s.priceCoins;
        return _ApplyButton(
          label: affordable ? 'BUY' : 'NOT ENOUGH',
          enabled: affordable && !busy,
          busy: busy,
          onTap: () => _buyPremium(s),
        );
      }
      // Level skin still locked → no action.
      return _ApplyButton(
        label: 'LOCKED',
        enabled: false,
        onTap: _noop,
      );
    }

    return _ApplyButton(
      label: equipped ? 'EQUIPPED' : 'EQUIP',
      enabled: !equipped && !busy,
      busy: busy,
      onTap: () => _equip(s),
    );
  }

  static void _noop() {}
}

// -------------------------------------------------------------- subwidgets

class _BackChip extends StatefulWidget {
  const _BackChip({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_BackChip> createState() => _BackChipState();
}

class _BackChipState extends State<_BackChip> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: SizedBox(
          width: 44,
          height: 48,
          child: Stack(
            children: [
              Positioned(
                left: 0, right: 0, top: 6, bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.moreBlueShadow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              Positioned(
                left: 0, right: 0, top: 0, bottom: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.moreBlue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.arrow_back,
                      color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArrowButton extends StatefulWidget {
  const _ArrowButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<_ArrowButton> createState() => _ArrowButtonState();
}

class _ArrowButtonState extends State<_ArrowButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: enabled ? Colors.white : const Color(0xFFEEEEEE),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.cardBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            widget.icon,
            color: enabled ? AppColors.textDark : AppColors.textMuted,
            size: 28,
          ),
        ),
      ),
    );
  }
}

class _ApplyButton extends StatefulWidget {
  const _ApplyButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.busy = false,
  });
  final String label;
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_ApplyButton> createState() => _ApplyButtonState();
}

class _ApplyButtonState extends State<_ApplyButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final color = widget.enabled ? AppColors.classicOrange : const Color(0xFFBBBBBB);
    final shadow = widget.enabled
        ? AppColors.classicOrangeShadow
        : const Color(0xFF888888);
    return GestureDetector(
      onTapDown:
          widget.enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: SizedBox(
          width: 200,
          height: 50,
          child: Stack(
            children: [
              Positioned(
                left: 0, right: 0, top: 6, bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: shadow,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              Positioned(
                left: 0, right: 0, top: 0, bottom: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: widget.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          )
                        : Text(
                            widget.label,
                            style: GoogleFonts.baloo2(
                              color: Colors.white,
                              fontSize: 16,
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
      ),
    );
  }
}
