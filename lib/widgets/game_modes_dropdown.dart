import 'package:flutter/material.dart';

import '../models/game_mode.dart';
import 'game_mode_button.dart';

class GameModesDropdown extends StatefulWidget {
  const GameModesDropdown({
    super.key,
    required this.isOpen,
    required this.onModeSelected,
  });

  final bool isOpen;
  final Function(String modeId) onModeSelected;

  @override
  State<GameModesDropdown> createState() => _GameModesDropdownState();
}

class _GameModesDropdownState extends State<GameModesDropdown>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 320),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutBack,
      ),
    );

    if (widget.isOpen) _animationController.forward();
  }

  @override
  void didUpdateWidget(GameModesDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen && !oldWidget.isOpen) {
      _animationController.forward();
    } else if (!widget.isOpen && oldWidget.isOpen) {
      _animationController.reverse();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handleModeSelected(String modeId) {
    debugPrint('Game mode selected: $modeId');
    widget.onModeSelected(modeId);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isSmall = size.shortestSide < 380;

    // 5 columns x 2 rows. Sized to stay compact and responsive.
    const columns = 5;
    const spacing = 8.0;
    final maxPanelWidth = isSmall ? 560.0 : 720.0;
    final panelWidth =
        size.width * 0.92 < maxPanelWidth ? size.width * 0.92 : maxPanelWidth;
    final cardWidth =
        (panelWidth - 8 /*panel padding*/ - spacing * (columns - 1)) /
            columns;
    final cardHeight = isSmall ? 56.0 : 62.0;

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: SizedBox(
            width: panelWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Wrap(
                spacing: spacing,
                runSpacing: spacing,
                alignment: WrapAlignment.center,
                children: [
                  for (final mode in gameModes)
                    GameModeButton(
                      mode: mode,
                      width: cardWidth,
                      height: cardHeight,
                      onTap: () => _handleModeSelected(mode.id),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
