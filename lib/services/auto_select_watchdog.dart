abstract final class AutoSelectWatchdog {
  static const listenEvery = Duration(seconds: 1);

  static const failureBurst = 1;

  static const silentSecondsBeforeCheck = 2;

  // на десктопе счётчики из API ядра не видят TCP-подтверждений, с порогом 2 были ложные тревоги
  static const desktopSilentSecondsBeforeCheck = 5;

  static const streakGapSeconds = 5;

  static const judgeTimeoutSeconds = 4;

  static const candidateLimit = 10;

  static const quietAfterCheck = Duration(seconds: 15);

  static const quietAfterSwitch = Duration(seconds: 5);

  static const probeEvery = Duration(seconds: 30);

  static const recheckEvery = Duration(minutes: 5);

  static const recheckLimit = 4;

  static const maxSwitchesPerWindow = 3;
  static const switchWindow = Duration(minutes: 3);

  static bool shouldProbe({
    required bool connected,
    required bool autoSelectOn,
    required bool trafficMoved,
    required bool trafficSent,
  }) =>
      connected && autoSelectOn && trafficSent && !trafficMoved;

  static bool dialFailuresSuggestDeadServer(int newFailures) =>
      newFailures >= failureBurst;

  static bool trafficStalled(int silentSeconds, {bool desktop = false}) =>
      silentSeconds >=
      (desktop ? desktopSilentSecondsBeforeCheck : silentSecondsBeforeCheck);

  static bool switchAllowed(List<DateTime> recent, DateTime now) {
    final inWindow = recent.where((t) => now.difference(t) < switchWindow);
    return inWindow.length < maxSwitchesPerWindow;
  }
}

final class SilenceStreak {
  const SilenceStreak({this.silent = 0, this.idle = 0});

  final int silent;

  final int idle;

  SilenceStreak next({required int sent, required int received}) {
    if (received > 0) return const SilenceStreak();
    if (sent > 0) {
      final fresh = idle > AutoSelectWatchdog.streakGapSeconds;
      return SilenceStreak(silent: fresh ? 1 : silent + 1);
    }
    return SilenceStreak(silent: silent, idle: idle + 1);
  }
}
