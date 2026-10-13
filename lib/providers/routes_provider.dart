part of 'providers.dart';

// состояние меняется раньше записи на диск, как у настроек. порядок записей держит очередь StorageService
class RoutesNotifier extends AsyncNotifier<List<TrafficRoute>> {
  @override
  Future<List<TrafficRoute>> build() => ref.read(storageProvider).getRoutes();

  Future<void> _save(List<TrafficRoute> routes) async {
    state = AsyncData(routes);
    await ref.read(storageProvider).saveRoutes(routes);
  }

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

  Future<void> replaceAll(List<TrafficRoute> routes) => _save(routes);
}

final routesProvider =
    AsyncNotifierProvider<RoutesNotifier, List<TrafficRoute>>(
  RoutesNotifier.new,
);

// чего ядро не умеет, того в шторках нет, а заведённый маршрут с этим показывает причину на карточке
class RouteCapabilities {
  const RouteCapabilities({
    this.apps = false,
    this.appsNeedTun = false,
    this.servers = false,
    this.core = VpnBackend.xray,
  });

  final bool apps;

  // сессия в режиме прокси: маршрут заработает в TUN, поэтому выбор приложений не прячем
  final bool appsNeedTun;

  final bool servers;

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
  bool runIn(ConnectionMode m) =>
      appRoutesRun(core: core, mode: m, android: Platform.isAndroid);
  return RouteCapabilities(
    apps: runIn(mode),
    appsNeedTun: !runIn(mode) && runIn(ConnectionMode.tun),
    servers: true,
    core: core,
  );
});

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
