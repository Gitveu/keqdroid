import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/app/app.dart';
import 'package:keqdroid/l10n/app_localizations.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/traffic_route.dart';
import 'package:keqdroid/providers/providers.dart';
import 'package:keqdroid/screens/settings_tab.dart';
import 'package:keqdroid/services/rule_list_service.dart';
import 'package:keqdroid/services/storage_service.dart';
import 'package:keqdroid/services/vpn_engine.dart';

import '../helpers/fake_tunnel_backend.dart';
import '../helpers/test_storage.dart';

class _FakeSettings extends SettingsNotifier {
  _FakeSettings(this._initial);
  final AppSettings _initial;

  @override
  Future<AppSettings> build() async => _initial;

  @override
  Future<void> save(AppSettings settings) async => state = AsyncData(settings);
}

class _FakeVpn extends VpnStateNotifier {
  _FakeVpn(this._status);
  final VpnStatus _status;
  var reconnects = 0;

  @override
  Future<VpnState> build() async => VpnState(status: _status);

  @override
  Future<void> reconnectToActiveServer() async => reconnects++;
}

/// Списки по ссылкам без сети и диска: экран только показывает их состояние.
class _FakeRuleLists extends RuleListsNotifier {
  _FakeRuleLists(this._statuses);
  final Map<String, RuleListStatus> _statuses;

  @override
  Map<String, RuleListStatus> build() => _statuses;
}

