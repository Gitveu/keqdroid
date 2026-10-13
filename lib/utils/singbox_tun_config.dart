import 'dart:convert';
import 'dart:io';

import '../models/app_settings.dart';
import '../models/tun_settings.dart';
import '../models/xray_core_settings.dart';
import '../tunnel/app_routing_mode.dart';
import 'fake_ip.dart';
import 'process_name_utils.dart';
import 'routing_entry.dart';
import 'rule_lists.dart';

const kTunInterfaceAddress = '172.19.0.1';

// /30: system-стеку sing-box нужен следующий адрес в префиксе
const kTunInterfacePrefix = '$kTunInterfaceAddress/30';

const kTunInterfaceIpv6Prefix = 'fdfe:dcba:9876::1/126';

const kLocalIpv6Cidrs = ['::1/128', 'fe80::/10', 'fc00::/7', 'ff00::/8'];

// без имени sing-box берёт tun0, а wintun считает GUID как MD5(wintun + имя), один на всех клиентов
const kTunInterfaceName = 'tun-keqdis';

// особые выходы sing-box объявил устаревшими. drop, а не умолчание: оно отвечало бы на UDP ICMP-ошибкой
const kSingboxBlockAction = {'action': 'reject', 'method': 'drop'};

// домен сюда попадает при неудачном резолве адреса сервера, а ip_cidr его не принимает и роняет конфиг
bool _isRoutableIpTarget(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return false;
  final slash = value.lastIndexOf('/');
  if (slash < 0) return InternetAddress.tryParse(value) != null;
  final address = InternetAddress.tryParse(value.substring(0, slash));
  if (address == null) return false;
  final bits = int.tryParse(value.substring(slash + 1));
  if (bits == null) return false;
  final max = address.type == InternetAddressType.IPv6 ? 128 : 32;
  return bits >= 0 && bits <= max;
}

// только строки sing-box: баннер встроенного xray печатается раньше инбаундов, и Подключено показывалось за 20 с до трафика
bool singboxTunReady(String rawLog) {
  final text = rawLog.toLowerCase();
  return text.contains('sing-box started') ||
      text.contains('keqrnel started') ||
      text.contains('started at ');
}

const _gvisorStacks = {TunSettings.stackGvisor, TunSettings.stackMixed};

// ядро без with_gvisor на gvisor и mixed падает на старте, system есть в любой сборке.
// null значит неизвестно, тогда выбор пользователя не трогаем
({String config, String? downgradedFrom}) applyTunStackFallback(
  String singboxConfig, {
  required bool? gvisorAvailable,
}) {
  if (gvisorAvailable != false) {
    return (config: singboxConfig, downgradedFrom: null);
  }
  final Map<String, dynamic> box;
  try {
    box = jsonDecode(singboxConfig) as Map<String, dynamic>;
  } catch (_) {
    return (config: singboxConfig, downgradedFrom: null);
  }
  final inbounds = box['inbounds'];
  if (inbounds is! List) return (config: singboxConfig, downgradedFrom: null);

  String? downgradedFrom;
  for (final raw in inbounds) {
    if (raw is! Map) continue;
    if (raw['type'] != 'tun') continue;
    final stack = raw['stack']?.toString();
    if (stack == null || !_gvisorStacks.contains(stack)) continue;
    raw['stack'] = TunSettings.stackSystem;
    // endpoint_independent_nat работает только на gvisor и mixed
    raw.remove('endpoint_independent_nat');
    downgradedFrom = stack;
  }
  if (downgradedFrom == null) {
    return (config: singboxConfig, downgradedFrom: null);
  }
  return (
    config: const JsonEncoder.withIndent('  ').convert(box),
    downgradedFrom: downgradedFrom,
  );
}

