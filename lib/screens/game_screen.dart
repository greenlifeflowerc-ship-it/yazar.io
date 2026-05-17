import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../game/game_engine.dart';
import '../game/game_settings.dart';
import '../game/painters/game_painter.dart';
import '../models/boost.dart';
import '../services/auth_service.dart';
import '../services/profile_service.dart';
import '../widgets/death_screen.dart';
import '../widgets/game_button.dart';
import '../widgets/live_leaderboard.dart';
import '../widgets/minimap.dart';
import '../widgets/pause_menu.dart';
import '../widgets/virtual_joystick.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, this.nickname = ''});
  final String nickname;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late final GameEngine _engine;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  // High-frequency notifier driving the world painter (60 Hz).
  final ValueNotifier<int> _frame = ValueNotifier(0);
  // Lower-frequency notifier for HUD chrome (~10 Hz). Avoids rebuilding text
  // and widgets that don't need 60 Hz updates.
  final ValueNotifier<int> _hudTick = ValueNotifier(0);
  // Even lower for the minimap CustomPainter (~3 Hz).
  final ValueNotifier<int> _miniTick = ValueNotifier(0);

  int _hudCounter = 0;
  int _miniCounter = 0;

  double _smoothedFps = 60;
  bool _leaderboardOpen = true;
  bool _minimapOpen = true;
  bool _lastGameOver = false;

  // Draggable button positions — initialised from GameSettings in initState.
  late final ValueNotifier<Offset> _ejectPos;
  late final ValueNotifier<Offset> _splitPos;
  bool _draggingEject = false;
  bool _draggingSplit = false;

  // PC Mode support
  final FocusNode _gameFocusNode = FocusNode();
  Offset _mousePos = Offset.zero;
  bool _firstMouseHover = false;

  // Hold-to-eject: fires once on touch-down, then every interval until release.
  Timer? _ejectHoldTimer;

  static const double _panelWidth = 150;
  static const double _minimapTop = 12;
  static const double _leaderboardTop = 132;

  static final _numberFmt = NumberFormat.decimalPattern('en_US');

  @override
  void initState() {
    super.initState();
    // Boost cache is normally fresh (AuthService refreshes on login + when
    // the main menu opens). Fire-and-forget another refresh to catch
    // expirations — if it produces a new multiplier the next death/respawn
    // will pick it up; we don't yank the player mid-life.
    AuthService.instance.refreshActiveBoosts();
    _ejectPos = ValueNotifier(GameSettings.instance.ejectBtnFrac);
    _splitPos = ValueNotifier(GameSettings.instance.splitBtnFrac);
    _engine = GameEngine()..init(nickname: widget.nickname);
    _ticker = createTicker(_onTick)..start();

    if (GameSettings.instance.pcMode) {
      _gameFocusNode.requestFocus();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    
    // FPS Capping logic
    final cap = GameSettings.instance.fpsCap;
    final minDt = 1.0 / cap;
    if (dt < minDt && _lastTick != Duration.zero) return;

    _lastTick = elapsed;
    final clamped = dt.clamp(0.0, 0.05);
    if (clamped > 0) {
      _smoothedFps = _smoothedFps * 0.92 + (1.0 / clamped) * 0.08;
    }

    if (GameSettings.instance.pcMode && _firstMouseHover && !(_engine.gameOver)) {
      final size = MediaQuery.of(context).size;
      final center = Offset(size.width / 2, size.height / 2);
      final diff = _mousePos - center;
      final dist = diff.distance;
      // max speed reached at 15% of screen height from center
      final maxRadius = size.shortestSide * 0.15;
      
      if (dist < 10) {
        _engine.moveDir = Offset.zero;
      } else {
        final mag = (dist / maxRadius).clamp(0.0, 1.0);
        _engine.moveDir = (diff / dist) * mag;
      }
    }

    _engine.update(clamped);
    _frame.value++;
    if (++_hudCounter >= 6) {
      _hudCounter = 0;
      _hudTick.value++;
    }
    if (++_miniCounter >= 18) {
      _miniCounter = 0;
      _miniTick.value++;
    }
    if (_engine.gameOver != _lastGameOver) {
      _lastGameOver = _engine.gameOver;
      if (mounted) setState(() {});
      // Death transition: post results to Supabase exactly once per match.
      if (_engine.gameOver) {
        _submitMatchResult();
      }
    }
  }

  bool _submittedThisMatch = false;
  Future<void> _submitMatchResult() async {
    if (_submittedThisMatch) return;
    if (!AuthService.instance.isLoggedIn) return;
    _submittedThisMatch = true;
    final human = _engine.humanPlayer;
    final score = human.highestMass.round();
    final massCollected = human.highestMass.round();
    final kills = human.eatenCount;
    final survival = _engine.timeSurvived.round();
    final rank = _engine.humanRank > 0 ? _engine.humanRank : 9999;
    final res = await ProfileService.instance.submitMatchResult(
      score: score,
      massCollected: massCollected,
      kills: kills,
      survivalSeconds: survival,
      rank: rank,
    );
    if (res != null) {
      // Apply fresh totals locally so the next render of the main menu / HUD
      // reflects the new level/coins/XP without another network round-trip.
      final existing = AuthService.instance.profile;
      if (existing != null) {
        AuthService.instance.applyProfile(existing.copyWith(
          level: res.level,
          xp: res.xp,
          coins: res.coins,
          dna: res.dna,
        ));
      } else {
        await AuthService.instance.refreshProfile();
      }
      // Queue the level-up popup so the main menu can show it once we're back.
      if (res.leveledUp) {
        AuthService.instance.queueLevelUp(res);
      }
    }
  }

  @override
  void dispose() {
    _ejectHoldTimer?.cancel();
    _ticker.dispose();
    _frame.dispose();
    _hudTick.dispose();
    _miniTick.dispose();
    _ejectPos.dispose();
    _splitPos.dispose();
    _gameFocusNode.dispose();
    super.dispose();
  }

  // Touch-down → start shooting every 100 ms.
  // Touch-up / cancel → stop immediately.
  void _startEjectHold() {
    if (_draggingEject) return;
    if (_ejectHoldTimer != null) return; // Already running

    _engine.attackMode = true;
    _engine.doEject(); // fire on first touch immediately
    
    // The timer now respects the user's "Feed speed" setting.
    // We allow it to go down to 1ms for true macro speed.
    final speedMult = GameSettings.instance.feedSpeedMultiplier;
    final ms = (100 / speedMult).round().clamp(1, 500);

    _ejectHoldTimer = Timer.periodic(
      Duration(milliseconds: ms),
      (_) => _engine.doEject(),
    );
  }

  void _endEjectHold() {
    _ejectHoldTimer?.cancel();
    _ejectHoldTimer = null;
    _engine.attackMode = false;
  }

  void _onSplitTap() {
    if (_draggingSplit) return;
    _engine.attackMode = true;
    _engine.doSplit();
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _engine.attackMode = false;
    });
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

  void _playAgain() {
    _engine.respawnHuman();
    _lastGameOver = false;
    _submittedThisMatch = false;
    setState(() {});
  }

  void _exitToMenu() => Navigator.of(context).pop();

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
            focusNode: _gameFocusNode,
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
                  // World canvas (60 Hz)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: GamePainter(engine: _engine, repaint: _frame),
                        size: size,
                      ),
                    ),
                  ),

                  // Joystick — side controlled by settings
                  if (!pcMode)
                    Positioned(
                      left: joystickRight ? null : 0,
                      right: joystickRight ? 0 : null,
                      top: 0,
                      bottom: 0,
                      width: size.width * 0.5,
                      child: VirtualJoystick(
                        onChanged: (dir) => _engine.moveDir = dir,
                        onReleased: () => _engine.moveDir = Offset.zero,
                      ),
                    ),

                  // Top-left: pause + mass + merge timer
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
                          builder: (context, value, child) {
                            final player = _engine.humanPlayer;
                            final remaining = player.remainingMergeTime;
                            final showTimer = remaining > Duration.zero;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Mass: ${_numberFmt.format(player.totalMass.round())}',
                                  style: GoogleFonts.baloo2(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    shadows: const [
                                      Shadow(color: Colors.black, blurRadius: 4),
                                    ],
                                  ),
                                ),
                                if (showTimer)
                                  Container(
                                    margin: const EdgeInsets.only(top: 2),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.3),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'Merge in: ${remaining.inSeconds + 1}s',
                                      style: GoogleFonts.baloo2(
                                        color: Colors.orangeAccent,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  // Top-center FPS (settings-gated)
                  if (GameSettings.instance.showFps)
                    Positioned(
                      top: 14,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: ValueListenableBuilder<int>(
                            valueListenable: _hudTick,
                            builder: (context, value, child) => Text(
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

                  // === Top-right minimap with slide (settings-gated) ===
                  if (GameSettings.instance.showMinimap) ...[
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      top: _minimapTop,
                      right: _minimapOpen ? 0 : -_panelWidth,
                      width: _panelWidth,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragEnd: (d) {
                          final vx = d.velocity.pixelsPerSecond.dx;
                          if (vx > 200 && _minimapOpen) {
                            setState(() => _minimapOpen = false);
                          }
                        },
                        child: Center(
                          child: RepaintBoundary(
                            child: ValueListenableBuilder<int>(
                              valueListenable: _miniTick,
                              builder: (context, value, child) =>
                                  Minimap(engine: _engine, size: 110),
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      top: _minimapTop + 36,
                      right: _minimapOpen ? _panelWidth : 0,
                      child: _ChevronTab(
                        open: _minimapOpen,
                        onTap: () => setState(() => _minimapOpen = !_minimapOpen),
                      ),
                    ),
                  ],

                  // === Below minimap: leaderboard with slide ===
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    top: GameSettings.instance.showMinimap ? _leaderboardTop : 12,
                    right: _leaderboardOpen ? 0 : -_panelWidth,
                    width: _panelWidth,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragEnd: (d) {
                        final vx = d.velocity.pixelsPerSecond.dx;
                        if (vx > 200 && _leaderboardOpen) {
                          setState(() => _leaderboardOpen = false);
                        }
                      },
                      child: RepaintBoundary(
                        child: ValueListenableBuilder<int>(
                          valueListenable: _hudTick,
                          builder: (context, value, child) =>
                              LiveLeaderboard(engine: _engine),
                        ),
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    top: (GameSettings.instance.showMinimap ? _leaderboardTop : 12) + 30,
                    right: _leaderboardOpen ? _panelWidth : 0,
                    child: _ChevronTab(
                      open: _leaderboardOpen,
                      onTap: () =>
                          setState(() => _leaderboardOpen = !_leaderboardOpen),
                    ),
                  ),

                  // PC Mode Hint
                  if (pcMode && !_engine.gameOver)
                    Positioned(
                      bottom: 20,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

                  // ── Eject button — freely draggable ─────────────────────────
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
                              final newPos = Offset(
                                (d.globalPosition.dx / size.width).clamp(0.04, 0.96),
                                (d.globalPosition.dy / size.height).clamp(0.04, 0.96),
                              );
                              _ejectPos.value = newPos;
                              GameSettings.instance.ejectBtnFrac = newPos;
                            },
                            onLongPressEnd: (_) =>
                                setState(() => _draggingEject = false),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Drag-mode glow ring
                                if (_draggingEject)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.yellowAccent, width: 3),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.yellowAccent
                                                  .withValues(alpha: 0.45),
                                              blurRadius: 18,
                                              spreadRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ValueListenableBuilder<int>(
                                  valueListenable: _hudTick,
                                  builder: (ctx, tick, child) => GameButton(
                                    onPressStart: _startEjectHold,
                                    onPressEnd: _endEjectHold,
                                    color: const Color(0xFFFF7A2F),
                                    size: 60 * btnScale,
                                    enabled: _engine.canEject && !_draggingEject,
                                    hint: _draggingEject ? 'hold & drag' : null,
                                    builder: (_) => const EjectIcon(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                  // ── Split button — freely draggable ─────────────────────────
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
                                // Drag-mode glow ring
                                if (_draggingSplit)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.yellowAccent, width: 3),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.yellowAccent
                                                  .withValues(alpha: 0.45),
                                              blurRadius: 18,
                                              spreadRadius: 4,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ValueListenableBuilder<int>(
                                  valueListenable: _hudTick,
                                  builder: (ctx, tick, child) => GameButton(
                                    onTap: _onSplitTap,
                                    color: const Color(0xFF3DA5F5),
                                    size: 70 * btnScale,
                                    enabled: _engine.canSplit && !_draggingSplit,
                                    hint: _draggingSplit ? 'hold & drag' : null,
                                    builder: (_) => const SplitIcon(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                  // Death overlay
                  if (_engine.gameOver)
                    Positioned.fill(
                      child: DeathScreen(
                        highestMass: _engine.humanPlayer.highestMass,
                        timeSurvived: _engine.timeSurvived,
                        eatenCount: _engine.humanPlayer.eatenCount,
                        rank: _engine.humanRank,
                        onPlayAgain: _playAgain,
                        onMainMenu: _exitToMenu,
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

/// Small floating chip placed alongside the mass HUD. Shows the active
/// boost's multiplier + remaining time. Ticks every second so the countdown
/// stays live without rebuilding the whole game tree.
class _GameBoostBadge extends StatefulWidget {
  const _GameBoostBadge({required this.boost});
  final PlayerBoost boost;

  @override
  State<_GameBoostBadge> createState() => _GameBoostBadgeState();
}

class _GameBoostBadgeState extends State<_GameBoostBadge> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.boost;
    final color = b.isMass
        ? const Color(0xFFFF6A00)
        : const Color(0xFF00C8E0);
    final icon = b.isMass ? Icons.fitness_center : Icons.bolt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 1),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 4),
          Text(
            '${b.multiplier % 1 == 0 ? b.multiplier.toStringAsFixed(0) : b.multiplier.toStringAsFixed(1)}×',
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _fmt(b.remaining),
            style: GoogleFonts.baloo2(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final secs = d.inSeconds.clamp(0, 1 << 30);
    if (secs >= 3600) {
      final h = d.inHours;
      final m = d.inMinutes.remainder(60);
      return '${h}h${m.toString().padLeft(2, '0')}';
    }
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _ChevronTab extends StatefulWidget {
  const _ChevronTab({required this.open, required this.onTap});
  final bool open;
  final VoidCallback onTap;

  @override
  State<_ChevronTab> createState() => _ChevronTabState();
}

class _ChevronTabState extends State<_ChevronTab> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 90),
        child: Container(
          width: 30,
          height: 64,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.black.withValues(alpha: 0.72),
                Colors.black.withValues(alpha: 0.55),
              ],
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              bottomLeft: Radius.circular(14),
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.22),
                width: 1,
              ),
              left: BorderSide(
                color: Colors.white.withValues(alpha: 0.22),
                width: 1,
              ),
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(-3, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              // grip dots on the inner edge
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    3,
                    (i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: AnimatedRotation(
                  turns: widget.open ? 0.0 : 0.5,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: const Icon(
                    Icons.chevron_right,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
