import '../models/traffic_route.dart';
import '../tunnel/connection_mode.dart';
import '../tunnel/vpn_backend.dart';
import 'process_name_utils.dart';
import 'route_servers.dart';
import 'split_tunneling_entries.dart';
import 'traffic_routes.dart';

/// Работают ли маршруты отдельных приложений в такой сессии. Одно правило на
/// экран и на подключение: что экран обещает, то ядро и получает.
///
/// Владельца соединения mihomo узнаёт только у своего туннеля: на ПК сам, на
/// Android спрашивает у VpnService. xray на ПК внутри keqrnel видит один выход
/// на всех, а на Android его искатель процессов пока не подключён.
bool appRoutesRun({
  required VpnBackend core,
  required ConnectionMode mode,
}) =>
    core == VpnBackend.mihomo && mode == ConnectionMode.tun;

/// Маршрут отдельных приложений в виде, готовом для генератора.
class RouteAppRules {
  const RouteAppRules({
    required this.tag,
    required this.apps,
    required this.target,
    this.serverTag = '',
    this.allTraffic = false,
    this.entries = '',
    this.listDomains = const [],
  });

  /// Имя в конфиге ядра: набор правил маршрута и его скачанных списков.
  final String tag;

  /// Имена процессов и пути, приведённые к виду, в котором их видит ядро.
  final List<String> apps;

  final RouteTarget target;

  /// Выход другого сервера; пусто у маршрута на сервер — выхода у него нет
  /// (пропал, совпал с активным, не встаёт в ядро), и маршрут идёт через VPN.
  final String serverTag;

  final bool allTraffic;

  /// Сайты маршрута в формате полей списков.
  final String entries;

  /// Домены скачанных списков из ссылок в [entries].
  final List<String> listDomains;

  RouteAppRules copyWith({String? entries, List<String>? listDomains}) =>
      RouteAppRules(
        tag: tag,
        apps: apps,
        target: target,
        serverTag: serverTag,
        allTraffic: allTraffic,
        entries: entries ?? this.entries,
        listDomains: listDomains ?? this.listDomains,
      );
}

/// Маршруты отдельных приложений в порядке проверки: блокировка, затем
/// приложения (сайты раньше «весь трафик»). Сервер маршрута берётся из
/// [outbounds]; нет там — маршрут идёт через VPN, как и у всех приложений.
List<RouteAppRules> routeAppRules({
  required List<TrafficRoute> routes,
  required List<RouteServerOutbound> outbounds,
  bool? windows,
}) {
  final tagOf = {for (final o in outbounds) o.serverId: o.tag};
  final out = <RouteAppRules>[];
  for (final route in orderedRoutes(routes)) {
    if (!route.enabled || route.allApps || routeIsEmpty(route)) continue;
    // Повторы — без учёта регистра: так сравнивает и ядро.
    final seen = <String>{};
    final apps = [
      for (final app in route.apps)
        if (isProcessPathEntry(app))
          normalizeProcessPath(app, windows: windows)
        else
          normalizeProcessName(app, windows: windows),
    ].where((e) => e.isNotEmpty && seen.add(e.toLowerCase())).toList();
    if (apps.isEmpty) continue;
    out.add(RouteAppRules(
      tag: 'keq-app-${out.length}',
      apps: apps,
      target: route.target,
      serverTag: route.target == RouteTarget.server
          ? tagOf[route.serverId] ?? ''
          : '',
      allTraffic: route.content == RouteContent.allTraffic,
      entries: routeEntriesText(route).trim(),
    ));
  }
  return out;
}

/// Приложения маршрута, которые раздельное туннелирование ведёт мимо VPN: до
/// ядра они не доходят, и маршрут для них не сработает никогда.
///
/// Сомнение трактуется в пользу маршрута: имя без пути при «только
/// выбранных» с путём того же имени считается пропущенным — та программа в
/// туннель идёт, хоть и не из любой папки.
List<String> appsOutsideSplit(
  List<String> apps, {
  required Set<String> include,
  required Set<String> exclude,
  bool? windows,
}) {
  if (include.isNotEmpty) {
    final selection = SplitSelection(include, windows: windows);
    final names = {for (final e in include) splitNameKey(e, windows: windows)};
    return [
      for (final app in apps)
        if (!selection.covers(splitStubForEntry(app, windows: windows)) &&
            (isProcessPathEntry(app) ||
                !names.contains(splitNameKey(app, windows: windows))))
          app,
    ];
  }
  if (exclude.isNotEmpty) {
    final selection = SplitSelection(exclude, windows: windows);
    return [
      for (final app in apps)
        if (selection.covers(splitStubForEntry(app, windows: windows))) app,
    ];
  }
  return const [];
}
