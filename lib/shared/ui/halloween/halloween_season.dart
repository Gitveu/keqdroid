import 'package:flutter/foundation.dart';

// год зашит нарочно: забытая сборка не должна через год снова стать тыквой
abstract final class HalloweenSeason {
  static const int year = 2026;

  static DateTime get start => DateTime(year, 10, 20);

  static DateTime get end => DateTime(year, 11, 3);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static DateTime get current => now();

  static bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  static bool get isNow => contains(now());

  static Duration? untilNextBoundary(DateTime t) {
    if (t.isBefore(start)) return start.difference(t);
    if (t.isBefore(end)) return end.difference(t);
    return null;
  }
}
