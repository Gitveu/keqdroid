import 'server_item.dart';
import 'subscription.dart';

const String kChainsServerGroupKey = '__chains__';

const String kManualServerGroupKey = '__manual__';

enum ServerGroupKind { chains, subscription, manual }

class ServerGroupRef {
  final ServerGroupKind kind;

  final String key;

  final Subscription? subscription;

  final List<ServerItem> servers;

  const ServerGroupRef({
    required this.kind,
    required this.key,
    required this.subscription,
    required this.servers,
  });

  String get subscriptionName => subscription?.name.trim() ?? '';
}

List<ServerGroupRef> buildServerGroups({
  required List<ServerItem> servers,
  required List<Subscription> subscriptions,
}) {
  final chains = servers.where((s) => s.protocol == 'chain').toList();
  final manual = servers
      .where((s) => s.subscriptionId == null && s.protocol != 'chain')
      .toList();
  final bySubId = <String, List<ServerItem>>{};
  for (final s in servers.where((s) => s.subscriptionId != null)) {
    bySubId.putIfAbsent(s.subscriptionId!, () => []).add(s);
  }

  return [
    if (chains.isNotEmpty)
      ServerGroupRef(
        kind: ServerGroupKind.chains,
        key: kChainsServerGroupKey,
        subscription: null,
        servers: chains,
      ),
    for (final sub in subscriptions)
      if ((bySubId[sub.id] ?? const []).isNotEmpty)
        ServerGroupRef(
          kind: ServerGroupKind.subscription,
          key: sub.id,
          subscription: sub,
          servers: bySubId[sub.id]!,
        ),
    if (manual.isNotEmpty)
      ServerGroupRef(
        kind: ServerGroupKind.manual,
        key: kManualServerGroupKey,
        subscription: null,
        servers: manual,
      ),
  ];
}
