part of '../settings_tab.dart';

/// Вход в экран для виджет-теста: сам экран приватный, а путь к нему через
/// «Дополнительно» тесту не нужен.
@visibleForTesting
Widget routingScreenForTest() => const _RoutingScreen();

// Цвет, значок и слово «куда» одни на строке маршрута, в шторке выбора и в
// «Всём остальном»: одно действие на экране выглядит одинаково везде.

Color _targetColor(BuildContext context, RouteTarget target) =>
    switch (target) {
      RouteTarget.direct => AppTheme.green(context),
      RouteTarget.block => AppTheme.red(context),
      RouteTarget.vpn || RouteTarget.server => AppTheme.accent(context),
    };

IconData _targetIcon(RouteTarget target) => switch (target) {
      RouteTarget.direct => Icons.call_made_rounded,
      RouteTarget.block => Icons.block_rounded,
      RouteTarget.vpn => Icons.vpn_lock_rounded,
      RouteTarget.server => Icons.dns_rounded,
    };

/// «Всё остальное» — то же «куда», только без другого сервера.
RouteTarget _finalTarget(String finalOutbound) => switch (finalOutbound) {
      AppSettings.finalOutboundDirect => RouteTarget.direct,
      AppSettings.finalOutboundBlock => RouteTarget.block,
      _ => RouteTarget.vpn,
    };

String _finalOutboundOf(RouteTarget target) => switch (target) {
      RouteTarget.direct => AppSettings.finalOutboundDirect,
      RouteTarget.block => AppSettings.finalOutboundBlock,
      _ => AppSettings.finalOutboundProxy,
    };

String _presetName(AppLocalizations l10n, String id) => switch (id) {
      'ru' => l10n.settingsRoutingPresetRuTitle,
      'ads' => l10n.settingsRoutingPresetAdsTitle,
      'refilter' => l10n.settingsRoutingPresetRefilterTitle,
      _ => id,
    };

IconData _presetIcon(String id) => switch (id) {
      'ru' => Icons.flag_rounded,
      'ads' => Icons.block_rounded,
      'refilter' => Icons.shield_rounded,
      _ => Icons.playlist_add_check_rounded,
    };

IconData _contentIcon(TrafficRoute route) => switch (route.content) {
      RouteContent.allTraffic => Icons.all_inclusive_rounded,
      RouteContent.sites => Icons.language_rounded,
      RouteContent.preset => _presetIcon(route.presetId),
    };

/// Имя приложения из записи сплита: путь режется до файла, `.exe` у имени
/// процесса на экране лишний.
String _appLabel(String entry) {
  var name = normalizeProcessName(entry);
  if (name.toLowerCase().endsWith('.exe')) {
    name = name.substring(0, name.length - 4);
  }
  return name;
}

/// Значок маршрута приложений — первого из них: у записи с путём это иконка
/// самой программы, у имени — его буква, как в шторке «Кто».
Widget _appsBadge(List<String> apps, AppIconCache cache) => AppIconView(
      iconBase64: null,
      appName: _appLabel(apps.first),
      iconPath: isProcessPathEntry(apps.first) ? apps.first : null,
      cache: cache,
    );

/// Почему маршрут работает не так, как написан; null — работает.
String? _routeIssue(
  AppLocalizations l10n,
  TrafficRoute route,
  RouteCapabilities caps,
  List<ServerItem> servers,
  SplitTunnelingState split,
) {
  if (!route.allApps) {
    if (!caps.apps) {
      return caps.appsNeedTun
          ? l10n.routeAppsNeedTun
          : l10n.routeAppsUnsupported;
    }
    final outside = appsOutsideSplit(
      route.apps,
      include: split.includePackages,
      exclude: split.excludePackages,
    );
    if (outside.isNotEmpty) {
      return l10n.routeSplitExcluded(
        ltrIsolate(outside.map(_appLabel).join(', ')),
      );
    }
  }
  if (route.target == RouteTarget.server) {
    final server = servers.where((s) => s.id == route.serverId).firstOrNull;
    if (server == null) return l10n.routeServerMissing;
    if (!caps.servers || !routeServerSupported(server.config, caps.core)) {
      return l10n.routeServerUnsupported;
    }
  }
  return null;
}

ServerItem? _routeServer(TrafficRoute route, List<ServerItem> servers) =>
    route.target == RouteTarget.server
        ? servers.where((s) => s.id == route.serverId).firstOrNull
        : null;

