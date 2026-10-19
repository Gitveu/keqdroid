import 'package:flutter/foundation.dart';

/// Окно праздничного оформления: с 20 октября по 2 ноября включительно, по
/// местному времени устройства.
///
/// Год задан намеренно. Без него тема возвращалась бы каждый октябрь в сборке,
/// про которую к тому времени все забудут; продлить её на следующий год — одна
/// правка здесь, и решают это осознанно.
abstract final class HalloweenSeason {
  static const int year = 2026;

  static DateTime get start => DateTime(year, 10, 20);

  /// Первый момент после окна: полночь на 3 ноября.
  static DateTime get end => DateTime(year, 11, 3);

  /// Часы, по которым сверяется окно. Подменяются в тестах, чтобы проверять
  /// границы, не переводя системное время.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static DateTime get current => now();

  static bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  static bool get isNow => contains(now());

  /// Через сколько окно откроется или закроется; `null` — после окна, ждать нечего.
  ///
  /// Нужно оттого, что приложение на ПК неделями висит в трее, а на телефоне
  /// днями лежит в фоне: проверки при запуске мало, тыква появилась бы только
  /// после перезапуска.
  static Duration? untilNextBoundary(DateTime t) {
    if (t.isBefore(start)) return start.difference(t);
    if (t.isBefore(end)) return end.difference(t);
    return null;
  }
}
