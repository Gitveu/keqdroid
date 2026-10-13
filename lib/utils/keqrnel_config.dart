import 'dart:convert';

import 'singbox_tun_config.dart' show kSingboxBlockAction;

class KeqrnelConfig {
  KeqrnelConfig._();

  static Map<String, dynamic> _clashApi(int port, String? secret) => {
        'external_controller': '127.0.0.1:$port',
        if (secret != null && secret.isNotEmpty) 'secret': secret,
      };

  static String fromChain({
    required String singboxConfig,
    required String xrayConfig,
    required bool windows,
    int? clashApiPort,
    String? clashApiSecret,
  }) {
    final box = jsonDecode(singboxConfig) as Map<String, dynamic>;
    final xray = jsonDecode(xrayConfig) as Map<String, dynamic>;

    if (clashApiPort != null) {
      final experimental = Map<String, dynamic>.from(
        (box['experimental'] as Map<String, dynamic>?) ?? const {},
      );
      experimental['clash_api'] = _clashApi(clashApiPort, clashApiSecret);
      box['experimental'] = experimental;
    }

    final outbounds = box['outbounds'] as List;
    var swapped = false;
    for (var i = 0; i < outbounds.length; i++) {
      final ob = outbounds[i] as Map<String, dynamic>;
      if (ob['tag'] == 'proxy') {
        outbounds[i] = _xrayOutbound(xray);
        swapped = true;
        break;
      }
    }
    if (!swapped) {
      throw const FormatException(
        'singbox config has no outbound tagged "proxy" to replace',
      );
    }

    // трафик самого keqrnel мимо TUN, иначе коннект встроенного xray к серверу завернётся в петлю
    final route = box['route'] as Map<String, dynamic>;
    final rules = route['rules'] as List;
    rules.insert(0, <String, dynamic>{
      'process_name': [windows ? 'keqrnel.exe' : 'keqrnel'],
      'outbound': 'direct',
    });

    return const JsonEncoder.withIndent('  ').convert(box);
  }

  static String wrapXray(String xrayConfig) {
    final xray = jsonDecode(xrayConfig) as Map<String, dynamic>;
    final inbounds = _singboxInboundsFromXray(xray);
    final outbound = _xrayOutbound(xray);
    xray.remove('inbounds');
    final box = <String, dynamic>{
      'log': {'level': 'warn'},
      if (inbounds.isNotEmpty) 'inbounds': inbounds,
      'outbounds': [outbound],
      'route': {'final': 'proxy'},
    };
    return const JsonEncoder.withIndent('  ').convert(box);
  }

  // соединения приходят в xray от sing-box, мимо его входов, а под TUN ещё и
  // адресом вместо домена: без сниффинга в keqrnel правила xray по доменам и
  // geosite их не видят
  static Map<String, dynamic> _xrayOutbound(Map<String, dynamic> xray) {
    final inbounds = xray['inbounds'];
    Object? sniffing;
    if (inbounds is List) {
      for (final inbound in inbounds) {
        if (inbound is Map && inbound['sniffing'] is Map) {
          sniffing = inbound['sniffing'];
          break;
        }
      }
    }
    return {
      'type': 'xray',
      'tag': 'proxy',
      'xray': xray,
      'sniffing': ?sniffing,
    };
  }

  static List<Map<String, dynamic>> _singboxInboundsFromXray(
    Map<String, dynamic> xray,
  ) {
    final rawInbounds = xray['inbounds'];
    if (rawInbounds is! List) return const [];

    final result = <Map<String, dynamic>>[];
    for (final raw in rawInbounds) {
      if (raw is! Map) continue;
      final protocol = raw['protocol']?.toString().toLowerCase();
      if (protocol != 'socks' && protocol != 'http') continue;

      final port = (raw['port'] as num?)?.toInt();
      if (port == null || port <= 0) continue;

      final inbound = <String, dynamic>{
        'type': protocol,
        'tag': raw['tag']?.toString() ?? '$protocol-in',
        'listen': raw['listen']?.toString() ?? '127.0.0.1',
        'listen_port': port,
      };

      final settings = raw['settings'];
      if (settings is Map) {
        final accounts = settings['accounts'];
        if (accounts is List && accounts.isNotEmpty) {
          final users = <Map<String, dynamic>>[];
          for (final account in accounts) {
            if (account is! Map) continue;
            final username = account['user']?.toString() ?? '';
            final password = account['pass']?.toString() ?? '';
            if (username.isEmpty || password.isEmpty) continue;
            users.add({'username': username, 'password': password});
          }
          if (users.isNotEmpty) inbound['users'] = users;
        }
      }

      result.add(inbound);
    }
    return result;
  }

  // поиск процесса только в дебаг-режиме: это syscall на каждое соединение
  static String proxyWithStats({
    required String xrayConfig,
    required int socksPort,
    required int httpPort,
    required int clashPort,
    String? clashApiSecret,
    bool findProcess = false,
  }) {
    final xray = jsonDecode(xrayConfig) as Map<String, dynamic>;
    final lanInbounds = _singboxInboundsFromXray(xray)
        .where((i) => !const {'127.0.0.1', '::1', 'localhost'}.contains(i['listen']))
        .toList();
    final lanTags = [for (final i in lanInbounds) i['tag'] as String];
    final outbound = _xrayOutbound(xray);
    xray.remove('inbounds');

    final box = <String, dynamic>{
      'log': {'level': 'warn'},
      'experimental': {
        'clash_api': _clashApi(clashPort, clashApiSecret),
      },
      'inbounds': [
        {
          'type': 'socks',
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'listen_port': socksPort,
        },
        {
          'type': 'http',
          'tag': 'http-in',
          'listen': '127.0.0.1',
          'listen_port': httpPort,
        },
        ...lanInbounds,
      ],
      'outbounds': [
        outbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        if (findProcess) 'find_process': true,
        // зеркало source-правил xray: в LAN-инбаунды только с частных адресов
        if (lanTags.isNotEmpty)
          'rules': [
            {
              'inbound': lanTags,
              'source_ip_cidr': _lanAllowedSources,
              'outbound': 'proxy',
            },
            {'inbound': lanTags, ...kSingboxBlockAction},
          ],
        'final': 'proxy',
      },
    };
    return const JsonEncoder.withIndent('  ').convert(box);
  }

  static const _lanAllowedSources = [
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '169.254.0.0/16',
    '127.0.0.0/8',
  ];
}
