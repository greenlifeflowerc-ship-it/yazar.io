/// Online Classic V2 screen — the user-facing entry point for the new mode.
///
/// Owns:
///   • a [V2Controller] (network, local sim, world cache, prediction)
///   • a single [Ticker] that drives 60 Hz simulation + render
///   • the same control surface as Offline Classic — joystick, split button,
///     eject button (hold-to-feed), PC-mode keyboard, draggable buttons,
///     pause menu, death/respawn overlay
///
/// More→Online routes here. The old `OnlineClassicScreen` stays on disk but
/// is no longer wired into the main menu.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../game/game_engine.dart';
import '../game/game_settings.dart';
import '../widgets/death_screen.dart';
import '../widgets/game_button.dart';
import '../widgets/pause_menu.dart';
import '../widgets/virtual_joystick.dart';
import 'net/v2_packets.dart';
import 'v2_controller.dart';
import 'v2_painter.dart';

class OnlineClassicV2Screen extends StatefulWidget {
  const OnlineClassicV2Screen({super.key, this.nickname = ''});
  final String nickname;

  @override
  State<OnlineClassicV2Screen> createState() => _OnlineClassicV2ScreenState();
}

class _OnlineClassicV2ScreenState extends State<OnlineClassicV2Screen>
    with SingleTickerProviderStateMixin {
  late final V2Controller _ctrl;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  final ValueNotifier<int> _frame = ValueNotifier(0);
  final ValueNotifier<int> _hudTick = ValueNotifier(0);
  int _hudCounter = 0;

  double _smoothedFps = 60;

  // Camera — lerped center-of-mass + offline zoom curve.
  Offset _camPos =
      const Offset(GameConstants.worldSize / 2, GameConstants.worldSize / 2);
  double _camZoom = 1.0;

  // Draggable button positions reuse the offline GameSettings keys so users
  // get one consistent layout across modes.
  late final ValueNotifier<Offset> _ejectPos;
  late final ValueNotifier<Offset> _splitPos;
  bool _draggingEject = false;
  bool _draggingSplit = false;

  // PC Mode support.
  final FocusNode _focus = FocusNode();
  Offset _mousePos = Offset.zero;
  bool _firstMouseHover = false;

  // Hold-to-eject.
  Timer? _ejectHoldTimer;

  static final _numberFmt = NumberFormat.decimalPattern('en_US');

  @override
  void initState() {
    super.initState();
    _ejectPos = ValueNotifier(GameSettings.instance.ejectBtnFrac);
    _splitPos = ValueNotifier(GameSettings.instance.splitBtnFrac);
    _ctrl = V2Controller();
    _ctrl.connect(playerName: widget.nickname.trim());
    _ticker = createTicker(_onTick)..start();
    if (GameSettings.instance.pcMode) _focus.requestFocus();
  }

  void _onTick(Duration elapsed) {
    final dtRaw = (elapsed - _lastTick).inMicroseconds / 1e6;
    final cap = GameSettings.instance.fpsCap;
    if (cap > 0) {
      final minDt = 1.0 / cap;
      if (dtRaw < minDt && _lastTick != Duration.zero) return;
    }
    _lastTick = elapsed;
    final dt = dtRaw.clamp(0.0, 0.05);
    if (dt > 0) {
      _smoothedFps = _smoothedFps * 0.92 + (1.0 / dt) * 0.08;
    }

    // PC-mode pointer steering — same model as Offline Classic.
    if (GameSettings.instance.pcMode && _firstMouseHover && !_ctrl.isDead) {
      final size = MediaQuery.of(context).size;
      final center = Offset(size.width / 2, size.height / 2);
      final diff = _mousePos - center;
      final dist = diff.distance;
      final maxRadius = size.shortestSide * 0.15;
      if (dist < 10) {
        _ctrl.setMoveDir(Offset.zero);
      } else {
        final mag = (dist / maxRadius).clamp(0.0, 1.0);
        _ctrl.setMoveDir((diff / dist) * mag);
      }
    }

    _ctrl.tick(dt);

    // Camera follow + zoom (mirrors GameEngine._targetZoom).
    if (_ctrl.sim.isInitialized && _ctrl.sim.cells.isNotEmpty) {
      final target = _ctrl.sim.centerOfMass;
      _camPos = Offset.lerp(_camPos, target, 0.1)!;
      final mass = _ctrl.sim.totalMass.clamp(10, 1e9).toDouble();
      final z = math.pow(64 / mass, 0.25).toDouble();
      final mult = 1.0 / GameSettings.instance.zoomMultiplier;
      final targetZoom = (z * mult).clamp(0.01, 4.0);
      _camZoom = _camZoom + (targetZoom - _camZoom) * 0.1;
    }

    _frame.value++;
    if (++_hudCounter >= 6) {
      _hudCounter = 0;
      _hudTick.value++;
    }
  }

  // ───────────────────────────────────────────────────── action handlers
  void _startEjectHold() {
    if (_draggingEject) return;
    if (_ejectHoldTimer != null) return;
    _ctrl.setAttackMode(true);
    _ctrl.doEject();
    final speed = GameSettings.instance.feedSpeedMultiplier;
    final ms = (100 / speed).round().clamp(1, 500);
    _ejectHoldTimer = Timer.periodic(
      Duration(milliseconds: ms),
      (_) => _ctrl.doEject(),
    );
  }

  void _endEjectHold() {
    _ejectHoldTimer?.cancel();
    _ejectHoldTimer = null;
    _ctrl.setAttackMode(false);
  }

  void _onSplitTap() {
    if (_draggingSplit) return;
    _ctrl.setAttackMode(true);
    _ctrl.doSplit();
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _ctrl.setAttackMode(false);
    });
  }

  void _showPauseMenu() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      barrierDismissible: true,
      builder: (dCtx) => PauseMenu(
        onResume: () => Navigator.of(dCtx).pop(),
        onExit: () {
          Navigator.of(dCtx).pop();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _playAgain() {
    _ctrl.respawn();
  }

  void _exit() => Navigator.of(context).pop();

  // ───────────────────────────────────────────────────── lifecycle
  @override
  void dispose() {
    _ejectHoldTimer?.cancel();
    _ticker.dispose();
    _frame.dispose();
    _hudTick.dispose();
    _ejectPos.dispose();
    _splitPos.dispose();
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // ───────────────────────────────────────────────────── build
  Widget _buildWorldCanvas(Size size) {
    final scale = GameSettings.instance.renderScale;
    if (scale == 1.0) {
      return RepaintBoundary(
        child: CustomPaint(
          painter: V2Painter(
            controller: _ctrl,
            cameraPos: _camPos,
            cameraZoom: _camZoom,
            repaint: _frame,
          ),
          size: size,
        ),
      );
    }
    final canvasSize = Size(size.width * scale, size.height * scale);
    return FittedBox(
      fit: BoxFit.fill,
      child: SizedBox(
        width: canvasSize.width,
        height: canvasSize.height,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: V2Painter(
              controller: _ctrl,
              cameraPos: _camPos,
              cameraZoom: _camZoom,
              repaint: _frame,
            ),
            size: canvasSize,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final gs = GameSettings.instance;

    return AnimatedBuilder(
      animation: gs,
      builder: (context, _) {
        final btnScale = gs.buttonScale;
        final joystickRight = gs.joystickOnRight;
        final pcMode = gs.pcMode;

        return Scaffold(
          backgroundColor: const Color(0xFFF5F5F5),
          body: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: (node, event) {
              if (!pcMode) return KeyEventResult.ignored;
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
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
              onHover: (event) {
                if (pcMode) {
                  _mousePos = event.localPosition;
                  _firstMouseHover = true;
                }
              },
              child: Stack(
                children: [
                  Positioned.fill(child: _buildWorldCanvas(size)),

                  // Joystick.
                  if (!pcMode)
                    Positioned(
                      left: joystickRight ? null : 0,
                      right: joystickRight ? 0 : null,
                      top: 0,
                      bottom: 0,
                      width: size.width * 0.5,
                      child: VirtualJoystick(
                        onChanged: (dir) => _ctrl.setMoveDir(dir),
                        onReleased: () => _ctrl.setMoveDir(Offset.zero),
                      ),
                    ),

                  // Top-left: pause + mass + connection chip.
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _pauseButton(),
                        const SizedBox(width: 10),
                        ValueListenableBuilder<int>(
                          valueListenable: _hudTick,
                          builder: (context, _, _) {
                            final m = _ctrl.sim.isInitialized
                                ? _ctrl.sim.totalMass.round()
                                : 0;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Mass: ${_numberFmt.format(m)}',
                                  style: GoogleFonts.baloo2(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    shadows: const [
                                      Shadow(color: Colors.black, blurRadius: 4),
                                    ],
                                  ),
                                ),
                                _ConnectionChip(
                                  state: _ctrl.connState,
                                  ping: _ctrl.pingMs,
                                  online: _ctrl.online,
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  // FPS top-center (gated by setting).
                  if (gs.showFps)
                    Positioned(
                      top: 14,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: ValueListenableBuilder<int>(
                            valueListenable: _hudTick,
                            builder: (context, _, _) => Text(
                              'FPS ${_smoothedFps.toStringAsFixed(0)}',
                              style: GoogleFonts.baloo2(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                shadows: const [
                                  Shadow(color: Colors.black87, blurRadius: 2),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Right side: leaderboard (simple list — no slide-out for v1).
                  Positioned(
                    right: 12,
                    top: 12,
                    width: 160,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _hudTick,
                      builder: (context, _, _) => _LeaderboardCard(
                        entries: _ctrl.leaderboard,
                        selfId: _ctrl.playerId,
                      ),
                    ),
                  ),

                  // Eject button — draggable + hold-to-feed.
                  if (!pcMode)
                    ValueListenableBuilder<Offset>(
                      valueListenable: _ejectPos,
                      builder: (context, pos, _) {
                        final half = 30.0 * btnScale;
                        return Positioned(
                          left: pos.dx * size.width - half,
                          top: pos.dy * size.height - half,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPressStart: (_) =>
                                setState(() => _draggingEject = true),
                            onLongPressMoveUpdate: (d) {
                              final n = Offset(
                                (d.globalPosition.dx / size.width)
                                    .clamp(0.04, 0.96),
                                (d.globalPosition.dy / size.height)
                                    .clamp(0.04, 0.96),
                              );
                              _ejectPos.value = n;
                              GameSettings.instance.ejectBtnFrac = n;
                            },
                            onLongPressEnd: (_) =>
                                setState(() => _draggingEject = false),
                            child: GameButton(
                              onPressStart: _startEjectHold,
                              onPressEnd: _endEjectHold,
                              color: const Color(0xFFFF7A2F),
                              size: 60 * btnScale,
                              enabled: !_ctrl.isDead && !_draggingEject,
                              hint: _draggingEject ? 'hold & drag' : null,
                              builder: (_) => const EjectIcon(),
                            ),
                          ),
                        );
                      },
                    ),

                  // Split button — draggable.
                  if (!pcMode)
                    ValueListenableBuilder<Offset>(
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
                              final n = Offset(
                                (d.globalPosition.dx / size.width)
                                    .clamp(0.04, 0.96),
                                (d.globalPosition.dy / size.height)
                                    .clamp(0.04, 0.96),
                              );
                              _splitPos.value = n;
                              GameSettings.instance.splitBtnFrac = n;
                            },
                            onLongPressEnd: (_) =>
                                setState(() => _draggingSplit = false),
                            child: GameButton(
                              onTap: _onSplitTap,
                              color: const Color(0xFF3DA5F5),
                              size: 70 * btnScale,
                              enabled: !_ctrl.isDead && !_draggingSplit,
                              hint: _draggingSplit ? 'hold & drag' : null,
                              builder: (_) => const SplitIcon(),
                            ),
                          ),
                        );
                      },
                    ),

                  // PC mode hint.
                  if (pcMode && !_ctrl.isDead)
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
                              'PC Mode: Move with mouse • Split: Space • Feed: W',
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

                  // Death overlay.
                  if (_ctrl.isDead)
                    Positioned.fill(
                      child: DeathScreen(
                        highestMass: _ctrl.sim.isInitialized
                            ? _ctrl.sim.player.highestMass
                            : 0,
                        timeSurvived: 0,
                        eatenCount: 0,
                        rank: -1,
                        onPlayAgain: _playAgain,
                        onMainMenu: _exit,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
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
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({
    required this.state,
    required this.ping,
    required this.online,
  });
  final V2ConnState state;
  final int ping;
  final int online;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      V2ConnState.idle => ('idle', Colors.white70),
      V2ConnState.connecting => ('connecting…', Colors.orangeAccent),
      V2ConnState.reconnecting => ('reconnecting…', Colors.orangeAccent),
      V2ConnState.connected => ('${ping}ms · $online online', Colors.greenAccent),
      V2ConnState.failed => ('disconnected', Colors.redAccent),
      V2ConnState.closed => ('closed', Colors.white54),
    };
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.baloo2(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _LeaderboardCard extends StatelessWidget {
  const _LeaderboardCard({required this.entries, required this.selfId});
  final List<V2LeaderboardEntry> entries;
  final String? selfId;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Leaderboard',
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          for (int i = 0; i < entries.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: Text(
                      '${i + 1}.',
                      style: GoogleFonts.baloo2(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entries[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.baloo2(
                        color: entries[i].id == selfId
                            ? Colors.yellowAccent
                            : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    entries[i].mass.toString(),
                    style: GoogleFonts.baloo2(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
