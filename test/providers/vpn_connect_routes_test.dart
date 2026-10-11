import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/models/traffic_route.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/services/vpn_engine.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

/// Подключение собирает конфиг из маршрутов. Прежние поля списков после
/// переноса не читает никто: иначе удалённый маршрут продолжал бы работать
/// из старого поля.
class _Backend extends FakeTunnelBackend {
  VpnState current = VpnState.disconnected;
  TunnelSessionRequest? session;

  @override
  Future<VpnState> getCurrentState() async => current;

  @override
  Future<void> startSession(TunnelSessionRequest request) async {
    session = request;
    current = const VpnState(status: VpnStatus.connected);
  }
}

final _server = ServerItem(
  id: 'srv-1',
  type: ServerItemType.manual,
  config: 'vless://00000000-0000-4000-8000-000000000000@198.51.100.10:443'
      '?type=tcp&security=none#test',
);

List<Map<String, dynamic>> _rules(String xray) => [
      for (final r in ((jsonDecode(xray) as Map)['routing'] as Map)['rules']
          as List)
        (r as Map).cast<String, dynamic>(),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('в сессию едут маршруты, а не прежние поля списков', () async {
    final backend = _Backend();
    final storage = await buildStorageService();
    await storage.saveServers([_server]);
    await storage.setActiveServerId(_server.id);
    await storage.saveSettings(const AppSettings(
      directRules: 'legacy-direct.example',
      blockedRules: 'legacy-block.example',
    ));
    await storage.saveRoutes(const [
      TrafficRoute(
        id: 'a',
        sites: 'route-direct.example',
        target: RouteTarget.direct,
      ),
      TrafficRoute(
        id: 'b',
        sites: 'route-block.example',
        target: RouteTarget.block,
      ),
      TrafficRoute(
        id: 'c',
        sites: 'route-off.example',
        target: RouteTarget.vpn,
        enabled: false,
      ),
    ]);

    final container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        vpnEngineProvider.overrideWithValue(VpnEngine.withBackend(backend)),
      ],
    );
    addTearDown(container.dispose);
    container.read(serversProvider);
    await container.read(vpnStateProvider.future);

    await container.read(vpnStateProvider.notifier).connect();

    final xray = backend.session!.xrayConfig;
    List<String> domainsOf(String tag) => [
          for (final r in _rules(xray))
            if (r['ruleTag'] == tag) ...(r['domain'] as List).cast<String>(),
        ];
    expect(domainsOf('direct-domains'), ['domain:route-direct.example']);
    expect(domainsOf('block-domains'), ['domain:route-block.example']);
    expect(xray, isNot(contains('legacy-')));
    expect(xray, isNot(contains('route-off.example')));
  });
}
