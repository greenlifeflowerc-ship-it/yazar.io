import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../game/game_engine.dart';

class LiveLeaderboard extends StatelessWidget {
  const LiveLeaderboard({super.key, required this.engine});

  final GameEngine engine;

  static const double width = 150;

  @override
  Widget build(BuildContext context) {
    final entries = engine.leaderboard;
    final fmt = NumberFormat.decimalPattern('en_US');

    return Container(
      width: width,
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
          for (int i = 0; i < entries.length; i++)
            _row(
              rank: i + 1,
              name: entries[i].name,
              mass: entries[i].mass,
              isHuman: entries[i].isHuman,
              fmt: fmt,
            ),
          if (engine.humanRank > 10) ...[
            const Divider(color: Colors.white24, height: 8),
            _row(
              rank: engine.humanRank,
              name: '${engine.humanPlayer.name} (You)',
              mass: engine.humanPlayer.totalMass,
              isHuman: true,
              fmt: fmt,
            ),
          ],
        ],
      ),
    );
  }

  Widget _row({
    required int rank,
    required String name,
    required double mass,
    required bool isHuman,
    required NumberFormat fmt,
  }) {
    final color = isHuman ? const Color(0xFFFFD60A) : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: Row(
        children: [
          SizedBox(
            width: 14,
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
              name,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.baloo2(
                color: color,
                fontSize: 10,
                fontWeight: isHuman ? FontWeight.w900 : FontWeight.w700,
              ),
            ),
          ),
          Text(
            fmt.format(mass.round()),
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
