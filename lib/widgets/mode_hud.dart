import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../game/chaos_events.dart';
import '../game/game_engine.dart';
import '../game/game_mode_type.dart';

/// Per-mode status panel rendered at the top-center of the HUD.
///
/// Returns an empty SizedBox for Classic/Teams so nothing extra is drawn.
/// Every other mode supplies one short status line (timer, role, event…).
class ModeHud extends StatelessWidget {
  const ModeHud({super.key, required this.engine});

  final GameEngine engine;

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[];

    // Match timer (any mode that has one).
    if (engine.matchTimeRemaining > 0) {
      lines.add(_chip(
        icon: Icons.timer,
        text: _fmtTime(engine.matchTimeRemaining),
        color: const Color(0xFFFFD600),
      ));
    }

    switch (engine.mode) {
      case GameMode.battleRoyale:
        lines.add(_chip(
          icon: Icons.groups,
          text: 'Alive: ${engine.aliveBotCount + (engine.humanPlayer.isDead ? 0 : 1)}',
          color: const Color(0xFFFFC107),
        ));
        if (!engine.humanPlayer.isDead) {
          final dist = (engine.humanPlayer.centerOfMass -
                  engine.safeZoneCenter)
              .distance;
          if (dist > engine.safeZoneRadius) {
            lines.add(_chip(
              icon: Icons.warning_amber_rounded,
              text: 'OUTSIDE ZONE',
              color: const Color(0xFFFF1744),
            ));
          }
        }
        break;

      case GameMode.zombieInfection:
        lines.add(_chip(
          icon: Icons.coronavirus,
          text: 'Z:${engine.aliveZombieCount}  S:${engine.aliveSurvivorCount}',
          color: const Color(0xFF76FF03),
        ));
        lines.add(_rolePill(engine.humanPlayer.role));
        break;

      case GameMode.hideSeek:
        lines.add(_chip(
          icon: Icons.visibility_off,
          text: 'Hiders: ${engine.aliveHiderCount}',
          color: const Color(0xFF18FFFF),
        ));
        lines.add(_rolePill(engine.humanPlayer.role));
        break;

      case GameMode.coinRush:
        lines.add(_chip(
          icon: Icons.monetization_on,
          text: 'Coins: ${engine.humanPlayer.coinScore}',
          color: const Color(0xFFFFD600),
        ));
        break;

      case GameMode.rankedArena:
        lines.add(_chip(
          icon: Icons.emoji_events,
          text: '${engine.humanPlayer.rankedPoints} pts',
          color: const Color(0xFFE040FB),
        ));
        break;

      case GameMode.chaosMode:
        final c = engine.chaos;
        if (c != null) {
          if (c.active != null && c.isActiveAt(engine.elapsed)) {
            lines.add(_chip(
              icon: Icons.local_fire_department,
              text: c.active!.displayName,
              color: const Color(0xFFFF3D00),
            ));
          } else {
            final remaining =
                (c.nextEventAt - engine.elapsed).clamp(0, 9999).round();
            lines.add(_chip(
              icon: Icons.schedule,
              text: 'Next chaos: ${remaining}s',
              color: const Color(0xFFFF9800),
            ));
          }
        }
        break;

      case GameMode.classic:
      case GameMode.teams:
      case GameMode.turbo:
      case GameMode.hardcore:
      case GameMode.blackHole:
        break;
    }

    if (engine.matchEnded) {
      lines.add(_chip(
        icon: Icons.flag,
        text: engine.matchEndMessage,
        color: const Color(0xFFFFD600),
      ));
    }

    if (lines.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: lines,
          ),
        ),
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: color.withValues(alpha: 0.7),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.3),
            blurRadius: 10,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rolePill(PlayerRole role) {
    final color = RoleConfig.glowColor(role);
    final label = RoleConfig.displayName(role);
    if (label.isEmpty) return const SizedBox.shrink();
    return _chip(
      icon: role == PlayerRole.zombie || role == PlayerRole.seeker
          ? Icons.local_fire_department
          : Icons.shield,
      text: label,
      color: color == Colors.transparent ? Colors.white70 : color,
    );
  }

  static String _fmtTime(double secs) {
    final s = secs.clamp(0, 9999).round();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }
}
