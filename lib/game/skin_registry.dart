import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// Bulk skin loader. Decodes every image under `assets/skins/...` once at
/// app startup and keeps them in memory so bots can sport a random skin each
/// match without any per-game loading cost.
class SkinRegistry {
  SkinRegistry._();
  static final SkinRegistry instance = SkinRegistry._();

  static const _exts = ['.png', '.jpg', '.jpeg', '.webp'];
  static const _folders = [
    'assets/skins/level/',
    'assets/skins/premium/',
  ];

  final List<ui.Image> _images = [];
  bool _loaded = false;
  Future<void>? _loading;

  bool get isLoaded => _loaded;
  int get count => _images.length;

  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest
          .listAssets()
          .where((a) =>
              _folders.any(a.startsWith) &&
              _exts.any((e) => a.toLowerCase().endsWith(e)))
          .toList()
        ..sort();
      for (final path in assets) {
        try {
          final data = await rootBundle.load(path);
          final codec =
              await ui.instantiateImageCodec(data.buffer.asUint8List());
          final frame = await codec.getNextFrame();
          _images.add(frame.image);
        } catch (_) {
          // Skip unreadable images.
        }
      }
    } catch (_) {
      // Manifest unavailable (unlikely) — leave empty.
    }
    _loaded = true;
  }

  ui.Image? randomSkin(Random rng) {
    if (_images.isEmpty) return null;
    return _images[rng.nextInt(_images.length)];
  }
}
