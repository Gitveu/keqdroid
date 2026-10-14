import '../models/routing_profile.dart';
import '../models/server_item.dart';
import '../models/traffic_route.dart';

// null значит «Основной»: свои серверы, подписки без профиля и выключенные профили
RoutingProfile? profileForServer(
  List<RoutingProfile> profiles,
  ServerItem server,
) {
  final sub = server.subscriptionId;
  if (sub == null) return null;
  for (final p in profiles) {
    if (p.enabled && p.subscriptionIds.contains(sub)) return p;
  }
  return null;
}

// у подписки один профиль: отмеченная в этом уходит из прежнего
List<RoutingProfile> withSubscriptions(
  List<RoutingProfile> profiles,
  String profileId,
  List<String> subscriptionIds,
) =>
    [
      for (final p in profiles)
        if (p.id == profileId)
          p.copyWith(subscriptionIds: subscriptionIds)
        else
          p.copyWith(subscriptionIds: [
            for (final s in p.subscriptionIds)
              if (!subscriptionIds.contains(s)) s,
          ]),
    ];

List<TrafficRoute> withRoute(List<TrafficRoute> routes, TrafficRoute route) {
  final exists = routes.any((r) => r.id == route.id);
  return [
    if (exists)
      for (final r in routes) r.id == route.id ? route : r
    else ...[...routes, route],
  ];
}

List<TrafficRoute> withoutRoute(List<TrafficRoute> routes, String id) => [
      for (final r in routes)
        if (r.id != id) r,
    ];
