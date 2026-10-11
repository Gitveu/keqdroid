import 'package:flutter/foundation.dart' show listEquals;
import 'package:uuid/uuid.dart';

/// Что из трафика забирает маршрут.
enum RouteContent { allTraffic, sites, preset }

/// Куда маршрут отправляет трафик. [vpn] — текущий сервер, тот же, что у
/// «Всего остального» в положении «Через VPN»; [server] — конкретный другой.
enum RouteTarget { vpn, server, direct, block }

/// Маршрут: кто (все приложения или выбранные) → что → куда.
///
/// Порядок маршрутов не хранится: раздел и место в нём выводятся из самого
/// маршрута (см. `traffic_routes.dart`), так что порядок на экране и порядок
/// проверки в ядре не могут разойтись.
class TrafficRoute {
  const TrafficRoute({
    required this.id,
    this.enabled = true,
    this.apps = const [],
    this.content = RouteContent.sites,
    this.sites = '',
    this.presetId = '',
    this.target = RouteTarget.vpn,
    this.serverId = '',
  });

  factory TrafficRoute.create({
    List<String> apps = const [],
    RouteContent content = RouteContent.sites,
    String sites = '',
    String presetId = '',
    RouteTarget target = RouteTarget.vpn,
    String serverId = '',
    bool enabled = true,
  }) =>
      TrafficRoute(
        id: const Uuid().v4(),
        enabled: enabled,
        apps: apps,
        content: content,
        sites: sites,
        presetId: presetId,
        target: target,
        serverId: serverId,
      );

  final String id;
  final bool enabled;

  /// Записи приложений в формате сплита: имя пакета на Android, имя процесса
  /// или путь к файлу на ПК. Пусто — все приложения.
  final List<String> apps;

  final RouteContent content;

  /// Для [RouteContent.sites]: тот же текст, что в прежних полях списков —
  /// домены, адреса, geo-коды и ссылки на списки.
  final String sites;

  /// Для [RouteContent.preset]: id из `RoutingPresets.all`. Хранится id, а не
  /// значения, чтобы маршрут подхватывал обновлённый пресет.
  final String presetId;

  final RouteTarget target;

  /// Для [RouteTarget.server]: id `ServerItem`. Обновление подписки id
  /// сохраняет, как и у активного сервера.
  final String serverId;

  bool get allApps => apps.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'enabled': enabled,
        if (apps.isNotEmpty) 'apps': apps,
        'content': content.name,
        if (sites.isNotEmpty) 'sites': sites,
        if (presetId.isNotEmpty) 'preset': presetId,
        'target': target.name,
        if (serverId.isNotEmpty) 'server': serverId,
      };

  factory TrafficRoute.fromJson(Map<String, dynamic> json) => TrafficRoute(
        id: json['id'] as String,
        enabled: json['enabled'] as bool? ?? true,
        apps: [
          for (final a in (json['apps'] as List? ?? const [])) a.toString(),
        ],
        content: RouteContent.values.firstWhere(
          (c) => c.name == json['content'],
          orElse: () => RouteContent.sites,
        ),
        sites: json['sites'] as String? ?? '',
        presetId: json['preset'] as String? ?? '',
        // Неизвестная цель из будущей версии безопаснее всего как «через VPN»:
        // так ведёт себя и маршрут, чей сервер пропал.
        target: RouteTarget.values.firstWhere(
          (t) => t.name == json['target'],
          orElse: () => RouteTarget.vpn,
        ),
        serverId: json['server'] as String? ?? '',
      );

  TrafficRoute copyWith({
    bool? enabled,
    List<String>? apps,
    RouteContent? content,
    String? sites,
    String? presetId,
    RouteTarget? target,
    String? serverId,
  }) =>
      TrafficRoute(
        id: id,
        enabled: enabled ?? this.enabled,
        apps: apps ?? this.apps,
        content: content ?? this.content,
        sites: sites ?? this.sites,
        presetId: presetId ?? this.presetId,
        target: target ?? this.target,
        serverId: serverId ?? this.serverId,
      );

  @override
  bool operator ==(Object other) =>
      other is TrafficRoute &&
      other.id == id &&
      other.enabled == enabled &&
      listEquals(other.apps, apps) &&
      other.content == content &&
      other.sites == sites &&
      other.presetId == presetId &&
      other.target == target &&
      other.serverId == serverId;

  @override
  int get hashCode => Object.hash(
        id,
        enabled,
        Object.hashAll(apps),
        content,
        sites,
        presetId,
        target,
        serverId,
      );
}
