class BoostDefinition {
  BoostDefinition({
    required this.id,
    required this.key,
    required this.name,
    required this.type,
    required this.multiplier,
    required this.durationSeconds,
    required this.priceCoins,
    required this.priceDna,
    this.description,
    this.iconUrl,
  });

  final String id;
  final String key;
  final String name;
  final String type; // 'mass' | 'xp'
  final double multiplier;
  final int durationSeconds;
  final int priceCoins;
  final int priceDna;
  final String? description;
  final String? iconUrl;

  bool get isMass => type == 'mass';
  bool get isXp => type == 'xp';

  factory BoostDefinition.fromJson(Map<String, dynamic> json) {
    return BoostDefinition(
      id: json['id'] as String,
      key: json['key'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      multiplier: (json['multiplier'] as num).toDouble(),
      durationSeconds: (json['duration_seconds'] as num).toInt(),
      priceCoins: (json['price_coins'] as num?)?.toInt() ?? 0,
      priceDna: (json['price_dna'] as num?)?.toInt() ?? 0,
      description: json['description'] as String?,
      iconUrl: json['icon_url'] as String?,
    );
  }
}

/// A row from get_boost_inventory: a boost definition + the player's owned
/// quantity + the expiry of the active instance of this exact SKU (if any).
class BoostInventoryEntry {
  BoostInventoryEntry({
    required this.def,
    required this.quantity,
    required this.activeExpiresAt,
  });

  final BoostDefinition def;
  final int quantity;
  final DateTime? activeExpiresAt;

  bool get isActive =>
      activeExpiresAt != null && DateTime.now().isBefore(activeExpiresAt!);

  Duration get remaining {
    final e = activeExpiresAt;
    if (e == null) return Duration.zero;
    final r = e.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  factory BoostInventoryEntry.fromJson(Map<String, dynamic> json) {
    return BoostInventoryEntry(
      def: BoostDefinition.fromJson(json),
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      activeExpiresAt: _parseTs(json['active_expires_at']),
    );
  }

  static DateTime? _parseTs(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }
}

/// View of an active boost (consumed by AuthService + UI badges). Compatible
/// with the older PlayerBoost surface that the rest of the app expected.
class PlayerBoost {
  PlayerBoost({
    required this.id,
    required this.boostKey,
    required this.type,
    required this.multiplier,
    required this.activatedAt,
    required this.expiresAt,
  });

  final String id;
  final String boostKey;
  final String type;
  final double multiplier;
  final DateTime activatedAt;
  final DateTime expiresAt;

  bool get isMass => type == 'mass';
  bool get isXp => type == 'xp';
  bool get isActive => DateTime.now().isBefore(expiresAt);

  Duration get remaining {
    final r = expiresAt.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  // For HUD callers from the older code path:
  String get key => boostKey;
  String get name => '${multiplier % 1 == 0 ? multiplier.toStringAsFixed(0) : multiplier.toStringAsFixed(1)}x ${type == 'mass' ? 'Mass' : 'XP'} Boost';
  int get durationSeconds => expiresAt.difference(activatedAt).inSeconds;

  factory PlayerBoost.fromInventoryActive(BoostInventoryEntry e) {
    return PlayerBoost(
      id: e.def.key, // good enough for UI keying
      boostKey: e.def.key,
      type: e.def.type,
      multiplier: e.def.multiplier,
      activatedAt: e.activeExpiresAt!.subtract(
        Duration(seconds: e.def.durationSeconds),
      ),
      expiresAt: e.activeExpiresAt!,
    );
  }
}
