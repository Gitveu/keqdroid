import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/route_servers.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

/// «Другой сервер» маршрута на mihomo: отдельный выход в конфиге сессии и
/// правила на него между «напрямую» и «через VPN» — там, где ТЗ ставит его
/// в разделе всех приложений.
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
  entries: 'youtube.com, geoip:de',
);

const _clashYaml = '''
proxies:
  - name: "NL"
    type: trojan
    server: nl.example
    port: 443
    password: password
    sni: nl.example
proxy-groups:
  - name: "Proxy"
    type: select
    proxies: ["NL"]
rules:
  - DOMAIN-SUFFIX,author.example,DIRECT
  - MATCH,Proxy
''';

List<String> _rules(Map<String, dynamic> c) =>
    (c['rules'] as List).cast<String>();

List<Map<String, dynamic>> _proxies(Map<String, dynamic> c) =>
    (c['proxies'] as List).cast<Map<String, dynamic>>();

void main() {
  setUp(() => Socks5Credentials().init('u', 'p'));

  test('сервер маршрута — отдельный выход со своим именем', () {
    final c = MihomoConfigGen.build(
      _active,
      _settings,
      socksPort: 2080,
      routeServers: const [_toDe],
    );
    final proxies = _proxies(c);
    expect(proxies.map((p) => p['name']), [
      MihomoConfigGen.proxyName,
      'keq-srv-0',
    ]);
    expect(proxies.last['server'], 'de.example');
    expect(proxies.last['type'], 'trojan');
  });

  test('правила на него — после «напрямую», раньше «через VPN»', () {
    final rules = _rules(MihomoConfigGen.build(
      _active,
      _settings,
      socksPort: 2080,
      routeServers: const [_toDe],
    ));
    final direct = rules.indexOf('DOMAIN-SUFFIX,vk.com,DIRECT');
    final server = rules.indexOf('DOMAIN-SUFFIX,youtube.com,keq-srv-0');
    final proxy = rules.indexOf(
      'DOMAIN-SUFFIX,discord.com,${MihomoConfigGen.proxyName}',
    );
    final block = rules.indexOf('DOMAIN-SUFFIX,ads.example,REJECT');
    expect(server, isNonNegative, reason: '$rules');
    expect(block, lessThan(server));
    expect(direct, lessThan(server));
    expect(server, lessThan(proxy));
    expect(rules, contains('GEOIP,de,keq-srv-0,no-resolve'));
  });

  test('к самому серверу маршрута — напрямую, как к активному', () {
    final rules = _rules(MihomoConfigGen.build(
      _active,
      _settings,
      socksPort: 2080,
      routeServers: const [_toDe],
    ));
    expect(rules, contains('DOMAIN,de.example,DIRECT'));
    expect(
      rules.indexOf('DOMAIN,de.example,DIRECT'),
      lessThan(rules.indexOf('DOMAIN-SUFFIX,youtube.com,keq-srv-0')),
    );
  });

  test('скачанные списки сервера — своим набором', () {
    final c = MihomoConfigGen.build(
      _active,
      _settings,
      socksPort: 2080,
      routeServers: [_toDe.copyWith(listDomains: ['list.example'])],
    );
    final providers = c['rule-providers'] as Map;
    expect(providers['keq-list-keq-srv-0'], {
      'type': 'inline',
      'behavior': 'domain',
      'payload': ['+.list.example'],
    });
    expect(_rules(c), contains('RULE-SET,keq-list-keq-srv-0,keq-srv-0'));
  });

  test('без маршрутов на другие серверы конфиг прежний', () {
    expect(
      MihomoConfigGen.generate(_active, _settings, socksPort: 2080),
      MihomoConfigGen.generate(
        _active,
        _settings,
        socksPort: 2080,
        routeServers: const [],
      ),
    );
  });

  test('готовый clash-конфиг: выход добавлен к выходам автора', () {
    final c = MihomoConfigGen.build(
      _clashYaml,
      _settings,
      socksPort: 2080,
      routeServers: const [_toDe],
    );
    expect(_proxies(c).map((p) => p['name']), ['NL', 'keq-srv-0']);
    final rules = _rules(c);
    expect(rules, contains('DOMAIN-SUFFIX,youtube.com,keq-srv-0'));
    expect(rules, contains('DOMAIN,de.example,DIRECT'));
    expect(rules.last, 'MATCH,Proxy');
  });
}
