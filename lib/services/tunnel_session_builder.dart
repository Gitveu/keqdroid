import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../tunnel/app_routing_mode.dart';
import '../tunnel/connection_mode.dart';
import '../tunnel/tunnel_session_request.dart';
import '../tunnel/vpn_backend.dart';
import '../utils/singbox_tun_config.dart';

class TunnelSessionBuilder {
  static ConnectionMode resolveMode(
    AppSettings settings, {
    bool? isAndroid,
  }) {
    final android = isAndroid ?? Platform.isAndroid;
    // на Android сохранённый режим только если выбран руками, до 0.13.0 у всех лежит proxy
    if (android && !settings.connectionModeChosen) return ConnectionMode.tun;
    return ConnectionMode.fromStorage(settings.connectionMode);
  }

  static TunnelSessionRequest build({
    required AppSettings settings,
    required String xrayConfig,
    VpnBackend vpnBackend = VpnBackend.xray,
    String? mihomoConfig,
    required String resolvedServerIp,
    required String socksUsername,
    required String socksPassword,
    List<String> excludePackages = const [],
    List<String> includePackages = const [],
    List<String> excludeProcesses = const [],
    List<String> includeProcesses = const [],
    String? serverName,
    AppRoutingMode routingMode = AppRoutingMode.allProxy,
    ConnectionMode? modeOverride,
    bool hostHasIpv6 = false,
  }) {
    final mode = modeOverride ?? resolveMode(settings);

    String? singboxConfig;
    if ((Platform.isWindows || Platform.isLinux) && mode == ConnectionMode.tun) {
      final managed = switch (routingMode) {
        AppRoutingMode.onlySelected => includeProcesses,
        AppRoutingMode.allExceptSelected => excludeProcesses,
        AppRoutingMode.allProxy => const <String>[],
      };
      singboxConfig = SingBoxTunConfigGen.generate(
        localSocksPort: settings.localPort,
        socksUsername: socksUsername,
        socksPassword: socksPassword,
        serverIpToExclude: resolvedServerIp,
        settings: settings,
        managedProcessNames: managed,
        routingMode: routingMode,
        appProcessName: p.basename(Platform.resolvedExecutable),
        hostHasIpv6: hostHasIpv6,
      );
    }

    return TunnelSessionRequest(
      mode: mode,
      vpnBackend: vpnBackend,
      xrayConfig: xrayConfig,
      mihomoConfig: mihomoConfig,
      socksPort: settings.localPort,
      httpPort: settings.httpPort,
      singboxConfig: singboxConfig,
      excludePackages: excludePackages,
      includePackages: includePackages,
      excludeProcesses: excludeProcesses,
      includeProcesses: includeProcesses,
      serverName: serverName,
      systemProxy: settings.systemProxyEnabled,
      coreEngine: settings.coreEngine,
      debugMode: settings.debugMode,
    );
  }
}
