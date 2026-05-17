import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    // Increased range: 0.2 to 10.0
    final c = v.clamp(0.2, 10.0);
    if (_zoomMultiplier == c) return;
    _zoomMultiplier = c;
    notifyListeners();
  }

  double _ejectSpeedMultiplier = 1.0;
  double get ejectSpeedMultiplier => _ejectSpeedMultiplier;
  set ejectSpeedMultiplier(double v) {
    final c = v.clamp(0.5, 2.5);
    if (_ejectSpeedMultiplier == c) return;
    _ejectSpeedMultiplier = c;
    notifyListeners();
  }

  double _ejectDistanceMultiplier = 1.0;
  double get ejectDistanceMultiplier => _ejectDistanceMultiplier;
  set ejectDistanceMultiplier(double v) {
    final c = v.clamp(0.5, 2.5);
    if (_ejectDistanceMultiplier == c) return;
    _ejectDistanceMultiplier = c;
    notifyListeners();
  }

  double _feedSpeedMultiplier = 1.0;
  double get feedSpeedMultiplier => _feedSpeedMultiplier;
  set feedSpeedMultiplier(double v) {
    // Max increased to 100.0
    final c = v.clamp(0.5, 100.0);
    if (_feedSpeedMultiplier == c) return;
    _feedSpeedMultiplier = c;
    notifyListeners();
  }

  bool _stopOnRelease = false;
  bool get stopOnRelease => _stopOnRelease;
  set stopOnRelease(bool v) {
    if (_stopOnRelease == v) return;
    _stopOnRelease = v;
    notifyListeners();
  }

  // Controls
  double _buttonScale = 1.0;
  double get buttonScale => _buttonScale;
  set buttonScale(double v) {
    final c = v.clamp(0.6, 1.5);
    if (_buttonScale == c) return;
    _buttonScale = c;
    notifyListeners();
  }

  bool _joystickOnRight = false;
  bool get joystickOnRight => _joystickOnRight;
  set joystickOnRight(bool v) {
    if (_joystickOnRight == v) return;
    _joystickOnRight = v;
    notifyListeners();
  }

  bool _pcMode = false;
  bool get pcMode => _pcMode;
  set pcMode(bool v) {
    if (_pcMode == v) return;
    _pcMode = v;
    _persistPcMode(v);
    notifyListeners();
  }

  void _persistPcMode(bool v) {
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser != null) {
        client.auth.updateUser(UserAttributes(data: {'pcMode': v}));
      }
    } catch (_) {}
  }

  void initFromSupabase() {
    try {
      final client = Supabase.instance.client;
      final metadata = client.auth.currentUser?.userMetadata;
      if (metadata != null && metadata.containsKey('pcMode')) {
        _pcMode = metadata['pcMode'] == true;
        notifyListeners();
      }
    } catch (_) {}
  }

  // Normalised button positions (0-1 fraction of screen width/height).
  // Stored so dragged positions survive screen rebuilds.
  Offset _ejectBtnFrac = const Offset(0.80, 0.85);
  Offset get ejectBtnFrac => _ejectBtnFrac;
  set ejectBtnFrac(Offset v) {
    final c = Offset(v.dx.clamp(0.04, 0.96), v.dy.clamp(0.04, 0.96));
    if (_ejectBtnFrac == c) return;
    _ejectBtnFrac = c;
    notifyListeners();
  }

  Offset _splitBtnFrac = const Offset(0.91, 0.80);
  Offset get splitBtnFrac => _splitBtnFrac;
  set splitBtnFrac(Offset v) {
    final c = Offset(v.dx.clamp(0.04, 0.96), v.dy.clamp(0.04, 0.96));
    if (_splitBtnFrac == c) return;
    _splitBtnFrac = c;
    notifyListeners();
  }

  // Theme
  bool _darkMode = false;
  bool get darkMode => _darkMode;
  set darkMode(bool v) {
    if (_darkMode == v) return;
    _darkMode = v;
    // Sync game background so the world matches the UI theme.
    _backgroundColor =
        v ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5);
    notifyListeners();
  }

  // Graphics Quality (Low, Medium, High)
  int _graphicsQuality = 2; // 0: Low, 1: Medium, 2: High
  int get graphicsQuality => _graphicsQuality;
  set graphicsQuality(int v) {
    if (_graphicsQuality == v) return;
    _graphicsQuality = v;
    notifyListeners();
  }

  // FPS Cap (60, 90, 120)
  int _fpsCap = 60;
  int get fpsCap => _fpsCap;
  set fpsCap(int v) {
    if (_fpsCap == v) return;
    _fpsCap = v;
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
    _ejectDistanceMultiplier = 1.0;
    _feedSpeedMultiplier = 1.0;
    _stopOnRelease = false;
    _buttonScale = 1.0;
    _joystickOnRight = false;
    _pcMode = false;
    _ejectBtnFrac = const Offset(0.80, 0.85);
    _splitBtnFrac = const Offset(0.91, 0.80);
    _darkMode = false;
    _graphicsQuality = 2;
    _fpsCap = 60;
    notifyListeners();
  }
}
