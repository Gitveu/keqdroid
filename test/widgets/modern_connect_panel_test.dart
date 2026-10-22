import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/l10n/app_localizations_en.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/server_item.dart';
import 'package:keqdroid/providers/halloween_provider.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/servers_tab.dart';
import 'package:keqdroid/services/vpn_engine.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

/// Верх экрана серверов в двух видах: «Легаси» как было и «Модерн» одной
/// панелью. Переключатель во «Внешнем виде» не должен оставлять мёртвый режим.

class _FakeServers extends ServersNotifier {
  @override
  ServersState build() => ServersState(
        servers: [
          ServerItem(
            id: 'pl',
            config: 'vless://00000000-0000-0000-0000-000000000000@pl.example'
                '.com:443#Poland',
            type: ServerItemType.manual,
            pingMs: 44,
            lastTestedAt: DateTime(2026),
          ),
        ],
        activeServerId: 'pl',
      );
}

class _FakeSettings extends SettingsNotifier {
  _FakeSettings(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

class _FakeVpn extends VpnStateNotifier {
  @override
  Future<VpnState> build() async =>
      const VpnState(status: VpnStatus.disconnected);
}

class _NoHalloween extends HalloweenActiveNotifier {
  @override
  bool build() => false;
}

final _l10n = AppLocalizationsEn();

Future<void> _pump(WidgetTester tester, {required bool modern}) async {
  tester.view.physicalSize = const Size(412, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final storage = await tester.runAsync(buildStorageService);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage!),
        serversProvider.overrideWith(_FakeServers.new),
        settingsNotifierProvider.overrideWith(
          () => _FakeSettings(
            const AppSettings().copyWith(modernConnectPanel: modern),
          ),
        ),
        vpnStateProvider.overrideWith(_FakeVpn.new),
        halloweenActiveProvider.overrideWith(_NoHalloween.new),
        vpnEngineProvider.overrideWithValue(
          VpnEngine.withBackend(FakeTunnelBackend()),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ServersTab()),
      ),
    ),
  );
  // волна в шапке анимируется вечно, pumpAndSettle повис бы
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('«Модерн» собирает сервер и пинг в панель', (tester) async {
    await _pump(tester, modern: true);
    // имя сервера в панели и в строке списка
    expect(find.text('Poland'), findsNWidgets(2));
    expect(find.textContaining('44 ms'), findsNWidgets(2));
    expect(find.text(_l10n.vpnTapToConnect('Poland')), findsNothing);
  });

  testWidgets('«Легаси» остаётся прежней шапкой', (tester) async {
    await _pump(tester, modern: false);
    expect(find.text('Poland'), findsOneWidget);
    expect(find.text(_l10n.vpnTapToConnect('Poland')), findsOneWidget);
  });

  test('выбор режима переживает сохранение настроек', () {
    final saved = const AppSettings()
        .copyWith(modernConnectPanel: true)
        .toJsonString();
    expect(AppSettings.fromJsonString(saved).modernConnectPanel, isTrue);
    expect(const AppSettings().modernConnectPanel, isFalse);
  });
}
