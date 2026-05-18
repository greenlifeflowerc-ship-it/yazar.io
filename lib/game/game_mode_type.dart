import 'package:flutter/material.dart';

/// All gameplay modes the engine can run.
/// Classic is the baseline (no rule changes). Other modes layer extra rules on
/// top of Classic without forking the engine.
enum GameMode {
  classic,
  teams,
  turbo,
  battleRoyale,
  zombieInfection,
  hardcore,
  rankedArena,
  coinRush,
  blackHole,
  hideSeek,
  chaosMode,
}

/// Teams used in [GameMode.teams]. `none` means the player isn't on a team
/// (used in every non-teams mode).
enum Team {
  none,
  blue,
  red,
  green,
}

/// Per-player role used by mode-specific gameplay (zombie infection, hide &
/// seek). `none` is the default and means "no special role" for every mode
/// that doesn't use roles.
enum PlayerRole {
  none,
  survivor,
  zombie,
  hider,
  seeker,
}

/// Static configuration for each team: display name + visual identity.
class TeamConfig {
  TeamConfig._();

  static const List<Team> playable = [Team.blue, Team.red, Team.green];

  static String displayName(Team t) {
    switch (t) {
      case Team.blue:
        return 'Blue Team';
      case Team.red:
        return 'Red Team';
      case Team.green:
        return 'Green Team';
      case Team.none:
        return '';
    }
  }

  /// Saturated cell color used when a player is on this team.
  static Color color(Team t) {
    switch (t) {
      case Team.blue:
        return const Color(0xFF1E9BFF);
      case Team.red:
        return const Color(0xFFFF1F2D);
      case Team.green:
        return const Color(0xFF34C924);
      case Team.none:
        return Colors.grey;
    }
  }

  /// Soft glow tint used around cells for the team aura.
  static Color glowColor(Team t) {
    switch (t) {
      case Team.blue:
        return const Color(0xFF4FC3F7);
      case Team.red:
        return const Color(0xFFFF6E70);
      case Team.green:
        return const Color(0xFF76FF6A);
      case Team.none:
        return Colors.transparent;
    }
  }
}

/// Visual config for [PlayerRole] — color + glow used when the active mode
/// uses roles (zombie/hide-seek). Survivors keep their original skin so we
/// return null/transparent for them.
class RoleConfig {
  RoleConfig._();

  static Color? color(PlayerRole r) {
    switch (r) {
      case PlayerRole.zombie:
        return const Color(0xFF2E7D32);
      case PlayerRole.seeker:
        return const Color(0xFFFF3D00);
      case PlayerRole.hider:
        return const Color(0xFF18FFFF);
      case PlayerRole.survivor:
      case PlayerRole.none:
        return null;
    }
  }

  static Color glowColor(PlayerRole r) {
    switch (r) {
      case PlayerRole.zombie:
        return const Color(0xFF76FF03);
      case PlayerRole.seeker:
        return const Color(0xFFFF6E40);
      case PlayerRole.hider:
        return const Color(0xFF80DEEA);
      default:
        return Colors.transparent;
    }
  }

  static String displayName(PlayerRole r) {
    switch (r) {
      case PlayerRole.survivor:
        return 'Survivor';
      case PlayerRole.zombie:
        return 'Zombie';
      case PlayerRole.hider:
        return 'Hider';
      case PlayerRole.seeker:
        return 'Seeker';
      case PlayerRole.none:
        return '';
    }
  }
}

/// Per-mode tunable parameters. Every mode resolves to one of these in
/// [forMode]. The engine reads this once during init and applies the values.
///
/// Defaults match Classic so any field left out keeps Classic behavior.
class ModeConfig {
  const ModeConfig({
    this.speedMultiplier = 1.0,
    this.pelletMultiplier = 1.0,
    this.virusMultiplier = 1.0,
    this.splitCooldownMultiplier = 1.0,
    this.botAggression = 1.0,
    this.canBotsRespawn = true,
    this.canHumanRespawn = true,
    this.showHelperUi = true,
    this.shrinkingZone = false,
    this.matchTimerSeconds,
    this.zombieMode = false,
    this.initialZombieCount = 0,
    this.coinMode = false,
    this.coinCount = 0,
    this.blackHoleMode = false,
    this.blackHoleCount = 0,
    this.hideSeekMode = false,
    this.seekerCount = 0,
    this.chaosMode = false,
    this.rankedScoring = false,
  });

