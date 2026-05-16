import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Holds the player's currently-selected skin: its asset path plus the
/// already-decoded `ui.Image` so the painter can blit it synchronously each
/// frame. Listeners are notified when the selection changes (so the main-menu
/// avatar preview and the painter both refresh).
class SkinSettings extends ChangeNotifier {
  SkinSettings._();
  static final SkinSettings instance = SkinSettings._();

  String? _skinPath;
  String? get skinPath => _skinPath;

  ui.Image? _skinImage;
  ui.Image? get skinImage => _skinImage;

  bool _loading = false;
  bool get isLoading => _loading;

  Future<void> selectSkin(String? path) async {
    if (path == _skinPath) return;
    _skinPath = path;

    if (path == null) {
      _skinImage = null;
      notifyListeners();
      return;
    }

    _loading = true;
    notifyListeners();

    try {
      final data = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      // Re-check that the user didn't pick a different skin while we decoded.
      if (path == _skinPath) {
        _skinImage = frame.image;
      }
    } catch (_) {
      if (path == _skinPath) _skinImage = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void clear() {
    _skinPath = null;
    _skinImage = null;
    notifyListeners();
  }
}
