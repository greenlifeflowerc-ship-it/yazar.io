import 'package:flutter/material.dart';

const List<Color> kBackgroundPalette = [
  Color(0xFFF5F5F5), // off-white (default)
  Color(0xFF1A1A1A), // dark
  Color(0xFFDCEEFF), // sky blue
  Color(0xFFE0F5E0), // mint
  Color(0xFFFFEBDE), // peach
  Color(0xFF2C1B47), // night purple
];

class GameSettings extends ChangeNotifier {
  GameSettings._();
  static final GameSettings instance = GameSettings._();

  // Visual
  Color _backgroundColor = const Color(0xFFF5F5F5);
  Color get backgroundColor => _backgroundColor;
  set backgroundColor(Color v) {
    if (_backgroundColor.toARGB32() == v.toARGB32()) return;
    _backgroundColor = v;
    notifyListeners();
  }

  bool _showGrid = true;
  bool get showGrid => _showGrid;
  set showGrid(bool v) {
    if (_showGrid == v) return;
    _showGrid = v;
    notifyListeners();
  }

  bool _showMassLabels = true;
  bool get showMassLabels => _showMassLabels;
  set showMassLabels(bool v) {
    if (_showMassLabels == v) return;
    _showMassLabels = v;
    notifyListeners();
  }

  bool _showFps = true;
  bool get showFps => _showFps;
  set showFps(bool v) {
    if (_showFps == v) return;
    _showFps = v;
    notifyListeners();
  }

  bool _showMinimap = true;
  bool get showMinimap => _showMinimap;
  set showMinimap(bool v) {
    if (_showMinimap == v) return;
    _showMinimap = v;
    notifyListeners();
  }

  // Gameplay
  double _zoomMultiplier = 1.0;
  double get zoomMultiplier => _zoomMultiplier;
  set zoomMultiplier(double v) {
    final c = v.clamp(0.5, 2.0);
    if (_zoomMultiplier == c) return;
    _zoomMultiplier = c;
    notifyListeners();
  }

  double _ejectSpeedMultiplier = 1.0;
  double get ejectSpeedMultiplier => _ejectSpeedMultiplier;
  set ejectSpeedMultiplier(double v) {
    final c = v.clamp(0.5, 2.0);
    if (_ejectSpeedMultiplier == c) return;
    _ejectSpeedMultiplier = c;
    notifyListeners();
  }

  bool _stopOnRelease = false;
  bool get stopOnRelease => _stopOnRelease;
  set stopOnRelease(bool v) {
    if (_stopOnRelease == v) return;
    _stopOnRelease = v;
    notifyListeners();
  }

  Color get gridColor {
    final l = HSLColor.fromColor(_backgroundColor).lightness;
    return l > 0.5
        ? Color.lerp(_backgroundColor, Colors.black, 0.08)!
        : Color.lerp(_backgroundColor, Colors.white, 0.10)!;
  }

  Color get borderColor {
    final l = HSLColor.fromColor(_backgroundColor).lightness;
    return l > 0.5 ? const Color(0xFF3A3A3A) : Colors.white70;
  }

  void resetToDefaults() {
    _backgroundColor = const Color(0xFFF5F5F5);
    _showGrid = true;
    _showMassLabels = true;
    _showFps = true;
    _showMinimap = true;
    _zoomMultiplier = 1.0;
    _ejectSpeedMultiplier = 1.0;
    _stopOnRelease = false;
    notifyListeners();
  }
}
