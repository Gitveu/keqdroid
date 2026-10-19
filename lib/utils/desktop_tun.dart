import 'dart:io';

import '../models/tun_settings.dart';
import '../tunnel/app_routing_mode.dart';

const kTunInterfaceAddress = '172.19.0.1';

const kTunInterfacePrefix = '$kTunInterfaceAddress/30';

const kTunInterfaceIpv6Prefix = 'fdfe:dcba:9876::1/126';

// резолвер системы на Windows, следующий адрес в /30. держать в паре с ConfigGeneratorV2._androidTunDns
const kTunDnsAddress = '172.19.0.2';

// wintun считает GUID из имени, у чужого клиента с тем же именем адаптер общий
const kTunInterfaceName = 'tun-keqdis';

class DesktopTunOptions {
  const DesktopTunOptions({
    required this.windows,
    required this.mtu,
    this.autoRoute = true,
    this.strictRoute = false,
    this.captureIpv6 = false,
    this.udpTimeoutSec = TunSettings.defaultUdpTimeoutSec,
    this.routingMode = AppRoutingMode.allProxy,
    this.managedProcessNames = const [],
    this.appProcessName = '',
    this.systemResolvers = const [],
  });

  final bool windows;
  final int mtu;
  final bool autoRoute;
  final bool strictRoute;
  final bool captureIpv6;
  final int udpTimeoutSec;
  final AppRoutingMode routingMode;
  final List<String> managedProcessNames;
  final String appProcessName;

  final List<String> systemResolvers;
}

// маршрут xray на Linux кладёт в main рядом с LAN, а sing-tun уводил в туннель порт 53 на любой адрес.
// без этих /32 запросы к DNS роутера шли мимо перехвата, и не работали свои DNS, hosts и Fake IP
List<String> linuxSystemResolvers({bool ipv6 = false}) {
  final String text;
  try {
    text = File('/etc/resolv.conf').readAsStringSync();
  } catch (_) {
    return const [];
  }
  return parseResolvConf(text, ipv6: ipv6);
}

List<String> parseResolvConf(String text, {bool ipv6 = false}) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts.first != 'nameserver') continue;
    final address = InternetAddress.tryParse(parts[1].split('%').first);
    if (address == null || address.isLoopback || address.isLinkLocal) continue;
    if (address.type == InternetAddressType.IPv6 && !ipv6) continue;
    final cidr =
        '${address.address}/${address.type == InternetAddressType.IPv6 ? 128 : 32}';
    if (!out.contains(cidr)) out.add(cidr);
  }
  return out;
}
