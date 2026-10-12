part of 'providers.dart';

/// Маршруты экрана «Маршрутизация». Порядок в списке значения не имеет:
/// разделы и место в них выводятся из самих маршрутов ([orderedRoutes]).
///
/// Состояние меняется раньше записи на диск, как у настроек: правка не
/// транзакция, а круговой рейс до SharedPreferences не должен тормозить
/// экран. Порядок записей держит очередь StorageService.
class RoutesNotifier extends AsyncNotifier<List<TrafficRoute>> {
  @override
  Future<List<TrafficRoute>> build() => ref.read(storageProvider).getRoutes();

  Future<void> _save(List<TrafficRoute> routes) async {
    state = AsyncData(routes);
    await ref.read(storageProvider).saveRoutes(routes);
  }

  /// Новый маршрут добавляется в конец, существующий меняется на месте.
  Future<void> upsert(TrafficRoute route) async {
    final current = await future;
    final exists = current.any((r) => r.id == route.id);
    await _save([
      if (exists)
        for (final r in current) r.id == route.id ? route : r
      else ...[...current, route],
    ]);
  }

  Future<void> remove(String id) async {
    final current = await future;
    await _save([
      for (final r in current)
        if (r.id != id) r,
    ]);
  }

  /// Замена целиком — импорт резервной копии.
  Future<void> replaceAll(List<TrafficRoute> routes) => _save(routes);
}

final routesProvider =
    AsyncNotifierProvider<RoutesNotifier, List<TrafficRoute>>(
  RoutesNotifier.new,
);

/// Что маршруты умеют прямо сейчас: различать приложения и вести трафик на
/// другой сервер. Зависит от платформы и ядра активного сервера. Чего ядро
/// не умеет, того в шторках нет, а уже заведённый маршрут с таким пунктом
/// показывает на карточке, почему не работает.
class RouteCapabilities {
  const RouteCapabilities({
    this.apps = false,
    this.appsNeedTun = false,
    this.servers = false,
    this.core = VpnBackend.xray,
  });

  final bool apps;

  /// Ядро и платформа приложения различают, но сессия идёт в режиме прокси:
  /// маршрут заработает после переключения в TUN. Выбор приложений тогда
  /// не прячется — до рабочего маршрута один переключатель.
  final bool appsNeedTun;

  final bool servers;

  /// Ядро активного сервера: от него зависит, какой сервер встанет в маршрут
  /// отдельным выходом (`routeServerSupported`).
  final VpnBackend core;

  bool get appsOffered => apps || appsNeedTun;
}

final routeCapabilitiesProvider = Provider<RouteCapabilities>((ref) {
  final core = ref.watch(activeVpnBackendProvider);
  final mode = ref.watch(
    settingsNotifierProvider.select(
      (a) => TunnelSessionBuilder.resolveMode(a.value ?? const AppSettings()),
    ),
  );
  bool runIn(ConnectionMode m) => appRoutesRun(core: core, mode: m);
  return RouteCapabilities(
    apps: runIn(mode),
    appsNeedTun: !runIn(mode) && runIn(ConnectionMode.tun),
    servers: true,
    core: core,
  );
});

/// Разовая подсказка «списки стали маршрутами» после обновления.
class RoutesHintNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(storageProvider).routesHintPending;

  Future<void> dismiss() async {
    state = false;
    await ref.read(storageProvider).dismissRoutesHint();
  }
}

final routesHintProvider =
    NotifierProvider<RoutesHintNotifier, bool>(RoutesHintNotifier.new);