/// «Куда» строкой: у другого сервера — его имя.
String _targetLabel(
  AppLocalizations l10n,
  TrafficRoute route,
  List<ServerItem> servers,
) =>
    switch (route.target) {
      RouteTarget.vpn => l10n.routeToVpn,
      RouteTarget.direct => l10n.routeToDirect,
      RouteTarget.block => l10n.routeToBlock,
      RouteTarget.server =>
        servers.where((s) => s.id == route.serverId).firstOrNull?.displayName ??
            l10n.routeToVpn,
    };

/// «Что» строкой: список сайтов, имя готового списка или «весь трафик».
/// Ссылка на список — именем хоста, как под полем: полный адрес съел бы
/// всю строку, не сказав ничего нового.
String _contentLabel(AppLocalizations l10n, TrafficRoute route) {
  switch (route.content) {
    case RouteContent.allTraffic:
      return l10n.routeAllTrafficShort;
    case RouteContent.preset:
      return _presetName(l10n, route.presetId);
    case RouteContent.sites:
      final entries = routingEntries(route.sites);
      if (entries.isEmpty) return l10n.settingsRoutingItemCount(0);
      return [
        for (final e in entries)
          if (isRuleListUrl(e))
            ltrIsolate(Uri.tryParse(e)?.host.nonEmptyOr(e) ?? e)
          else
            e,
      ].join(', ');
  }
}

extension on String {
  String nonEmptyOr(String fallback) => isEmpty ? fallback : this;
}

class _RoutingScreen extends ConsumerWidget {
  const _RoutingScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Маршруты читаются только в момент connect() — при активном туннеле
    // изменения вступят в силу после переподключения.
    final vpnStatus = ref.watch(
      vpnStateProvider.select((a) => a.value?.status),
    );
    final tunnelActive = vpnStatus == VpnStatus.connected ||
        vpnStatus == VpnStatus.connecting;
    final routes = ref.watch(routesProvider).value ?? const <TrafficRoute>[];
    final hint = ref.watch(routesHintProvider);
    final caps = ref.watch(routeCapabilitiesProvider);
    final servers = ref.watch(serversProvider.select((s) => s.servers));
    final split = ref.watch(splitTunnelingProvider);
    final iconCache = ref.read(appIconCacheProvider);
    final finalTarget = _finalTarget(
      ref.watch(
        settingsNotifierProvider.select(
          (a) => a.value?.finalOutbound ?? AppSettings.finalOutboundProxy,
        ),
      ),
    );

    Widget tile(TrafficRoute route) => _RouteTile(
          route: route,
          servers: servers,
          iconCache: iconCache,
          issue: _routeIssue(l10n, route, caps, servers, split),
          onTap: () => _openRouteEditor(context, route),
        );

    final block = routesIn(RouteSection.block, routes);
    final apps = routesIn(RouteSection.apps, routes);
    final allApps = routesIn(RouteSection.allApps, routes);

