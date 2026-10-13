import '../models/app_settings.dart';
import '../models/routing_rule.dart';
import '../models/traffic_route.dart';
import 'routing_presets.dart';
import 'rule_lists.dart';

// порядок разделов это порядок проверки в ядре: блокировка везде, отдельные приложения раньше общих
enum RouteSection { block, apps, allApps }

RouteSection sectionOf(TrafficRoute route) {
  if (route.target == RouteTarget.block) return RouteSection.block;
  return route.allApps ? RouteSection.allApps : RouteSection.apps;
}

// у приложений сайты и списки выше всего трафика: Chrome YouTube на Германию решает раньше Chrome всё на Нидерланды.
// у всех приложений напрямую, другой сервер, через VPN, как стояли прежние списки, чтобы у обновившихся ничего не переставилось
List<TrafficRoute> routesIn(RouteSection section, List<TrafficRoute> routes) {
  final inSection = [
    for (final r in routes)
      if (sectionOf(r) == section) r,
  ];
  int rank(TrafficRoute r) => switch (section) {
        RouteSection.block => 0,
        RouteSection.apps => r.content == RouteContent.allTraffic ? 1 : 0,
        RouteSection.allApps => switch (r.target) {
            RouteTarget.direct => 0,
            RouteTarget.server => 1,
            _ => 2,
          },
      };
  // List.sort устойчивость не обещает, поэтому ступени собираются по очереди
  final ranks = {for (final r in inSection) rank(r)}.toList()..sort();
  return [
    for (final k in ranks)
      for (final r in inSection)
        if (rank(r) == k) r,
  ];
}

List<TrafficRoute> orderedRoutes(List<TrafficRoute> routes) => [
      for (final s in RouteSection.values) ...routesIn(s, routes),
    ];

RoutingPreset? presetById(String id) {
  for (final p in RoutingPresets.all) {
    if (p.id == id) return p;
  }
  return null;
}

// пусто у всего трафика и у пресета, которого больше нет
String routeEntriesText(TrafficRoute route) => switch (route.content) {
      RouteContent.sites => route.sites,
      RouteContent.preset => (presetById(route.presetId)?.values ?? const [])
          .join(', '),
      RouteContent.allTraffic => '',
    };

bool routeIsEmpty(TrafficRoute route) =>
    route.content != RouteContent.allTraffic &&
    routingEntries(routeEntriesText(route)).isEmpty;

// маршруты отдельных приложений сюда не попадают: в общих списках их сайты достались бы всем.
// не едет на свой сервер, значит через VPN: связь важнее, причину покажет карточка
AppSettings foldRoutes(
  AppSettings settings,
  List<TrafficRoute> routes, {
  bool Function(TrafficRoute route) serverUsable = _never,
}) {
  final direct = <String>[];
  final proxy = <String>[];
  final blocked = <String>[];
  for (final route in orderedRoutes(routes)) {
    if (!route.enabled || !route.allApps) continue;
    final text = routeEntriesText(route).trim();
    if (text.isEmpty) continue;
    switch (route.target) {
      case RouteTarget.direct:
        direct.add(text);
      case RouteTarget.block:
        blocked.add(text);
      case RouteTarget.vpn:
        proxy.add(text);
      case RouteTarget.server:
        if (!serverUsable(route)) proxy.add(text);
    }
  }
  return settings.copyWith(
    directRules: direct.join('\n'),
    proxyRules: proxy.join('\n'),
    blockedRules: blocked.join('\n'),
  );
}

bool _never(TrafficRoute _) => false;

List<String> routeListUrls(List<TrafficRoute> routes) => {
      for (final r in routes)
        if (r.content == RouteContent.sites) ...ruleListUrls(r.sites),
    }.toList();

// правило по процессу становится маршрутом, но выключенным: раньше такие правила не применялись нигде,
// и включить их молча значило бы поменять маршрутизацию при обновлении
List<TrafficRoute> routesFromLegacy(
  AppSettings settings,
  List<RoutingRule> rules, {
  String Function()? newId,
}) {
  TrafficRoute make({
    List<String> apps = const [],
    RouteContent content = RouteContent.sites,
    String sites = '',
    required RouteTarget target,
    bool enabled = true,
  }) {
    final fresh = TrafficRoute.create(
      apps: apps,
      content: content,
      sites: sites,
      target: target,
      enabled: enabled,
    );
    if (newId == null) return fresh;
    return TrafficRoute(
      id: newId(),
      enabled: fresh.enabled,
      apps: fresh.apps,
      content: fresh.content,
      sites: fresh.sites,
      target: fresh.target,
    );
  }

  RouteTarget targetOf(RuleAction a) => switch (a) {
        RuleAction.direct => RouteTarget.direct,
        RuleAction.proxy => RouteTarget.vpn,
        RuleAction.block => RouteTarget.block,
      };

  final routes = <TrafficRoute>[
    for (final (text, target) in [
      (settings.blockedRules, RouteTarget.block),
      (settings.directRules, RouteTarget.direct),
      (settings.proxyRules, RouteTarget.vpn),
    ])
      if (routingEntries(text).isNotEmpty)
        make(sites: text.trim(), target: target),
  ];

  for (final rule in rules) {
    final values = [
      for (final v in rule.values)
        if (v.trim().isNotEmpty) v.trim(),
    ];
    if (values.isEmpty) continue;
    if (rule.type == RuleType.processName) {
      routes.add(make(
        apps: values,
        content: RouteContent.allTraffic,
        target: targetOf(rule.action),
        enabled: false,
      ));
      continue;
    }
    final tokens = switch (rule.type) {
      RuleType.geoip => [
          for (final v in values)
            v.toLowerCase().startsWith('geoip:') ? v : 'geoip:$v',
        ],
      RuleType.geosite => [
          for (final v in values)
            v.toLowerCase().startsWith('geosite:') ? v : 'geosite:$v',
        ],
      _ => values,
    };
    routes.add(make(
      sites: tokens.join(', '),
      target: targetOf(rule.action),
      enabled: rule.enabled,
    ));
  }
  return routes;
}

// нетронутые значения по умолчанию подсказки не стоят
bool legacyRoutingCustomized(AppSettings settings, List<RoutingRule> rules) =>
    rules.isNotEmpty ||
    settings.directRules.trim() != RoutingPresets.defaultDirectRules ||
    settings.proxyRules.trim() != RoutingPresets.defaultProxyRules ||
    settings.blockedRules.trim() != RoutingPresets.defaultBlockedRules;
