import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/route_servers.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

/// «Другой сервер» маршрута на xray: отдельный аутбаунд и правила на него
/// между «напрямую» и «через VPN».
const _active = 'vless://00000000-0000-4000-8000-000000000000@nl.example:443'
    '?type=tcp&security=tls&sni=nl.example#NL';
const _de = 'trojan://pw@de.example:443?security=tls&sni=de.example#DE';

const _settings = AppSettings(
  directRules: 'vk.com',
  proxyRules: 'discord.com',
  blockedRules: 'ads.example',
);

const _toDe = RouteServerOutbound(
  tag: 'keq-srv-0',
  serverId: 'de',
  config: _de,
  address: 'de.example',
  entries: 'youtube.com, geoip:de, 9.9.9.9',
);

const _xrayCustom = '''
{
  "outbounds": [
    {
      "tag": "my-proxy",
      "protocol": "vless",
      "settings": {"vnext": [{"address": "nl.example", "port": 443,
        "users": [{"id": "00000000-0000-4000-8000-000000000000", "encryption": "none"}]}]}
    },
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"rules": []}
}
''';

Map<String, dynamic> _build(
  String server, {
  AppSettings settings = _settings,
  List<RouteServerOutbound> routes = const [_toDe],
}) =>
    jsonDecode(ConfigGeneratorV2.generateConfig(
      server,
      settings,
      routeServers: routes,
    )) as Map<String, dynamic>;

List<Map<String, dynamic>> _rules(Map<String, dynamic> c) => [
      for (final r in (c['routing'] as Map)['rules'] as List)
        (r as Map).cast<String, dynamic>(),
    ];

List<Map<String, dynamic>> _outbounds(Map<String, dynamic> c) => [
      for (final o in c['outbounds'] as List) (o as Map).cast<String, dynamic>(),
    ];

int _at(List<Map<String, dynamic>> rules, String tag) =>
    rules.indexWhere((r) => r['ruleTag'] == tag);

void main() {
  setUp(() => Socks5Credentials().init('u', 'p'));

  test('сервер маршрута — отдельный аутбаунд после основного', () {
    final outbounds = _outbounds(_build(_active));
    expect(outbounds.first['tag'], 'proxy',
        reason: 'первый аутбаунд у xray основной');
    final de = outbounds.firstWhere((o) => o['tag'] == 'keq-srv-0');
    expect(de['protocol'], 'trojan');
    expect((de['settings'] as Map)['address'], 'de.example');
  });

  test('правила на него — после «напрямую», раньше «через VPN»', () {
    final rules = _rules(_build(_active));
    final domains = _at(rules, 'keq-srv-0-domains');
    expect(domains, isNonNegative, reason: '$rules');
    expect(rules[domains]['domain'], ['domain:youtube.com']);
    expect(rules[domains]['outboundTag'], 'keq-srv-0');
    expect(rules[_at(rules, 'keq-srv-0-geoip')]['ip'], ['geoip:de']);
    expect(rules[_at(rules, 'keq-srv-0-ips')]['ip'], ['9.9.9.9']);
    expect(_at(rules, 'block-domains'), lessThan(domains));
    expect(_at(rules, 'direct-private'), lessThan(domains));
    expect(domains, lessThan(_at(rules, 'proxy-domains')));
  });

  test('к самому серверу маршрута — напрямую, его домен резолвится без туннеля',
      () {
    final c = _build(_active);
    final rules = _rules(c);
    final direct = rules.firstWhere((r) => r['ruleTag'] == 'route-server-0');
    expect(direct['domain'], ['full:de.example']);
    expect(direct['outboundTag'], 'direct');
    expect(jsonEncode(c['dns']), contains('full:de.example'));
  });

  test('скачанные списки — в его доменные правила', () {
    final rules = _rules(_build(
      _active,
      routes: [_toDe.copyWith(listDomains: ['list.example'])],
    ));
    expect(
      rules[_at(rules, 'keq-srv-0-domains')]['domain'],
      ['domain:youtube.com', 'domain:list.example'],
    );
  });

  test('фрагментация доходит и до сервера маршрута', () {
    final c = _build(
      _active,
      settings: _settings.copyWith(
        xrayCore: const XrayCoreSettings(fragmentEnabled: true),
      ),
    );
    final outbounds = _outbounds(c);
    String? dialer(String tag) =>
        ((outbounds.firstWhere((o) => o['tag'] == tag)['streamSettings']
                as Map?)?['sockopt'] as Map?)?['dialerProxy'] as String?;
    expect(dialer('proxy'), 'fragment');
    expect(dialer('keq-srv-0'), 'fragment');
    expect(outbounds.where((o) => o['tag'] == 'fragment'), hasLength(1));
  });

  test('без маршрутов на другие серверы конфиг прежний', () {
    expect(
      ConfigGeneratorV2.generateConfig(_active, _settings, routeServers: const []),
      ConfigGeneratorV2.generateConfig(_active, _settings),
    );
  });

  test('готовый конфиг: аутбаунд и правила добавлены к авторским', () {
    final c = _build(_xrayCustom);
    final outbounds = _outbounds(c);
    expect(outbounds.first['tag'], 'my-proxy');
    expect(outbounds.map((o) => o['tag']), contains('keq-srv-0'));
    final rules = _rules(c);
    final at = rules.indexWhere(
      (r) => (r['domain'] as List?)?.contains('domain:youtube.com') ?? false,
    );
    expect(at, isNonNegative);
    expect(rules[at]['outboundTag'], 'keq-srv-0');
  });
}