    return ExpressivePage(
      title: l10n.settingsRoutingTitle,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        ExpressiveSpacing.large,
        ExpressiveSpacing.none,
        ExpressiveSpacing.large,
        ExpressiveSpacing.extraLargeIncreased,
      ),
      actions: [
        IconButton(
          tooltip: l10n.routingCheatSheetTitle,
          icon: const Icon(Icons.help_outline_rounded),
          onPressed: () => _showRoutingCheatSheet(context, l10n),
        ),
      ],
      children: [
        if (tunnelActive)
          ExpressiveNotice(
            color: AppTheme.orange(context),
            icon: Icons.info_outline_rounded,
            text: l10n.splitTunnelingReconnectHint,
            action: TextButton(
              // Пока туннель поднимается, второе нажатие ничего бы не дало:
              // переподключение само дождётся текущего.
              onPressed: vpnStatus == VpnStatus.connected
                  ? () => unawaited(_reconnect(ref))
                  : null,
              child: Text(l10n.settingsRoutingReconnect),
            ),
          ),
        if (hint)
          ExpressiveNotice(
            color: Theme.of(context).colorScheme.primary,
            icon: Icons.info_outline_rounded,
            text: l10n.routesHint,
            action: TextButton(
              onPressed: () =>
                  unawaited(ref.read(routesHintProvider.notifier).dismiss()),
              child: Text(l10n.routesHintDismiss),
            ),
          ),
        // Пустые разделы не показываются: заголовок над пустотой читался бы
        // как недогруженный список.
        if (block.isNotEmpty) ...[
          ExpressiveSectionHeader(l10n.routesSectionBlock),
          ExpressiveGroup(children: [for (final r in block) tile(r)]),
        ],
        if (apps.isNotEmpty) ...[
          ExpressiveSectionHeader(l10n.routesSectionApps),
          ExpressiveGroup(children: [for (final r in apps) tile(r)]),
        ],
        ExpressiveSectionHeader(l10n.routesSectionAllApps),
        ExpressiveGroup(
          children: [
            for (final r in allApps) tile(r),
            _FinalRouteTile(
              target: finalTarget,
              onTap: () => _pickFinalTarget(context, ref, finalTarget),
            ),
          ],
        ),
        const SizedBox(height: ExpressiveSpacing.large),
        ExpressiveGroup(
          children: [
            ExpressiveGroupTile(
              onTap: () => _openRouteEditor(context, null),
              child: _RouteRowContent(
                badge: const ExpressiveIconBadge(icon: Icons.add_rounded),
                title: Text(l10n.routeNew),
                subtitle: Text(
                  caps.appsOffered
                      ? l10n.routeNewSubtitle
                      : l10n.routeNewSubtitleSites,
                ),
                chevron: false,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static Future<void> _reconnect(WidgetRef ref) async {
    try {
      await ref.read(vpnStateProvider.notifier).reconnectToActiveServer();
    } catch (_) {
      // Исход подключения показывает сам экран VPN, здесь его не дублируем.
    }
  }

  static void _openRouteEditor(BuildContext context, TrafficRoute? route) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _RouteEditorScreen(initial: route)),
    );
  }

  static Future<void> _pickFinalTarget(
    BuildContext context,
    WidgetRef ref,
    RouteTarget current,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await _showTargetSheet(
      context,
      title: l10n.settingsRoutingFinalTitle,
      current: current,
    );
    if (picked == null) return;
    final settings = ref.read(settingsNotifierProvider).value;
    if (settings == null) return;
    await ref
        .read(settingsNotifierProvider.notifier)
        .save(settings.copyWith(finalOutbound: _finalOutboundOf(picked)));
  }
}

/// Значок, две строки и стрелка — тот же склад, что у пунктов настроек.
class _RouteRowContent extends StatelessWidget {
  const _RouteRowContent({
    required this.badge,
    required this.title,
    required this.subtitle,
    this.chevron = true,
    this.dimmed = false,
    this.note,
  });

  final Widget badge;
  final Widget title;
  final Widget subtitle;
  final bool chevron;

  /// Третья строка — почему маршрут не работает. Своей строкой, а не в хвосте
  /// подписи: там её обрезал бы длинный список сайтов.
  final Widget? note;

  /// Выключенный маршрут бледнее: на месте и редактируется, но не действует.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final row = Row(
      children: [
        badge,
        const SizedBox(width: ExpressiveSpacing.large),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle.merge(
                style: textTheme.titleMedium
                    ?.copyWith(color: AppTheme.text(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: title,
              ),
              DefaultTextStyle.merge(
                style: textTheme.bodyMedium
                    ?.copyWith(color: AppTheme.textLight(context)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                child: subtitle,
              ),
              if (note != null)
                DefaultTextStyle.merge(
                  style: textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  child: note!,
                ),
            ],
          ),
        ),
        if (chevron)
          Icon(Icons.chevron_right_rounded, color: AppTheme.textLight(context)),
      ],
    );
    return dimmed ? Opacity(opacity: 0.5, child: row) : row;
  }
}

/// Строка маршрута: сверху «кто» (у маршрута для всех приложений — сами
/// сайты или имя готового списка), снизу «→ куда · что». «Куда» стоит первым,
/// чтобы при нехватке места обрезался список сайтов, а не сервер.
class _RouteTile extends StatelessWidget {
  const _RouteTile({
    required this.route,
    required this.servers,
    required this.iconCache,
    required this.issue,
    required this.onTap,
  });

  final TrafficRoute route;
  final List<ServerItem> servers;
  final AppIconCache iconCache;
  final String? issue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = _targetColor(context, route.target);
    final title = route.allApps
        ? _contentLabel(l10n, route)
        : route.apps.map(_appLabel).join(', ');
    final details = [
      if (!route.allApps) _contentLabel(l10n, route),
      if (!route.enabled) l10n.routeDisabledShort,
    ];
    return ExpressiveGroupTile(
      onTap: onTap,
      child: _RouteRowContent(
        dimmed: !route.enabled,
        badge: route.allApps
            ? ExpressiveIconBadge(icon: _contentIcon(route))
            : _appsBadge(route.apps, iconCache),
        title: Text(title),
        note: issue == null ? null : Text(issue!),
        subtitle: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: '→ '),
              // Флаг сервера — тем же значком, что в списке серверов: имя
              // «Германия» у трёх провайдеров одинаковое, а вид флага тот же.
              if (_routeServer(route, servers) case final server?)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(end: 4),
                    child: ServerAvatar(
                      flag: server.flag,
                      protocol: server.protocol,
                      size: 18,
                    ),
                  ),
                ),
              TextSpan(
                text: _targetLabel(l10n, route, servers),
                style: TextStyle(color: color),
              ),
              for (final d in details) TextSpan(text: ' · $d'),
            ],
          ),
        ),
      ),
    );
  }
}

