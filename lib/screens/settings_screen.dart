import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../game/game_settings.dart';
import '../utils/app_colors.dart';
import '../widgets/background_painter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  GameSettings get _s => GameSettings.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBg,
      body: SafeArea(
        child: Stack(
          children: [
            const MenuBackground(pelletCount: 35),
            AnimatedBuilder(
              animation: _s,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  _backgroundSection(),
                                  const SizedBox(height: 10),
                                  _displaySection(),
                                  const SizedBox(height: 10),
                                  _performanceSection(),
                                  const SizedBox(height: 10),
                                  _themeSection(),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _gameplaySection(),
                                  const SizedBox(height: 10),
                                  _controlsSection(),
                                  const SizedBox(height: 10),
                                  _resetButton(),
                                ],
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
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        _PressableCircle(
          onTap: () => Navigator.of(context).pop(),
          color: AppColors.moreBlue,
          shadow: AppColors.moreBlueShadow,
          icon: Icons.arrow_back,
        ),
        const SizedBox(width: 14),
        Text(
          'SETTINGS',
          style: GoogleFonts.baloo2(
            color: AppColors.primaryText,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorderColor, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: GoogleFonts.baloo2(
              color: AppColors.primaryText,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _backgroundSection() {
    return _card(
      title: 'BACKGROUND',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final color in kBackgroundPalette)
            _colorSwatch(color, selected: _s.backgroundColor.toARGB32() == color.toARGB32()),
        ],
      ),
    );
  }

  Widget _colorSwatch(Color color, {required bool selected}) {
    return GestureDetector(
      onTap: () => _s.backgroundColor = color,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppColors.classicOrange : AppColors.cardBorder,
            width: selected ? 3 : 1.5,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.classicOrange.withValues(alpha: 0.35),
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
      ),
    );
  }

  Widget _displaySection() {
    return _card(
      title: 'DISPLAY',
      child: Column(
        children: [
          _toggleRow('Show grid', _s.showGrid, (v) => _s.showGrid = v),
          _toggleRow('Show mass on cells', _s.showMassLabels,
              (v) => _s.showMassLabels = v),
          _toggleRow('Show FPS', _s.showFps, (v) => _s.showFps = v),
          _toggleRow('Show minimap', _s.showMinimap,
              (v) => _s.showMinimap = v),
        ],
      ),
    );
  }

  Widget _gameplaySection() {
    return _card(
      title: 'GAMEPLAY',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sliderRow(
            'Zoom',
            _s.zoomMultiplier,
            min: 0.2,
            max: 10.0,
            onChanged: (v) => _s.zoomMultiplier = v,
          ),
          _sliderRow(
            'Eject distance',
            _s.ejectDistanceMultiplier,
            min: 0.5,
            max: 2.5,
            onChanged: (v) => _s.ejectDistanceMultiplier = v,
          ),
          _sliderRow(
            'Feed speed 1',
            _s.feedSpeedMultiplier,
            min: 0.5,
            max: 150.0,
            onChanged: (v) => _s.feedSpeedMultiplier = v,
          ),
          _sliderRow(
            'Feed speed 2',
            _s.feedSpeedMultiplier2,
            min: 0.5,
            max: 150.0,
            onChanged: (v) => _s.feedSpeedMultiplier2 = v,
          ),
          _sliderRow(
            'Eject speed',
            _s.ejectSpeedMultiplier,
            min: 0.5,
            max: 2.5,
            onChanged: (v) => _s.ejectSpeedMultiplier = v,
          ),
          _toggleRow(
            'Stop on release',
            _s.stopOnRelease,
            (v) => _s.stopOnRelease = v,
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.baloo2(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Transform.scale(
            scale: 0.8,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.classicOrange,
              activeTrackColor: AppColors.classicOrange.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sliderRow(
    String label,
    double value, {
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.baloo2(
                    color: AppColors.primaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${value.toStringAsFixed(2)}×',
                style: GoogleFonts.baloo2(
                  color: AppColors.classicOrange,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: AppColors.classicOrange,
              inactiveTrackColor: AppColors.classicOrange.withValues(alpha: 0.2),
              thumbColor: AppColors.classicOrange,
            ),
            child: Slider(
              min: min,
              max: max,
              value: value.clamp(min, max),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlsSection() {
    return _card(
      title: 'CONTROLS',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sliderRow(
            'Button size',
            _s.buttonScale,
            min: 0.6,
            max: 1.5,
            onChanged: (v) => _s.buttonScale = v,
          ),
          _toggleRow(
            'Joystick on right',
            _s.joystickOnRight,
            (v) => _s.joystickOnRight = v,
          ),
          _toggleRow(
            'PC Mode',
            _s.pcMode,
            (v) => _s.pcMode = v,
          ),
          if (_s.pcMode)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                'Use mouse movement with Space to split and W/E to feed.',
                style: GoogleFonts.baloo2(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _themeSection() {
    return _card(
      title: 'THEME',
      child: _toggleRow(
        'Night mode',
        _s.darkMode,
        (v) => _s.darkMode = v,
      ),
    );
  }

  Widget _performanceSection() {
    return _card(
      title: 'PERFORMANCE',
      child: Column(
        children: [
          _segmentedRow<int>(
            'Quality',
            _s.graphicsQuality,
            {0: 'Low', 1: 'Med', 2: 'High'},
            (v) => _s.graphicsQuality = v!,
          ),
          const SizedBox(height: 8),
          _segmentedRow<int>(
            'FPS Cap',
            _s.fpsCap,
            {60: '60', 90: '90', 120: '120', 144: '144', 0: '∞'},
            (v) => _s.fpsCap = v!,
          ),
          const SizedBox(height: 8),
          _segmentedRow<int>(
            'Resolution',
            (_s.renderScale * 100).round(),
            {60: '60%', 80: '80%', 100: '100%', 125: '125%'},
            (v) => _s.renderScale = (v ?? 100) / 100.0,
          ),
        ],
      ),
    );
  }

  Widget _segmentedRow<T>(
    String label,
    T value,
    Map<T, String> options,
    ValueChanged<T?> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: GoogleFonts.baloo2(
              color: AppColors.primaryText,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.cardBorder.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: options.entries.map((e) {
                final isSelected = e.key == value;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => onChanged(e.key),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected ? AppColors.classicOrange : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          e.value,
                          style: GoogleFonts.baloo2(
                            color: isSelected ? Colors.white : AppColors.primaryText,
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resetButton() {
    return _PressableButton(
      onTap: _s.resetToDefaults,
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
                  color: AppColors.classicOrangeShadow,
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
                  color: AppColors.classicOrange,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    'RESET TO DEFAULTS',
                    style: GoogleFonts.baloo2(
                      color: Colors.white,
                      fontSize: 14,
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

class _PressableCircle extends StatefulWidget {
  const _PressableCircle({
    required this.onTap,
    required this.color,
    required this.shadow,
    required this.icon,
  });
  final VoidCallback onTap;
  final Color color;
  final Color shadow;
  final IconData icon;

  @override
  State<_PressableCircle> createState() => _PressableCircleState();
}

class _PressableCircleState extends State<_PressableCircle> {
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
                    color: widget.shadow,
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
                    color: widget.color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(widget.icon, color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PressableButton extends StatefulWidget {
  const _PressableButton({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
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
        child: widget.child,
      ),
    );
  }
}
