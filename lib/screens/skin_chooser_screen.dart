import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:google_fonts/google_fonts.dart';

import '../game/skin_settings.dart';
import '../utils/app_colors.dart';
import '../widgets/background_painter.dart';

class _SkinTab {
  const _SkinTab(this.label, this.folder);
  final String label;
  final String? folder; // null = empty/placeholder
}

class SkinChooserScreen extends StatefulWidget {
  const SkinChooserScreen({super.key});

  @override
  State<SkinChooserScreen> createState() => _SkinChooserScreenState();
}

class _SkinChooserScreenState extends State<SkinChooserScreen> {
  static const List<_SkinTab> _tabs = [
    _SkinTab('Level', 'assets/skins/level/'),
    _SkinTab('Premium', 'assets/skins/premium/'),
    _SkinTab('—', null),
    _SkinTab('—', null),
  ];

  static const _imageExtensions = ['.png', '.jpg', '.jpeg', '.webp'];

  int _tabIndex = 0;
  List<String> _skins = [];
  int _skinIndex = 0;
  bool _loading = true;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.28);
    _loadCurrentTab();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentTab() async {
    final tab = _tabs[_tabIndex];
    if (tab.folder == null) {
      setState(() {
        _skins = [];
        _skinIndex = 0;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest
          .listAssets()
          .where((a) =>
              a.startsWith(tab.folder!) &&
              _imageExtensions.any((e) => a.toLowerCase().endsWith(e)))
          .toList()
        ..sort();
      if (!mounted) return;
      // Try to keep the user on their currently-equipped skin if it's in this
      // tab.
      final selectedPath = SkinSettings.instance.skinPath;
      final preIndex = selectedPath != null ? assets.indexOf(selectedPath) : -1;
      setState(() {
        _skins = assets;
        _skinIndex = preIndex >= 0 ? preIndex : 0;
        _loading = false;
      });
      if (assets.isNotEmpty && _pageController.hasClients) {
        _pageController.jumpToPage(_skinIndex);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _skins = [];
        _skinIndex = 0;
        _loading = false;
      });
    }
  }

  void _selectTab(int i) {
    if (_tabs[i].folder == null) return;
    if (i == _tabIndex) return;
    setState(() => _tabIndex = i);
    _loadCurrentTab();
  }

  Future<void> _applySelected() async {
    if (_skins.isEmpty) return;
    await SkinSettings.instance.selectSkin(_skins[_skinIndex]);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _clearAndExit() async {
    await SkinSettings.instance.selectSkin(null);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: false, // header/tabs hug the very top of the screen
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

  // ---------------------------------------------------------------- header
  Widget _header() {
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
        // Right-side "no skin" reset.
        if (SkinSettings.instance.skinPath != null)
          TextButton(
            onPressed: _clearAndExit,
            child: Text(
              'NO SKIN',
              style: GoogleFonts.baloo2(
                color: AppColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- tabs
  Widget _tabRow() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          for (int i = 0; i < _tabs.length; i++)
            Expanded(child: _tabButton(i)),
        ],
      ),
    );
  }

  Widget _tabButton(int i) {
    final t = _tabs[i];
    final selected = i == _tabIndex;
    final enabled = t.folder != null;
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

  // ------------------------------------------------------------- carousel
  Widget _carousel() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_skins.isEmpty) {
      final folder = _tabs[_tabIndex].folder;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                folder == null ? Icons.lock_outline : Icons.image_outlined,
                color: AppColors.textMuted,
                size: 44,
              ),
              const SizedBox(height: 10),
              Text(
                folder == null
                    ? 'Coming soon'
                    : 'No skins yet — drop images into\n$folder',
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
      itemCount: _skins.length,
      onPageChanged: (i) => setState(() => _skinIndex = i),
      itemBuilder: (context, i) => _skinTile(i),
    );
  }

  Widget _skinTile(int i) {
    final selected = i == _skinIndex;
    final equipped = _skins[i] == SkinSettings.instance.skinPath;
    return Center(
      child: AnimatedScale(
        scale: selected ? 1.0 : 0.78,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: selected ? 1.0 : 0.65,
          duration: const Duration(milliseconds: 220),
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(
                  color: selected
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
                      Image.asset(
                        _skins[i],
                        fit: BoxFit.cover,
                        errorBuilder: (ctx, err, st) => Container(
                          color: const Color(0xFFEEEEEE),
                          child: const Icon(Icons.broken_image,
                              color: AppColors.textMuted),
                        ),
                      ),
                      if (equipped)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: AppColors.shopGreen,
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

  // ------------------------------------------------------------- bottom bar
  Widget _bottomBar() {
    final hasSkin = _skins.isNotEmpty;
    final isEquipped =
        hasSkin && _skins[_skinIndex] == SkinSettings.instance.skinPath;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ArrowButton(
            icon: Icons.chevron_left,
            onTap: hasSkin && _skinIndex > 0
                ? () => _pageController.previousPage(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                    )
                : null,
          ),
          const SizedBox(width: 16),
          _ApplyButton(
            label: !hasSkin
                ? 'NO SKINS'
                : isEquipped
                    ? 'EQUIPPED'
                    : 'USE THIS SKIN',
            enabled: hasSkin && !isEquipped,
            onTap: _applySelected,
          ),
          const SizedBox(width: 16),
          _ArrowButton(
            icon: Icons.chevron_right,
            onTap: hasSkin && _skinIndex < _skins.length - 1
                ? () => _pageController.nextPage(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                    )
                : null,
          ),
        ],
      ),
    );
  }
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
                left: 0,
                right: 0,
                top: 6,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.moreBlueShadow,
                    borderRadius: BorderRadius.circular(12),
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
            color: enabled
                ? Colors.white
                : const Color(0xFFEEEEEE),
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
  });
  final String label;
  final bool enabled;
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
