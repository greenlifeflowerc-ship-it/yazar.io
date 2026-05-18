import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/config/server_config.dart';
import '../game/game_engine.dart' show GameConstants;
import '../game/game_settings.dart';
import '../game/skin_registry.dart';
import '../game/skin_settings.dart';
import '../network/online_socket_service.dart';
import 'online_entities.dart';

/// Source-of-truth for the online classic gameplay screen.
///
/// - Subscribes to the socket service.
/// - Maps incoming snapshot JSON into in-memory entity maps.
/// - Drives interpolation toward server targets every frame.
/// - Runs client-side prediction + camera/zoom smoothing identical to the
///   offline GameEngine so the feel is 1:1.
/// - Throttles outgoing input so the server isn't spammed.
/// - Exposes a `ChangeNotifier`-style ticker (`frame`) the renderer can listen to.
class OnlineClassicController {
  OnlineClassicController({required this.playerName, String? serverUrl})
      : socket = OnlineSocketService(
          url: serverUrl ?? ServerConfig.gameServerUrl,
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
  // When a pellet overlaps one of our cells we immediately remove it from
  // the `pellets` map and record its id here with an expiry timestamp.
  // `_applyState` skips any server update for that id until it expires —
  // prevents "teleporting pellet" flicker because the server now gives each
  // respawned pellet a brand-new id.
  final Map<String, int> _locallyEatenPellets = {};
  int _predictedMassDelta = 0;
  int _lastServerMass = 0;
  static const int _predictedEatTtlMs = 1200;

  // Self / world info.
  String? selfId;
  double mapWidth = 8000;
  double mapHeight = 8000;
  int onlineCount = 0;
  int selfMass = 0;
  bool selfDead = false;

  // Smoothed round-trip latency in ms. -1 means we haven't measured yet.
  int pingMs = -1;
  static const _pingSmoothing = 0.3;

  // Server-reported self center.
  double serverSelfX = 4000;
  double serverSelfY = 4000;

  // Predicted self center: updated locally from joystick input each frame,
  // then smooth-corrected toward the server position when snapshots arrive.
  double selfX = 4000;
  double selfY = 4000;

  // ── Camera smoothing — identical time constant to offline GameEngine ──────
  // Offline: `cameraPos = Offset.lerp(cameraPos, target, 0.1)` per frame at
  // 60 fps → equivalent to 1 - exp(-6.32 * dt) in continuous time.
  double cameraX = 4000;
  double cameraY = 4000;
  double cameraZoom = 1.0;

  // ── Input tracking for stopOnRelease (matches offline lastNonZeroDir) ─────
  Offset inputDir = Offset.zero;
  Offset lastNonZeroInputDir = const Offset(1, 0);

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

  bool hasFirstState = false;
  final _readyNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get readyListenable => _readyNotifier;

  Timer? _inputTimer;
  Offset _lastSentInput = const Offset(2, 2); // sentinel: never matches

  bool _disposed = false;

  /// Effective input direction, respecting the `stopOnRelease` setting.
  /// When joystick is released and stopOnRelease is off, we keep the last
  /// known direction — identical to offline's `lastNonZeroDir` logic.
  Offset get _effectiveInputDir {
    if (inputDir.distance > 0.05) return inputDir;
    return GameSettings.instance.stopOnRelease
        ? Offset.zero
        : lastNonZeroInputDir;
  }

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
    // Input pump at 50 Hz — uses effectiveInputDir so stopOnRelease is
    // honoured on the server side too.
    _inputTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (_disposed) return;
      final v = _clampInput(_effectiveInputDir);
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

  /// Local cooldown timestamp for the split button.
  int _splitReadyAtMs = 0;
  static const int _splitCooldownMs = 800;
  bool get canSplit =>
      !selfDead && DateTime.now().millisecondsSinceEpoch >= _splitReadyAtMs;

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

  void sendBoost(bool active) {
    if (selfDead) return;
    socket.sendBoost(active);
  }

  void requestRespawn() {
    if (selfDead) socket.sendRespawn();
  }

  /// Displayed mass = server mass + unconfirmed predicted pellet eats.
  int get displayedMass => selfMass + _predictedMassDelta;

  // ── Camera helpers ─────────────────────────────────────────────────────────

  double _targetCameraX() {
    final selfCells = <OnlineCell>[];
    for (final c in cells.values) {
      if (c.isSelf) selfCells.add(c);
    }
    if (selfCells.isEmpty) return selfX;
    // Single cell: use the prediction-smoothed position so the camera tracks
    // input instantly, identical to offline.
    if (selfCells.length == 1) return selfX;
    // Multi-cell (post-split): mass-weighted center of all fragments.
    double cx = 0, tm = 0;
    for (final c in selfCells) {
      cx += c.renderX * c.renderMass;
      tm += c.renderMass;
    }
    return tm > 0 ? cx / tm : selfX;
  }

  double _targetCameraY() {
    final selfCells = <OnlineCell>[];
    for (final c in cells.values) {
      if (c.isSelf) selfCells.add(c);
    }
    if (selfCells.isEmpty) return selfY;
    if (selfCells.length == 1) return selfY;
    double cy = 0, tm = 0;
    for (final c in selfCells) {
      cy += c.renderY * c.renderMass;
      tm += c.renderMass;
    }
    return tm > 0 ? cy / tm : selfY;
  }

  /// Target zoom — identical formula to offline GameEngine._targetZoom().
  double _targetZoom() {
    double totalMass = 0;
    for (final c in cells.values) {
      if (c.isSelf) totalMass += c.renderMass;
    }
    if (totalMass < 10) totalMass = selfMass.clamp(10, 1 << 30).toDouble();
    final m = totalMass.clamp(10.0, 1e9);
    final z = pow(64.0 / m, 0.25).toDouble();
    final mult = 1.0 / GameSettings.instance.zoomMultiplier;
    return (z * mult).clamp(0.01, 4.0);
  }

  // ── Main interpolation tick ────────────────────────────────────────────────

  /// Drive interpolation + local prediction. Call from a Ticker each frame
  /// with the delta time.
  void tickInterpolation(double dt) {
    // Track last non-zero direction for stopOnRelease support — mirrors
    // offline's `if (moveDir.distance > 0.05) lastNonZeroDir = moveDir`.
    if (inputDir.distance > 0.05) lastNonZeroInputDir = inputDir;

    // 1. Exponential blend toward server-confirmed targets. Rate 40 gives a
    //    ~25 ms time constant at 50 Hz snapshots — tight but jitter-free.
    final t = 1 - exp(-40 * dt);
    for (final c in cells.values) {
      c.interpolate(t);
      // Wobble phase + jelly bump decay — identical to offline _integrateCells.
      c.wobblePhase += dt * 4;
      if (c.bumps.isNotEmpty) {
        final bumpDecay = exp(-6.0 * dt);
        for (int i = c.bumps.length - 1; i >= 0; i--) {
          c.bumps[i].magnitude *= bumpDecay;
          if (c.bumps[i].magnitude < 0.005) c.bumps.removeAt(i);
        }
      }
    }
    for (final e in ejected.values) {
      e.interpolate(t);
    }

    // 2. Client-side prediction for the local player. Uses effectiveInputDir
    //    so stopOnRelease is respected locally too.
    if (!selfDead) {
      final effectiveDir = _effectiveInputDir;
      final unit = _clampInput(effectiveDir);
      if (unit != Offset.zero) {
        final speed = _classicSpeedForMass(selfMass.toDouble());
        selfX += unit.dx * speed * dt;
        selfY += unit.dy * speed * dt;
      }
      // Smooth-correct toward server position. Three regimes:
      //   • drift < deadzone (35 u) → trust prediction entirely.
      //   • drift < snap (200 u) → gentle correction for impulse recovery.
      //   • drift ≥ snap → teleport (respawn / packet gap).
      final ex = selfX - serverSelfX;
      final ey = selfY - serverSelfY;
      final err = ex * ex + ey * ey;
      const double deadzone = 35.0;
      const double snap = 200.0;
      if (err > snap * snap) {
        selfX = serverSelfX;
        selfY = serverSelfY;
      } else if (err > deadzone * deadzone) {
        final blend = 1 - exp(-2 * dt);
        selfX = selfX + (serverSelfX - selfX) * blend;
        selfY = selfY + (serverSelfY - selfY) * blend;
      }
      // World bounds.
      if (selfX < 0) selfX = 0;
      if (selfX > mapWidth) selfX = mapWidth;
      if (selfY < 0) selfY = 0;
      if (selfY > mapHeight) selfY = mapHeight;
    }

    // 3. Mirror predicted position back onto the local self cell (single-cell
    //    case). Multi-cell: server per-cell positions drive it via step 1.
    if (!selfDead) {
      final selfCells = <OnlineCell>[];
      for (final c in cells.values) {
        if (c.isSelf) selfCells.add(c);
      }
      if (selfCells.length == 1) {
        final c = selfCells.first;
        c.renderX = selfX;
        c.renderY = selfY;
        final dm = displayedMass.toDouble();
        if (dm > c.renderMass) {
          c.renderMass = dm;
          c.renderRadius = sqrt(dm / pi) * 10;
        }
      }
    }

    // 4. Pellet eat prediction + jelly bumps.
    _predictPelletEats();

    // 5. Advance pellet pulse phases — identical to offline engine pellet tick.
    for (final p in pellets.values) {
      p.pulsePhase += dt * 3;
    }

    // 6. Camera smoothing — 1 - exp(-6.32 * dt) matches offline's 0.1/frame
    //    coefficient at 60 fps. Only moves while alive.
    if (!selfDead) {
      final camLerp = 1 - exp(-6.32 * dt);
      final txCamera = _targetCameraX();
      final tyCamera = _targetCameraY();
      cameraX += (txCamera - cameraX) * camLerp;
      cameraY += (tyCamera - cameraY) * camLerp;
      final targetZoom = _targetZoom();
      cameraZoom += (targetZoom - cameraZoom) * camLerp;
    }

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
    // Expire stale predictions and retire their mass delta contribution.
    _locallyEatenPellets.removeWhere((id, expiry) {
      if (expiry > now) return false;
      _predictedMassDelta -= 1;
      if (_predictedMassDelta < 0) _predictedMassDelta = 0;
      return true;
    });
    // Walk a snapshot of keys because we mutate the map inside the loop.
    final ids = pellets.keys.toList(growable: false);
    for (final id in ids) {
      final p = pellets[id];
      if (p == null) continue;
      for (final c in selfCells) {
        final dx = p.x - c.renderX;
        final dy = p.y - c.renderY;
        final rr = c.renderRadius;
        if (dx * dx + dy * dy < rr * rr) {
          // Immediately remove — no flicker waiting for server confirmation.
          pellets.remove(id);
          _locallyEatenPellets[id] = now + _predictedEatTtlMs;
          _predictedMassDelta += 1;
          c.addBump(atan2(dy, dx), 0.04);
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

  void _applyState(Map<String, dynamic> msg) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final self = msg['self'] as Map<String, dynamic>?;
    if (self != null) {
      final newMass = (self['mass'] as num?)?.toInt();
      if (newMass != null) {
        final delta = newMass - _lastServerMass;
        if (delta > 0 && _predictedMassDelta > 0) {
          _predictedMassDelta -= delta;
          if (_predictedMassDelta < 0) _predictedMassDelta = 0;
        }
        _lastServerMass = newMass;
        selfMass = newMass;
      }
      final deadField = self['dead'];
      final wasDead = selfDead;
      if (deadField is bool) selfDead = deadField;
      final newX = (self['x'] as num?)?.toDouble();
      final newY = (self['y'] as num?)?.toDouble();
      if (newX != null && newX.isFinite) serverSelfX = newX;
      if (newY != null && newY.isFinite) serverSelfY = newY;
      // Teleport predicted position + camera on respawn.
      if (wasDead && !selfDead) {
        selfX = serverSelfX;
        selfY = serverSelfY;
        cameraX = serverSelfX;
        cameraY = serverSelfY;
        _locallyEatenPellets.clear();
        _predictedMassDelta = 0;
      }
    }
    onlineCount = (msg['online'] as num?)?.toInt() ?? onlineCount;

    // Mark first real state — teleport camera so it doesn't slide from center.
    if (!hasFirstState) {
      hasFirstState = true;
      selfX = serverSelfX;
      selfY = serverSelfY;
      cameraX = serverSelfX;
      cameraY = serverSelfY;
      cameraZoom = _targetZoom();
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
    cells.removeWhere((id, c) => nowMs - c.lastSnapshotMs > 600);

    // ── pellets / viruses (half-rate)
    final pelletsRaw = msg['pellets'];
    if (pelletsRaw is List) {
      // Expire stale local predictions before reconciling.
      final nowMs2 = DateTime.now().millisecondsSinceEpoch;
      _locallyEatenPellets.removeWhere((id, expiry) {
        if (expiry > nowMs2) return false;
        _predictedMassDelta -= 1;
        if (_predictedMassDelta < 0) _predictedMassDelta = 0;
        return true;
      });
      for (final raw in pelletsRaw) {
        final j = raw as Map<String, dynamic>;
        final id = j['id'] as String;
        // Skip while locally predicted eaten — server now gives fresh IDs on
        // respawn, so this id is guaranteed to be the old (consumed) pellet.
        if (_locallyEatenPellets.containsKey(id)) continue;
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
    }

    final virusesRaw = msg['viruses'];
    if (virusesRaw is List) {
      for (final raw in virusesRaw) {
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
    }

    // ── ejected
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

  /// Resolve a skin image for the given cell.
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

  Future<void> retry() async {
    hasFirstState = false;
    _readyNotifier.value = false;
    cells.clear();
    pellets.clear();
    viruses.clear();
    ejected.clear();
    _skinCache.clear();
    _locallyEatenPellets.clear();
    _predictedMassDelta = 0;
    _lastServerMass = 0;
    leaderboard = const [];
    selfDead = false;
    cameraX = mapWidth / 2;
    cameraY = mapHeight / 2;
    cameraZoom = 1.0;
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
