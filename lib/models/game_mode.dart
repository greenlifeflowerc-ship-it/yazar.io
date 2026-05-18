import 'package:flutter/material.dart';

class GameMode {
  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
  final List<Color> gradientColors;
  final Color glowColor;
  final Color iconBgColor;

  const GameMode({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.gradientColors,
    required this.glowColor,
    required this.iconBgColor,
  });
}

final List<GameMode> gameModes = [
  GameMode(
    id: 'online_classic',
    name: 'Online',
    subtitle: 'Play online',
    icon: Icons.public,
    gradientColors: const [
      Color(0xFF00E5FF),
      Color(0xFF0277BD),
      Color(0xFF01579B),
    ],
    glowColor: const Color(0xFF40C4FF),
    iconBgColor: Color(0xFF01579B),
  ),
  GameMode(
    id: 'teams',
    name: 'Teams',
    subtitle: 'Squad up',
    icon: Icons.groups,
    gradientColors: const [
      Color(0xFF4FC3F7),
      Color(0xFF1976D2),
      Color(0xFF0D47A1),
    ],
    glowColor: const Color(0xFF29B6F6),
    iconBgColor: Color(0xFF0D47A1),
  ),
  GameMode(
    id: 'turbo',
    name: 'Turbo',
    subtitle: 'Max speed',
    icon: Icons.bolt,
    gradientColors: const [
      Color(0xFFFFEB3B),
      Color(0xFFFF9800),
      Color(0xFFE65100),
    ],
    glowColor: const Color(0xFFFFC107),
    iconBgColor: Color(0xFFE65100),
  ),
  GameMode(
    id: 'battle_royale',
    name: 'Battle Royale',
    subtitle: 'Last one wins',
    icon: Icons.emoji_events,
    gradientColors: const [
      Color(0xFFFFD54F),
      Color(0xFF9C27B0),
      Color(0xFF4A148C),
    ],
    glowColor: const Color(0xFFFFD700),
    iconBgColor: Color(0xFF4A148C),
  ),
  GameMode(
    id: 'zombie_infection',
    name: 'Zombie',
    subtitle: 'Infection',
    icon: Icons.coronavirus,
    gradientColors: const [
      Color(0xFF76FF03),
      Color(0xFF2E7D32),
      Color(0xFF1B5E20),
    ],
    glowColor: const Color(0xFF64DD17),
    iconBgColor: Color(0xFF1B5E20),
  ),
  GameMode(
    id: 'hardcore',
    name: 'Hardcore',
    subtitle: 'No mercy',
    icon: Icons.whatshot,
    gradientColors: const [
      Color(0xFFFF1744),
      Color(0xFFB71C1C),
      Color(0xFF1A0000),
    ],
    glowColor: const Color(0xFFFF1744),
    iconBgColor: Color(0xFF1A0000),
  ),
  GameMode(
    id: 'ranked_arena',
    name: 'Ranked',
    subtitle: 'Arena',
    icon: Icons.shield,
    gradientColors: const [
      Color(0xFFE040FB),
      Color(0xFF7B1FA2),
      Color(0xFF311B92),
    ],
    glowColor: const Color(0xFFE040FB),
    iconBgColor: Color(0xFF311B92),
  ),
  GameMode(
    id: 'coin_rush',
    name: 'Coin Rush',
    subtitle: 'Get rich',
    icon: Icons.monetization_on,
    gradientColors: const [
      Color(0xFFFFF176),
      Color(0xFFFFC107),
      Color(0xFFFF8F00),
    ],
    glowColor: const Color(0xFFFFD600),
    iconBgColor: Color(0xFFFF8F00),
  ),
  GameMode(
    id: 'black_hole',
    name: 'Black Hole',
    subtitle: 'Cosmic',
    icon: Icons.blur_circular,
    gradientColors: const [
      Color(0xFF311B92),
      Color(0xFF1A237E),
      Color(0xFF000000),
    ],
    glowColor: const Color(0xFF40C4FF),
    iconBgColor: Color(0xFF000000),
  ),
  GameMode(
    id: 'hide_seek',
    name: 'Hide & Seek',
    subtitle: 'Stay hidden',
    icon: Icons.visibility_off,
    gradientColors: const [
      Color(0xFF18FFFF),
      Color(0xFF006064),
      Color(0xFF263238),
    ],
    glowColor: const Color(0xFF18FFFF),
    iconBgColor: Color(0xFF263238),
  ),
  GameMode(
    id: 'chaos_mode',
    name: 'Chaos',
    subtitle: 'Pure madness',
    icon: Icons.local_fire_department,
    gradientColors: const [
      Color(0xFFFFEA00),
      Color(0xFFFF3D00),
      Color(0xFFBF360C),
    ],
    glowColor: const Color(0xFFFF3D00),
    iconBgColor: Color(0xFFBF360C),
  ),
];
