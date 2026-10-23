import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/app_settings.dart';
import 'package:keqdroid/models/xray_core_settings.dart';
import 'package:keqdroid/utils/config_gen.dart';
import 'package:keqdroid/utils/mihomo_config_gen.dart';
import 'package:keqdroid/utils/proxy_chain.dart';
import 'package:keqdroid/utils/socks5_credentials.dart';

/// Ядро замера в TUN выходит мимо туннеля, иначе сниффинг туннеля подменяет
/// адрес REALITY на сайт маски раньше правила своих процессов (живой TUN,
/// 23.10.2026: сервер с маской store.teamfortress.com мерился до Valve).
///
/// Привязка обязана лечь ровно на те аутбаунды, что сами открывают сокет
/// наружу, и не тронуть больше ничего: без интерфейса конфиг байт в байт
/// прежний.
void main() {
  const uuid = '00000000-0000-4000-8000-000000000000';
  const iface = 'Ethernet';
  const settings = AppSettings();

  setUp(() => Socks5Credentials().init('u', 'p'));

  const reality = 'vless://$uuid@198.51.100.40:443?type=xhttp&security=reality'
      '&sni=decoy.example&pbk=publickey&sid=aabb&fp=chrome&path=%2Fx#de';
  const hysteria = 'hysteria2://password@198.51.100.41:443?sni=hy2.example#hy';
  final chain = ProxyChainConfig(
    name: 'chain',
    hops: [
      ProxyChainHop(
        config: 'vless://$uuid@198.51.100.42:443?type=tcp&security=reality'
            '&sni=decoy.example&pbk=publickey&sid=aabb&fp=chrome#hop1',
      ),
      const ProxyChainHop(
        config: 'trojan://pass@198.51.100.43:8443?sni=tr.example&type=ws&path=%2Fw#hop2',
      ),
    ],
  ).encode();
  final custom = jsonEncode({
    'outbounds': [
      {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': '198.51.100.44',
              'port': 443,
              'users': [
                {'id': uuid, 'encryption': 'none'},
              ],
            },
          ],
        },
        'streamSettings': {
          'network': 'tcp',
          'sockopt': {'dialerProxy': 'front'},
        },
      },
      {'tag': 'front', 'protocol': 'freedom', 'settings': <String, dynamic>{}},
      {
        'tag': 'author-bound',
        'protocol': 'freedom',
        'streamSettings': {
          'sockopt': {'interface': 'wlan-author'},
        },
      },
      {
        'tag': 'old-chain',
        'protocol': 'freedom',
        'proxySettings': {'tag': 'front'},
      },
      {'tag': 'drop', 'protocol': 'blackhole'},
    ],
  });

  Map<String, dynamic> xray(String input, {String? bind, AppSettings? s}) =>
      jsonDecode(
        ConfigGeneratorV2.generatePingConfig(
          input,
          s ?? settings,
          socksPort: 28150,
          httpInbound: true,
          outboundInterface: bind,
        ),
      ) as Map<String, dynamic>;

  Map<String, dynamic> byTag(Map<String, dynamic> config, String tag) =>
      (config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['tag'] == tag);

  Object? boundTo(Map<String, dynamic> outbound) =>
      ((outbound['streamSettings'] as Map?)?['sockopt'] as Map?)?['interface'];

  // убрать то, что добавляет привязка: остаток обязан совпасть с конфигом без неё
  Map<String, dynamic> unbind(Map<String, dynamic> config) {
    final copy = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    for (final outbound in (copy['outbounds'] as List).cast<Map<String, dynamic>>()) {
      final stream = outbound['streamSettings'] as Map<String, dynamic>?;
      final sockopt = stream?['sockopt'] as Map<String, dynamic>?;
      if (sockopt == null || sockopt['interface'] != iface) continue;
      sockopt.remove('interface');
      if (sockopt.isEmpty) stream!.remove('sockopt');
      if (stream!.isEmpty) outbound.remove('streamSettings');
    }
    return copy;
  }

  group('без интерфейса', () {
    test('конфиг тот же, что раньше', () {
      for (final input in [reality, hysteria, chain, custom]) {
        expect(
          ConfigGeneratorV2.generatePingConfig(input, settings,
              socksPort: 28150, httpInbound: true, outboundInterface: null),
          ConfigGeneratorV2.generatePingConfig(input, settings,
              socksPort: 28150, httpInbound: true),
        );
      }
    });
  });

  group('xray, с интерфейсом', () {
    test('сокет наружу привязан, заглушка нет', () {
      final config = xray(reality, bind: iface);
      expect(boundTo(byTag(config, 'proxy')), iface);
      expect(boundTo(byTag(config, 'direct')), iface);
      expect(byTag(config, 'block').containsKey('streamSettings'), isFalse);
    });

    test('кроме привязки не меняется ничего', () {
      for (final input in [reality, hysteria, chain, custom]) {
        expect(unbind(xray(input, bind: iface)), xray(input));
      }
    });

    test('hysteria2 тоже: она открывает UDP тем же dialer', () {
      expect(boundTo(byTag(xray(hysteria, bind: iface), 'proxy')), iface);
    });

    test('с фрагментацией сокет открывает fragment, а не proxy', () {
      final s = settings.copyWith(
        xrayCore: const XrayCoreSettings(fragmentEnabled: true),
      );
      final config = xray(reality.replaceFirst('security=reality', 'security=tls'),
          bind: iface, s: s);
      final proxy = byTag(config, 'proxy');
      expect((proxy['streamSettings'] as Map)['sockopt'], {'dialerProxy': 'fragment'});
      final fragment = byTag(config, 'fragment');
      expect(boundTo(fragment), iface);
      expect(((fragment['streamSettings'] as Map)['sockopt'] as Map)['domainStrategy'],
          'UseIPv4');
    });

    test('в цепочке наружу выходит только первое звено', () {
      final config = xray(chain, bind: iface);
      expect(boundTo(byTag(config, 'proxy')), isNull);
      expect(boundTo(byTag(config, 'chain-0')), iface);
    });

    test('готовый JSON: свой интерфейс автора и proxySettings не трогаем', () {
      final config = xray(custom, bind: iface);
      expect(boundTo(byTag(config, 'proxy')), isNull);
      expect(boundTo(byTag(config, 'front')), iface);
      expect(boundTo(byTag(config, 'author-bound')), 'wlan-author');
      expect(byTag(config, 'old-chain').containsKey('streamSettings'), isFalse);
      expect(byTag(config, 'drop').containsKey('streamSettings'), isFalse);
    });

    test('имя сети по-русски доезжает как есть', () {
      const ru = 'Беспроводная сеть';
      expect(boundTo(byTag(xray(reality, bind: ru), 'proxy')), ru);
    });
  });

  group('mihomo', () {
    Map<String, dynamic> mihomo({String? bind}) => jsonDecode(
          MihomoConfigGen.generatePingConfig(
            reality.replaceFirst('type=xhttp', 'type=tcp'),
            settings,
            socksPort: 28150,
            httpInbound: true,
            outboundInterface: bind,
          ),
        ) as Map<String, dynamic>;

    test('без интерфейса ключа нет', () {
      expect(mihomo().containsKey('interface-name'), isFalse);
    });

    test('с интерфейсом общий interface-name, остальное как было', () {
      final bound = mihomo(bind: iface);
      expect(bound['interface-name'], iface);
      expect(Map.of(bound)..remove('interface-name'), mihomo());
    });
  });
}
