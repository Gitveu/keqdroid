// так мост отвечает ядру, когда Android назвал соединение чужим для нашего VPN (INVALID_UID): приложение вне VPN
// привязалось к tun0. то же имя в ConnectionOwnerServer.kt и tool/patches/mihomo-uid-owner-guard.patch
const kOutsideVpnOwner = 'keqdroid:outside-vpn';

// DNS самого Android в режиме только выбранные тоже приходит без владельца: его мост узнаёт по адресу и маркером не называет
enum OwnerGuard { off, all }

OwnerGuard ownerGuardFor({required bool enabled}) =>
    enabled ? OwnerGuard.all : OwnerGuard.off;
