import 'dart:convert';

class TunSettings {
  final String stack;
  final int mtu;
  // auto выключает strict_route на Windows: с ним ломаются маршруты при втором VPN вроде Tailscale
  final String strictRoute;
  final int udpTimeoutSec;
  final bool autoRoute;

  final bool blockIpv6Leak;

  const TunSettings({
    this.stack = defaultStack,
    this.mtu = defaultMtu,
    this.strictRoute = strictRouteAuto,
    this.udpTimeoutSec = defaultUdpTimeoutSec,
    this.autoRoute = true,
    this.blockIpv6Leak = true,
  });

  static const stackSystem = 'system';
  static const stackGvisor = 'gvisor';
  static const stackMixed = 'mixed';

  // только у mihomo: sing-tun на таком имени отвергает весь конфиг (unknown stack)
  static const stackMips = 'mips';

  static const stacks = [stackSystem, stackGvisor, stackMixed, stackMips];

  // system на Windows держится на правиле фаервола, sing-tun глотает ошибку его создания,
  // и TUN поднимается без трафика
  static const defaultStack = stackGvisor;

  static const strictRouteAuto = 'auto';
  static const strictRouteOn = 'on';
  static const strictRouteOff = 'off';
  static const strictRouteModes = [strictRouteAuto, strictRouteOn, strictRouteOff];

  static const defaultMtu = 9000;
  static const minMtu = 576;
  static const maxMtu = 65535;

  static const _legacyDefaultStack = stackSystem;
  static const _legacyDefaultMtu = 1400;

  static const _defaultsVersion = 2;

  static const defaultUdpTimeoutSec = 300;
  static const minUdpTimeoutSec = 10;
  static const maxUdpTimeoutSec = 86400;

  bool get isDefault => this == const TunSettings();

  bool strictRouteEnabled({required bool windows}) => switch (strictRoute) {
        strictRouteOn => true,
        strictRouteOff => false,
        _ => !windows,
      };

  static String normalizeStack(String? raw) {
    final v = raw?.trim().toLowerCase();
    return stacks.contains(v) ? v! : defaultStack;
  }

  static String normalizeStrictRoute(String? raw) {
    final v = raw?.trim().toLowerCase();
    return strictRouteModes.contains(v) ? v! : strictRouteAuto;
  }

  static int clampMtu(int v) => v.clamp(minMtu, maxMtu);

  static int clampUdpTimeout(int v) =>
      v.clamp(minUdpTimeoutSec, maxUdpTimeoutSec);

  Map<String, dynamic> toJson() => {
        'stack': stack,
        'mtu': mtu,
        'strictRoute': strictRoute,
        'udpTimeoutSec': udpTimeoutSec,
        'autoRoute': autoRoute,
        'blockIpv6Leak': blockIpv6Leak,
        'defaultsVersion': _defaultsVersion,
      };

  factory TunSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TunSettings();
    var stack = normalizeStack(json['stack'] as String?);
    var mtu = clampMtu((json['mtu'] as num?)?.toInt() ?? defaultMtu);

    // старая пара system/1400 лежит почти у всех без выбора, меняем только её и один раз
    final migrated = json['defaultsVersion'] == null;
    if (migrated && stack == _legacyDefaultStack && mtu == _legacyDefaultMtu) {
      stack = defaultStack;
      mtu = defaultMtu;
    }

    return TunSettings(
      stack: stack,
      mtu: mtu,
      strictRoute: normalizeStrictRoute(json['strictRoute'] as String?),
      udpTimeoutSec: clampUdpTimeout(
        (json['udpTimeoutSec'] as num?)?.toInt() ?? defaultUdpTimeoutSec,
      ),
      autoRoute: json['autoRoute'] as bool? ?? true,
      blockIpv6Leak: json['blockIpv6Leak'] as bool? ?? true,
    );
  }

  TunSettings copyWith({
    String? stack,
    int? mtu,
    String? strictRoute,
    int? udpTimeoutSec,
    bool? autoRoute,
    bool? blockIpv6Leak,
  }) =>
      TunSettings(
        stack: stack ?? this.stack,
        mtu: mtu ?? this.mtu,
        strictRoute: strictRoute ?? this.strictRoute,
        udpTimeoutSec: udpTimeoutSec ?? this.udpTimeoutSec,
        autoRoute: autoRoute ?? this.autoRoute,
        blockIpv6Leak: blockIpv6Leak ?? this.blockIpv6Leak,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TunSettings &&
          runtimeType == other.runtimeType &&
          stack == other.stack &&
          mtu == other.mtu &&
          strictRoute == other.strictRoute &&
          udpTimeoutSec == other.udpTimeoutSec &&
          autoRoute == other.autoRoute &&
          blockIpv6Leak == other.blockIpv6Leak;

  @override
  int get hashCode => Object.hash(
        stack,
        mtu,
        strictRoute,
        udpTimeoutSec,
        autoRoute,
        blockIpv6Leak,
      );

  String toJsonString() => jsonEncode(toJson());

  factory TunSettings.fromJsonString(String s) =>
      TunSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
