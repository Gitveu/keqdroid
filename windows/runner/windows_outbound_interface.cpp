#include "windows_outbound_interface.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include <climits>

namespace {

bool ReadIpInterface(const NET_LUID& luid,
                     ADDRESS_FAMILY family,
                     ULONG* metric,
                     bool* connected) {
  MIB_IPINTERFACE_ROW row;
  ::InitializeIpInterfaceEntry(&row);
  row.Family = family;
  row.InterfaceLuid = luid;
  if (::GetIpInterfaceEntry(&row) != NO_ERROR) {
    return false;
  }
  *metric = row.Metric;
  *connected = row.Connected != FALSE;
  return true;
}

}  // namespace

std::wstring FindTunBypassInterface(uint32_t tun_index, bool mihomo_rule) {
  PMIB_IPFORWARD_TABLE2 table = nullptr;
  if (::GetIpForwardTable2(mihomo_rule ? AF_INET : AF_UNSPEC, &table) !=
      NO_ERROR) {
    return L"";
  }

  ULONG best = ULONG_MAX;
  ULONG best_wifi = ULONG_MAX;
  bool found = false;
  bool found_wifi = false;
  NET_LUID luid = {};
  NET_LUID luid_wifi = {};

  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IPFORWARD_ROW2& route = table->Table[i];
    if (route.DestinationPrefix.PrefixLength != 0 ||
        route.InterfaceIndex == tun_index) {
      continue;
    }
    MIB_IF_ROW2 ifrow = {};
    ifrow.InterfaceLuid = route.InterfaceLuid;
    if (::GetIfEntry2(&ifrow) != NO_ERROR ||
        ifrow.OperStatus != IfOperStatusUp) {
      continue;
    }

    ULONG if_metric = 0;
    bool connected = false;
    if (mihomo_rule) {
      if (ifrow.Type == IF_TYPE_PROP_VIRTUAL ||
          ifrow.Type == IF_TYPE_SOFTWARE_LOOPBACK) {
        continue;
      }
      if (!ReadIpInterface(route.InterfaceLuid, AF_INET, &if_metric,
                           &connected) ||
          !connected) {
        continue;
      }
    } else if (!ReadIpInterface(route.InterfaceLuid, AF_INET, &if_metric,
                                &connected) &&
               !ReadIpInterface(route.InterfaceLuid, AF_INET6, &if_metric,
                                &connected)) {
      continue;
    }

    const ULONG metric = route.Metric + if_metric;
    // xray отдаёт Wi-Fi первенство над любым проводом, у sing-tun решает только метрика
    if (!mihomo_rule && ifrow.Type == IF_TYPE_IEEE80211) {
      if (metric < best_wifi) {
        best_wifi = metric;
        luid_wifi = route.InterfaceLuid;
        found_wifi = true;
      }
      continue;
    }
    if (metric < best) {
      best = metric;
      luid = route.InterfaceLuid;
      found = true;
    }
  }
  ::FreeMibTable(table);

  if (found_wifi) {
    luid = luid_wifi;
    found = true;
  }
  if (!found) {
    return L"";
  }
  WCHAR alias[NDIS_IF_MAX_STRING_SIZE + 1] = {};
  if (::ConvertInterfaceLuidToAlias(&luid, alias, NDIS_IF_MAX_STRING_SIZE + 1) !=
      NO_ERROR) {
    return L"";
  }
  return alias;
}
