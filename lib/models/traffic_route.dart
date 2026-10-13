import 'package:flutter/foundation.dart' show listEquals;
import 'package:uuid/uuid.dart';

enum RouteContent { allTraffic, sites, preset }

enum RouteTarget { vpn, server, direct, block }

// порядок не хранится, раздел выводится из самого маршрута: порядок на экране и проверки в ядре не разойдутся
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

  // записи в формате сплита: пакет на Android, имя процесса или путь на ПК. пусто значит все приложения
  final List<String> apps;

  final RouteContent content;

  final String sites;

  // id, а не значения: маршрут подхватит обновлённый пресет
  final String presetId;

  final RouteTarget target;

  // обновление подписки id сохраняет
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
        // неизвестная цель из будущей версии идёт через VPN, как маршрут с пропавшим сервером
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
