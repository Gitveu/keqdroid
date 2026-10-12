import '../models/server_item.dart';
import '../models/traffic_route.dart';
import '../tunnel/vpn_backend.dart';
import 'traffic_routes.dart';
import 'vpn_core_support.dart';

/// Может ли сервер стать «другим сервером» маршрута в сессии ядра [core].
///
/// Только то, что встаёт в конфиг одним выходом: ссылка, если её берёт это
/// ядро, и профиль AmneziaWG у mihomo. Готовый конфиг и цепочка — нет: у них
/// свои выходы, правила и DNS, и в чужой конфиг они не вставляются. Так же
/// решил Throne для Android: такой сервер в правиле там запрещён.
bool routeServerSupported(String config, VpnBackend core) =>
    switch (detectServerFormat(config)) {
      ServerFormat.link => backendsForLink(config).contains(core),
      ServerFormat.amneziaWg => core == VpnBackend.mihomo,
      _ => false,
    };

/// Выход «другого сервера» в конфиге сессии: один на сервер, сколько бы
/// маршрутов на него ни вело.
class RouteServerOutbound {
  const RouteServerOutbound({
    required this.tag,
    required this.serverId,
    required this.config,
    required this.address,
    required this.entries,
    this.listDomains = const [],
  });

  /// Имя выхода в конфиге ядра.
  final String tag;
  final String serverId;
  final String config;

  /// Адрес сервера: обращения к нему самому идут мимо туннеля, как к
  /// активному серверу.
  final String address;

  /// Записи всех маршрутов на этот сервер в формате полей списков, в порядке
  /// маршрутов.
  final String entries;

  /// Домены скачанных списков из ссылок в [entries].
  final List<String> listDomains;

  RouteServerOutbound copyWith({String? entries, List<String>? listDomains}) =>
      RouteServerOutbound(
        tag: tag,
        serverId: serverId,
        config: config,
        address: address,
        entries: entries ?? this.entries,
        listDomains: listDomains ?? this.listDomains,
      );
}

/// Выходы для маршрутов «все приложения» на другие серверы.
///
/// Маршрут остаётся без выхода, если его сервер пропал, совпадает с
/// активным (это и так «через VPN») или не встаёт в ядро сессии. При
/// сворачивании такие маршруты уходят «через VPN» (см. [foldRoutes]).
List<RouteServerOutbound> routeServerOutbounds({
  required List<TrafficRoute> routes,
  required List<ServerItem> servers,
  required String? activeServerId,
  required VpnBackend core,
}) {
  final byId = {for (final s in servers) s.id: s};
  final entries = <String, List<String>>{};
  for (final route in orderedRoutes(routes)) {
    if (!route.enabled || !route.allApps) continue;
    if (route.target != RouteTarget.server) continue;
    final server = byId[route.serverId];
    if (server == null || server.id == activeServerId) continue;
    if (!routeServerSupported(server.config, core)) continue;
    final text = routeEntriesText(route).trim();
    if (text.isEmpty) continue;
    entries.putIfAbsent(server.id, () => []).add(text);
  }
  var index = 0;
  return [
    for (final MapEntry(key: id, value: texts) in entries.entries)
      RouteServerOutbound(
        tag: 'keq-srv-${index++}',
        serverId: id,
        config: byId[id]!.config,
        address: byId[id]!.address,
        entries: texts.join('\n'),
      ),
  ];
}
