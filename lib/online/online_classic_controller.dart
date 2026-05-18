import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../game/game_engine.dart' show GameConstants;
import '../game/skin_registry.dart';
import '../game/skin_settings.dart';
import '../network/online_socket_service.dart';
import 'online_entities.dart';

/// Source-of-truth for the online classic gameplay screen.
///
/// - Subscribes to the socket service.
/// - Maps incoming snapshot JSON into in-memory entity maps.
/// - Drives interpolation toward server targets every frame.
/// - Runs light client-side prediction for the local player so movement feels
///   instant even at 25 Hz state cadence; server snapshots smoothly correct.
/// - Throttles outgoing input so the server isn't spammed.
/// - Exposes a `ChangeNotifier`-style ticker (`frame`) the renderer can listen to.
class OnlineClassicController {
  OnlineClassicController({required this.playerName, String? serverUrl})
      : socket = OnlineSocketService(
          url: serverUrl ?? 'ws://89.167.123.101:2567',
        );

  final String playerName;
  final OnlineSocketService socket;

  // Server-confirmed entities indexed by id.
  final Map<String, OnlineCell> cells = {};
  final Map<String, OnlinePellet> pellets = {};
  final Map<String, OnlineVirus> viruses = {};
  final Map<String, OnlineEjected> ejected = {};
  List<OnlineLeaderboardEntry> leaderboard = const [];

  // Skin lookup. The key is "owner id + skin id"; the value is a decoded
  // ui.Image. The local player resolves to SkinSettings.instance.skinImage;
  // every other player/bot maps deterministically into SkinRegistry so each
  // remote cell shows a consistent (if locally chosen) skin.
  final Map<String, ui.Image?> _skinCache = {};

  // ── Client-side pellet eat prediction.
  // Pellet id → ms timestamp until which we keep it hidden locally. We pair
  // each entry with a small mass delta that's added to the displayed mass
  // until the next server snapshot bumps the authoritative figure.
  final Map<String, int> _eatenPelletExpiry = {};
  int _predictedMassDelta = 0;
  int _lastServerMass = 0;
  static const int _predictedEatTtlMs = 500;

  // Self / world info.
  String? selfId;
  double mapWidth = 8000;
  double mapHeight = 8000;
  int onlineCount = 0;
  int selfMass = 0;
  bool selfDead = false;

  // Smoothed round-trip latency in ms. -1 means we haven't measured yet.
  int pingMs = -1;
  static const _pingSmoothing = 0.3; // 0 = stick, 1 = always replace

  // Server-reported self center. Used as the prediction target for smoothing.
  double serverSelfX = 4000;
  double serverSelfY = 4000;

  // Predicted self center: this is what the camera/painter actually read.
  // Updated locally from joystick input each frame, then smooth-corrected
  // toward the server position when snapshots arrive.
  double selfX = 4000;
  double selfY = 4000;

  // Convenience accessors for the renderer/screen.
  double get predictedX => selfX;
  double get predictedY => selfY;

  // High-frequency repaint signal for the renderer.
  final ValueNotifier<int> frame = ValueNotifier(0);
  // Slower signal for HUD chrome.
  final ValueNotifier<int> hud = ValueNotifier(0);

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<OnlineConnState>? _stateSub;

  OnlineConnState connection = OnlineConnState.idle;
  final _connNotifier = ValueNotifier<OnlineConnState>(OnlineConnState.idle);
  ValueListenable<OnlineConnState> get connectionListenable => _connNotifier;

  /// True once we've received at least one full `state` snapshot from the
  /// server. Used by the screen to gate the game render + death overlay —
  /// neither should appear before we actually have data.
  bool hasFirstState = false;
  final _readyNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get readyListenable => _readyNotifier;

  // Input is held as a unit vector. The renderer updates it; we flush over
  // the network on a fixed cadence below.
  Offset inputDir = Offset.zero;

  Timer? _inputTimer;
  Offset _lastSentInput = const Offset(2, 2); // sentinel: never matches

  bool _disposed = false;

