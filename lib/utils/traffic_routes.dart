import '../models/app_settings.dart';
import '../models/routing_rule.dart';
import '../models/traffic_route.dart';
import 'routing_presets.dart';
import 'rule_lists.dart';

/// Раздел экрана маршрутизации. Порядок разделов — порядок проверки в ядре:
/// блокировка действует во всех приложениях, маршруты отдельных приложений
/// решают раньше общих, «Всё остальное» — последним.
enum RouteSection { block, apps, allApps }

RouteSection sectionOf(TrafficRoute route) {
  if (route.target == RouteTarget.block) return RouteSection.block;
  return route.allApps ? RouteSection.allApps : RouteSection.apps;
}

/// Маршруты раздела в порядке проверки.
///
/// У приложений сайты и готовые списки выше «весь трафик»: «Chrome: YouTube
/// → Германия» обязан решать раньше «Chrome: всё → Нидерланды». У всех
/// приложений — «напрямую», «другой сервер», «через VPN»: так стояли прежние
/// списки (обход раньше прокси), и у обновившихся ничего не переставится.
/// Внутри одной ступени — порядок добавления.
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
  // Сортировка устойчивая: List.sort её не обещает, поэтому ступени
  // собираются по очереди.
  final ranks = {for (final r in inSection) rank(r)}.toList()..sort();
  return [
    for (final k in ranks)
      for (final r in inSection)
        if (rank(r) == k) r,
  ];
}

/// Все маршруты в порядке проверки.
List<TrafficRoute> orderedRoutes(List<TrafficRoute> routes) => [
      for (final s in RouteSection.values) ...routesIn(s, routes),
    ];

RoutingPreset? presetById(String id) {
  for (final p in RoutingPresets.all) {
    if (p.id == id) return p;
  }
  return null;
}

/// Записи «что» маршрута в формате прежних полей списков. Пусто — у маршрута
/// «весь трафик» и у пресета, которого больше нет.
String routeEntriesText(TrafficRoute route) => switch (route.content) {
      RouteContent.sites => route.sites,
      RouteContent.preset => (presetById(route.presetId)?.values ?? const [])
          .join(', '),
      RouteContent.allTraffic => '',
    };

/// Маршрут, который ничего не забирает: свои сайты без единой записи.
bool routeIsEmpty(TrafficRoute route) =>
    route.content != RouteContent.allTraffic &&
    routingEntries(routeEntriesText(route)).isEmpty;

/// Настройки для генераторов: три списка собраны из маршрутов «все
/// приложения», прежние поля настроек не участвуют.
///
/// Маршруты отдельных приложений сюда не попадают никогда: свёрнутые в общие
/// списки, их сайты достались бы всем приложениям. [serverUsable] решает,
/// поедет ли маршрут на свой сервер. Не поедет (сервер пропал, ядро сессии
/// его не возьмёт) — маршрут уходит «через VPN»: связь важнее, а карточка на
/// экране показывает причину.
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

/// Ссылки на списки во всех маршрутах со своими сайтами, без повторов.
List<String> routeListUrls(List<TrafficRoute> routes) => {
      for (final r in routes)
        if (r.content == RouteContent.sites) ...ruleListUrls(r.sites),
    }.toList();

/// Маршруты из прежних настроек: три списка и «Свои правила».
///
/// Списки становятся маршрутами «все приложения» в своих разделах. Правило
/// по процессу становится маршрутом этих приложений, но выключенным: прежде
/// такие правила не применялись нигде, и молча включить их значило бы
/// поменять человеку маршрутизацию при обновлении. [newId] — для тестов.
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

/// Человек менял маршрутизацию до обновления — ему одна подсказка о том, что
/// списки стали маршрутами. Нетронутые значения по умолчанию подсказки не
/// стоят: на экране новой установки их и так видно.
bool legacyRoutingCustomized(AppSettings settings, List<RoutingRule> rules) =>
    rules.isNotEmpty ||
    settings.directRules.trim() != RoutingPresets.defaultDirectRules ||
    settings.proxyRules.trim() != RoutingPresets.defaultProxyRules ||
    settings.blockedRules.trim() != RoutingPresets.defaultBlockedRules;
