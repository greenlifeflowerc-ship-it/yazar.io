import 'dart:math';

/// Catalog of events that fire during [GameMode.chaosMode].
/// Each event is a self-contained, reversible tweak to engine state.
enum ChaosEvent {
  speedBoost,
  slowMotion,
  pelletFlood,
  virusStorm,
  massRain,
}

extension ChaosEventInfo on ChaosEvent {
  String get displayName {
    switch (this) {
      case ChaosEvent.speedBoost:
        return 'Speed Boost';
      case ChaosEvent.slowMotion:
        return 'Slow Motion';
      case ChaosEvent.pelletFlood:
        return 'Pellet Flood';
      case ChaosEvent.virusStorm:
        return 'Virus Storm';
      case ChaosEvent.massRain:
        return 'Mass Rain';
    }
  }

  /// Duration the event remains active before the engine reverts it.
  Duration get duration {
    switch (this) {
      case ChaosEvent.speedBoost:
      case ChaosEvent.slowMotion:
        return const Duration(seconds: 12);
      case ChaosEvent.pelletFlood:
        return const Duration(seconds: 10);
      case ChaosEvent.virusStorm:
        return const Duration(seconds: 15);
      case ChaosEvent.massRain:
        return const Duration(seconds: 8);
    }
  }
}

/// Pure-data state for the running chaos event scheduler. The engine owns one
/// of these; this class doesn't touch the engine directly so unit-testing the
/// scheduler is trivial.
class ChaosState {
  ChaosState(this._rng);

  final Random _rng;
  ChaosEvent? active;
  double activeUntil = -1; // engine.elapsed time
  double nextEventAt = 0;

  /// Cached event-specific scratch — e.g. temporary viruses to remove later.
  final List<String> tempVirusIds = [];

  bool isActiveAt(double now) => active != null && now < activeUntil;

  void scheduleNext(double now) {
    // 15–25s gap between events as spec'd.
    nextEventAt = now + 15 + _rng.nextDouble() * 10;
  }

  ChaosEvent pickRandom() {
    return ChaosEvent.values[_rng.nextInt(ChaosEvent.values.length)];
  }

  void start(ChaosEvent e, double now) {
    active = e;
    activeUntil = now + e.duration.inMilliseconds / 1000.0;
  }

  void clear() {
    active = null;
    activeUntil = -1;
    tempVirusIds.clear();
  }
}
