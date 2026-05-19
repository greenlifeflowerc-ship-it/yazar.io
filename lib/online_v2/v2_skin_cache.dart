/// Async skin loader for V2.
///
/// Two responsibilities:
///  1. Asset-path skins: remote human players send their chosen skin's asset
///     path (e.g. `assets/skins/free/skin_007_cocacola.png`) in every
///     `addCells` payload. The painter needs the decoded [ui.Image]
///     synchronously each frame, so we lazy-load + cache the asset bytes.
///  2. Bot skins: the server sends synthetic ids like `bot_<botid>`. We map
///     each unique synthetic id to one of the 200 free skins via a stable
///     hash, so each bot shows the same skin for as long as it lives.
library;

import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

class V2SkinCache {
  /// Path → image, or null while still loading / on failure.
  final Map<String, ui.Image?> _cache = {};
  final Set<String> _loading = {};

  /// All `assets/skins/free/*.png` paths, loaded once from the asset manifest.
  /// Used to pick a deterministic skin per bot id.
  List<String> _freeSkins = const [];
  bool _freeSkinsLoaded = false;

  V2SkinCache() {
    _loadFreeSkinList();
  }

  Future<void> _loadFreeSkinList() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final paths = manifest
          .listAssets()
          .where((a) =>
              a.startsWith('assets/skins/free/') &&
              a.toLowerCase().endsWith('.png'))
          .toList()
        ..sort();
      _freeSkins = paths;
    } catch (_) {
      _freeSkins = const [];
    }
    _freeSkinsLoaded = true;
  }

  /// Returns the decoded image if available. Triggers a background load
  /// otherwise and returns null until the next frame after the load completes.
  /// Bot synthetic ids (`bot_...`) are remapped to a deterministic free skin
  /// so bots look distinct in-game instead of plain-color blobs.
  ui.Image? get(String skinId) {
    if (skinId.isEmpty) return null;
    final path = _resolvePath(skinId);
    if (path == null) return null;
    if (_cache.containsKey(path)) return _cache[path];
    if (_loading.contains(path)) return null;
    _loading.add(path);
    _load(path);
    return null;
  }

  String? _resolvePath(String skinId) {
    if (skinId.startsWith('assets/')) return skinId;
    if (skinId.startsWith('bot_')) {
      if (!_freeSkinsLoaded || _freeSkins.isEmpty) return null;
      // Stable hash of the bot id → fixed free-skin index for this session.
      final h = skinId.hashCode & 0x7fffffff;
      return _freeSkins[h % _freeSkins.length];
    }
    return null;
  }

  Future<void> _load(String path) async {
    try {
      final data = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      _cache[path] = frame.image;
    } catch (_) {
      _cache[path] = null;
    } finally {
      _loading.remove(path);
    }
  }
}
