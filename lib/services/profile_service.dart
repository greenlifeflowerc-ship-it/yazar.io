import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/boost.dart';
import '../models/match_history_entry.dart';
import '../models/player_stats.dart';
import '../models/profile.dart';
import '../models/skin.dart';

class MatchSubmitResult {
  MatchSubmitResult({
    required this.level,
    required this.xp,
    required this.coins,
    required this.dna,
    required this.coinsEarned,
    required this.dnaEarned,
    required this.xpEarned,
    required this.xpMultiplier,
    required this.levelUpCoinsEarned,
    required this.levelUpDnaEarned,
    required this.levelsGained,
    required this.leveledUp,
    required this.newlyUnlockedSkins,
  });

  final int level;
  final int xp;
  final int coins;
  final int dna;
  final int coinsEarned;
  final int dnaEarned;
  final int xpEarned;
  final double xpMultiplier;
  final int levelUpCoinsEarned;
  final int levelUpDnaEarned;
  final int levelsGained;
  final bool leveledUp;
  final List<UnlockedSkin> newlyUnlockedSkins;

  factory MatchSubmitResult.fromJson(Map<String, dynamic> json) {
    final raw = json['newly_unlocked_skins'];
    final unlocks = <UnlockedSkin>[];
    if (raw is List) {
      for (final r in raw) {
        if (r is Map) unlocks.add(UnlockedSkin.fromJson(r.cast<String, dynamic>()));
      }
    }
    return MatchSubmitResult(
      level: (json['level'] as num?)?.toInt() ?? 1,
      xp: (json['xp'] as num?)?.toInt() ?? 0,
      coins: (json['coins'] as num?)?.toInt() ?? 0,
      dna: (json['dna'] as num?)?.toInt() ?? 0,
      coinsEarned: (json['coins_earned'] as num?)?.toInt() ?? 0,
      dnaEarned: (json['dna_earned'] as num?)?.toInt() ?? 0,
      xpEarned: (json['xp_earned'] as num?)?.toInt() ?? 0,
      xpMultiplier: (json['xp_multiplier'] as num?)?.toDouble() ?? 1.0,
      levelUpCoinsEarned:
          (json['level_up_coins_earned'] as num?)?.toInt() ?? 0,
      levelUpDnaEarned:
          (json['level_up_dna_earned'] as num?)?.toInt() ?? 0,
      levelsGained: (json['levels_gained'] as num?)?.toInt() ?? 0,
      leveledUp: json['leveled_up'] as bool? ?? false,
      newlyUnlockedSkins: unlocks,
    );
  }
}

class PlayerSkinsPayload {
  PlayerSkinsPayload({required this.skins, required this.equippedKey});
  final List<Skin> skins;
  final String? equippedKey;
}

