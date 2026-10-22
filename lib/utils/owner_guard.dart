import '../tunnel/app_routing_mode.dart';

// так мост отвечает ядру, когда Android назвал соединение чужим для нашего VPN (INVALID_UID): приложение вне VPN
// привязалось к tun0. то же имя в ConnectionOwnerServer.kt и tool/patches/mihomo-uid-owner-guard.patch
const kOutsideVpnOwner = 'keqdroid:outside-vpn';

enum OwnerGuard {
  off,

  // только выбранные: системный DNS и DoT Частного DNS идут в туннель от AID_DNS, а он тут вне VPN.
  // DNS (53) и DoT (853) пропускаем, иначе у выбранных приложений пропадёт интернет
  connections,

  all,
}

OwnerGuard ownerGuardFor({
  required bool enabled,
  required AppRoutingMode routingMode,
}) {
  if (!enabled) return OwnerGuard.off;
  return routingMode == AppRoutingMode.onlySelected
      ? OwnerGuard.connections
      : OwnerGuard.all;
}
