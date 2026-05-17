/// One row from `skin_definitions` + per-player flags returned by
/// `get_player_skins()`.
class Skin {
  Skin({
    required this.id,
    required this.key,
    required this.name,
    required this.category,
    required this.imagePath,
    required this.unlockLevel,
    required this.priceCoins,
    required this.sortOrder,
    required this.owned,
    required this.equipped,
    this.source,
  });

  final String id;
  final String key;
  final String name;
  final String category; // 'level' | 'premium' | 'free'
  final String imagePath;
  final int unlockLevel;
  final int priceCoins;
  final int sortOrder;
  final bool owned;
  final bool equipped;
  final String? source;

  bool get isLevel => category == 'level';
  bool get isPremium => category == 'premium';
  bool get isFree => category == 'free';

  factory Skin.fromJson(Map<String, dynamic> json) {
    return Skin(
      id: json['id'] as String,
      key: json['key'] as String,
      name: json['name'] as String,
      category: json['category'] as String,
      imagePath: json['image_path'] as String,
      unlockLevel: (json['unlock_level'] as num?)?.toInt() ?? 0,
      priceCoins: (json['price_coins'] as num?)?.toInt() ?? 0,
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      owned: json['owned'] as bool? ?? false,
      equipped: json['equipped'] as bool? ?? false,
      source: json['source'] as String?,
    );
  }
}

/// A freshly-unlocked skin returned by `submit_match_result` so the level-up
/// popup can preview it.
class UnlockedSkin {
  UnlockedSkin({
    required this.key,
    required this.name,
    required this.imagePath,
    required this.unlockLevel,
  });

  final String key;
  final String name;
  final String imagePath;
  final int unlockLevel;

  factory UnlockedSkin.fromJson(Map<String, dynamic> json) {
    return UnlockedSkin(
      key: json['key'] as String,
      name: json['name'] as String? ?? '',
      imagePath: json['image_path'] as String? ?? '',
      unlockLevel: (json['unlock_level'] as num?)?.toInt() ?? 0,
    );
  }
}
