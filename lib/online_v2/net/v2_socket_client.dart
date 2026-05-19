/// V2 WebSocket transport for Online Classic V2.
///
/// Owns the socket, parses incoming packets into the typed
/// [V2Welcome] / [V2State] / [V2Pong] classes, and exposes typed `send*`
/// helpers that stamp every outbound action with a monotonically-increasing
/// input sequence number.
///
/// Reconnect is exponential with a small cap so a brief outage doesn't break
/// the session; the controller is allowed to keep simulating locally during
/// that window and reconciles when the next state arrives.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/config/server_config.dart';
import 'v2_packets.dart';

class V2SocketClient {
  V2SocketClient({this.url = ServerConfig.gameServerUrl});

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _wantConnected = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 6;

  /// Monotonic input sequence — stamped onto every input/split/eject packet
  /// so the server can echo `ack` and the client can reconcile.
  int _inputSeq = 0;
  int get lastSentSeq => _inputSeq;

  String? _lastName;
  String _lastSkin = 'default';
  double _lastMassMult = 1.0;

  final _welcome = StreamController<V2Welcome>.broadcast();
  final _states = StreamController<V2State>.broadcast();
  final _pongs = StreamController<V2Pong>.broadcast();
  final _stateChanges = StreamController<V2ConnState>.broadcast();

  V2ConnState _state = V2ConnState.idle;
  V2ConnState get state => _state;
  bool get isConnected => _state == V2ConnState.connected;

  Stream<V2Welcome> get welcomes => _welcome.stream;
  Stream<V2State> get snapshots => _states.stream;
  Stream<V2Pong> get pongs => _pongs.stream;
  Stream<V2ConnState> get stateChanges => _stateChanges.stream;

  void _setState(V2ConnState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateChanges.isClosed) _stateChanges.add(s);
  }

  /// Open the socket and immediately send `join`. Idempotent.
  Future<void> connect({
    required String playerName,
    String skin = 'default',
    double massMultiplier = 1.0,
  }) async {
    if (_disposed) return;
    _wantConnected = true;
    _reconnectAttempts = 0;
    _lastName = playerName;
    _lastSkin = skin;
    _lastMassMult = massMultiplier;
    await _openOnce();
  }

  Future<void> _openOnce() async {
    _setState(_reconnectAttempts == 0
        ? V2ConnState.connecting
        : V2ConnState.reconnecting);
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
      await Future<void>.delayed(const Duration(milliseconds: 50));
      _sendRaw({
        'type': 'join',
        'name': _lastName ?? 'Player',
        'skin': _lastSkin,
        'massMult': _lastMassMult,
      });
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) => sendPing());
    } catch (e, st) {
      debugPrint('V2 socket connect failed: $e\n$st');
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    Map<String, dynamic>? m;
    try {
      if (raw is String) {
        m = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } else if (raw is List<int>) {
        m = (jsonDecode(utf8.decode(raw)) as Map).cast<String, dynamic>();
      }
    } catch (_) {
      return;
    }
    if (m == null) return;

    final w = V2Welcome.tryParse(m);
    if (w != null) {
      _reconnectAttempts = 0;
      _setState(V2ConnState.connected);
      if (!_welcome.isClosed) _welcome.add(w);
      return;
    }
    final s = V2State.tryParse(m);
    if (s != null) {
      if (!_states.isClosed) _states.add(s);
      return;
    }
    final p = V2Pong.tryParse(m);
    if (p != null) {
      if (!_pongs.isClosed) _pongs.add(p);
      return;
    }
  }

  void _onError(Object err, StackTrace st) {
    debugPrint('V2 socket error: $err');
    _onDone();
  }

  void _onDone() {
    if (_disposed) return;
    if (!_wantConnected) {
      _setState(V2ConnState.closed);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !_wantConnected) return;
    _reconnectAttempts++;
    if (_reconnectAttempts > _maxReconnectAttempts) {
      _setState(V2ConnState.failed);
      return;
    }
    _setState(V2ConnState.reconnecting);
    final delay = (500 * (1 << (_reconnectAttempts - 1))).clamp(500, 6000);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delay), _openOnce);
  }

  // ───────────────────────────────────────────────────────── send API

  int _nextSeq() => ++_inputSeq;

  /// Continuous joystick input. Stamped with the next sequence number so the
  /// server can `ack` and the client can reconcile its pending input buffer.
  void sendInput({
    required double dx,
    required double dy,
    required bool attack,
  }) {
    final seq = _nextSeq();
    _sendRaw({
      'type': 'input',
      'seq': seq,
      'dx': dx.clamp(-1.0, 1.0),
      'dy': dy.clamp(-1.0, 1.0),
      'attack': attack,
    });
  }

  void sendSplit() {
    final seq = _nextSeq();
    _sendRaw({'type': 'split', 'seq': seq});
  }

  void sendEject() {
    final seq = _nextSeq();
    _sendRaw({'type': 'eject', 'seq': seq});
  }

  void sendRespawn() => _sendRaw({'type': 'respawn'});

  void sendPing() {
    _sendRaw({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
  }

  void _sendRaw(Map<String, dynamic> msg) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('V2 socket send failed (${msg['type']}): $e');
    }
  }

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
    try { await s?.cancel(); } catch (_) {}
    try { await c?.sink.close(ws_status.goingAway); } catch (_) {}
    if (notify && !_disposed) _setState(V2ConnState.closed);
  }

  Future<void> dispose() async {
    _disposed = true;
    _wantConnected = false;
    await _teardown(notify: false);
    await _welcome.close();
    await _states.close();
    await _pongs.close();
    await _stateChanges.close();
  }
}
