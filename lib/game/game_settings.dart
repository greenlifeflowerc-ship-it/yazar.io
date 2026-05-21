import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/storage_service.dart';

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
    StorageService.instance.setInt('backgroundColor', v.toARGB32());
    notifyListeners();
  }

  bool _showGrid = true;
  bool get showGrid => _showGrid;
  set showGrid(bool v) {
    if (_showGrid == v) return;
    _showGrid = v;
    StorageService.instance.setBool('showGrid', v);
    notifyListeners();
  }

  bool _showMassLabels = true;
  bool get showMassLabels => _showMassLabels;
  set showMassLabels(bool v) {
    if (_showMassLabels == v) return;
    _showMassLabels = v;
    StorageService.instance.setBool('showMassLabels', v);
    notifyListeners();
  }

  bool _showFps = true;
  bool get showFps => _showFps;
  set showFps(bool v) {
    if (_showFps == v) return;
    _showFps = v;
    StorageService.instance.setBool('showFps', v);
    notifyListeners();
  }

  bool _showMinimap = true;
  bool get showMinimap => _showMinimap;
  set showMinimap(bool v) {
    if (_showMinimap == v) return;
    _showMinimap = v;
    StorageService.instance.setBool('showMinimap', v);
    notifyListeners();
  }

  // Gameplay
  double _zoomMultiplier = 1.0;
  double get zoomMultiplier => _zoomMultiplier;
  set zoomMultiplier(double v) {
    final c = v.clamp(0.2, 10.0);
    if (_zoomMultiplier == c) return;
    _zoomMultiplier = c;
    StorageService.instance.setDouble('zoomMultiplier', c);
    notifyListeners();
  }

  double _ejectSpeedMultiplier = 1.0;
  double get ejectSpeedMultiplier => _ejectSpeedMultiplier;
  set ejectSpeedMultiplier(double v) {
    final c = v.clamp(0.5, 2.5);
    if (_ejectSpeedMultiplier == c) return;
    _ejectSpeedMultiplier = c;
    StorageService.instance.setDouble('ejectSpeedMultiplier', c);
    notifyListeners();
  }

  double _ejectDistanceMultiplier = 1.0;
  double get ejectDistanceMultiplier => _ejectDistanceMultiplier;
  set ejectDistanceMultiplier(double v) {
    final c = v.clamp(0.5, 2.5);
    if (_ejectDistanceMultiplier == c) return;
    _ejectDistanceMultiplier = c;
    StorageService.instance.setDouble('ejectDistanceMultiplier', c);
    notifyListeners();
  }

  double _feedSpeedMultiplier = 1.0;
  double get feedSpeedMultiplier => _feedSpeedMultiplier;
  set feedSpeedMultiplier(double v) {
    final c = v.clamp(0.5, 150.0);
    if (_feedSpeedMultiplier == c) return;
    _feedSpeedMultiplier = c;
    StorageService.instance.setDouble('feedSpeedMultiplier', c);
    notifyListeners();
  }

  double _feedSpeedMultiplier2 = 1.0;
  double get feedSpeedMultiplier2 => _feedSpeedMultiplier2;
  set feedSpeedMultiplier2(double v) {
    final c = v.clamp(0.5, 200.0);
    if (_feedSpeedMultiplier2 == c) return;
    _feedSpeedMultiplier2 = c;
    StorageService.instance.setDouble('feedSpeedMultiplier2', c);
    notifyListeners();
  }

  bool _stopOnRelease = false;
  bool get stopOnRelease => _stopOnRelease;
  set stopOnRelease(bool v) {
    if (_stopOnRelease == v) return;
    _stopOnRelease = v;
    StorageService.instance.setBool('stopOnRelease', v);
    notifyListeners();
  }

  /// Dev / QA-only spawn-mass override for online matches. 0 = no override
  /// (the server uses the player's normal start mass × active boost). Any
  /// positive value is converted to a massMultiplier by the V2 controller
  /// before being sent on `join`, and the server clamps it to a sane upper
  /// bound. Useful for quickly testing late-game scenarios (splits, large
  /// virus pops, max-cell-count behaviour) without grinding up.
  double _devStartMass = 0;
  double get devStartMass => _devStartMass;
  set devStartMass(double v) {
    final c = v.clamp(0.0, 22500.0);
    if (_devStartMass == c) return;
    _devStartMass = c;
    StorageService.instance.setDouble('devStartMass', c);
    notifyListeners();
  }

  // Controls
  double _buttonScale = 1.0;
  double get buttonScale => _buttonScale;
  set buttonScale(double v) {
    final c = v.clamp(0.6, 1.5);
    if (_buttonScale == c) return;
    _buttonScale = c;
    StorageService.instance.setDouble('buttonScale', c);
    notifyListeners();
  }

  bool _joystickOnRight = false;
  bool get joystickOnRight => _joystickOnRight;
  set joystickOnRight(bool v) {
    if (_joystickOnRight == v) return;
    _joystickOnRight = v;
    StorageService.instance.setBool('joystickOnRight', v);
    notifyListeners();
  }

  bool _pcMode = false;
  bool get pcMode => _pcMode;
  set pcMode(bool v) {
    if (_pcMode == v) return;
    _pcMode = v;
    _persistPcMode(v);
    StorageService.instance.setBool('pcMode', v);
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

  void loadFromStorage() {
    final storage = StorageService.instance;
    
    _backgroundColor = Color(storage.getInt('backgroundColor') ?? 0xFFF5F5F5);
    _showGrid = storage.getBool('showGrid') ?? true;
    _showMassLabels = storage.getBool('showMassLabels') ?? true;
    _showFps = storage.getBool('showFps') ?? true;
    _showMinimap = storage.getBool('showMinimap') ?? true;
    _zoomMultiplier = storage.getDouble('zoomMultiplier') ?? 1.0;
    _ejectSpeedMultiplier = storage.getDouble('ejectSpeedMultiplier') ?? 1.0;
    _ejectDistanceMultiplier = storage.getDouble('ejectDistanceMultiplier') ?? 1.0;
    _feedSpeedMultiplier = storage.getDouble('feedSpeedMultiplier') ?? 1.0;
    _feedSpeedMultiplier2 = storage.getDouble('feedSpeedMultiplier2') ?? 1.0;
    _stopOnRelease = storage.getBool('stopOnRelease') ?? false;
    _devStartMass = storage.getDouble('devStartMass') ?? 0;
    _buttonScale = storage.getDouble('buttonScale') ?? 1.0;
    _joystickOnRight = storage.getBool('joystickOnRight') ?? false;
    _pcMode = storage.getBool('pcMode') ?? false;
    _darkMode = storage.getBool('darkMode') ?? false;
    _graphicsQuality = storage.getInt('graphicsQuality') ?? 2;
    _fpsCap = storage.getInt('fpsCap') ?? 60;
    _renderScale = storage.getDouble('renderScale') ?? 1.0;

    final ejDx = storage.getOffsetDx('ejectBtn');
    final ejDy = storage.getOffsetDy('ejectBtn');
    if (ejDx != null && ejDy != null) _ejectBtnFrac = Offset(ejDx, ejDy);

    final ejDx2 = storage.getOffsetDx('ejectBtn2');
    final ejDy2 = storage.getOffsetDy('ejectBtn2');
    if (ejDx2 != null && ejDy2 != null) _ejectBtnFrac2 = Offset(ejDx2, ejDy2);

    final spDx = storage.getOffsetDx('splitBtn');
    final spDy = storage.getOffsetDy('splitBtn');
    if (spDx != null && spDy != null) _splitBtnFrac = Offset(spDx, spDy);

    notifyListeners();
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

  // Normalised button positions
  Offset _ejectBtnFrac = const Offset(0.80, 0.85);
  Offset get ejectBtnFrac => _ejectBtnFrac;
  set ejectBtnFrac(Offset v) {
    final c = Offset(v.dx.clamp(0.04, 0.96), v.dy.clamp(0.04, 0.96));
    if (_ejectBtnFrac == c) return;
    _ejectBtnFrac = c;
    StorageService.instance.setOffset('ejectBtn', c.dx, c.dy);
    notifyListeners();
  }

  Offset _ejectBtnFrac2 = const Offset(0.70, 0.85);
  Offset get ejectBtnFrac2 => _ejectBtnFrac2;
  set ejectBtnFrac2(Offset v) {
    final c = Offset(v.dx.clamp(0.04, 0.96), v.dy.clamp(0.04, 0.96));
    if (_ejectBtnFrac2 == c) return;
    _ejectBtnFrac2 = c;
    StorageService.instance.setOffset('ejectBtn2', c.dx, c.dy);
    notifyListeners();
  }

  Offset _splitBtnFrac = const Offset(0.91, 0.80);
  Offset get splitBtnFrac => _splitBtnFrac;
  set splitBtnFrac(Offset v) {
    final c = Offset(v.dx.clamp(0.04, 0.96), v.dy.clamp(0.04, 0.96));
    if (_splitBtnFrac == c) return;
    _splitBtnFrac = c;
    StorageService.instance.setOffset('splitBtn', c.dx, c.dy);
    notifyListeners();
  }

  // Theme
  bool _darkMode = false;
  bool get darkMode => _darkMode;
  set darkMode(bool v) {
    if (_darkMode == v) return;
    _darkMode = v;
    _backgroundColor = v ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5);
    StorageService.instance.setBool('darkMode', v);
    StorageService.instance.setInt('backgroundColor', _backgroundColor.toARGB32());
    notifyListeners();
  }

  // Graphics Quality
  int _graphicsQuality = 2;
  int get graphicsQuality => _graphicsQuality;
  set graphicsQuality(int v) {
    if (_graphicsQuality == v) return;
    _graphicsQuality = v;
    StorageService.instance.setInt('graphicsQuality', v);
    notifyListeners();
  }

  // FPS Cap (0 = unlimited / use device refresh rate)
  int _fpsCap = 60;
  int get fpsCap => _fpsCap;
  set fpsCap(int v) {
    if (_fpsCap == v) return;
    _fpsCap = v;
    StorageService.instance.setInt('fpsCap', v);
    notifyListeners();
  }

  /// Render-resolution multiplier for the game world canvas.
  /// 0.6 = render at 60% pixels (much faster, blurrier).
  /// 1.0 = native (default).
  /// 1.25 = supersampled (sharper, slower).
  double _renderScale = 1.0;
  double get renderScale => _renderScale;
  set renderScale(double v) {
    final c = v.clamp(0.5, 1.5);
    if ((_renderScale - c).abs() < 0.001) return;
    _renderScale = c;
    StorageService.instance.setDouble('renderScale', c);
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
    _feedSpeedMultiplier2 = 1.0;
    _stopOnRelease = false;
    _buttonScale = 1.0;
    _joystickOnRight = false;
    _pcMode = false;
    _ejectBtnFrac = const Offset(0.80, 0.85);
    _ejectBtnFrac2 = const Offset(0.70, 0.85);
    _splitBtnFrac = const Offset(0.91, 0.80);
    _darkMode = false;
    _graphicsQuality = 2;
    _fpsCap = 60;
    _renderScale = 1.0;
    
    // Clear storage or just let setters handle it. Better to clear or overwrite.
    final storage = StorageService.instance;
    storage.setInt('backgroundColor', _backgroundColor.toARGB32());
    storage.setBool('showGrid', true);
    storage.setBool('showMassLabels', true);
    storage.setBool('showFps', true);
    storage.setBool('showMinimap', true);
    storage.setDouble('zoomMultiplier', 1.0);
    storage.setDouble('ejectSpeedMultiplier', 1.0);
    storage.setDouble('ejectDistanceMultiplier', 1.0);
    storage.setDouble('feedSpeedMultiplier', 1.0);
    storage.setDouble('feedSpeedMultiplier2', 1.0);
    storage.setBool('stopOnRelease', false);
    storage.setDouble('buttonScale', 1.0);
    storage.setBool('joystickOnRight', false);
    storage.setBool('pcMode', false);
    storage.setBool('darkMode', false);
    storage.setInt('graphicsQuality', 2);
    storage.setInt('fpsCap', 60);
    storage.setDouble('renderScale', 1.0);
    storage.setOffset('ejectBtn', 0.80, 0.85);
    storage.setOffset('ejectBtn2', 0.70, 0.85);
    storage.setOffset('splitBtn', 0.91, 0.80);

    notifyListeners();
  }
}
