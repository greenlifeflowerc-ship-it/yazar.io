import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/boost.dart';
import '../models/profile.dart';
import '../game/game_settings.dart';
import 'profile_service.dart';

/// Holds the current Supabase session + the player's profile, boost
/// inventory, and equipped skin and notifies listeners when anything
/// changes. Use [AuthService.instance] everywhere; do not construct.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  final SupabaseClient _client = Supabase.instance.client;
  StreamSubscription<AuthState>? _sub;

  Session? _session;
  Session? get session => _session;
  User? get user => _session?.user;
  bool get isLoggedIn => _session != null;

  Profile? _profile;
  Profile? get profile => _profile;

  bool _loadingProfile = false;
  bool get isLoadingProfile => _loadingProfile;

  /// Full boost catalogue + per-player owned quantity + active expiries.
  /// Sourced from `get_boost_inventory()`.
  List<BoostInventoryEntry> _boostInventory = [];
  List<BoostInventoryEntry> get boostInventory => _boostInventory;

  /// Server-validated active boosts (one per type at most). Derived from
  /// the same inventory call, so they auto-refresh together.
  List<PlayerBoost> get activeBoosts => [
        for (final e in _boostInventory)
          if (e.isActive) PlayerBoost.fromInventoryActive(e),
      ];

  PlayerBoost? get activeMassBoost {
    for (final b in activeBoosts) {
      if (b.isMass) return b;
    }
    return null;
  }

  PlayerBoost? get activeXpBoost {
    for (final b in activeBoosts) {
      if (b.isXp) return b;
    }
    return null;
  }

  double get activeMassMultiplier => activeMassBoost?.multiplier ?? 1.0;

  String? _equippedSkinKey;
  String? get equippedSkinKey => _equippedSkinKey;

  /// Pending level-up payload from the last submit_match_result. The main
  /// menu consumes this on first build after returning from a match and
  /// pops the LevelUpPopup.
  MatchSubmitResult? _pendingLevelUp;
  MatchSubmitResult? get pendingLevelUp => _pendingLevelUp;

  void queueLevelUp(MatchSubmitResult r) {
    _pendingLevelUp = r;
    notifyListeners();
  }

  MatchSubmitResult? consumePendingLevelUp() {
    final r = _pendingLevelUp;
    _pendingLevelUp = null;
    return r;
  }

  void bootstrap() {
    _session = _client.auth.currentSession;
    _sub ??= _client.auth.onAuthStateChange.listen(_onAuthChange);
    if (_session != null) {
      _hydrateAuthed();
    }
  }

  void _onAuthChange(AuthState state) {
    _session = state.session;
    notifyListeners();
    if (state.session != null) {
      _hydrateAuthed();
    } else {
      _profile = null;
      _boostInventory = [];
      _equippedSkinKey = null;
      notifyListeners();
    }
  }

  /// Fired on login and on bootstrap with an existing session. Loads the
  /// profile, syncs the skin catalogue from local assets, claims any level
  /// skins the player has already grown into, refreshes the boost cache,
  /// and grabs the equipped-skin key.
  Future<void> _hydrateAuthed() async {
    await _refreshProfile();
    GameSettings.instance.initFromSupabase();
    // Fire and forget — order doesn't matter for the UI's first paint.
    unawaited(refreshActiveBoosts());
    unawaited(_setupSkins());
  }

  Future<void> _setupSkins() async {
    try {
      await ProfileService.instance.syncSkinCatalogueFromAssets();
    } catch (e) {
      debugPrint('syncSkinCatalogueFromAssets failed: $e');
    }
    try {
      await ProfileService.instance.claimLevelSkins();
    } catch (e) {
      debugPrint('claimLevelSkins failed: $e');
    }
    await refreshEquippedSkin();
  }

  Future<void> refreshActiveBoosts() async {
    if (_session == null) {
      if (_boostInventory.isNotEmpty) {
        _boostInventory = [];
        notifyListeners();
      }
      return;
    }
    try {
      _boostInventory = await ProfileService.instance.getBoostInventory();
    } catch (e) {
      debugPrint('refreshActiveBoosts failed: $e');
    }
    notifyListeners();
  }

  /// Re-read the equipped skin key from the server.
  Future<void> refreshEquippedSkin() async {
    if (_session == null) {
      if (_equippedSkinKey != null) {
        _equippedSkinKey = null;
        notifyListeners();
      }
      return;
    }
    try {
      final payload = await ProfileService.instance.getPlayerSkins();
      _equippedSkinKey = payload.equippedKey;
    } catch (e) {
      debugPrint('refreshEquippedSkin failed: $e');
    }
    notifyListeners();
  }

  // ----------------------------------------------------------- auth ops
  Future<bool> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final res = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    _session = res.session;
    notifyListeners();
    if (_session != null) {
      await _hydrateAuthed();
      return true;
    }
    return false;
  }

  Future<bool> signUp({
    required String email,
    required String password,
  }) async {
    final res = await _client.auth.signUp(
      email: email.trim(),
      password: password,
    );
    _session = res.session;
    notifyListeners();
    if (_session != null) {
      await _hydrateAuthed();
      return true;
    }
    return false;
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    _session = null;
    _profile = null;
    _boostInventory = [];
    _equippedSkinKey = null;
    notifyListeners();
  }

  // ----------------------------------------------------- profile cache
  Future<void> _refreshProfile() async {
    final u = _client.auth.currentUser;
    if (u == null) return;
    _loadingProfile = true;
    notifyListeners();
    try {
      _profile = await ProfileService.instance.fetchOrCreateProfile(u);
    } catch (e) {
      debugPrint('Failed to fetch profile: $e');
      _profile = null;
    } finally {
      _loadingProfile = false;
      notifyListeners();
    }
  }

  Future<void> refreshProfile() => _refreshProfile();

  void applyProfile(Profile p) {
    _profile = p;
    notifyListeners();
  }

  /// Apply a freshly-equipped skin key locally so the menu/game reflect it
  /// without a re-fetch.
  void setEquippedSkinKey(String? key) {
    _equippedSkinKey = key;
    notifyListeners();
  }
}
