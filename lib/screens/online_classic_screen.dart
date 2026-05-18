import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../game/game_settings.dart';
import '../online/online_classic_controller.dart';
import '../online/online_classic_renderer.dart';
import '../online/online_entities.dart';
import '../utils/app_colors.dart';
import '../widgets/game_button.dart';
import '../widgets/pause_menu.dart';
import '../widgets/virtual_joystick.dart';

/// Tick interval (ms) used to repeat the eject message while the feed
/// button is held — same cadence Offline Classic uses for hold-to-eject.
const int _onlineEjectIntervalMs = 100;

class OnlineClassicScreen extends StatefulWidget {
  const OnlineClassicScreen({super.key, required this.nickname});
  final String nickname;

  @override
  State<OnlineClassicScreen> createState() => _OnlineClassicScreenState();
}

class _OnlineClassicScreenState extends State<OnlineClassicScreen>
    with SingleTickerProviderStateMixin {
  late final OnlineClassicController _controller;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  static final _fmt = NumberFormat.decimalPattern('en_US');

  // Button positions — shared with Offline Classic via GameSettings so the
  // player only configures placement once.
  late final ValueNotifier<Offset> _ejectPos;
  late final ValueNotifier<Offset> _ejectPos2;
  late final ValueNotifier<Offset> _splitPos;

  bool _draggingEject = false;
  bool _draggingEject2 = false;
  bool _draggingSplit = false;

  // Hold-to-eject timers for the two feed buttons.
  Timer? _ejectHoldTimer;
  Timer? _ejectHoldTimer2;

  // PC mode: focus + mouse tracking so we can mirror Classic's keyboard +
  // mouse-look controls.
  final FocusNode _gameFocusNode = FocusNode();
  Offset _mousePos = Offset.zero;
  bool _firstMouseHover = false;

  @override
  void initState() {
    super.initState();
    _controller = OnlineClassicController(playerName: widget.nickname);
    _ejectPos = ValueNotifier(GameSettings.instance.ejectBtnFrac);
    _ejectPos2 = ValueNotifier(GameSettings.instance.ejectBtnFrac2);
    _splitPos = ValueNotifier(GameSettings.instance.splitBtnFrac);
    // Start connecting immediately so the loading screen ticks forward as
    // soon as the user lands on this page.
    _controller.start();
    _ticker = createTicker(_onTick)..start();

    if (GameSettings.instance.pcMode) {
      _gameFocusNode.requestFocus();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final clamped = dt.clamp(0.0, 0.05);

    // PC mode: derive input direction from mouse position relative to the
    // screen center. Same shape as Offline Classic — max input magnitude is
    // reached at 15% of the shorter screen edge.
    if (GameSettings.instance.pcMode && _firstMouseHover && !_controller.selfDead) {
      final size = MediaQuery.of(context).size;
      final center = Offset(size.width / 2, size.height / 2);
      final diff = _mousePos - center;
      final dist = diff.distance;
      final maxRadius = size.shortestSide * 0.15;
      if (dist < 10) {
        _controller.inputDir = Offset.zero;
      } else {
        final mag = (dist / maxRadius).clamp(0.0, 1.0);
        _controller.inputDir = (diff / dist) * mag;
      }
    }

    _controller.tickInterpolation(clamped);
    _controller.hudTick();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!GameSettings.instance.pcMode) return KeyEventResult.ignored;
    final isDown = event is KeyDownEvent;
    final isUp = event is KeyUpEvent;
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (isDown) _onSplitTap();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyW) {
      if (isDown) {
        _startEjectHold();
      } else if (isUp) {
        _endEjectHold();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyE) {
      if (isDown) {
        _startEjectHold2();
      } else if (isUp) {
        _endEjectHold2();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _ejectHoldTimer?.cancel();
    _ejectHoldTimer2?.cancel();
    _ejectPos.dispose();
    _ejectPos2.dispose();
    _splitPos.dispose();
    _gameFocusNode.dispose();
    _ticker.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startEjectHold() {
    if (_draggingEject) return;
    if (_ejectHoldTimer != null) return;
    debugPrint('ONLINE FEED PRESSED (1)');
    _controller.sendEject(); // fire on first touch
    _ejectHoldTimer = Timer.periodic(
      const Duration(milliseconds: _onlineEjectIntervalMs),
      (_) => _controller.sendEject(),
    );
  }

  void _endEjectHold() {
    _ejectHoldTimer?.cancel();
    _ejectHoldTimer = null;
  }

  void _startEjectHold2() {
    if (_draggingEject2) return;
    if (_ejectHoldTimer2 != null) return;
    debugPrint('ONLINE FEED PRESSED (2)');
    _controller.sendEject();
    _ejectHoldTimer2 = Timer.periodic(
      const Duration(milliseconds: _onlineEjectIntervalMs),
      (_) => _controller.sendEject(),
    );
  }

  void _endEjectHold2() {
    _ejectHoldTimer2?.cancel();
    _ejectHoldTimer2 = null;
  }

  void _onSplitTap() {
    if (_draggingSplit) return;
    debugPrint('ONLINE SPLIT PRESSED');
    _controller.sendSplit();
  }

  void _showPauseMenu() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      barrierDismissible: true,
      builder: (dialogCtx) => PauseMenu(
        onResume: () => Navigator.of(dialogCtx).pop(),
        onExit: () {
          Navigator.of(dialogCtx).pop();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Top-level branch on readiness keeps the loading screen completely
    // separated from the game stack. No Positioned/SafeArea/z-order ambiguity
    // can hide it.
    return ValueListenableBuilder<bool>(
      valueListenable: _controller.readyListenable,
      builder: (context, ready, _) {
        if (!ready) return _LoadingScreen(
          controller: _controller,
          onExit: () => Navigator.of(context).pop(),
        );
        return _buildGameScreen(context);
      },
    );
  }

  Widget _buildGameScreen(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final gs = GameSettings.instance;

    return AnimatedBuilder(
      animation: gs,
      builder: (context, _) {
        final joystickRight = gs.joystickOnRight;
        final btnScale = gs.buttonScale;
        final pcMode = gs.pcMode;
        if (pcMode && !_gameFocusNode.hasFocus) {
          // Re-grab focus if the user just toggled PC mode mid-session.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _gameFocusNode.requestFocus());
        }
        return Scaffold(
          backgroundColor: gs.backgroundColor,
          body: Focus(
            focusNode: _gameFocusNode,
            autofocus: pcMode,
            onKeyEvent: _onKey,
            child: MouseRegion(
              onHover: (event) {
                if (pcMode) {
                  _mousePos = event.localPosition;
                  _firstMouseHover = true;
                }
              },
              child: Stack(
            children: [
              // 1. World renderer (bottom).
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: OnlineClassicPainter(
                      controller: _controller,
                      repaint: _controller.frame,
                    ),
                    size: size,
                  ),
                ),
              ),

              // 2. Joystick — touch-only. PC mode replaces it with the
              //    mouse-look loop driven by _onTick.
              if (!pcMode)
                Positioned(
                  left: joystickRight ? null : 0,
                  right: joystickRight ? 0 : null,
                  top: 0,
                  bottom: 0,
                  width: size.width * 0.5,
                  child: VirtualJoystick(
                    onChanged: (dir) => _controller.inputDir = dir,
                    onReleased: () => _controller.inputDir = Offset.zero,
                  ),
                ),

              // 3. Top-left HUD (pause + mass + online pill).
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, top: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _pauseButton(),
                      const SizedBox(width: 10),
                      ValueListenableBuilder<int>(
                        valueListenable: _controller.hud,
                        builder: (context, _, __) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Mass: ${_fmt.format(_controller.displayedMass)}',
                              style: GoogleFonts.baloo2(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 4),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            _onlinePill(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 4. Leaderboard (top-right).
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12, right: 8),
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<int>(
                        valueListenable: _controller.hud,
                        builder: (context, _, __) => _OnlineLeaderboard(
                          entries: _controller.leaderboard,
                          selfId: _controller.selfId,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 5a-c. Touch action buttons. PC mode swaps them for the
              //       keyboard shortcuts (Space / W / E) handled by _onKey.
              if (!pcMode) ...[
                _buildEjectButton(
                  size,
                  btnScale,
                  pos: _ejectPos,
                  color: const Color(0xFFFF7A2F),
                  dragging: _draggingEject,
                  onDragStart: () => setState(() => _draggingEject = true),
                  onDragEnd: () => setState(() => _draggingEject = false),
                  onDragMove: (newPos) {
                    _ejectPos.value = newPos;
                    GameSettings.instance.ejectBtnFrac = newPos;
                  },
                  onPressStart: _startEjectHold,
                  onPressEnd: _endEjectHold,
                ),
                _buildEjectButton(
                  size,
                  btnScale,
                  pos: _ejectPos2,
                  color: const Color(0xFFFFB300),
                  dragging: _draggingEject2,
                  onDragStart: () => setState(() => _draggingEject2 = true),
                  onDragEnd: () => setState(() => _draggingEject2 = false),
                  onDragMove: (newPos) {
                    _ejectPos2.value = newPos;
                    GameSettings.instance.ejectBtnFrac2 = newPos;
                  },
                  onPressStart: _startEjectHold2,
                  onPressEnd: _endEjectHold2,
                ),
                _buildSplitButton(size, btnScale),
              ],

              // PC mode hint banner — same copy + look as Offline Classic.
              if (pcMode && !_controller.selfDead)
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'PC Mode: Move with mouse • Split: Space • Feed: W / E',
                          style: GoogleFonts.baloo2(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // 7. Reconnect banner — only fires when we lose mid-session.
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ValueListenableBuilder<OnlineConnState>(
                    valueListenable: _controller.connectionListenable,
                    builder: (context, state, _) => _ReconnectBanner(
                      state: state,
                      onRetry: _controller.retry,
                      onExit: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),

              // 8. Death overlay.
              ValueListenableBuilder<int>(
                valueListenable: _controller.hud,
                builder: (context, _, __) {
                  if (!_controller.selfDead) return const SizedBox.shrink();
                  return Positioned.fill(child: _deathOverlay());
                },
              ),
            ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEjectButton(
    Size size,
    double btnScale, {
    required ValueNotifier<Offset> pos,
    required Color color,
    required bool dragging,
    required VoidCallback onDragStart,
    required VoidCallback onDragEnd,
    required ValueChanged<Offset> onDragMove,
    required VoidCallback onPressStart,
    required VoidCallback onPressEnd,
  }) {
    return ValueListenableBuilder<Offset>(
      valueListenable: pos,
      builder: (context, p, _) {
        final half = 30.0 * btnScale;
        return Positioned(
          left: p.dx * size.width - half,
          top: p.dy * size.height - half,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) => onDragStart(),
            onLongPressMoveUpdate: (d) {
              onDragMove(Offset(
                (d.globalPosition.dx / size.width).clamp(0.04, 0.96),
                (d.globalPosition.dy / size.height).clamp(0.04, 0.96),
              ));
            },
            onLongPressEnd: (_) => onDragEnd(),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (dragging) Positioned.fill(child: _dragGlow()),
                ValueListenableBuilder<int>(
                  valueListenable: _controller.hud,
                  builder: (ctx, _, __) => GameButton(
                    onPressStart: onPressStart,
                    onPressEnd: onPressEnd,
                    color: color,
                    size: 60 * btnScale,
                    enabled: !_controller.selfDead && !dragging,
                    hint: dragging ? 'hold & drag' : null,
                    builder: (_) => const EjectIcon(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSplitButton(Size size, double btnScale) {
    return ValueListenableBuilder<Offset>(
      valueListenable: _splitPos,
      builder: (context, pos, _) {
        final half = 35.0 * btnScale;
        return Positioned(
          left: pos.dx * size.width - half,
          top: pos.dy * size.height - half,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) =>
                setState(() => _draggingSplit = true),
            onLongPressMoveUpdate: (d) {
              final newPos = Offset(
                (d.globalPosition.dx / size.width).clamp(0.04, 0.96),
                (d.globalPosition.dy / size.height).clamp(0.04, 0.96),
              );
              _splitPos.value = newPos;
              GameSettings.instance.splitBtnFrac = newPos;
            },
            onLongPressEnd: (_) =>
                setState(() => _draggingSplit = false),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (_draggingSplit)
                  Positioned.fill(child: _dragGlow()),
                ValueListenableBuilder<int>(
                  valueListenable: _controller.hud,
                  builder: (ctx, _, __) => GameButton(
                    onTap: _onSplitTap,
                    color: const Color(0xFF3DA5F5),
                    size: 70 * btnScale,
                    enabled: _controller.canSplit && !_draggingSplit,
                    hint: _draggingSplit ? 'hold & drag' : null,
                    builder: (_) => const SplitIcon(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dragGlow() {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.yellowAccent, width: 3),
          boxShadow: [
            BoxShadow(
              color: Colors.yellowAccent.withValues(alpha: 0.45),
              blurRadius: 18,
              spreadRadius: 4,
            ),
          ],
        ),
      ),
    );
  }

  Widget _pauseButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _showPauseMenu,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              offset: const Offset(0, 2),
              blurRadius: 4,
            ),
          ],
        ),
        child: const Icon(Icons.pause, color: Color(0xFF2A2A2A), size: 22),
      ),
    );
  }

  Widget _onlinePill() {
    final state = _controller.connection;
    final connected = state == OnlineConnState.connected;
    final color =
        connected ? const Color(0xFF34C924) : const Color(0xFFFFB300);
    final ping = _controller.pingMs;
    final pingLabel = ping < 0 ? '…' : '${ping}ms';
    final pingColor = ping < 0
        ? Colors.white70
        : (ping < 100
            ? const Color(0xFF8AFF8A)
            : (ping < 200
                ? const Color(0xFFFFD60A)
                : const Color(0xFFFF7A7A)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.8), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            connected
                ? 'Online · ${_controller.onlineCount}'
                : 'Reconnecting…',
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (connected) ...[
            const SizedBox(width: 8),
            Container(
              width: 1,
              height: 10,
              color: Colors.white24,
            ),
            const SizedBox(width: 6),
            Text(
              pingLabel,
              style: GoogleFonts.baloo2(
                color: pingColor,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deathOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        decoration: BoxDecoration(
          color: AppColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.cardBorderColor, width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You died',
              style: GoogleFonts.baloo2(
                color: AppColors.primaryText,
                fontSize: 32,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Last mass: ${_fmt.format(_controller.selfMass)}',
              style: GoogleFonts.baloo2(
                color: AppColors.secondaryText,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _menuButton(
                  label: 'Respawn',
                  color: const Color(0xFF34C924),
                  onTap: _controller.requestRespawn,
                ),
                const SizedBox(width: 12),
                _menuButton(
                  label: 'Main menu',
                  color: const Color(0xFF1E9BFF),
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          label,
          style: GoogleFonts.baloo2(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

/// Standalone Scaffold shown until the first server snapshot arrives.
/// Lives at the top of the widget tree so nothing can paint over it.
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen({
    required this.controller,
    required this.onExit,
  });

  final OnlineClassicController controller;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        body: Container(
          // Vibrant blue gradient so the loading state is unmistakable —
          // can't be confused with an "empty" or "white" screen.
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF0277BD),
                Color(0xFF01579B),
                Color(0xFF002A57),
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ValueListenableBuilder<OnlineConnState>(
                valueListenable: controller.connectionListenable,
                builder: (context, state, _) {
                  final failed = state == OnlineConnState.failed;
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _bigIcon(failed),
                      const SizedBox(height: 18),
                      Text(
                        'Online Classic',
                        style: GoogleFonts.baloo2(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _title(state, failed),
                        style: GoogleFonts.baloo2(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (!failed)
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor:
                                AlwaysStoppedAnimation(Colors.white),
                          ),
                        ),
                      if (!failed) const SizedBox(height: 14),
                      Text(
                        _subtitle(state),
                        textAlign: TextAlign.center,
                        style: GoogleFonts.baloo2(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (failed)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _button(
                              label: 'Retry',
                              color: const Color(0xFF34C924),
                              onTap: controller.retry,
                            ),
                            const SizedBox(width: 12),
                            _button(
                              label: 'Back',
                              color: Colors.white.withValues(alpha: 0.18),
                              onTap: onExit,
                            ),
                          ],
                        )
                      else
                        _button(
                          label: 'Cancel',
                          color: Colors.white.withValues(alpha: 0.2),
                          onTap: onExit,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bigIcon(bool failed) {
    return Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: failed
            ? const Color(0xFFFF1F2D).withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.15),
        border: Border.all(
          color:
              (failed ? const Color(0xFFFF6E70) : Colors.white)
                  .withValues(alpha: 0.9),
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: (failed ? const Color(0xFFFF1F2D) : const Color(0xFF40C4FF))
                .withValues(alpha: 0.5),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Icon(
        failed ? Icons.cloud_off : Icons.public,
        size: 52,
        color: Colors.white,
      ),
    );
  }

  String _title(OnlineConnState s, bool failed) {
    if (failed) return 'Couldn\'t reach the server';
    if (s == OnlineConnState.connected) return 'Loading world…';
    return 'Connecting to server…';
  }

  String _subtitle(OnlineConnState s) {
    switch (s) {
      case OnlineConnState.idle:
        return 'Starting…';
      case OnlineConnState.connecting:
        return 'Opening WebSocket…';
      case OnlineConnState.reconnecting:
        return 'Lost connection — retrying…';
      case OnlineConnState.failed:
        return 'Check your internet connection and try again.';
      case OnlineConnState.closed:
        return 'Connection closed.';
      case OnlineConnState.connected:
        return 'Waiting for the first snapshot…';
    }
  }

  Widget _button({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.25),
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.baloo2(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

/// Mid-session reconnect banner. Only appears once we've been in-game and
/// the connection drops — the initial connect is handled by [_LoadingScreen].
class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({
    required this.state,
    required this.onRetry,
    required this.onExit,
  });

  final OnlineConnState state;
  final Future<void> Function() onRetry;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    if (state == OnlineConnState.connected ||
        state == OnlineConnState.idle ||
        state == OnlineConnState.connecting) {
      return const SizedBox.shrink();
    }
    final isFailed = state == OnlineConnState.failed;
    final color = isFailed
        ? const Color(0xFFFF1F2D)
        : const Color(0xFFFFB300);
    final label = switch (state) {
      OnlineConnState.reconnecting => 'Reconnecting…',
      OnlineConnState.failed => 'Lost connection',
      OnlineConnState.closed => 'Disconnected',
      _ => '',
    };

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.8), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state == OnlineConnState.reconnecting) ...[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              const SizedBox(width: 10),
            ] else ...[
              Icon(Icons.error_outline, color: color, size: 16),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: GoogleFonts.baloo2(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isFailed || state == OnlineConnState.closed) ...[
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onRetry,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Retry',
                    style: GoogleFonts.baloo2(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onExit,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Exit',
                    style: GoogleFonts.baloo2(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OnlineLeaderboard extends StatelessWidget {
  const _OnlineLeaderboard({required this.entries, this.selfId});

  final List<OnlineLeaderboardEntry> entries;
  final String? selfId;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern('en_US');
    return Container(
      width: 160,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Center(
              child: Text(
                'LEADERBOARD',
                style: GoogleFonts.baloo2(
                  color: const Color(0xFFFFD60A),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Center(
                child: Text(
                  '—',
                  style: GoogleFonts.baloo2(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          for (int i = 0; i < entries.length; i++)
            _row(
              rank: i + 1,
              entry: entries[i],
              isSelf: selfId != null && entries[i].id == selfId,
              fmt: fmt,
            ),
        ],
      ),
    );
  }

  Widget _row({
    required int rank,
    required OnlineLeaderboardEntry entry,
    required bool isSelf,
    required NumberFormat fmt,
  }) {
    final color = isSelf ? const Color(0xFFFFD60A) : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              '$rank.',
              style: GoogleFonts.baloo2(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              isSelf ? '${entry.name} (You)' : entry.name,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.baloo2(
                color: color,
                fontSize: 10,
                fontWeight: isSelf ? FontWeight.w900 : FontWeight.w700,
              ),
            ),
          ),
          Text(
            fmt.format(entry.mass),
            style: GoogleFonts.baloo2(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