class _FinalRouteTile extends StatelessWidget {
  const _FinalRouteTile({required this.target, required this.onTap});

  final RouteTarget target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return ExpressiveGroupTile(
      onTap: onTap,
      child: _RouteRowContent(
        badge: ExpressiveIconBadge(
          icon: Icons.alt_route_rounded,
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
        ),
        title: Text(l10n.settingsRoutingFinalTitle),
        subtitle: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: '→ '),
              TextSpan(
                text: switch (target) {
                  RouteTarget.direct => l10n.routeToDirect,
                  RouteTarget.block => l10n.routeToBlock,
                  _ => l10n.routeToVpn,
                },
                style: TextStyle(color: _targetColor(context, target)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Шторка выбора: заголовок и группы пунктов, выбор в одно нажатие.
Future<T?> _showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<Widget> Function(BuildContext sheetContext) children,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  child: Text(
                    title,
                    style: theme.textTheme
                        .emphasized(theme.textTheme.titleMedium)
                        ?.copyWith(color: AppTheme.text(ctx)),
                  ),
                ),
                ...children(ctx),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// «Куда»: через VPN, напрямую, блокировать и — у маршрута, не у «Всего
/// остального» — раздел «Другой сервер» с пунктом [serverTile].
Future<RouteTarget?> _showTargetSheet(
  BuildContext context, {
  required String title,
  required RouteTarget current,
  Widget Function(BuildContext sheetContext)? serverTile,
}) {
  final l10n = AppLocalizations.of(context)!;
  return _showChoiceSheet<RouteTarget>(
    context,
    title: title,
    children: (ctx) => [
      ExpressiveGroup(
        children: [
          for (final (target, name, subtitle) in [
            (RouteTarget.vpn, l10n.settingsRoutingProxyTitle,
                l10n.routeWhereVpnSubtitle),
            (RouteTarget.direct, l10n.settingsRoutingDirectTitle,
                l10n.routeWhereDirectSubtitle),
            (RouteTarget.block, l10n.settingsRoutingBlockTitle,
                l10n.routeWhereBlockSubtitle),
          ])
            ExpressiveActionTile(
              icon: _targetIcon(target),
              title: name,
              subtitle: subtitle,
              selected: current == target,
              onTap: () => Navigator.pop(ctx, target),
            ),
        ],
      ),
      if (serverTile != null) ...[
        ExpressiveSectionHeader(l10n.routeWhereServers),
        ExpressiveGroup(children: [serverTile(ctx)]),
      ],
    ],
  );
}

// ── Шпаргалка «как писать правила» ─────────────────────────────────────────

void _showRoutingCheatSheet(BuildContext context, AppLocalizations l10n) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.routingCheatSheetTitle,
              style: Theme.of(ctx)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: AppTheme.text(ctx)),
            ),
            const SizedBox(height: 10),
            ..._cheatLines(ctx, l10n.routingCheatSheetBody),
          ],
        ),
      ),
    ),
  );
}

/// Разбивает текст шпаргалки на строки; строки с префиксом `## ` рисуются как
/// заголовки секций (акцентом), остальные — обычным текстом. Так один
/// локализованный текст остаётся живой заметкой, а не стеной.
List<Widget> _cheatLines(BuildContext context, String body) {
  final out = <Widget>[];
  for (final raw in body.split('\n')) {
    final isHeader = raw.startsWith('## ');
    if (raw.trim().isEmpty) {
      out.add(const SizedBox(height: 10));
      continue;
    }
    out.add(Padding(
      padding: EdgeInsets.only(top: isHeader ? 8 : 1, bottom: isHeader ? 4 : 1),
      child: Text(
        isHeader ? raw.substring(3) : raw,
        style: isHeader
            ? Theme.of(context)
                .textTheme
                .emphasized(Theme.of(context).textTheme.labelLarge)
                ?.copyWith(
                  letterSpacing: 0.3,
                  color: AppTheme.accent(context),
                )
            : Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: AppTheme.text(context),
                ),
      ),
    ));
  }
  return out;
}