  /// Cell input + max speed multiplier. Scales the inputMoveStrength and the
  /// per-radius speed clamp — affects players AND bots equally.
  final double speedMultiplier;

  /// Pellet target count multiplier. Hardcore <1, Turbo >1.
  final double pelletMultiplier;

  /// Virus target count multiplier.
  final double virusMultiplier;

  /// Time-cost multiplier for split cooldown. <1 = faster recombine (Turbo).
  final double splitCooldownMultiplier;

  /// Bot aggression scaler. >1 makes bots split more and pursue harder.
  final double botAggression;

  /// Whether bots respawn on death (false for battle royale).
  final bool canBotsRespawn;

  /// Whether the human can respawn within the same match (false for battle
  /// royale).
  final bool canHumanRespawn;

  /// Whether helper UI (minimap, hints) is allowed in the HUD.
  final bool showHelperUi;

  /// Battle royale: enables shrinking safe zone with edge damage.
  final bool shrinkingZone;

  /// Optional total match duration in seconds — drives modes that end on a
  /// timer (battle royale, hide & seek, coin rush, zombie).
  final int? matchTimerSeconds;

  /// Zombie infection mode flag + how many infected to seed at start.
  final bool zombieMode;
  final int initialZombieCount;

  /// Coin Rush: enables coins entity + counter.
  final bool coinMode;
  final int coinCount;

  /// Black Hole: spawn N gravity wells.
  final bool blackHoleMode;
  final int blackHoleCount;

  /// Hide & Seek: split players into seekers vs hiders.
  final bool hideSeekMode;
  final int seekerCount;

  /// Chaos: schedule random world events.
  final bool chaosMode;

  /// Ranked Arena: track score points alongside mass.
  final bool rankedScoring;

  /// Resolve mode → config. Classic and Teams keep defaults so they don't
  /// pick up any of the new branches.
  static ModeConfig forMode(GameMode mode) {
    switch (mode) {
      case GameMode.classic:
      case GameMode.teams:
        return const ModeConfig();

      case GameMode.turbo:
        return const ModeConfig(
          speedMultiplier: 1.55,
          pelletMultiplier: 1.25,
          virusMultiplier: 1.15,
          splitCooldownMultiplier: 0.55,
          botAggression: 1.25,
        );

      case GameMode.battleRoyale:
        return const ModeConfig(
          canBotsRespawn: false,
          canHumanRespawn: false,
          shrinkingZone: true,
          matchTimerSeconds: 240,
        );

      case GameMode.zombieInfection:
        return const ModeConfig(
          zombieMode: true,
          initialZombieCount: 6,
          matchTimerSeconds: 180,
          botAggression: 1.15,
        );

      case GameMode.hardcore:
        return const ModeConfig(
          pelletMultiplier: 0.7,
          virusMultiplier: 1.4,
          botAggression: 1.45,
          showHelperUi: false,
        );

      case GameMode.rankedArena:
        return const ModeConfig(
          rankedScoring: true,
          botAggression: 1.1,
        );

      case GameMode.coinRush:
        return const ModeConfig(
          coinMode: true,
          coinCount: 90,
          matchTimerSeconds: 180,
        );

      case GameMode.blackHole:
        return const ModeConfig(
          blackHoleMode: true,
          blackHoleCount: 3,
        );

      case GameMode.hideSeek:
        return const ModeConfig(
          hideSeekMode: true,
          seekerCount: 5,
          matchTimerSeconds: 180,
        );

      case GameMode.chaosMode:
        return const ModeConfig(
          chaosMode: true,
        );
    }
  }
}