class SingBoxTunConfigGen {
  static String generate({
    required int localSocksPort,
    required String socksUsername,
    required String socksPassword,
    required String serverIpToExclude,
    required AppSettings settings,
    List<String> managedProcessNames = const [],
    AppRoutingMode routingMode = AppRoutingMode.allProxy,
    String appProcessName = '',
    // ОС параметром: фикстура, снятая на Windows, иначе падала бы на linux-раннере
    bool? windows,
    bool hostHasIpv6 = false,
  }) {
    final isWindows = windows ?? Platform.isWindows;
    // и запятая, и перевод строки: сплит по запятой склеивал строки в один токен
    List<String> parseList(String s) => s
        .split(RegExp(r'[\r\n,]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !isRuleListUrl(e))
        .toList();

    Map<String, dynamic> buildProxyDnsServer() {
      final customDns = customDnsList(settings);

      // по умолчанию DoH через туннель: многие хостеры режут исходящий 53, и DNS через прокси умирал на EOF
      Map<String, dynamic> defaultDoh() => {
            'tag': 'proxy-dns',
            'type': 'https',
            'server': '1.1.1.1',
            'detour': 'proxy',
          };

      if (customDns.isEmpty) return defaultDoh();

      // сырую xray-строку sing-box не примет (exit code 2). берём первый переводимый адрес,
      // иначе localhost в начале списка уводил в дефолт весь список
      for (final address in customDns) {
        final server = _singBoxDnsServerFromXray(address);
        if (server != null) return server;
      }
      return defaultDoh();
    }

    ({
      List<String> domain,
      List<String> domainSuffix,
      List<String> domainRegex,
    }) classifyDomains(List<String> domains) {
      final exact = <String>[];
      final suffix = <String>[];
      final regex = <String>[];

      for (final raw in domains) {
        final cleaned = raw.trim().toLowerCase();
        if (cleaned.isEmpty) continue;

        if (cleaned.startsWith('full:')) {
          final v = cleaned.substring('full:'.length).trim();
          if (v.isNotEmpty) exact.add(v);
          continue;
        }
        if (cleaned.startsWith('regexp:')) {
          final v = cleaned.substring('regexp:'.length).trim();
          if (v.isNotEmpty) regex.add(v);
          continue;
        }
        if (cleaned.startsWith('domain:')) {
          final v = cleaned.substring('domain:'.length).trim();
          if (v.isNotEmpty) suffix.add(v.startsWith('.') ? v.substring(1) : v);
          continue;
        }
        if (cleaned.startsWith('geosite:')) {
          // sing-box не читает .dat, а domain_suffix: telegram не ловит ни telegram.org, ни t.me. geo оставляем встроенному xray
          continue;
        }
        if (cleaned.startsWith('.')) {
          final v = cleaned.substring(1).trim();
          if (v.isNotEmpty) suffix.add(v);
          continue;
        }
        if (!cleaned.contains('.')) {
          suffix.add(cleaned);
          continue;
        }
        suffix.add(cleaned);
      }

      return (domain: exact, domainSuffix: suffix, domainRegex: regex);
    }

    void addDomainRule({
      required List<Map<String, dynamic>> targetRules,
      required List<String> sourceDomains,
      required String outbound,
    }) {
      final parts = classifyDomains(sourceDomains);
      if (parts.domain.isEmpty &&
          parts.domainSuffix.isEmpty &&
          parts.domainRegex.isEmpty) {
        return;
      }
      targetRules.add({
        if (parts.domain.isNotEmpty) 'domain': parts.domain,
        if (parts.domainSuffix.isNotEmpty) 'domain_suffix': parts.domainSuffix,
        if (parts.domainRegex.isNotEmpty) 'domain_regex': parts.domainRegex,
        if (outbound == 'block') ...kSingboxBlockAction else 'outbound': outbound,
      });
    }

    final directSplit = splitDomainsAndIps(parseList(settings.directRules));
    final proxySplit = splitDomainsAndIps(parseList(settings.proxyRules));
    final blockedSplit = splitDomainsAndIps(parseList(settings.blockedRules));

    final directDomains = directSplit.domains;
    final blockedDomains = blockedSplit.domains;
    final proxyDomains = proxySplit.domains;

    bool isIPv4OrCidr(String value) {
      final v = value.trim();
      final ipV4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
      final cidrV4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$');
      return ipV4.hasMatch(v) || cidrV4.hasMatch(v);
    }

    bool isIPv6OrCidr(String value) {
      final v = value.trim();
      final ipV6 = RegExp(r'^[0-9a-fA-F:]+$');
      final cidrV6 = RegExp(r'^[0-9a-fA-F:]+/\d{1,3}$');
      return ipV6.hasMatch(v) || cidrV6.hasMatch(v);
    }

    // geoip отдаём встроенному xray: ip_cidr принимает только префикс или адрес, и geoip:private ронял весь конфиг
    List<String> ipsForSingBox(List<String> ips) => ips
        .where((entry) => isIPv4OrCidr(entry) || isIPv6OrCidr(entry))
        .map((e) => e.trim())
        .toList();

    final directIpsForSingBox = ipsForSingBox(directSplit.ips);
    final proxyIpsForSingBox = ipsForSingBox(proxySplit.ips);
    final blockedIpsForSingBox = ipsForSingBox(blockedSplit.ips);

    bool isGeoToken(String value) {
      final v = value.trim().toLowerCase();
      return v.startsWith('geosite:') || v.startsWith('geoip:');
    }

    final needsXrayForGeo = [
      ...proxySplit.domains,
      ...proxySplit.ips,
      ...blockedSplit.domains,
      ...blockedSplit.ips,
    ].any(isGeoToken);

    const tunInboundTag = 'tun-in';

    final captureIpv6 = settings.tun.blockIpv6Leak && hostHasIpv6;

    final fakeIp = settings.fakeIp;

    final rules = <Map<String, dynamic>>[
      {
        'inbound': [tunInboundTag],
        'action': 'sniff',
      },
      {'protocol': 'dns', 'action': 'hijack-dns'},
      // по порту тоже: не опознанный снифером запрос падает в direct подсети TUN, а резолвер системы 172.19.0.2 лежит в ней
      {'port': 53, 'action': 'hijack-dns'},
      // icmp через socks не пройдёт, отправляем локально
      {'protocol': 'icmp', 'outbound': 'direct'},
      {'ip_cidr': ['172.19.0.0/30'], 'outbound': 'direct'},
    ];

    // свои ядра и само приложение мимо TUN, раньше сплита. на Linux имя без .exe, sing-box берёт его из /proc/<pid>/exe
    final exe = isWindows ? '.exe' : '';
    final bypassProcessNames = <String>{
      // реальные бинари: отдельных xray и sing-box на десктопе больше нет, правило по ним не совпадало,
      // и без правила по IP сервера соединение ядра шло по кругу
      'keqrnel$exe',
      'mihomo$exe',
      'xray$exe',
      'sing-box$exe',
      // варианты, а не toLowerCase(): process_name сравнивается map-lookup'ом с регистром
      ...processNameMatchVariants(appProcessName.trim()),
    }.toList();
    rules.add({
      'process_name': bypassProcessNames,
      'outbound': 'direct',
    });

    if (routingMode == AppRoutingMode.allProxy) {
      rules.add({
        'process_name': [
          'tailscaled$exe',
          'wireguard$exe',
          'openvpn$exe',
          if (isWindows) 'openvpn-gui.exe',
        ],
        'outbound': 'direct',
      });
    }

    final splitOutbound = switch (routingMode) {
      AppRoutingMode.onlySelected => 'proxy',
      AppRoutingMode.allExceptSelected => 'direct',
      AppRoutingMode.allProxy => null,
    };
    if (splitOutbound != null) {
      final paths = <String>[];
      for (final process in managedProcessNames) {
        if (isProcessPathEntry(process)) {
          paths.add(process.trim());
          continue;
        }
        final variants = processNameMatchVariants(process);
        if (variants.isEmpty) continue;
        rules.add({'process_name': variants, 'outbound': splitOutbound});
      }
      // process_path сравнивает строку точно, а регистр пути у системы и диалога на Windows расходится
      if (paths.isNotEmpty) {
        rules.add({
          if (isWindows)
            'process_path_regex': [
              for (final path in paths) '(?i)^${processPathPattern(path)}\$',
            ]
          else
            'process_path': paths,
          'outbound': splitOutbound,
        });
      }
    }

    // невыбранные идут мимо туннеля целиком, как на Android. без единого имени списки остаются, иначе всё мимо VPN
    final selectedOnly = routingMode == AppRoutingMode.onlySelected &&
        managedProcessNames
            .any((name) => processNameMatchVariants(name).isNotEmpty);
    if (!selectedOnly) {
      if (blockedDomains.isNotEmpty) {
        addDomainRule(
          targetRules: rules,
          sourceDomains: blockedDomains,
          outbound: 'block',
        );
      }
      // с fake-ip настоящий адрес достаём, только если есть правила по IP, иначе каждое соединение снова ждёт DNS
      if (fakeIp &&
          (blockedIpsForSingBox.isNotEmpty ||
              directIpsForSingBox.isNotEmpty ||
              proxyIpsForSingBox.isNotEmpty)) {
        rules.add({'action': 'resolve', 'server': 'proxy-dns'});
      }
      if (blockedIpsForSingBox.isNotEmpty) {
        rules.add({'ip_cidr': blockedIpsForSingBox, ...kSingboxBlockAction});
      }

      // только настоящий адрес: при неудачном резолве сюда приезжает домен, а в ip_cidr он роняет весь конфиг.
      // круг в этом случае ловит правило по имени процесса выше
      if (_isRoutableIpTarget(serverIpToExclude)) {
        // /32 на IPv6 это треть интернета мимо туннеля, маску считаем по семейству
        final cidrs = serverIpToExclude.contains('/')
            ? [serverIpToExclude]
            : ['$serverIpToExclude/${serverIpToExclude.contains(':') ? 128 : 32}'];
        rules.add({'ip_cidr': cidrs, 'outbound': 'direct'});
      }

      if (directDomains.isNotEmpty) {
        addDomainRule(
          targetRules: rules,
          sourceDomains: directDomains,
          outbound: 'direct',
        );
      }

      if (directIpsForSingBox.isNotEmpty) {
        rules.add({'ip_cidr': directIpsForSingBox, 'outbound': 'direct'});
      }

      rules.add({
        'ip_cidr': [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '127.0.0.0/8',
          if (captureIpv6) ...kLocalIpv6Cidrs,
        ],
        'outbound': 'direct',
      });

      if (proxyDomains.isNotEmpty) {
        addDomainRule(
          targetRules: rules,
          sourceDomains: proxyDomains,
          outbound: 'proxy',
        );
      }
      if (proxyIpsForSingBox.isNotEmpty) {
        rules.add({'ip_cidr': proxyIpsForSingBox, 'outbound': 'proxy'});
      }

      // после пользовательских правил. закрываем, а не проксируем: закрытый выход Happy Eyeballs откатывает на IPv4 за миллисекунды
      if (captureIpv6) {
        rules.add({'ip_cidr': ['::/0'], ...kSingboxBlockAction});
      }
    }

    final finalOutbound = switch (settings.finalOutbound) {
      AppSettings.finalOutboundDirect => 'direct',
      AppSettings.finalOutboundBlock => 'block',
      _ => 'proxy',
    };
    var routeFinal = switch (routingMode) {
      AppRoutingMode.onlySelected => 'direct',
      AppRoutingMode.allExceptSelected => 'proxy',
      AppRoutingMode.allProxy => finalOutbound,
    };

    // при финале не proxy geo-правила иначе не срабатывали: остаток отдаём встроенному xray, его catch-all тот же.
    // только в allProxy, при сплите финал значит невыбранные напрямую
    if (needsXrayForGeo &&
        routingMode == AppRoutingMode.allProxy &&
        routeFinal != 'proxy') {
      routeFinal = 'proxy';
    }

    final proxyOutbound = <String, dynamic>{
      'type': 'socks',
      'tag': 'proxy',
      'server': '127.0.0.1',
      'server_port': localSocksPort,
      'version': '5',
      'username': socksUsername,
      'password': socksPassword,
    };

    // direct-домены системным резолвером: корпоративных и LAN-зон публичный DoH не знает
    final directDnsParts = classifyDomains(directDomains);
    final fakeIpExclusions = classifyDomains(fakeIpFilterAsRules());
    final hosts = hostsServerEntries(settings);
    final dnsPolicies = policyDnsServers(settings);
    final dnsRules = <Map<String, dynamic>>[
      // свои адреса первым правилом, раньше любого резолвера
      if (hosts.isNotEmpty)
        {'domain': hosts.keys.toList(), 'server': hostsServerTag},
      for (final policy in dnsPolicies)
        if (policy.mask.startsWith('*.'))
          {
            'domain': [policy.mask.substring(2)],
            'domain_suffix': [policy.mask.substring(1)],
            'server': policy.tag,
          }
        else
          {
            'domain': [policy.mask],
            'server': policy.tag,
          },
      if (settings.xrayCore.dnsSplitDirectDomains &&
          (directDnsParts.domain.isNotEmpty ||
              directDnsParts.domainSuffix.isNotEmpty ||
              directDnsParts.domainRegex.isNotEmpty))
        {
          if (directDnsParts.domain.isNotEmpty)
            'domain': directDnsParts.domain,
          if (directDnsParts.domainSuffix.isNotEmpty)
            'domain_suffix': directDnsParts.domainSuffix,
          if (directDnsParts.domainRegex.isNotEmpty)
            'domain_regex': directDnsParts.domainRegex,
          'server': 'local-dns',
        },
      // fake-ip последним. TTL секунда, как у mihomo: с умолчанием 600 после отключения система ходила бы в никуда
      if (fakeIp) ...[
        {
          if (fakeIpExclusions.domain.isNotEmpty)
            'domain': fakeIpExclusions.domain,
          if (fakeIpExclusions.domainSuffix.isNotEmpty)
            'domain_suffix': fakeIpExclusions.domainSuffix,
          if (fakeIpExclusions.domainRegex.isNotEmpty)
            'domain_regex': fakeIpExclusions.domainRegex,
          'server': 'proxy-dns',
        },
        {
          'query_type': ['A'],
          'server': fakeIpServerTag,
          'rewrite_ttl': 1,
        },
      ],
    ];

    final tun = settings.tun;
    // mips умеет только mihomo, у sing-box чужое имя стека роняет весь конфиг. настройку не трогаем
    final stack = tun.stack == TunSettings.stackMips
        ? TunSettings.defaultStack
        : tun.stack;
    final tunInbound = <String, dynamic>{
      'type': 'tun',
      'tag': tunInboundTag,
      'mtu': tun.mtu,
      // второй адрес и есть захват IPv6: маршруты ставятся только на интерфейс с IPv6-адресом
      'address': [kTunInterfacePrefix, if (captureIpv6) kTunInterfaceIpv6Prefix],
      'auto_route': tun.autoRoute,
      'strict_route': tun.strictRouteEnabled(windows: isWindows),
      'stack': stack,
      if (tun.endpointIndependentNat && stack != TunSettings.stackSystem)
        'endpoint_independent_nat': true,
      if (tun.udpTimeoutSec != TunSettings.defaultUdpTimeoutSec)
        'udp_timeout': '${tun.udpTimeoutSec}s',
    };
    tunInbound['interface_name'] = kTunInterfaceName;

    // в final действие не записать, поэтому блок остатка последним правилом без условий
    final blockRest = routeFinal == 'block';
    if (blockRest) rules.add({...kSingboxBlockAction});

    final map = <String, dynamic>{
      'log': {
        'level': 'info',
        'timestamp': true,
      },
      'dns': {
        'servers': [
          {'tag': 'local-dns', 'type': 'local'},
          if (hosts.isNotEmpty)
            {
              'tag': hostsServerTag,
              'type': 'hosts',
              'predefined': hosts,
            },
          for (final policy in dnsPolicies) policy.server,
          buildProxyDnsServer(),
          if (fakeIp)
            {
              'tag': fakeIpServerTag,
              'type': 'fakeip',
              'inet4_range': kFakeIpRange,
            },
        ],
        if (dnsRules.isNotEmpty) 'rules': dnsRules,
        // только A: AAAA тут либо мёртвое соединение, либо утечка
        'strategy': 'ipv4_only',
        if (settings.xrayCore.dnsDisableCache) 'disable_cache': true,
        // через туннель, а не системный резолвер: иначе DNS перехватывает MagicDNS Tailscale (100.100.100.100)
        'final': 'proxy-dns',
      },
      'inbounds': [tunInbound],
      'outbounds': [
        proxyOutbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'auto_detect_interface': true,
        'find_process': true,
        'default_domain_resolver': 'proxy-dns',
        'rules': rules,
        if (!blockRest) 'final': routeFinal,
      },
    };

    return const JsonEncoder.withIndent('  ').convert(map);
  }

  static const hostsServerTag = 'keq-hosts';

  static const fakeIpServerTag = 'keq-fakeip';

  // правило уводит в один тег, поэтому берём первый адрес, который ядро поднимет
  static List<({String tag, Map<String, dynamic> server, String mask})>
      policyDnsServers(AppSettings settings) {
    final parsed = XrayCoreSettings.parseDnsPolicy(settings.xrayCore.dnsPolicy);
    final out = <({String tag, Map<String, dynamic> server, String mask})>[];
    var index = 0;
    for (final entry in parsed.entries.entries) {
      for (final address in entry.value) {
        final tag = 'keq-policy-$index';
        final server = _singBoxDnsServerFromXray(address, tag: tag);
        if (server == null) continue;
        out.add((tag: tag, server: server, mask: entry.key));
        index++;
        break;
      }
    }
    return out;
  }

  // у hosts-сервера sing-box лукап точный, масок и псевдонимов он не знает
  static Map<String, List<String>> hostsServerEntries(AppSettings settings) {
    final out = <String, List<String>>{};
    final parsed = XrayCoreSettings.parseDnsHosts(settings.xrayCore.dnsHosts);
    for (final entry in parsed.entries.entries) {
      if (entry.key.startsWith('*.')) continue;
      if (!entry.value.every(_isIpLiteral)) continue;
      out[entry.key] = entry.value;
    }
    return out;
  }

  static List<String> ignoredHostsEntries(AppSettings settings) {
    final parsed = XrayCoreSettings.parseDnsHosts(settings.xrayCore.dnsHosts);
    return [
      for (final entry in parsed.entries.entries)
        if (entry.key.startsWith('*.') || !entry.value.every(_isIpLiteral))
          '${entry.key} ${entry.value.join(', ')}',
    ];
  }

  static bool _isIpLiteral(String value) =>
      InternetAddress.tryParse(value) != null;

  static List<String> customDnsList(AppSettings settings) =>
      !settings.xrayCore.dnsUseCustom
          ? const <String>[]
          : settings.xrayCore.dnsServers
              .split(RegExp(r'[\n,]+'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();

  // dns.final принимает один тег, отката на следующий сервер у ядра нет, работает первый пригодный
  static List<String> ignoredCustomDnsServers(AppSettings settings) {
    var used = false;
    final ignored = <String>[];
    for (final address in customDnsList(settings)) {
      if (!used && _singBoxDnsServerFromXray(address) != null) {
        used = true;
        continue;
      }
      ignored.add(address);
    }
    return ignored;
  }

  // +local снимает detour, и сервер идёт мимо туннеля. голый адрес остаётся проксированным, как у xray
  static Map<String, dynamic>? _singBoxDnsServerFromXray(
    String raw, {
    String tag = 'proxy-dns',
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();

    if (lower == 'localhost' || lower == 'fakedns' || lower.startsWith('dhcp')) {
      return null;
    }

    // тег исторический: proxy-dns и когда идёт напрямую, на него смотрят dns.final и default_domain_resolver
    Map<String, dynamic> server(String type, String host, int? port,
            {String? path, bool local = false}) =>
        {
          'tag': tag,
          'type': type,
          'server': host,
          'server_port': ?port,
          if (path != null && path.isNotEmpty && path != '/') 'path': path,
          if (!local) 'detour': 'proxy',
        };

    final schemeMatch = RegExp(r'^([a-z][a-z0-9.+-]*)://').firstMatch(lower);
    if (schemeMatch != null) {
      final scheme = schemeMatch.group(1)!;
      final base = scheme.split('+').first;
      final local = scheme.endsWith('+local');
      final uri = Uri.tryParse(trimmed);
      if (uri == null || uri.host.isEmpty) return null;
      final port = uri.hasPort ? uri.port : null;
      switch (base) {
        case 'https':
        case 'h2c':
          return server('https', uri.host, port, path: uri.path, local: local);
        case 'tls':
        case 'dot':
          return server('tls', uri.host, port, local: local);
        case 'quic':
        case 'doq':
          // type: quic в ядре не зарегистрирован, и конфиг не разбирается. берём DoT к тому же хосту
          return server('tls', uri.host, null, local: local);
        case 'tcp':
          return server('tcp', uri.host, port, local: local);
        case 'udp':
        case 'dns':
          // UDP через SOCKS ненадёжен
          return server('tcp', uri.host, port, local: local);
        default:
          return null;
      }
    }

    String host = trimmed;
    int? port;
    final bracketed = RegExp(r'^\[([0-9a-fA-F:]+)\]:(\d+)$').firstMatch(trimmed);
    if (bracketed != null) {
      host = bracketed.group(1)!;
      port = int.parse(bracketed.group(2)!);
    } else if (RegExp(r'^[^:]+:\d+$').hasMatch(trimmed)) {
      // ровно одно двоеточие с числом это порт, иначе голый IPv6
      final idx = trimmed.lastIndexOf(':');
      host = trimmed.substring(0, idx).trim();
      port = int.parse(trimmed.substring(idx + 1));
    }
    if (host.isEmpty) return null;
    return server('tcp', host, port);
  }
}
