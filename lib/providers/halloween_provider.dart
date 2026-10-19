import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/ui/halloween/halloween_season.dart';
import 'providers.dart';

/// Показывать ли сейчас праздничное оформление: окно дат открыто и человек его
/// не выключил.
///
/// Пересчитывается сам на границе окна и при возвращении приложения на экран.
/// Таймер на границу ловит открытое приложение, а возвращение — то, что таймер
/// пропускает: телефон во сне откладывает таймеры, и он мог сработать позже.
final halloweenActiveProvider =
    NotifierProvider<HalloweenActiveNotifier, bool>(HalloweenActiveNotifier.new);

class HalloweenActiveNotifier extends Notifier<bool> {
  @override
  bool build() {
    final enabled = ref.watch(
      settingsNotifierProvider.select((s) => s.value?.seasonalDecor ?? true),
    );

    final wait = HalloweenSeason.untilNextBoundary(HalloweenSeason.current);
    // Небольшой запас: таймер, сработавший на миллисекунду раньше полуночи,
    // посчитал бы окно ещё прежним и заснул бы до следующей границы.
    final timer = wait == null ? null : Timer(wait + const Duration(seconds: 1), ref.invalidateSelf);
    final lifecycle = AppLifecycleListener(onResume: ref.invalidateSelf);
    ref.onDispose(() {
      timer?.cancel();
      lifecycle.dispose();
    });

    return enabled && HalloweenSeason.isNow;
  }
}
