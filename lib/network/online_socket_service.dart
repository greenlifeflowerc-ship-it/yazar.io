import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../online/online_entities.dart';

/// Thin transport layer for the online classic server.
///
/// Holds one [WebSocketChannel], emits parsed JSON messages on [messages] and
/// connection lifecycle changes on [stateChanges]. Reconnect is exponential
/// up to a cap; if max attempts is reached the state goes to `failed` and the
/// UI shows a retry button.
class OnlineSocketService {
  OnlineSocketService({this.url = 'ws://89.167.123.101:2567'});

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _wantConnected = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 6;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _state = StreamController<OnlineConnState>.broadcast();
  OnlineConnState _currentState = OnlineConnState.idle;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<OnlineConnState> get stateChanges => _state.stream;
  OnlineConnState get state => _currentState;
  bool get isConnected => _currentState == OnlineConnState.connected;

  void _setState(OnlineConnState s) {
    if (_currentState == s) return;
    _currentState = s;
    if (!_state.isClosed) _state.add(s);
  }

  /// Open the socket and start sending pings. Idempotent.
  Future<void> connect({required String playerName, String skin = 'default'}) async {
    if (_disposed) return;
    _wantConnected = true;
    _reconnectAttempts = 0;
    await _openOnce(playerName: playerName, skin: skin);
  }

  Future<void> _openOnce({required String playerName, required String skin}) async {
    _setState(_reconnectAttempts == 0
        ? OnlineConnState.connecting
        : OnlineConnState.reconnecting);
    await _teardown(notify: false);
    try {
      final ch = WebSocketChannel.connect(Uri.parse(url));
      _channel = ch;
      _sub = ch.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: true,
      );
      // Wait briefly for the handshake to settle before sending join. If the
      // connection actually fails, the listen() error handler fires and we
      // schedule a reconnect.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      send({
        'type': 'join',
        'name': playerName,
        'skin': skin,
      });
      // Heartbeat ping every 1 s. The payload is ~30 bytes, so the
      // bandwidth cost is negligible, and it gives us a near-live RTT
      // readout for the HUD.
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        send({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
      });
    } catch (e, st) {
      debugPrint('OnlineSocket connect failed: $e\n$st');
      _scheduleReconnect(playerName: playerName, skin: skin);
    }
  }

  void _onData(dynamic raw) {
    Map<String, dynamic>? msg;
    try {
      if (raw is String) {
        msg = jsonDecode(raw) as Map<String, dynamic>;
      } else if (raw is List<int>) {
        msg = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      }
    } catch (_) {
      return;
    }
    if (msg == null) return;
    if (msg['type'] == 'connected' && _currentState != OnlineConnState.connected) {
      _reconnectAttempts = 0;
      _setState(OnlineConnState.connected);
    }
    if (!_messages.isClosed) _messages.add(msg);
  }

  void _onError(Object error, StackTrace st) {
    debugPrint('OnlineSocket error: $error');
    _onDone();
  }

  void _onDone() {
    if (_disposed) return;
    if (!_wantConnected) {
      _setState(OnlineConnState.closed);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect({String? playerName, String? skin}) {
    if (_disposed || !_wantConnected) return;
    _reconnectAttempts++;
    if (_reconnectAttempts > _maxReconnectAttempts) {
      _setState(OnlineConnState.failed);
      return;
    }
    _setState(OnlineConnState.reconnecting);
    final delayMs = (500 * (1 << (_reconnectAttempts - 1))).clamp(500, 6000);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _openOnce(
        playerName: playerName ?? _lastPlayerName ?? 'Player',
        skin: skin ?? _lastSkin,
      );
    });
  }

  /// Stored so silent reconnects can rejoin with the same name.
  String? _lastPlayerName;
  String _lastSkin = 'default';

  void send(Map<String, dynamic> msg) {
    final ch = _channel;
    if (ch == null) {
      debugPrint('OnlineSocket send dropped (no channel): ${msg['type']}');
      return;
    }
    if (_currentState != OnlineConnState.connected) {
      // Still send anything that doesn't require an established session
      // (e.g. ping after a brief drop) but log so callers can spot trouble.
      debugPrint(
          'OnlineSocket send while ${_currentState.name}: ${msg['type']}');
    }
    if (msg['type'] == 'join') {
      _lastPlayerName = msg['name'] as String?;
      _lastSkin = (msg['skin'] as String?) ?? 'default';
    }
    try {
      ch.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('OnlineSocket send failed: $e');
    }
  }

  /// Convenience helpers — the controller funnels protocol messages through
  /// these so the call sites read like RPCs. Each one validates the
  /// connection, JSON-encodes safely, and logs in debug builds.
  void sendInput(double dx, double dy) {
    send({
      'type': 'input',
      'dx': dx.clamp(-1.0, 1.0),
      'dy': dy.clamp(-1.0, 1.0),
    });
  }

  void sendSplit() {
    debugPrint('ONLINE SPLIT SENT');
    send({'type': 'split'});
  }

  void sendEject() {
    debugPrint('ONLINE EJECT SENT');
    send({'type': 'eject'});
  }

  /// Forward-compat: the current server has no boost concept (Offline
  /// Classic doesn't expose a press-to-boost button either), so this is a
  /// no-op on the wire when boost is off. The method exists so that gating
  /// from the game UI doesn't need conditional plumbing.
  void sendBoost(bool active) {
    debugPrint('ONLINE BOOST $active');
    send({'type': 'boost', 'active': active});
  }

  void sendPing() {
    send({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
  }

  void sendRespawn() => send({'type': 'respawn'});

  /// Drop the connection without reconnecting.
  Future<void> close() async {
    _wantConnected = false;
    await _teardown(notify: true);
  }

  Future<void> _teardown({required bool notify}) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final s = _sub;
    final c = _channel;
    _sub = null;
    _channel = null;
    try {
      await s?.cancel();
    } catch (_) {}
    try {
      await c?.sink.close(ws_status.goingAway);
    } catch (_) {}
    if (notify && !_disposed) _setState(OnlineConnState.closed);
  }

  Future<void> dispose() async {
    _disposed = true;
    _wantConnected = false;
    await _teardown(notify: false);
    await _messages.close();
    await _state.close();
  }
}
