import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/routing_profile.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/models/traffic_route.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/rule_list_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';
import 'package:keqdroid/utils/routing_profiles.dart';

import '../helpers/test_storage.dart';

const _games = RoutingProfile(
  id: 'games',
  name: 'Игры',
  subscriptionIds: ['sub-a', 'sub-b'],
  finalOutbound: AppSettings.finalOutboundDirect,
  routes: [
    TrafficRoute(
      id: 'steam',
      apps: ['steam.exe'],
      content: RouteContent.allTraffic,
      target: RouteTarget.direct,
    ),
  ],
);
const _work = RoutingProfile(
  id: 'work',
  name: 'Работа',
  enabled: false,
  subscriptionIds: ['sub-c'],
);

ServerItem _server({String? subscriptionId}) => ServerItem(
      id: 's',
      type: subscriptionId == null
          ? ServerItemType.manual
          : ServerItemType.subscription,
      subscriptionId: subscriptionId,
      config: 'vless://00000000-0000-4000-8000-000000000000@a.example:443'
          '?type=tcp&security=tls#a',
    );

class _FakeVpn extends VpnStateNotifier {
  @override
  Future<VpnState> build() async =>
      const VpnState(status: VpnStatus.disconnected);
}

/// Списки «уже скачаны и свежие»: синхронизация только сверяет их и чистит
/// лишнее, а что велено оставить, записывается.
class _FakeLists extends RuleListService {
  Set<String>? kept;

  @override
  Future<RuleListStatus> status(String url) async =>
      RuleListStatus(url: url, domains: 1, updatedAt: DateTime.now());

  @override
  Future<RuleListStatus> refresh(String url) => status(url);

  @override
  Future<void> prune(Set<String> keepUrls) async => kept = keepUrls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('профиль сервера', () {
    test('свой сервер и подписка без профиля идут по «Основному»', () {
      expect(profileForServer(const [_games], _server()), isNull);
      expect(
        profileForServer(const [_games], _server(subscriptionId: 'other')),
        isNull,
      );
    });

    test('подписка с включённым профилем берёт его', () {
      expect(
        profileForServer(const [_work, _games], _server(subscriptionId: 'sub-b'))
            ?.id,
        'games',
      );
    });

    test('выключенный профиль уступает «Основному»', () {
      expect(
        profileForServer(const [_work], _server(subscriptionId: 'sub-c')),
        isNull,
      );
    });
  });

  test('отмеченная подписка уходит из прежнего профиля', () {
    final moved = withSubscriptions(const [_games, _work], 'work', ['sub-b']);
    expect(moved.firstWhere((p) => p.id == 'games').subscriptionIds, ['sub-a']);
    expect(moved.firstWhere((p) => p.id == 'work').subscriptionIds, ['sub-b']);
  });

  test('маршрут заменяется на месте или добавляется в конец, удаляется по id',
      () {
    const a = TrafficRoute(id: 'a', sites: 'a.example');
    const b = TrafficRoute(id: 'b', sites: 'b.example');
    const a2 = TrafficRoute(id: 'a', sites: 'a2.example');
    expect(withRoute(const [a, b], a2), const [a2, b]);
    expect(withRoute(const [a], b), const [a, b]);
    expect(withoutRoute(const [a, b], 'a'), const [b]);
  });

  test('профиль переживает запись и чтение, пропущенные поля по умолчанию',
      () async {
    final storage = await buildStorageService();
    await storage.saveRoutingProfiles(const [_games, _work]);
    final back = await storage.getRoutingProfiles();
    expect(
      [for (final p in back) p.toJson()],
      [_games.toJson(), _work.toJson()],
    );

    final bare = RoutingProfile.fromJson({'id': 'x'});
    expect(bare.enabled, isTrue);
    expect(bare.finalOutbound, AppSettings.finalOutboundProxy);
    expect(bare.subscriptionIds, isEmpty);
    expect(bare.routes, isEmpty);
  });

  test('без профилей хранилище отдаёт пустой список', () async {
    final storage = await buildStorageService();
    expect(await storage.getRoutingProfiles(), isEmpty);
  });

  test('новый профиль забирает свои подписки у других', () async {
    final storage = await buildStorageService();
    await storage.saveRoutingProfiles(const [_games]);
    final container = ProviderContainer(
      overrides: [storageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    await container.read(routingProfilesProvider.notifier).add(
          RoutingProfile.create(name: 'Новый', subscriptionIds: ['sub-a']),
        );
    final saved = await storage.getRoutingProfiles();
    expect(saved.first.subscriptionIds, ['sub-b']);
    expect(saved.last.subscriptionIds, ['sub-a']);
  });

  test('скачанные списки маршрутов профиля не вычищаются', () async {
    final storage = await buildStorageService();
    await storage.saveRoutes(const [
      TrafficRoute(id: 'm', sites: 'https://lists.example/main.txt'),
    ]);
    await storage.saveRoutingProfiles(const [
      RoutingProfile(
        id: 'p',
        name: 'Профиль',
        enabled: false,
        routes: [
          TrafficRoute(id: 'r', sites: 'https://lists.example/profile.txt'),
        ],
      ),
    ]);
    final lists = _FakeLists();
    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        ruleListServiceProvider.overrideWithValue(lists),
        vpnStateProvider.overrideWith(_FakeVpn.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(ruleListsProvider, (_, _) {});
    for (var i = 0; i < 40 && lists.kept == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(lists.kept, {
      'https://lists.example/main.txt',
      'https://lists.example/profile.txt',
    });
  });
}