late _FakeVpn _vpn;
late StorageService _storage;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  VpnStatus status = VpnStatus.disconnected,
  AppSettings settings = const AppSettings(),
  List<TrafficRoute>? routes,
  bool hint = false,
  Map<String, RuleListStatus> ruleLists = const {},
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);

  _storage = await buildStorageService(
    initialValues: {if (hint) 'keqdis_routes_hint': true},
  );
  if (routes != null) await _storage.saveRoutes(routes);
  _vpn = _FakeVpn(status);
  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWithValue(_storage),
      settingsNotifierProvider.overrideWith(() => _FakeSettings(settings)),
      vpnStateProvider.overrideWith(() => _vpn),
      ruleListsProvider.overrideWith(() => _FakeRuleLists(ruleLists)),
      vpnEngineProvider.overrideWithValue(
        VpnEngine.withBackend(FakeTunnelBackend()),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.dark,
          ),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ru'),
        home: routingScreenForTest(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Тексты на экране без изоляторов направления, которыми код обкладывает
/// адреса для фарси.
List<String> _texts(WidgetTester tester) => [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        (t.data ?? t.textSpan?.toPlainText() ?? '')
            .replaceAll(RegExp('[\u2066-\u2069]'), ''),
    ];

const _block = TrafficRoute(
  id: 'block',
  sites: 'doubleclick.net, criteo.com',
  target: RouteTarget.block,
);
const _direct = TrafficRoute(
  id: 'direct',
  sites: 'ru, yandex.ru, vk.com',
  target: RouteTarget.direct,
);
const _vpnOff = TrafficRoute(
  id: 'off',
  sites: 'geosite:telegram',
  target: RouteTarget.vpn,
  enabled: false,
);

void main() {
  group('главный экран', () {
    testWidgets('разделы по порядку проверки, пустые не показываются',
        (tester) async {
      await _pump(tester, routes: const [_direct, _block]);
      final texts = _texts(tester);
      expect(texts, contains('Блокировка'));
      expect(texts, isNot(contains('Приложения')),
          reason: 'маршрутов отдельных приложений нет — и раздела нет');
      expect(
        texts.indexOf('Блокировка'),
        lessThan(texts.indexOf('Все приложения')),
      );
      expect(texts, contains('doubleclick.net, criteo.com'));
      expect(texts, contains('→ блокировать'));
      expect(texts, contains('→ напрямую'));
      // «Всё остальное» — последней строкой раздела всех приложений.
      expect(
        texts.indexOf('ru, yandex.ru, vk.com'),
        lessThan(texts.indexOf('Всё остальное')),
      );
    });

    testWidgets('выключенный маршрут подписан', (tester) async {
      await _pump(tester, routes: const [_vpnOff]);
      expect(_texts(tester), contains('→ через VPN · выключен'));
    });

    testWidgets('подсказка после обновления закрывается навсегда',
        (tester) async {
      await _pump(tester, routes: const [_direct], hint: true);
      expect(find.text('Понятно'), findsOneWidget);
      await tester.tap(find.text('Понятно'));
      await tester.pumpAndSettle();
      expect(find.text('Понятно'), findsNothing);
      expect(_storage.routesHintPending, isFalse);
    });

    testWidgets('«Всё остальное» — те же три пути, что у маршрутов',
        (tester) async {
      final c = await _pump(tester, routes: const [_direct]);
      await tester.tap(find.text('Всё остальное'));
      await tester.pumpAndSettle();
      expect(find.text('Через VPN'), findsOneWidget);
      expect(find.text('Напрямую'), findsOneWidget);
      await tester.tap(find.text('Блокировать'));
      await tester.pumpAndSettle();
      expect(
        c.read(settingsNotifierProvider).value!.finalOutbound,
        AppSettings.finalOutboundBlock,
      );
      expect(_texts(tester), contains('→ блокировать'));
    });

    testWidgets('при поднятом туннеле — напоминание и переподключение',
        (tester) async {
      await _pump(tester, routes: const [_direct], status: VpnStatus.connected);
      await tester.tap(find.text('Переподключить'));
      await tester.pumpAndSettle();
      expect(_vpn.reconnects, 1);
    });

    testWidgets('без туннеля напоминания нет', (tester) async {
      await _pump(tester, routes: const [_direct]);
      expect(find.text('Переподключить'), findsNothing);
    });
  });

  group('редактор', () {
    Future<void> openNew(WidgetTester tester) async {
      await tester.tap(find.text('Новый маршрут'));
      await tester.pumpAndSettle();
    }

    testWidgets('новый маршрут: по умолчанию свои сайты через VPN',
        (tester) async {
      await _pump(tester, routes: const []);
      await openNew(tester);
      expect(find.text('Новый маршрут'), findsWidgets);
      // Без отдельных приложений строки «Кто» нет: выбирать не из чего.
      expect(find.text('Кто'), findsNothing);
      expect(find.text('Свои сайты · пусто'), findsOneWidget);
      expect(find.text('Через VPN'), findsOneWidget);
    });

    testWidgets('пустой новый маршрут при уходе не сохраняется',
        (tester) async {
      await _pump(tester, routes: const []);
      await openNew(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await _storage.getRoutes(), isEmpty);
    });

    // Набор сохраняется на паузе; уйти со страницы можно раньше паузы.
    testWidgets('набранное сразу перед уходом не теряется', (tester) async {
      await _pump(tester, routes: const []);
      await openNew(tester);
      await tester.enterText(find.byType(TextField), 'youtube.com');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final saved = await _storage.getRoutes();
      expect(saved.single.sites, 'youtube.com');
      expect(saved.single.target, RouteTarget.vpn);
      expect(_texts(tester), contains('youtube.com'));
    });

    testWidgets('готовый список ставит своё «куда»', (tester) async {
      await _pump(tester, routes: const []);
      await openNew(tester);
      await tester.tap(find.text('Что'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Реклама и трекеры'));
      await tester.pumpAndSettle();
      expect(find.text('Готовый список · Реклама и трекеры'), findsOneWidget);
      final saved = (await _storage.getRoutes()).single;
      expect(saved.content, RouteContent.preset);
      expect(saved.presetId, 'ads');
      expect(saved.target, RouteTarget.block);
    });

    testWidgets('Re-filter заодно отправляет «Всё остальное» напрямую',
        (tester) async {
      final c = await _pump(tester, routes: const []);
      await openNew(tester);
      await tester.tap(find.text('Что'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Заблокировано в РФ (Re-filter)'));
      await tester.pumpAndSettle();
      expect(
        c.read(settingsNotifierProvider).value!.finalOutbound,
        AppSettings.finalOutboundDirect,
      );
      expect(find.text('«Всё остальное» теперь идёт напрямую'), findsOneWidget);
      expect((await _storage.getRoutes()).single.target, RouteTarget.vpn);
    });

    testWidgets('«куда» меняется в шторке', (tester) async {
      await _pump(tester, routes: const [_direct]);
      await tester.tap(find.text('ru, yandex.ru, vk.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Куда'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Блокировать').last);
      await tester.pumpAndSettle();
      expect((await _storage.getRoutes()).single.target, RouteTarget.block);
    });

    testWidgets('маршрут выключается и удаляется', (tester) async {
      await _pump(tester, routes: const [_direct]);
      await tester.tap(find.text('ru, yandex.ru, vk.com'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect((await _storage.getRoutes()).single.enabled, isFalse);

      await tester.tap(find.byTooltip('Удалить'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await tester.pumpAndSettle();
      expect(await _storage.getRoutes(), isEmpty);
      expect(find.text('Всё остальное'), findsOneWidget,
          reason: 'после удаления — снова главный экран');
    });

    // Перенесённое правило по процессу: отдельные приложения ядро пока не
    // различает, и карточка обязана сказать, что маршрут не работает.
    testWidgets('маршрут приложений без поддержки ядра — с причиной',
        (tester) async {
      await _pump(tester, routes: const [
        TrafficRoute(
          id: 'app',
          apps: ['chrome.exe'],
          content: RouteContent.allTraffic,
          target: RouteTarget.direct,
          enabled: false,
        ),
      ]);
      expect(_texts(tester), contains('Приложения'));
      expect(_texts(tester), contains('chrome'));
      expect(
        _texts(tester).any((t) => t.contains('не различает приложения')),
        isTrue,
      );
    });
  });

  group('списки по ссылкам', () {
    const ads = 'https://adguardteam.github.io/filter.txt';
    const big = 'https://big.oisd.nl/';
    const local = 'https://lists.example/hosts';

    testWidgets('под полем строка на каждую ссылку, в подписи их домены',
        (tester) async {
      await _pump(
        tester,
        routes: const [
          TrafficRoute(
            id: 'b',
            sites: 'doubleclick.net, $ads\n$big\n$local',
            target: RouteTarget.block,
          ),
        ],
        ruleLists: {
          ads: RuleListStatus(
            url: ads,
            domains: 82341,
            updatedAt: DateTime.now().subtract(const Duration(hours: 3)),
          ),
          big: const RuleListStatus(
            url: big,
            failure: RuleListFailure.network,
          ),
          local: RuleListStatus(
            url: local,
            domains: 120,
            updatedAt: DateTime.now().subtract(const Duration(days: 2)),
            failure: RuleListFailure.http,
            httpStatus: 404,
          ),
        },
      );
      await tester.tap(find.textContaining('doubleclick.net'));
      await tester.pumpAndSettle();

      final texts = _texts(tester);
      expect(
        texts,
        contains('Свои сайты · 1 запись, 82\u00a0461 домен по ссылкам'),
      );
      expect(
        texts,
        contains('adguardteam.github.io — 82\u00a0341 домен, обновлён 3ч назад'),
      );
      expect(
        texts,
        contains(
          'big.oisd.nl — не загрузился, повтор при следующем подключении',
        ),
      );
      // Скачанное раньше остаётся в силе — строка об этом, а не об ошибке.
      expect(
        texts,
        contains(
          'lists.example — 120 доменов, обновлён 2д назад, '
          'свежий не загрузился',
        ),
      );
    });

    testWidgets('пока ничего не скачано, ссылка — обычная запись',
        (tester) async {
      await _pump(
        tester,
        routes: const [
          TrafficRoute(id: 'b', sites: ads, target: RouteTarget.block),
        ],
        ruleLists: {ads: const RuleListStatus(url: ads, loading: true)},
      );
      await tester.tap(find.textContaining('adguardteam'));
      await tester.pumpAndSettle();
      final texts = _texts(tester);
      expect(texts, contains('Свои сайты · 1 запись'));
      expect(texts, contains('adguardteam.github.io — загружается…'));
    });
  });

  test('счётчик записей склоняется и для 21, 22, 25', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(ru.settingsRoutingItemCount(0), 'пусто');
    expect(ru.settingsRoutingItemCount(1), '1 запись');
    expect(ru.settingsRoutingItemCount(21), '21 запись');
    expect(ru.settingsRoutingItemCount(22), '22 записи');
    expect(ru.settingsRoutingItemCount(25), '25 записей');
    expect(ru.settingsRoutingRouteCount(21), '21 маршрут');
    expect(ru.settingsRoutingRouteCount(5), '5 маршрутов');
  });
}