class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  final SupabaseClient _c = Supabase.instance.client;

  // ---------------------------------------------------- profile / stats
  Future<Profile> fetchOrCreateProfile(User user) async {
    try {
      final row = await _c
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (row != null) return Profile.fromJson(row);
    } catch (e) {
      debugPrint('profile fetch failed, attempting upsert: $e');
    }

    try {
      final inserted = await _c
          .from('profiles')
          .insert({
            'id': user.id,
            'email': user.email,
            'username': _usernameFromEmail(user.email),
            'level': 1,
            'xp': 0,
            'coins': 200,
            'dna': 50,
          })
          .select()
          .single();
      try {
        await _c.from('player_stats').upsert({'user_id': user.id});
      } catch (_) {}
      return Profile.fromJson(inserted);
    } catch (_) {
      final row = await _c
          .from('profiles')
          .select()
          .eq('id', user.id)
          .single();
      return Profile.fromJson(row);
    }
  }

  String? _usernameFromEmail(String? email) {
    if (email == null || !email.contains('@')) return null;
    return email.split('@').first;
  }

  Future<PlayerStats?> fetchStats() async {
    final user = _c.auth.currentUser;
    if (user == null) return null;
    final row = await _c
        .from('player_stats')
        .select()
        .eq('user_id', user.id)
        .maybeSingle();
    if (row == null) return null;
    return PlayerStats.fromJson(row);
  }

  Future<List<MatchHistoryEntry>> fetchMatchHistory({int limit = 20}) async {
    final user = _c.auth.currentUser;
    if (user == null) return [];
    final rows = await _c
        .from('match_history')
        .select()
        .eq('user_id', user.id)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(MatchHistoryEntry.fromJson)
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchInventory() async {
    final user = _c.auth.currentUser;
    if (user == null) return [];
    final rows = await _c
        .from('player_inventory')
        .select('id, equipped, unlocked_at, inventory_items(*)')
        .eq('user_id', user.id);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> fetchAchievements() async {
    final user = _c.auth.currentUser;
    if (user == null) return [];
    final rows = await _c
        .from('player_achievements')
        .select('id, unlocked_at, achievements(*)')
        .eq('user_id', user.id)
        .order('unlocked_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  // ----------------------------------------------------------- boosts
  /// Boost catalogue + per-player owned quantity + active expiry, all in one
  /// server-validated call (auto-expires stale rows server-side).
  Future<List<BoostInventoryEntry>> getBoostInventory() async {
    try {
      final raw = await _c.rpc('get_boost_inventory');
      if (raw is List) {
        return raw
            .cast<Map<String, dynamic>>()
            .map(BoostInventoryEntry.fromJson)
            .toList();
      }
    } catch (e) {
      debugPrint('get_boost_inventory failed: $e');
    }
    return [];
  }

  Future<Map<String, dynamic>> buyBoost(String key) async {
    final raw = await _c.rpc('buy_boost', params: {'p_key': key});
    if (raw is Map) return raw.cast<String, dynamic>();
    throw Exception('Unexpected response from buy_boost');
  }

  Future<Map<String, dynamic>> activateBoost(String key) async {
    final raw = await _c.rpc('activate_boost', params: {'p_key': key});
    if (raw is Map) return raw.cast<String, dynamic>();
    throw Exception('Unexpected response from activate_boost');
  }

  /// Returns `{mass_multiplier, xp_multiplier, mass_expires_at, xp_expires_at}`.
  Future<Map<String, dynamic>> getMatchStartModifiers() async {
    try {
      final raw = await _c.rpc('get_match_start_modifiers');
      if (raw is Map) return raw.cast<String, dynamic>();
    } catch (e) {
      debugPrint('get_match_start_modifiers failed: $e');
    }
    return {'mass_multiplier': 1.0, 'xp_multiplier': 1.0};
  }

  // ------------------------------------------------------------- skins
  /// Scan the asset manifest, compute deterministic prices/levels, and push
  /// the catalogue to Supabase. Idempotent — safe to call on every launch.
  Future<void> syncSkinCatalogueFromAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final all = manifest.listAssets();

    bool isImg(String p) {
      final s = p.toLowerCase();
      return s.endsWith('.png') ||
          s.endsWith('.jpg') ||
          s.endsWith('.jpeg') ||
          s.endsWith('.webp');
    }

    List<String> pick(String prefix) =>
        all.where((p) => p.startsWith(prefix) && isImg(p)).toList()..sort();

    final levels = pick('assets/skins/level/');
    final premiums = pick('assets/skins/premium/');
    final frees = pick('assets/skins/free/');

    final items = <Map<String, dynamic>>[];

    // Level skins: unlock every 5 levels starting at 5, capped at 150.
    for (int i = 0; i < levels.length; i++) {
      final unlockLvl = ((i + 1) * 5).clamp(5, 150);
      items.add({
        'key': _keyOf(levels[i]),
        'name': _nameOf(levels[i]),
        'category': 'level',
        'image_path': levels[i],
        'unlock_level': unlockLvl,
        'price_coins': 0,
        'sort_order': i,
      });
    }

    // Premium skins: 50 → 9999 ascending by filename.
    if (premiums.isNotEmpty) {
      final n = premiums.length;
      for (int i = 0; i < n; i++) {
        final t = n == 1 ? 0.0 : i / (n - 1);
        final price = (50 + t * (9999 - 50)).round();
        items.add({
          'key': _keyOf(premiums[i]),
          'name': _nameOf(premiums[i]),
          'category': 'premium',
          'image_path': premiums[i],
          'unlock_level': 0,
          'price_coins': price,
          'sort_order': i,
        });
      }
    }

    // Free skins: owned by everyone.
    for (int i = 0; i < frees.length; i++) {
      items.add({
        'key': _keyOf(frees[i]),
        'name': _nameOf(frees[i]),
        'category': 'free',
        'image_path': frees[i],
        'unlock_level': 0,
        'price_coins': 0,
        'sort_order': i,
      });
    }

    if (items.isEmpty) return;
    try {
      await _c.rpc('sync_skin_catalogue', params: {'p_items': items});
    } catch (e) {
      debugPrint('sync_skin_catalogue failed: $e');
    }
  }

  String _keyOf(String path) {
    // `assets/skins/level/foo_bar.png` → `level/foo_bar`
    final s = path.replaceFirst('assets/skins/', '');
    final dot = s.lastIndexOf('.');
    return dot > 0 ? s.substring(0, dot) : s;
  }

  String _nameOf(String path) {
    final file = path.split('/').last;
    final dot = file.lastIndexOf('.');
    final stem = dot > 0 ? file.substring(0, dot) : file;
    return stem.replaceAll(RegExp(r'^skin_\d+_'), '').replaceAll('_', ' ');
  }

  Future<PlayerSkinsPayload> getPlayerSkins() async {
    try {
      final raw = await _c.rpc('get_player_skins');
      if (raw is Map) {
        final map = raw.cast<String, dynamic>();
        final list = map['skins'];
        final skins = <Skin>[];
        if (list is List) {
          for (final r in list) {
            if (r is Map) skins.add(Skin.fromJson(r.cast<String, dynamic>()));
          }
        }
        return PlayerSkinsPayload(
          skins: skins,
          equippedKey: map['equipped_key'] as String?,
        );
      }
    } catch (e) {
      debugPrint('get_player_skins failed: $e');
    }
    return PlayerSkinsPayload(skins: [], equippedKey: null);
  }

  Future<Map<String, dynamic>> buyPremiumSkin(String key) async {
    final raw = await _c.rpc('buy_premium_skin', params: {'p_key': key});
    if (raw is Map) return raw.cast<String, dynamic>();
    throw Exception('Unexpected response from buy_premium_skin');
  }

  Future<Map<String, dynamic>> equipSkin(String key) async {
    final raw = await _c.rpc('equip_skin', params: {'p_key': key});
    if (raw is Map) return raw.cast<String, dynamic>();
    throw Exception('Unexpected response from equip_skin');
  }

  Future<List<UnlockedSkin>> claimLevelSkins() async {
    try {
      final raw = await _c.rpc('claim_level_skins');
      if (raw is List) {
        return raw
            .cast<Map<String, dynamic>>()
            .map(UnlockedSkin.fromJson)
            .toList();
      }
    } catch (e) {
      debugPrint('claim_level_skins failed: $e');
    }
    return [];
  }

  // ------------------------------------------------------ submit match
  Future<MatchSubmitResult?> submitMatchResult({
    required int score,
    required int massCollected,
    required int kills,
    required int survivalSeconds,
    required int rank,
  }) async {
    final user = _c.auth.currentUser;
    if (user == null) return null;
    try {
      final raw = await _c.rpc('submit_match_result', params: {
        'p_score': score,
        'p_mass_collected': massCollected,
        'p_kills': kills,
        'p_survival_seconds': survivalSeconds,
        'p_rank': rank,
      });
      if (raw is Map) return MatchSubmitResult.fromJson(raw.cast<String, dynamic>());
      if (raw is List && raw.isNotEmpty && raw.first is Map) {
        return MatchSubmitResult.fromJson(
            (raw.first as Map).cast<String, dynamic>());
      }
    } catch (e) {
      debugPrint('submit_match_result failed: $e');
    }
    return null;
  }
}