  /// Open the connection and start the per-frame interpolation loop.
  Future<void> start() async {
    _msgSub = socket.messages.listen(_onMessage);
    _stateSub = socket.stateChanges.listen((s) {
      connection = s;
      _connNotifier.value = s;
    });
    await socket.connect(
      playerName: playerName.trim().isEmpty ? 'Player' : playerName,
      skin: SkinSettings.instance.skinPath ?? '',
    );
    // Input pump: 30 Hz. Skips sends when nothing changed.
    _inputTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_disposed) return;
      final v = _clampInput(inputDir);
      if ((v - _lastSentInput).distance < 0.01) return;
      socket.sendInput(v.dx, v.dy);
      _lastSentInput = v;
    });
  }

  Offset _clampInput(Offset v) {
    final m = v.distance;
    if (m > 1) return v / m;
    return v;
  }

  /// Local cooldown timestamp for the split button — mirrors the server's
  /// SPLIT_COOLDOWN_MS so the button can grey out between presses without a
  /// round-trip. The actual gate is on the server; we only suppress visual
  /// re-presses inside the cooldown window.
  int _splitReadyAtMs = 0;
  static const int _splitCooldownMs = 800;
  bool get canSplit =>
      !selfDead &&
          DateTime.now().millisecondsSinceEpoch >= _splitReadyAtMs;

  void sendSplit() {
    if (selfDead) {
      debugPrint('ONLINE SPLIT IGNORED (dead)');
      return;
    }
    _splitReadyAtMs =
        DateTime.now().millisecondsSinceEpoch + _splitCooldownMs;
    socket.sendSplit();
  }

  void sendEject() {
    if (selfDead) {
      debugPrint('ONLINE EJECT IGNORED (dead)');
      return;
    }
    socket.sendEject();
  }

  /// No-op on the wire today (Offline Classic doesn't expose a press-to-
  /// boost button), but kept so feature gating elsewhere can call it
  /// unconditionally.
  void sendBoost(bool active) {
    if (selfDead) return;
    socket.sendBoost(active);
  }

  void requestRespawn() {
    if (selfDead) socket.sendRespawn();
  }

  /// Displayed mass = server-authoritative mass + any unconfirmed predicted
  /// pellet eats. Predicted delta decays as the server reports growth, so
  /// the visible number can only ever lead reality — never lag it.
  int get displayedMass => selfMass + _predictedMassDelta;

  /// True while a local prediction is hiding this pellet.
  bool isPelletEatenLocally(String id) {
    final exp = _eatenPelletExpiry[id];
    if (exp == null) return false;
    return DateTime.now().millisecondsSinceEpoch < exp;
  }

  /// Drive interpolation + local prediction. Call from a Ticker each frame
  /// with the delta time.
  void tickInterpolation(double dt) {
    // 1. Exponential blend toward server-confirmed targets for every cell
    //    (remote players, bots, AND the self cell — for the self cell we
    //    override its render position below). Rate 25 ≈ 80 ms time
    //    constant — tight enough that remote players track the joystick
    //    they're driving, loose enough to absorb 30 Hz snapshot jitter.
    final t = 1 - exp(-25 * dt);
    for (final c in cells.values) {
      c.interpolate(t);
    }
    for (final e in ejected.values) {
      e.interpolate(t);
    }

    // 2. Client-side prediction for the local player. We move the predicted
    //    center by joystick input * Classic speed curve per frame, then
    //    blend it toward the server's reported self center to absorb any
    //    drift without snapping.
    if (!selfDead) {
      final unit = _clampInput(inputDir);
      if (unit != Offset.zero) {
        final speed = _classicSpeedForMass(selfMass.toDouble());
        selfX += unit.dx * speed * dt;
        selfY += unit.dy * speed * dt;
      }
      // Smooth-correct toward the server-authoritative position. Three
      // regimes:
      //   • drift < deadzone (50 u) → trust prediction entirely. The
      //     normal RTT × speed gap (~20–40 u) falls inside this window, so
      //     we never drag the local player backward and the input feels
      //     truly real-time.
      //   • drift < snap → gentle correction. Recovers from impulses
      //     (split, virus bounce, edge clamp) without rubber-banding.
      //   • drift ≥ snap → teleport. Respawn or a packet gap landed us
      //     somewhere completely different.
      final ex = selfX - serverSelfX;
      final ey = selfY - serverSelfY;
      final err = ex * ex + ey * ey;
      const double deadzone = 50.0;
      const double snap = 200.0;
      if (err > snap * snap) {
        selfX = serverSelfX;
        selfY = serverSelfY;
      } else if (err > deadzone * deadzone) {
        final blend = 1 - exp(-2 * dt);
        selfX = selfX + (serverSelfX - selfX) * blend;
        selfY = selfY + (serverSelfY - selfY) * blend;
      }
      // Keep predicted position inside the world. Server clamps too, but this
      // stops the camera from drifting off if we mash the joystick at an edge.
      if (selfX < 0) selfX = 0;
      if (selfX > mapWidth) selfX = mapWidth;
      if (selfY < 0) selfY = 0;
      if (selfY > mapHeight) selfY = mapHeight;
    }

    // 3. Mirror predicted position back onto the local self cell so the
    //    rendered blob tracks the joystick instantly. The prediction step
    //    already smooths the server correction, so we can set this directly
    //    without an extra lerp — no visual delay on the local player.
    //    Also predict mass/radius growth from confirmed-locally eats so the
    //    cell visibly grows the instant pellets are consumed — the server
    //    snapshot arriving 30–40 ms later just confirms what we've already
    //    drawn.
    if (!selfDead) {
      final selfCells = <OnlineCell>[];
      for (final c in cells.values) {
        if (c.isSelf) selfCells.add(c);
      }
      if (selfCells.length == 1) {
        // Single-cell case: easy — funnel the whole displayed mass into it.
        final c = selfCells.first;
        c.renderX = selfX;
        c.renderY = selfY;
        final dm = displayedMass.toDouble();
        if (dm > c.renderMass) {
          c.renderMass = dm;
          // r = sqrt(m / pi) * 10 (matches server geometry).
          c.renderRadius = sqrt(dm / pi) * 10;
        }
      }
      // Multi-cell (post-split): the server's per-cell positions are the
      // only sane source of truth — each fragment has its own dash velocity
      // and merge state. We let the standard interpolation in step 1 flow
      // through untouched so the cells don't collapse onto a single point.
    }

    // 4. Pellet eat prediction. Walk our self cells against the pellet map
    //    and hide any pellet whose center is inside one of our cells — the
    //    server will catch up within a tick or two, and our display mass
    //    already accounts for the predicted gain via `_predictedMassDelta`.
    _predictPelletEats();

    frame.value++;
  }

  void _predictPelletEats() {
    if (selfDead) return;
    if (pellets.isEmpty) return;
    final selfCells = <OnlineCell>[];
    for (final c in cells.values) {
      if (c.isSelf) selfCells.add(c);
    }
    if (selfCells.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Expire stale entries first so the delta doesn't grow unboundedly.
    _eatenPelletExpiry.removeWhere((id, expiry) {
      if (expiry > now) return false;
      // When the prediction expires we drop its mass contribution too — the
      // server should've reported the gain by now, but cap at zero in case
      // the eat was rejected.
      _predictedMassDelta -= 1;
      if (_predictedMassDelta < 0) _predictedMassDelta = 0;
      return true;
    });
    for (final p in pellets.values) {
      if (_eatenPelletExpiry.containsKey(p.id)) continue;
      for (final c in selfCells) {
        final dx = p.x - c.renderX;
        final dy = p.y - c.renderY;
        final rr = c.renderRadius;
        if (dx * dx + dy * dy < rr * rr) {
          _eatenPelletExpiry[p.id] = now + _predictedEatTtlMs;
          _predictedMassDelta += 1; // server pellet mass is always 1
          break;
        }
      }
    }
  }

  /// Mirrors `GameConstants.maxSpeedForRadius` from the offline engine,
  /// capped at the classic terminal velocity (1200 / 5.8 ≈ 207 u/s).
  static const double _classicTerminal =
      GameConstants.inputMoveStrength / GameConstants.dampingPerSecond;
  double _classicSpeedForMass(double mass) {
    final m = mass < 1 ? 1.0 : mass;
    // r = sqrt(m / pi) * 10  (matches server radius() and offline geometry)
    final r = sqrt(m / pi) * 10;
    final maxSpeed = GameConstants.maxSpeedForRadius(r);
    return maxSpeed < _classicTerminal ? maxSpeed : _classicTerminal;
  }

  int _hudCounter = 0;
  void hudTick() {
    if (++_hudCounter >= 6) {
      _hudCounter = 0;
      hud.value++;
    }
  }

  void _onMessage(Map<String, dynamic> msg) {
    final type = msg['type'];
    if (type == 'connected') {
      selfId = msg['id'] as String?;
      mapWidth = (msg['mapWidth'] as num?)?.toDouble() ?? mapWidth;
      mapHeight = (msg['mapHeight'] as num?)?.toDouble() ?? mapHeight;
      hud.value++;
    } else if (type == 'state') {
      _applyState(msg);
    } else if (type == 'pong') {
      final t = (msg['t'] as num?)?.toInt();
      if (t != null && t > 0) {
        final rtt = DateTime.now().millisecondsSinceEpoch - t;
        if (rtt >= 0 && rtt < 5000) {
          if (pingMs < 0) {
            pingMs = rtt;
          } else {
            pingMs = (pingMs * (1 - _pingSmoothing) + rtt * _pingSmoothing)
                .round();
          }
        }
      }
    }
  }

  /// Reconcile a server snapshot with our local entity maps. Anything not in
  /// the snapshot (and which is older than 1.5 s) gets dropped.
  void _applyState(Map<String, dynamic> msg) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // ── self. Only treat the player as dead once the server has actually
    // told us so — `dead == true` strictly. Missing fields stay at their
    // previous values, so we don't flicker between alive/dead.
    final self = msg['self'] as Map<String, dynamic>?;
    if (self != null) {
      final newMass = (self['mass'] as num?)?.toInt();
      if (newMass != null) {
        // Reconcile predicted-eat delta: every mass point the server adds is
        // one less prediction we need to keep on top. Never go below zero.
        final delta = newMass - _lastServerMass;
        if (delta > 0 && _predictedMassDelta > 0) {
          _predictedMassDelta -= delta;
          if (_predictedMassDelta < 0) _predictedMassDelta = 0;
        }
        _lastServerMass = newMass;
        selfMass = newMass;
      }
      // dead defaults to false; only `true` flips it on. This is the key
      // fix for the "dead before connected" bug.
      final deadField = self['dead'];
      final wasDead = selfDead;
      if (deadField is bool) selfDead = deadField;
      final newX = (self['x'] as num?)?.toDouble();
      final newY = (self['y'] as num?)?.toDouble();
      if (newX != null && newX.isFinite) serverSelfX = newX;
      if (newY != null && newY.isFinite) serverSelfY = newY;
      // On (re)spawn the predicted center must teleport to the server position
      // — otherwise it'd lerp across the entire map.
      if (wasDead && !selfDead) {
        selfX = serverSelfX;
        selfY = serverSelfY;
        // Fresh life: drop any stale eat predictions so we start from a
        // clean baseline.
        _eatenPelletExpiry.clear();
        _predictedMassDelta = 0;
      }
    }
    onlineCount = (msg['online'] as num?)?.toInt() ?? onlineCount;

    // Mark first real state — gates the loading screen. Initialise the
    // predicted center to the server position so the camera doesn't start
    // mid-world and slide toward the player.
    if (!hasFirstState) {
      hasFirstState = true;
      selfX = serverSelfX;
      selfY = serverSelfY;
      _readyNotifier.value = true;
    }

    // ── cells
    final cellsJson = (msg['players'] as List?) ?? const [];
    for (final raw in cellsJson) {
      final j = raw as Map<String, dynamic>;
      final id = j['id'] as String;
      final existing = cells[id];
      if (existing == null) {
        final e = OnlineCell.fromJson(j);
        e.lastSnapshotMs = nowMs;
        cells[id] = e;
      } else {
        existing.updateFromJson(j, nowMs);
      }
    }
    // Tighter stale window so cells eaten right next to us don't linger on
    // screen for a second. 600 ms is still enough to absorb a brief snapshot
    // gap (the server ticks at 25 Hz, so any live cell is reconfirmed every
    // ~40 ms).
    cells.removeWhere((id, c) => nowMs - c.lastSnapshotMs > 600);

    // ── pellets
    final pelletsJson = (msg['pellets'] as List?) ?? const [];
    for (final raw in pelletsJson) {
      final j = raw as Map<String, dynamic>;
      final id = j['id'] as String;
      final existing = pellets[id];
      if (existing == null) {
        final e = OnlinePellet.fromJson(j);
        e.lastSnapshotMs = nowMs;
        pellets[id] = e;
      } else {
        existing.updateFromJson(j, nowMs);
      }
    }
    pellets.removeWhere((id, p) => nowMs - p.lastSnapshotMs > 2000);

    // ── viruses
    final virusesJson = (msg['viruses'] as List?) ?? const [];
    for (final raw in virusesJson) {
      final j = raw as Map<String, dynamic>;
      final id = j['id'] as String;
      final existing = viruses[id];
      if (existing == null) {
        final e = OnlineVirus.fromJson(j);
        e.lastSnapshotMs = nowMs;
        viruses[id] = e;
      } else {
        existing.updateFromJson(j, nowMs);
      }
    }
    viruses.removeWhere((id, v) => nowMs - v.lastSnapshotMs > 3000);

    // ── ejected (feed)
    final ejectedJson = (msg['ejected'] as List?) ?? const [];
    for (final raw in ejectedJson) {
      final j = raw as Map<String, dynamic>;
      final id = j['id'] as String;
      final existing = ejected[id];
      if (existing == null) {
        final e = OnlineEjected.fromJson(j);
        e.lastSnapshotMs = nowMs;
        ejected[id] = e;
      } else {
        existing.updateFromJson(j, nowMs);
      }
    }
    ejected.removeWhere((id, e) => nowMs - e.lastSnapshotMs > 800);

    // ── leaderboard
    final lb = (msg['leaderboard'] as List?) ?? const [];
    leaderboard = lb
        .map((j) => OnlineLeaderboardEntry.fromJson(j as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Resolve a skin image for the given cell. Self → user's selected skin
  /// (decoded once on profile load). Others → deterministic pick from the
  /// local SkinRegistry so each remote owner has a stable visual.
  ui.Image? skinFor(OnlineCell c) {
    if (c.isSelf) return SkinSettings.instance.skinImage;
    final key = '${c.ownerId}|${c.skinId}';
    if (_skinCache.containsKey(key)) return _skinCache[key];
    final reg = SkinRegistry.instance;
    if (!reg.isLoaded || reg.count == 0) {
      _skinCache[key] = null;
      return null;
    }
    final h = _stableHash(key);
    final idx = h % reg.count;
    // SkinRegistry has no public indexer, but `randomSkin` is seeded by a
    // Random — we just want a stable image per key. Build a Random from the
    // hash so each owner consistently lands on the same image.
    final img = reg.randomSkin(Random(idx));
    _skinCache[key] = img;
    return img;
  }

  int _stableHash(String s) {
    var h = 0;
    for (int i = 0; i < s.length; i++) {
      h = 0x1fffffff & (h * 31 + s.codeUnitAt(i));
    }
    return h;
  }

  /// Ask the controller to fully reconnect (e.g. user tapped "Retry").
  Future<void> retry() async {
    hasFirstState = false;
    _readyNotifier.value = false;
    cells.clear();
    pellets.clear();
    viruses.clear();
    ejected.clear();
    _skinCache.clear();
    _eatenPelletExpiry.clear();
    _predictedMassDelta = 0;
    _lastServerMass = 0;
    leaderboard = const [];
    selfDead = false;
    await socket.close();
    await socket.connect(
      playerName: playerName.trim().isEmpty ? 'Player' : playerName,
      skin: SkinSettings.instance.skinPath ?? '',
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _inputTimer?.cancel();
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    await socket.dispose();
    frame.dispose();
    hud.dispose();
    _connNotifier.dispose();
    _readyNotifier.dispose();
  }
}
